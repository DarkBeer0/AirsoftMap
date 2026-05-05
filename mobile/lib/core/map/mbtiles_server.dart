import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

/// Локальный HTTP-сервер на 127.0.0.1, отдающий тайлы из MBTiles.
/// MapLibre указывает raster source на `http://127.0.0.1:{port}/tiles/{z}/{x}/{y}.png`.
class MbtilesServer {
  HttpServer? _server;
  Database? _db;
  int? _port;

  int? get port => _port;
  String get tileUrl => 'http://127.0.0.1:$_port/tiles/{z}/{x}/{y}.png';

  Future<void> start(String mbtilesPath) async {
    await stop();
    _db = sqlite3.open(mbtilesPath, mode: OpenMode.readOnly);

    final router = Router()..get('/tiles/<z>/<x>/<y>.png', _serveTile);
    _server = await io.serve(router.call, InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
  }

  Response _serveTile(Request req, String z, String x, String y) {
    final db = _db;
    if (db == null) return Response.internalServerError();

    final zoom = int.tryParse(z);
    final col = int.tryParse(x);
    final row = int.tryParse(y);
    if (zoom == null || col == null || row == null) {
      return Response.badRequest();
    }

    // XYZ → TMS
    final yTms = (1 << zoom) - 1 - row;
    final res = db.select(
      'SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?',
      [zoom, col, yTms],
    );
    if (res.isEmpty) return Response.notFound('no tile');
    final data = res.first['tile_data'] as List<int>;
    return Response.ok(data, headers: {
      'content-type': 'image/png',
      'cache-control': 'public, max-age=86400',
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _db?.dispose();
    _db = null;
    _port = null;
  }
}
