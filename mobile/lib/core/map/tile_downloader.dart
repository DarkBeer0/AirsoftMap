import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sqlite3/sqlite3.dart';

/// Скачивает тайлы OpenTopoMap для bbox / zooms и пакует в MBTiles SQLite.
///
/// Закрывает риски фазы 1:
///   C2 — кастомный User-Agent (OpenTopoMap может банить пустой), retry с backoff,
///        connect/receive timeouts.
///   C3 — настоящий пул worker'ов на shared iterator (если один тайл застрянет —
///        остальные продолжат).
///   C4 — batched INSERT в одной транзакции (по умолчанию 200), без отдельного
///        commit на каждый тайл.
///   C5 — MBTiles metadata (name/type/format/bounds/minzoom/maxzoom/attribution) —
///        без неё некоторые читатели карты (включая будущий MapLibre verify) ругаются.
///
/// Лицензия OpenTopoMap (CC-BY-SA 3.0) разрешает оффлайн-кэш при атрибуции —
/// показываем её в углу боевой карты.
class TileDownloader {
  static const _tileUrl = 'https://tile.opentopomap.org/{z}/{x}/{y}.png';
  static const _userAgent =
      'AirsoftMap/0.1 (tactical map for airsoft; contact via github)';

  final Dio _dio;
  final int concurrency;
  final int maxRetries;
  final int batchSize;

  TileDownloader({
    Dio? dio,
    this.concurrency = 4,
    this.maxRetries = 3,
    this.batchSize = 200,
  }) : _dio = dio ??
            Dio(BaseOptions(
              headers: {'User-Agent': _userAgent},
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              responseType: ResponseType.bytes,
            ));

  /// Список (z, x, y) для bbox в WGS84 (lng/lat).
  static List<TileCoord> tilesForBbox({
    required double minLng,
    required double minLat,
    required double maxLng,
    required double maxLat,
    required int minZoom,
    required int maxZoom,
  }) {
    final tiles = <TileCoord>[];
    for (var z = minZoom; z <= maxZoom; z++) {
      final tl = _lngLatToTile(minLng, maxLat, z);
      final br = _lngLatToTile(maxLng, minLat, z);
      for (var x = tl.x; x <= br.x; x++) {
        for (var y = tl.y; y <= br.y; y++) {
          tiles.add(TileCoord(z, x, y));
        }
      }
    }
    return tiles;
  }

  /// Грубая оценка размера итогового файла в байтах.
  /// OpenTopoMap PNG — обычно 15–30 KB/тайл; берём верхнюю границу с запасом.
  static int estimateBytes(int tileCount) => tileCount * 28 * 1024;

  /// Скачивание с очередью worker-ов, ретраями, batched-commit и записью metadata.
  ///
  /// Все worker-ы берут следующий тайл из общего итератора атомарно (Dart
  /// однопоточный, между `moveNext` и взятием `current` нет await — гонок нет).
  Future<DownloadResult> downloadToMbtiles({
    required List<TileCoord> tiles,
    required String outputPath,
    required double bboxMinLng,
    required double bboxMinLat,
    required double bboxMaxLng,
    required double bboxMaxLat,
    required int minZoom,
    required int maxZoom,
    String name = 'AirsoftMap pack',
    void Function(int done, int total)? onProgress,
  }) async {
    final db = sqlite3.open(outputPath);
    try {
      _initMbtilesSchema(db);
      _writeMetadata(
        db,
        name: name,
        minZoom: minZoom,
        maxZoom: maxZoom,
        bbox: [bboxMinLng, bboxMinLat, bboxMaxLng, bboxMaxLat],
      );

      final iter = tiles.iterator;
      var done = 0;
      var failed = 0;
      final pending = <_PendingTile>[];

      void flush() {
        if (pending.isEmpty) return;
        db.execute('BEGIN');
        try {
          final stmt = db.prepare(
            'INSERT OR REPLACE INTO tiles(zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)',
          );
          try {
            for (final p in pending) {
              stmt.execute([p.z, p.x, p.y, p.data]);
            }
          } finally {
            stmt.dispose();
          }
          db.execute('COMMIT');
        } catch (e) {
          db.execute('ROLLBACK');
          rethrow;
        }
        pending.clear();
      }

      Future<void> worker() async {
        while (true) {
          if (!iter.moveNext()) return;
          final t = iter.current;
          final data = await _fetchWithRetry(t);
          if (data != null) {
            // XYZ → TMS row order: y_tms = 2^z - 1 - y_xyz
            final yTms = (1 << t.z) - 1 - t.y;
            pending.add(_PendingTile(t.z, t.x, yTms, data));
            // flush — синхронный (db.execute блокирует event loop) → race
            // с другими worker-ами не страшен; они в этот момент висят на await.
            if (pending.length >= batchSize) flush();
          } else {
            failed++;
          }
          done++;
          onProgress?.call(done, tiles.length);
        }
      }

      await Future.wait(
        List.generate(concurrency, (_) => worker()),
      );
      flush(); // последний хвост

      return DownloadResult(
        total: tiles.length,
        downloaded: tiles.length - failed,
        failed: failed,
        sizeBytes: File(outputPath).lengthSync(),
      );
    } finally {
      db.dispose();
    }
  }

