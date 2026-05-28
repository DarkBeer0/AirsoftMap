import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api/events_api.dart';
import '../../core/api/games_api.dart';
import '../../core/api/markers_api.dart';
import '../../core/gps/geo.dart';
import '../../core/gps/gps_provider.dart';
import '../../core/gps/kalman_filter.dart';
import '../../core/gps/motion_service.dart';
import '../../core/map/map_pack_cache.dart';
import '../../core/map/mbtiles_server.dart';
import '../../core/session/game_session.dart';
import '../../core/sync/event_sync_service.dart';
import '../../core/ws/ws_service.dart';
import '../voice/tts_service.dart';

/// Боевая карта. Если у сессии есть `mapPackUrl` — скачиваем .mbtiles
/// (или используем кэшированный), поднимаем локальный shelf-сервер и
/// рендерим MapLibre поверх него. Иначе — fallback на онлайн OpenTopoMap.
///
/// Реал-тайм слой:
///   * WsService подключается к /api/v1/ws и шлёт сглаженную позицию
///     (троттл 3с уже внутри сервиса);
///   * входящие пакеты position обновляют allies (круги на карте);
///   * входящие/локальные marker — круги + label на карте;
///   * long-press по карте → выбор kind/visibility → POST /markers.
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

  MapLibreMapController? _map;
  bool _mapReady = false;

  StreamSubscription<KalmanPoint>? _gpsSub;
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  StreamSubscription<WsConnectionState>? _wsStateSub;
  StreamSubscription<CompassEvent>? _compassSub;
  WsConnectionState _wsState = WsConnectionState.idle;
  double? _heading;
  KalmanPoint? _myPos;

  // userID → круг союзника на карте + последний пакет (для bearing/tooltip).
  final Map<String, _AllyVisual> _allies = {};
  // markerID → визуал.
  final Map<String, _MarkerVisual> _markers = {};
  // spawnID → визуал.
  final Map<String, _SpawnVisual> _spawns = {};
  // Стороны игры — для дропдауна при постановке точки возрождения (organizer).
  List<SideInfo> _sides = const [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _wsSub?.cancel();
    _wsStateSub?.cancel();
    _compassSub?.cancel();
    ref.read(wsServiceProvider).disconnect();
    ref.read(gpsServiceProvider).stop();
    _mbtilesServer?.stop();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _requestLocation();
    await _loadMap();

    final session = ref.read(gameSessionProvider);
    if (session == null) return;

    // GPS + автодетект движения через акселерометр.
    final gps = ref.read(gpsServiceProvider);
    final motion = ref.read(motionServiceProvider);
    if (_locationGranted) {
      await gps.start(motion: motion);
      _gpsSub = gps.stream.listen(_onMyPosition);
    }

    // Компас для UI-стрелки севера.
    _compassSub = FlutterCompass.events?.listen((e) {
      if (!mounted || e.heading == null) return;
      setState(() => _heading = e.heading);
    });

    // WebSocket + начальная загрузка маркеров.
    final ws = ref.read(wsServiceProvider);
    _wsStateSub = ws.state.listen((s) {
      if (mounted) setState(() => _wsState = s);
      // Восстановили связь — сливаем накопленный offline-outbox (kill/respawn).
      if (s == WsConnectionState.connected) {
        ref.read(eventSyncServiceProvider).flush(session.gameId);
      }
    });
    _wsSub = ws.incoming.listen(_onWsPacket);
    try {
      await ws.connect(session.gameId);
    } catch (_) {/* банер reconnect покажет состояние */}

    await _refreshMarkersFromBackend();
    await _refreshSpawnsFromBackend();

    // Список сторон нужен только организатору (для постановки spawn-points).
    if (session.isOrganizer) {
      try {
        _sides = await ref.read(gamesApiProvider).listSides(session.gameId);
      } catch (_) {/* поставит без стороны */}
    }
  }

  Future<void> _loadMap() async {
    final session = ref.read(gameSessionProvider);
    final url = session?.mapPackUrl;
    if (session == null || url == null || url.isEmpty) {
      if (mounted) setState(() => _styleString = _onlineStyle);
      return;
    }

    try {
      final cache = ref.read(mapPackCacheProvider);
      if (!await cache.existsFor(session.gameId) && mounted) {
        setState(() => _statusMsg = 'Скачиваю карту полигона…');
      }
      final filePath = await cache.ensure(gameId: session.gameId, url: url);
      if (mounted) setState(() => _statusMsg = null);

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
      if (mounted) {
        setState(() {
          _styleString = _onlineStyle;
          _statusMsg = 'Оффлайн-карта недоступна, перешли на онлайн: $e';
        });
      }
    }
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

  Future<void> _refreshMarkersFromBackend() async {
    final session = ref.read(gameSessionProvider);
    if (session == null) return;
    try {
      final items = await ref.read(markersApiProvider).list(session.gameId);
      // Если карта ещё не готова — отрисуем при onStyleLoaded.
      for (final m in items) {
        await _upsertMarker(m);
      }
    } catch (_) {/* нет интернета — оффлайн всё равно работает */}
  }

  Future<void> _refreshSpawnsFromBackend() async {
    final session = ref.read(gameSessionProvider);
    if (session == null) return;
    try {
      final items =
          await ref.read(eventsApiProvider).listSpawnPoints(session.gameId);
      for (final sp in items) {
        await _upsertSpawn(sp);
      }
    } catch (_) {/* не критично */}
  }

  void _onMyPosition(KalmanPoint p) {
    if (p.warming) return;
    _myPos = p;
    // Свою позицию шлём в WS. Сервер сам затроттлит и broadcast'нёт союзникам.
    ref.read(wsServiceProvider).sendPosition(
          lng: p.lng,
          lat: p.lat,
          heading: _heading,
        );
  }

  void _onWsPacket(Map<String, dynamic> packet) {
    final type = packet['type'] as String?;
    switch (type) {
      case 'position':
        _handlePosition(packet);
        break;
      case 'marker':
        _handleMarker(packet);
        break;
      case 'kill':
        _speakKill(packet, died: true);
        break;
      case 'respawn':
        _speakKill(packet, died: false);
        break;
    }
  }

  Future<void> _handlePosition(Map<String, dynamic> packet) async {
    final author = packet['author'] as String?;
    final payload = packet['payload'] as Map<String, dynamic>?;
    if (author == null || payload == null) return;
    final lng = (payload['lng'] as num?)?.toDouble();
    final lat = (payload['lat'] as num?)?.toDouble();
    if (lng == null || lat == null) return;

    await _upsertAlly(author, LatLng(lat, lng));
  }

  Future<void> _handleMarker(Map<String, dynamic> packet) async {
    final payload = packet['payload'] as Map<String, dynamic>?;
    if (payload == null) return;
    final m = MarkerInfo.fromJson(payload);
    await _upsertMarker(m);
    _speakMarker(m);
  }

  void _speakMarker(MarkerInfo m) {
    final tts = ref.read(ttsServiceProvider);
    final my = _myPos;
    if (my == null) {
      // Без своей позиции — без азимута. Всё равно полезно знать, что метка пришла.
      tts.enqueue(VoiceMessage(
        'Новая метка: ${_kindToRu(m.kind)}',
        VoicePriority.tactical,
      ));
      return;
    }
    final distM = distanceMeters(my.lat, my.lng, m.lat, m.lng);
    final bearing = bearingDeg(my.lat, my.lng, m.lat, m.lng);
    tts.enqueue(VoiceMessage(
      TtsService.formatMarker(
        kind: _kindToRu(m.kind),
        distanceM: distM,
        azimuth: cardinal8(bearing),
      ),
      m.kind == 'enemy' ? VoicePriority.tactical : VoicePriority.info,
    ));
  }

  void _speakKill(Map<String, dynamic> packet, {required bool died}) {
    final tts = ref.read(ttsServiceProvider);
    final session = ref.read(gameSessionProvider);
    final payload = packet['payload'] as Map<String, dynamic>?;
    final author = packet['author'] as String?;
    if (author == null) return;

    // На клиент прилетают только пакеты, которые сервер уже отфильтровал
    // по правилу «убит/возродился — союзникам и организатору». Здесь только
    // формулируем фразу.
    final isMine = session != null && author == _userIdOrEmpty();
    if (isMine) return; // про самого себя мы и так знаем

    final sideId = payload?['side_id'] as String?;
    final allied = session != null &&
        session.sideId != null &&
        sideId != null &&
        session.sideId == sideId;
    final who = allied ? 'Союзник' : 'Боец';
    final what = died ? 'убит' : 'возродился';
    tts.enqueue(VoiceMessage('$who $what', VoicePriority.info));
  }

  String _userIdOrEmpty() {
    // Supabase user_id — он же author в WS-пакете. Riverpod-провайдера
    // здесь нет, тащим через супабейзовский синглтон, чтобы не плодить зависимости.
    // Возвращает '' если сессии нет (тогда _speakKill всё равно никуда не зайдёт).
    return Supabase.instance.client.auth.currentSession?.user.id ?? '';
  }

  String _kindToRu(String kind) => switch (kind) {
        'enemy' => 'противник',
        'ally' => 'союзник',
        'danger' => 'опасность',
        'objective' => 'цель',
        'support' => 'поддержка',
        'note' => 'заметка',
        _ => kind,
      };

  // ─── Map layer mutations ──────────────────────────────────────────────────

  Future<void> _upsertAlly(String userId, LatLng pos) async {
    if (!_mapReady || _map == null) return;
    final session = ref.read(gameSessionProvider);
    final color = _parseHexColor(session?.sideColor) ?? Colors.green;

    final existing = _allies[userId];
    if (existing != null) {
      await _map!.updateCircle(existing.circle, CircleOptions(geometry: pos));
      return;
    }
    final circle = await _map!.addCircle(CircleOptions(
      geometry: pos,
      circleRadius: 7,
      circleColor: '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}',
      circleStrokeColor: '#FFFFFF',
      circleStrokeWidth: 2,
    ));
    _allies[userId] = _AllyVisual(circle: circle);
  }

  Future<void> _upsertMarker(MarkerInfo m) async {
    if (!_mapReady || _map == null) return;
    final pos = LatLng(m.lat, m.lng);
    final color = _markerColor(m.kind);
    final hex = '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}';

    final existing = _markers[m.id];
    if (existing != null) {
      await _map!.updateCircle(existing.circle, CircleOptions(geometry: pos));
      return;
    }
    final circle = await _map!.addCircle(CircleOptions(
      geometry: pos,
      circleRadius: 9,
      circleColor: hex,
      circleOpacity: 0.85,
      circleStrokeColor: '#000000',
      circleStrokeWidth: 1.5,
    ));
    Symbol? label;
    if (m.label != null && m.label!.isNotEmpty) {
      label = await _map!.addSymbol(SymbolOptions(
        geometry: pos,
        textField: m.label,
        textOffset: const Offset(0, 1.5),
        textSize: 12,
        textColor: '#FFFFFF',
        textHaloColor: '#000000',
        textHaloWidth: 1.2,
      ));
    }
    _markers[m.id] = _MarkerVisual(circle: circle, label: label);
  }

  Future<void> _upsertSpawn(SpawnPointInfo sp) async {
    if (!_mapReady || _map == null) return;
    final pos = LatLng(sp.lat, sp.lng);
    // Цвет точки = цвет стороны (если привязана), иначе нейтральный белый.
    final side = _sideById(sp.sideId);
    final color = _parseHexColor(side?.color) ?? Colors.white;
    final hex = '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}';

    final existing = _spawns[sp.id];
    if (existing != null) {
      await _map!.updateCircle(existing.circle, CircleOptions(geometry: pos));
      return;
    }
    // Кольцо + подпись-флаг. Радиус крупнее меток — это «дом», его видно издали.
    final circle = await _map!.addCircle(CircleOptions(
      geometry: pos,
      circleRadius: 12,
      circleColor: hex,
      circleOpacity: 0.25,
      circleStrokeColor: hex,
      circleStrokeWidth: 3,
    ));
    final label = await _map!.addSymbol(SymbolOptions(
      geometry: pos,
      textField: '⚑ ${sp.name}',
      textOffset: const Offset(0, 1.6),
      textSize: 12,
      textColor: '#FFFFFF',
      textHaloColor: '#000000',
      textHaloWidth: 1.4,
    ));
    _spawns[sp.id] = _SpawnVisual(circle: circle, label: label);
  }

  SideInfo? _sideById(String? id) {
    if (id == null) return null;
    for (final s in _sides) {
      if (s.id == id) return s;
    }
    return null;
  }

  // ─── User actions ─────────────────────────────────────────────────────────

  Future<void> _onMapLongClick(Point<double> point, LatLng coord) async {
    final session = ref.read(gameSessionProvider);
    if (session == null) return;

    // Организатор сначала выбирает, что ставит: метку или точку возрождения.
    if (session.isOrganizer) {
      final choice = await showModalBottomSheet<_LongPressChoice>(
        context: context,
        builder: (_) => const _LongPressChoiceSheet(),
      );
      if (choice == null) return;
      if (choice == _LongPressChoice.spawn) {
        await _createSpawn(coord);
        return;
      }
    }
    await _createMarker(coord, session);
  }

  Future<void> _createMarker(LatLng coord, GameSession session) async {
    final result = await showModalBottomSheet<_MarkerDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MarkerSheet(isOrganizer: session.isOrganizer),
    );
    if (result == null) return;

    try {
      final created = await ref.read(markersApiProvider).create(
            session.gameId,
            kind: result.kind,
            visibility: result.visibility,
            lng: coord.longitude,
            lat: coord.latitude,
            label: result.label,
          );
      await _upsertMarker(created);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать метку: $e')),
      );
    }
  }

  Future<void> _createSpawn(LatLng coord) async {
    final session = ref.read(gameSessionProvider);
    if (session == null) return;

    final draft = await showModalBottomSheet<_SpawnDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SpawnSheet(sides: _sides),
    );
    if (draft == null) return;

    try {
      final created = await ref.read(eventsApiProvider).createSpawnPoint(
            session.gameId,
            sideId: draft.sideId,
            name: draft.name,
            lng: coord.longitude,
            lat: coord.latitude,
            isBase: draft.isBase,
          );
      await _upsertSpawn(created);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать точку: $e')),
      );
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

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
              target: LatLng(55.751244, 37.618423),
              zoom: 13,
            ),
            myLocationEnabled: _locationGranted,
            myLocationTrackingMode: _locationGranted
                ? MyLocationTrackingMode.tracking
                : MyLocationTrackingMode.none,
            myLocationRenderMode: MyLocationRenderMode.compass,
            onMapCreated: (c) => _map = c,
            onStyleLoadedCallback: () async {
              _mapReady = true;
              // Стиль пересоздаёт слои аннотаций — старые хэндлы инвалидны,
              // чистим карты визуалов и перезаливаем из бэкенда.
              _markers.clear();
              _allies.clear();
              _spawns.clear();
              await _refreshMarkersFromBackend();
              await _refreshSpawnsFromBackend();
            },
            onMapLongClick: _onMapLongClick,
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
                if (_wsState == WsConnectionState.reconnecting ||
                    _wsState == WsConnectionState.connecting) ...[
                  const SizedBox(height: 6),
                  _Banner(
                    message: _wsState == WsConnectionState.reconnecting
                        ? 'Связь потеряна, переподключаюсь…'
                        : 'Подключение…',
                    color: Colors.brown.shade700,
                    icon: Icons.sync,
                  ),
                ],
              ],
            ),
          ),
          if (_heading != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 80,
              right: 12,
              child: _CompassRose(heading: _heading!),
            ),
          Positioned(
            left: 8,
            bottom: 8,
            child: _Attribution(offline: _usingOffline),
          ),
          Positioned(
            right: 16,
            bottom: 32,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (session != null &&
                    (session.isOrganizer || session.role == 'side_commander'))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: FloatingActionButton.small(
                      heroTag: 'cmd',
                      tooltip: 'Распределение',
                      onPressed: () => context.go('/command'),
                      child: const Icon(Icons.people_alt),
                    ),
                  ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 18),
                  ),
                  onPressed: () async {
                    await ref.read(gpsServiceProvider).markDead();
                    if (!context.mounted) return;
                    context.go('/dead');
                  },
                  child: const Text(
                    'УБИТ',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          if (_myPos != null) _BearingHud(myPos: _myPos!, markers: _markers),
        ],
      ),
    );
  }
}

