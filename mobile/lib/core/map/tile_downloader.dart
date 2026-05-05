import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:sqlite3/sqlite3.dart';

/// Скачивает тайлы OpenTopoMap для bbox / zooms и пакует в MBTiles SQLite.
///
/// Лицензия OpenTopoMap (CC BY-SA 3.0) разрешает оффлайн-кэш при атрибуции —
/// показываем её в углу карты.
class TileDownloader {
  static const _tileUrl =
      'https://tile.opentopomap.org/{z}/{x}/{y}.png'; // TODO: уважать лимиты

  final Dio _dio;
  final int concurrency;

  TileDownloader({Dio? dio, this.concurrency = 4}) : _dio = dio ?? Dio();

  /// Список (z, x, y) для bbox в lng/lat.
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

  /// Скачивает все тайлы и записывает в MBTiles по пути [outputPath].
  /// Возвращает реальный размер файла. Прогресс — через [onProgress] (0..1).
  Future<int> downloadToMbtiles({
    required List<TileCoord> tiles,
    required String outputPath,
    void Function(double progress)? onProgress,
  }) async {
    final db = sqlite3.open(outputPath);
    _initMbtilesSchema(db);

    var done = 0;
    final total = tiles.length;

    Future<void> worker(Iterable<TileCoord> chunk) async {
      for (final t in chunk) {
        final url = _tileUrl
            .replaceAll('{z}', '${t.z}')
            .replaceAll('{x}', '${t.x}')
            .replaceAll('{y}', '${t.y}');
        try {
          final res = await _dio.get<List<int>>(
            url,
            options: Options(responseType: ResponseType.bytes),
          );
          if (res.data != null) {
            // MBTiles использует TMS row order: y_tms = 2^z - 1 - y_xyz
            final yTms = (1 << t.z) - 1 - t.y;
            db.execute(
              'INSERT OR REPLACE INTO tiles(zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)',
              [t.z, t.x, yTms, res.data],
            );
          }
        } catch (_) {/* TODO: лог + ретрай */}
        done++;
        onProgress?.call(done / total);
      }
    }

    final chunkSize = (tiles.length / concurrency).ceil();
    final futures = <Future<void>>[];
    for (var i = 0; i < tiles.length; i += chunkSize) {
      final end = math.min(i + chunkSize, tiles.length);
      futures.add(worker(tiles.sublist(i, end)));
    }
    await Future.wait(futures);

    db.dispose();
    return File(outputPath).lengthSync();
  }

  static TileCoord _lngLatToTile(double lng, double lat, int z) {
    final n = 1 << z;
    final x = ((lng + 180) / 360 * n).floor();
    final latRad = lat * math.pi / 180;
    final y =
        ((1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
                2 *
                n)
            .floor();
    return TileCoord(z, x, y);
  }

  static void _initMbtilesSchema(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS metadata (name TEXT, value TEXT);
      CREATE TABLE IF NOT EXISTS tiles (
        zoom_level INTEGER,
        tile_column INTEGER,
        tile_row INTEGER,
        tile_data BLOB,
        PRIMARY KEY (zoom_level, tile_column, tile_row)
      );
    ''');
  }
}

class TileCoord {
  final int z;
  final int x;
  final int y;
  const TileCoord(this.z, this.x, this.y);
}