  Future<Uint8List?> _fetchWithRetry(TileCoord t) async {
    final url = _tileUrl
        .replaceAll('{z}', '${t.z}')
        .replaceAll('{x}', '${t.x}')
        .replaceAll('{y}', '${t.y}');
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final res = await _dio.get<List<int>>(url);
        final data = res.data;
        if (data != null && data.isNotEmpty) {
          return Uint8List.fromList(data);
        }
      } on DioException catch (_) {
        // ниже подождём перед следующей попыткой
      } catch (_) {
        // unexpected — выходим из ретраев
        return null;
      }
      if (attempt < maxRetries - 1) {
        await Future.delayed(Duration(milliseconds: 400 * (1 << attempt)));
      }
    }
    return null;
  }

  static TileCoord _lngLatToTile(double lng, double lat, int z) {
    final n = 1 << z;
    final x = ((lng + 180) / 360 * n).floor();
    final latRad = lat * math.pi / 180;
    final y = ((1 -
                math.log(math.tan(latRad) + 1 / math.cos(latRad)) /
                    math.pi) /
            2 *
            n)
        .floor();
    return TileCoord(z, x, y);
  }

  static void _initMbtilesSchema(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS metadata (name TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE IF NOT EXISTS tiles (
        zoom_level INTEGER,
        tile_column INTEGER,
        tile_row INTEGER,
        tile_data BLOB,
        PRIMARY KEY (zoom_level, tile_column, tile_row)
      );
    ''');
  }

  static void _writeMetadata(
    Database db, {
    required String name,
    required int minZoom,
    required int maxZoom,
    required List<double> bbox,
  }) {
    final entries = <String, String>{
      'name': name,
      'type': 'baselayer',
      'format': 'png',
      'version': '1',
      'minzoom': '$minZoom',
      'maxzoom': '$maxZoom',
      'bounds': bbox.map((v) => v.toStringAsFixed(6)).join(','),
      'attribution':
          '© OpenStreetMap contributors, SRTM | © OpenTopoMap (CC-BY-SA)',
    };
    final stmt = db.prepare(
      'INSERT OR REPLACE INTO metadata(name, value) VALUES (?, ?)',
    );
    try {
      for (final e in entries.entries) {
        stmt.execute([e.key, e.value]);
      }
    } finally {
      stmt.dispose();
    }
  }
}

class TileCoord {
  final int z;
  final int x;
  final int y;
  const TileCoord(this.z, this.x, this.y);
}

class DownloadResult {
  final int total;
  final int downloaded;
  final int failed;
  final int sizeBytes;
  const DownloadResult({
    required this.total,
    required this.downloaded,
    required this.failed,
    required this.sizeBytes,
  });
}

class _PendingTile {
  final int z, x, y;
  final Uint8List data;
  _PendingTile(this.z, this.x, this.y, this.data);
}
