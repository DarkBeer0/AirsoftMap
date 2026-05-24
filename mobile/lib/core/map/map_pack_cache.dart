import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Кеш .mbtiles в documents/maps/. Одна и та же логика прежде дублировалась
/// в battle_map; теперь lobby тоже может запустить prefetch — battle_map
/// при start обнаружит файл уже на диске и сразу поднимет MbtilesServer.
class MapPackCache {
  static const _subdir = 'maps';

  /// Путь, по которому ляжет (или уже лежит) карта-пачка.
  Future<String> filePathFor(String gameId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, _subdir));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return p.join(dir.path, '$gameId.mbtiles');
  }

  Future<bool> existsFor(String gameId) async {
    final path = await filePathFor(gameId);
    final f = File(path);
    return f.existsSync() && f.lengthSync() > 0;
  }

  /// Скачать пачку, если ещё не лежит локально. Идемпотентно. Возвращает
  /// абсолютный путь к файлу.
  Future<String> ensure({
    required String gameId,
    required String url,
    void Function(double progress)? onProgress,
  }) async {
    final path = await filePathFor(gameId);
    if (await existsFor(gameId)) return path;

    final dio = Dio(BaseOptions(
      receiveTimeout: const Duration(minutes: 5),
      connectTimeout: const Duration(seconds: 15),
    ));

    final res = await dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
      onReceiveProgress: (received, total) {
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      },
    );
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw Exception('пустой ответ Storage');
    }
    File(path).writeAsBytesSync(data, flush: true);
    return path;
  }
}

final mapPackCacheProvider = Provider<MapPackCache>((ref) => MapPackCache());
