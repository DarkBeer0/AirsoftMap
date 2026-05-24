import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/session/game_session.dart';

/// Боевая карта. Пока — онлайн OpenTopoMap + собственная позиция через
/// нативный location-слой MapLibre. В фазе 2 переключим source на
/// локальный MBTiles-сервер; в фазе 3 добавим WS-слой союзников и меток.
class BattleMapScreen extends ConsumerStatefulWidget {
  const BattleMapScreen({super.key});

  @override
  ConsumerState<BattleMapScreen> createState() => _BattleMapScreenState();
}

class _BattleMapScreenState extends ConsumerState<BattleMapScreen> {
  // Стиль MapLibre: один raster-источник OpenTopoMap.
  // Атрибуция OpenTopoMap (CC-BY-SA) обязательна — показываем её в углу.
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

  bool _locationGranted = false;
  String? _permissionError;

  @override
  void initState() {
    super.initState();
    _requestLocation();
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

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(gameSessionProvider);
    return Scaffold(
      body: Stack(
        children: [
          MapLibreMap(
            styleString: _onlineStyle,
            initialCameraPosition: const CameraPosition(
              // Дефолтный центр пока bbox игры не пришёл. Москва как нейтральная точка.
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
                  _PermissionBanner(
                    message: _permissionError!,
                    onRetry: _requestLocation,
                  ),
                ],
              ],
            ),
          ),
          // Атрибуция OpenTopoMap — обязательна по лицензии CC-BY-SA.
          const Positioned(
            left: 8,
            bottom: 8,
            child: _Attribution(),
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
    // У организатора стороны нет — показываем нейтральную серую точку
    // и подпись «Organizer» вместо названия стороны.
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
              width: 14,
              height: 14,
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

class _PermissionBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _PermissionBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.orange.shade800,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
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
  const _Attribution();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '© OpenStreetMap · OpenTopoMap (CC-BY-SA)',
        style: TextStyle(color: Colors.white, fontSize: 10),
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
