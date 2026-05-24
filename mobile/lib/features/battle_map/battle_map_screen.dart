import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/map/mbtiles_server.dart';
import '../../core/session/game_session.dart';

/// Боевая карта. Если у сессии есть `mapPackUrl` — скачиваем .mbtiles
/// (или используем кэшированный), поднимаем локальный shelf-сервер и
/// рендерим MapLibre поверх него. Иначе — fallback на онлайн OpenTopoMap.
class BattleMapScreen extends ConsumerStatefulWidget {
  const BattleMapScreen({super.key});

  @override
  ConsumerState<BattleMapScreen> createState() => _BattleMapScreenState();
}

class _BattleMapScreenState extends ConsumerState<BattleMapScreen> {
  static const _onlineStyle = '''
{
  "version": 8,
  "sources": {
    "opentopomap": {
      "type": "raster",
      "tiles": [
        "https://a.tile.opentopomap.org/{z}/{x}/{y}.png",
        "https://b.tile.opentopomap.org/{z}/{x}/{y}.png",
        "https://c.tile.opentopomap.org/{z}/{x}/{y}.png"
      ],
      "tileSize": 256,
      "maxzoom": 17
    }
  },
  "layers": [
    {"id": "bg", "type": "background", "paint": {"background-color": "#cfd8dc"}},
    {"id": "opentopomap", "type": "raster", "source": "opentopomap"}
  ]
}
''';

  MbtilesServer? _mbtilesServer;
  String? _styleString;
  String? _statusMsg;
  bool _locationGranted = false;
  String? _permissionError;
  bool _usingOffline = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _mbtilesServer?.stop();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _requestLocation();

    final session = ref.read(gameSessionProvider);
    final url = session?.mapPackUrl;
    if (session == null || url == null || url.isEmpty) {
      // Оффлайн-пачки нет — работаем по онлайн-источнику.
      if (mounted) setState(() => _styleString = _onlineStyle);
      return;
    }

    try {
      final filePath = await _ensureMapPack(session.gameId, url);
      final server = MbtilesServer();
      await server.start(filePath);
      _mbtilesServer = server;
      if (mounted) {
        setState(() {
          _styleString = _buildOfflineStyle(server.tileUrl);
          _usingOffline = true;
        });
      }
    } catch (e) {
      // Любая ошибка (скачивания, sqlite, shelf) — fallback на онлайн,
      // чтобы организатор/боец не остался без карты вообще.
      if (mounted) {
        setState(() {
          _styleString = _onlineStyle;
          _statusMsg = 'Оффлайн-карта недоступна, перешли на онлайн: $e';
        });
      }
    }
  }

  Future<String> _ensureMapPack(String gameId, String url) async {
    final docs = await getApplicationDocumentsDirectory();
    final mapsDir = Directory(p.join(docs.path, 'maps'));
    if (!mapsDir.existsSync()) mapsDir.createSync(recursive: true);
    final filePath = p.join(mapsDir.path, '$gameId.mbtiles');
    final file = File(filePath);
    if (file.existsSync() && file.lengthSync() > 0) {
      return filePath; // уже кэширован (организатор/повторный заход)
    }
    if (mounted) setState(() => _statusMsg = 'Скачиваю карту полигона…');
    final dio = Dio(BaseOptions(
      receiveTimeout: const Duration(minutes: 5),
      connectTimeout: const Duration(seconds: 15),
    ));
    final res = await dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw Exception('пустой ответ Storage');
    }
    file.writeAsBytesSync(data, flush: true);
    if (mounted) setState(() => _statusMsg = null);
    return filePath;
  }

  Future<void> _requestLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      final granted = perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse;
      if (!mounted) return;
      setState(() {
        _locationGranted = granted;
        _permissionError = granted ? null : 'Нет разрешения на геолокацию';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _permissionError = 'GPS ошибка: $e');
    }
  }

  String _buildOfflineStyle(String tileUrl) => '''
{
  "version": 8,
  "sources": {
    "mbtiles": {
      "type": "raster",
      "tiles": ["$tileUrl"],
      "tileSize": 256,
      "maxzoom": 17
    }
  },
  "layers": [
    {"id": "bg", "type": "background", "paint": {"background-color": "#cfd8dc"}},
    {"id": "mbtiles", "type": "raster", "source": "mbtiles"}
  ]
}
''';

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(gameSessionProvider);

    if (_styleString == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          MapLibreMap(
            styleString: _styleString!,
            initialCameraPosition: const CameraPosition(
              // Дефолтный центр пока bbox игры не пришёл в сессию.
              target: LatLng(55.751244, 37.618423),
              zoom: 13,
            ),
            myLocationEnabled: _locationGranted,
            myLocationTrackingMode: _locationGranted
                ? MyLocationTrackingMode.tracking
                : MyLocationTrackingMode.none,
            myLocationRenderMode: MyLocationRenderMode.compass,
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: Column(
              children: [
                if (session != null) _SessionBadge(session: session),
                if (_permissionError != null) ...[
                  const SizedBox(height: 6),
                  _Banner(
                    message: _permissionError!,
                    color: Colors.orange.shade800,
                    icon: Icons.warning_amber,
                    onRetry: _requestLocation,
                  ),
                ],
                if (_statusMsg != null) ...[
                  const SizedBox(height: 6),
                  _Banner(
                    message: _statusMsg!,
                    color: Colors.blueGrey.shade800,
                    icon: Icons.info_outline,
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            left: 8,
            bottom: 8,
            child: _Attribution(offline: _usingOffline),
          ),
          Positioned(
            right: 16,
            bottom: 32,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              ),
              onPressed: () => context.go('/dead'),
              child: const Text(
                'УБИТ',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionBadge extends StatelessWidget {
  final GameSession session;
  const _SessionBadge({required this.session});

  @override
  Widget build(BuildContext context) {
    final color = session.sideColor != null
        ? (_parseHexColor(session.sideColor!) ?? Colors.green)
        : Colors.grey;
    final label = session.sideName ?? session.gameName;

    return Material(
      color: Colors.black.withOpacity(0.55),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 14, height: 14,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$label · ${session.callsign}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              session.role,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String message;
  final Color color;
  final IconData icon;
  final VoidCallback? onRetry;
  const _Banner({
    required this.message,
    required this.color,
    required this.icon,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            if (onRetry != null)
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('Повторить'),
              ),
          ],
        ),
      ),
    );
  }
}

class _Attribution extends StatelessWidget {
  final bool offline;
  const _Attribution({this.offline = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        offline
            ? '© OSM · OpenTopoMap (CC-BY-SA) · offline'
            : '© OpenStreetMap · OpenTopoMap (CC-BY-SA)',
        style: const TextStyle(color: Colors.white, fontSize: 10),
      ),
    );
  }
}

Color? _parseHexColor(String hex) {
  final s = hex.replaceAll('#', '').trim();
  if (s.length == 6) return Color(int.parse('FF$s', radix: 16));
  if (s.length == 8) return Color(int.parse(s, radix: 16));
  return null;
}
