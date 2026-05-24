import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Заливает .mbtiles в Supabase Storage и возвращает публичный URL.
///
/// Предполагается, что bucket `map-packs` уже создан в Supabase Dashboard
/// и помечен как PUBLIC (Storage → Buckets → New bucket → public). Иначе
/// нужно генерировать signed URL и хранить TTL в БД — это в Фазе 5.
///
/// `upsert: true` — если организатор перезаливает карту (исправил bbox),
/// файл перетирается; URL не меняется.
class MapPackUploader {
  static const bucket = 'map-packs';

  Future<String> upload(String gameId, File mbtiles) async {
    final storage = Supabase.instance.client.storage.from(bucket);
    final path = '$gameId.mbtiles';
    await storage.upload(
      path,
      mbtiles,
      fileOptions: const FileOptions(
        upsert: true,
        contentType: 'application/x-sqlite3',
      ),
    );
    return storage.getPublicUrl(path);
  }
}

final mapPackUploaderProvider = Provider<MapPackUploader>((ref) {
  return MapPackUploader();
});