// ─── HUD / UI bits ──────────────────────────────────────────────────────────

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

class _CompassRose extends StatelessWidget {
  final double heading;
  const _CompassRose({required this.heading});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.6),
      shape: const CircleBorder(),
      child: SizedBox(
        width: 48,
        height: 48,
        child: Transform.rotate(
          // Стрелка севера: heading — куда смотрит телефон;
          // ось «север» относительно экрана = -heading.
          angle: -heading * 3.1415926535 / 180.0,
          child: const Icon(Icons.navigation, color: Colors.redAccent, size: 28),
        ),
      ),
    );
  }
}

/// Маленький HUD внизу слева: показывает азимут и дистанцию до ближайшей
/// «вражеской» метки. Для TTS в фазе 4 берём те же значения.
class _BearingHud extends StatelessWidget {
  final KalmanPoint myPos;
  final Map<String, _MarkerVisual> markers;
  const _BearingHud({required this.myPos, required this.markers});

  @override
  Widget build(BuildContext context) {
    // Сейчас отображаем только если хотя бы одна метка отрисована.
    if (markers.isEmpty) return const SizedBox.shrink();
    // Берём из стейта первый круг — у нас под рукой нет lng/lat в _MarkerVisual,
    // поэтому HUD пока заглушка под расширение в фазе 4 (когда добавим автора
    // в визуал и таблицу last positions).
    return const SizedBox.shrink();
  }
}

// ─── Marker creation sheet ──────────────────────────────────────────────────

class _MarkerDraft {
  final MarkerKind kind;
  final MarkerVisibility visibility;
  final String? label;
  _MarkerDraft({required this.kind, required this.visibility, this.label});
}

class _MarkerSheet extends StatefulWidget {
  final bool isOrganizer;
  const _MarkerSheet({required this.isOrganizer});

  @override
  State<_MarkerSheet> createState() => _MarkerSheetState();
}

class _MarkerSheetState extends State<_MarkerSheet> {
  MarkerKind _kind = MarkerKind.enemy;
  MarkerVisibility _visibility = MarkerVisibility.side;
  final _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visibilities = [
      MarkerVisibility.self,
      MarkerVisibility.squad,
      MarkerVisibility.side,
      if (widget.isOrganizer) MarkerVisibility.organizers,
      MarkerVisibility.all,
    ];
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Новая метка',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: MarkerKind.values.map((k) {
              return ChoiceChip(
                label: Text(_kindLabel(k)),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
                avatar: CircleAvatar(
                  backgroundColor: _markerColor(k.wire),
                  radius: 8,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          const Text('Кому видно'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: visibilities.map((v) {
              return ChoiceChip(
                label: Text(_visLabel(v)),
                selected: _visibility == v,
                onSelected: (_) => setState(() => _visibility = v),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _label,
            decoration: const InputDecoration(
              labelText: 'Подпись (опционально)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            maxLength: 30,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Поставить'),
                onPressed: () => Navigator.pop(
                  context,
                  _MarkerDraft(
                    kind: _kind,
                    visibility: _visibility,
                    label: _label.text.trim().isEmpty ? null : _label.text.trim(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _kindLabel(MarkerKind k) => switch (k) {
        MarkerKind.enemy => 'Противник',
        MarkerKind.ally => 'Союзник',
        MarkerKind.danger => 'Опасность',
        MarkerKind.objective => 'Цель',
        MarkerKind.support => 'Поддержка',
        MarkerKind.note => 'Заметка',
      };

  String _visLabel(MarkerVisibility v) => switch (v) {
        MarkerVisibility.self => 'Только мне',
        MarkerVisibility.squad => 'Отряду',
        MarkerVisibility.side => 'Стороне',
        MarkerVisibility.organizers => 'Организаторам',
        MarkerVisibility.all => 'Всем',
      };
}

// ─── Long-press choice (organizer) ──────────────────────────────────────────

enum _LongPressChoice { marker, spawn }

class _LongPressChoiceSheet extends StatelessWidget {
  const _LongPressChoiceSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.add_location_alt, color: Colors.orange),
            title: const Text('Метка'),
            subtitle: const Text('Противник, цель, опасность…'),
            onTap: () => Navigator.pop(context, _LongPressChoice.marker),
          ),
          ListTile(
            leading: const Icon(Icons.flag, color: Colors.greenAccent),
            title: const Text('Точка возрождения'),
            subtitle: const Text('Мертвяк / база стороны'),
            onTap: () => Navigator.pop(context, _LongPressChoice.spawn),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─── Spawn creation sheet ───────────────────────────────────────────────────

class _SpawnDraft {
  final String name;
  final String? sideId;
  final bool isBase;
  _SpawnDraft({required this.name, this.sideId, required this.isBase});
}

class _SpawnSheet extends StatefulWidget {
  final List<SideInfo> sides;
  const _SpawnSheet({required this.sides});

  @override
  State<_SpawnSheet> createState() => _SpawnSheetState();
}

class _SpawnSheetState extends State<_SpawnSheet> {
  final _name = TextEditingController(text: 'Мертвяк');
  String? _sideId; // null = нейтральная (общая) точка
  bool _isBase = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Точка возрождения',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Название',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            maxLength: 40,
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<String?>(
            initialValue: _sideId,
            decoration: const InputDecoration(
              labelText: 'Сторона',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Нейтральная (общая)'),
              ),
              ...widget.sides.map((s) => DropdownMenuItem<String?>(
                    value: s.id,
                    child: Text(s.name),
                  )),
            ],
            onChanged: (v) => setState(() => _sideId = v),
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _isBase,
            onChanged: (v) => setState(() => _isBase = v ?? false),
            title: const Text('Это база стороны'),
            subtitle: const Text('База — главная точка, не просто мертвяк'),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                icon: const Icon(Icons.flag),
                label: const Text('Поставить'),
                onPressed: () {
                  final name = _name.text.trim();
                  if (name.isEmpty) return;
                  Navigator.pop(
                    context,
                    _SpawnDraft(name: name, sideId: _sideId, isBase: _isBase),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Helpers ────────────────────────────────────────────────────────────────

class _AllyVisual {
  final Circle circle;
  _AllyVisual({required this.circle});
}

class _MarkerVisual {
  final Circle circle;
  final Symbol? label;
  _MarkerVisual({required this.circle, this.label});
}

class _SpawnVisual {
  final Circle circle;
  final Symbol label;
  _SpawnVisual({required this.circle, required this.label});
}

Color? _parseHexColor(String? hex) {
  if (hex == null) return null;
  final s = hex.replaceAll('#', '').trim();
  if (s.length == 6) return Color(int.parse('FF$s', radix: 16));
  if (s.length == 8) return Color(int.parse(s, radix: 16));
  return null;
}

Color _markerColor(String kind) {
  switch (kind) {
    case 'enemy':
      return const Color(0xFFD32F2F);
    case 'ally':
      return const Color(0xFF388E3C);
    case 'danger':
      return const Color(0xFFFFA000);
    case 'objective':
      return const Color(0xFF1976D2);
    case 'support':
      return const Color(0xFF7B1FA2);
    case 'note':
    default:
      return const Color(0xFF455A64);
  }
}

