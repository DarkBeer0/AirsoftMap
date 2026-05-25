import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/events_api.dart';
import '../../core/gps/geo.dart';
import '../../core/gps/gps_provider.dart';
import '../../core/session/game_session.dart';
import '../voice/tts_service.dart';

/// Экран «Убит».
///
/// При входе:
///   1. POST /games/:id/kills → respawn_until от сервера;
///   2. GpsService.markDead() — переводит GPS в low-power и игнорирует
///      motion-сенсоры (засада не должна возвращать battle-режим);
///   3. подгружаем spawn-points, выбираем ближайший «к моей стороне» или общий;
///   4. стрелка-компас крутится на азимут к мертвяку, под ней дистанция;
///   5. таймер обратного отсчёта; при 0 кнопка «Возродиться» активируется.
///
/// При выходе:
///   * POST /games/:id/respawn → GpsService.markAlive() → /battle.
class KillStateScreen extends ConsumerStatefulWidget {
  const KillStateScreen({super.key});

  @override
  ConsumerState<KillStateScreen> createState() => _KillStateScreenState();
}

class _KillStateScreenState extends ConsumerState<KillStateScreen> {
  DateTime? _respawnUntil;
  Timer? _ticker;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;

  double? _myLat;
  double? _myLng;
  double? _heading;
  SpawnPointInfo? _target;
  List<SpawnPointInfo> _spawns = const [];

  String? _error;
  bool _killing = true;
  bool _respawning = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _posSub?.cancel();
    _compassSub?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final session = ref.read(gameSessionProvider);
    if (session == null) {
      // Нет активной сессии — некуда возвращаться, просто кидаем в лобби.
      if (mounted) context.go('/lobby');
      return;
    }
    final tts = ref.read(ttsServiceProvider);

    try {
      // 1. POST /kills — сервер выставит status=dead + respawn_until.
      final res = await ref.read(eventsApiProvider).kill(session.gameId);
      if (mounted) {
        setState(() {
          _respawnUntil = res.respawnUntil;
          _killing = false;
        });
      }
      tts.enqueue(
        VoiceMessage('Убит. Двигайся к мертвяку.', VoicePriority.critical),
      );
    } catch (e) {
      // Сервер может быть недоступен (нет связи в лесу) — переходим в локальный
      // режим: таймер 60с от текущего момента, статус храним только локально.
      if (mounted) {
        setState(() {
          _respawnUntil = DateTime.now().add(const Duration(seconds: 60));
          _killing = false;
          _error = 'Нет связи: статус локальный';
        });
      }
    }

    await ref.read(gpsServiceProvider).markDead();

    // 2. Слушаем сырые координаты — Kalman здесь избыточен, нам нужны
    //    только bearing/distance до мертвяка.
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 5,
      ),
    ).listen((p) {
      if (!mounted) return;
      setState(() {
        _myLat = p.latitude;
        _myLng = p.longitude;
        _retargetIfNeeded();
      });
    });

    _compassSub = FlutterCompass.events?.listen((e) {
      if (!mounted || e.heading == null) return;
      setState(() => _heading = e.heading);
    });

    // 3. Подтягиваем spawn-points (могут быть пусты — тогда показываем только таймер).
    try {
      final spawns =
          await ref.read(eventsApiProvider).listSpawnPoints(session.gameId);
      if (!mounted) return;
      setState(() {
        _spawns = spawns;
        _retargetIfNeeded();
      });
    } catch (_) {/* не критично */}

    // 4. Тикер обратного отсчёта.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  /// Выбираем ближайший spawn-point своей стороны или общий (sideId==null).
  /// Чужие точки игнорируем — там нас не возродят.
  void _retargetIfNeeded() {
    if (_spawns.isEmpty || _myLat == null || _myLng == null) return;
    final session = ref.read(gameSessionProvider);
    final mySide = session?.sideId;
    final candidates = _spawns.where((s) {
      return s.sideId == null || (mySide != null && s.sideId == mySide);
    }).toList();
    if (candidates.isEmpty) return;

    candidates.sort((a, b) {
      final da = distanceMeters(_myLat!, _myLng!, a.lat, a.lng);
      final db = distanceMeters(_myLat!, _myLng!, b.lat, b.lng);
      return da.compareTo(db);
    });
    _target = candidates.first;
  }

  Duration get _remaining {
    if (_respawnUntil == null) return Duration.zero;
    final d = _respawnUntil!.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  bool get _canRespawn => _remaining == Duration.zero;

  Future<void> _doRespawn() async {
    if (!_canRespawn || _respawning) return;
    final session = ref.read(gameSessionProvider);
    if (session == null) return;
    setState(() => _respawning = true);

    try {
      await ref.read(eventsApiProvider).respawn(session.gameId);
    } catch (_) {
      // Нет связи — переход в бой всё равно делаем (сервер досинхронит позже
      // через положение и события из батча — фаза 5).
    }
    await ref.read(gpsServiceProvider).markAlive();
    ref.read(ttsServiceProvider).enqueue(
          VoiceMessage('Возрождение. В бой.', VoicePriority.critical),
        );
    if (!mounted) return;
    context.go('/battle');
  }

  @override
  Widget build(BuildContext context) {
    if (_killing) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.red)),
      );
    }

    final hasTarget = _target != null && _myLat != null && _myLng != null;
    final distance = hasTarget
        ? distanceMeters(_myLat!, _myLng!, _target!.lat, _target!.lng)
        : null;
    final azimuth = hasTarget
        ? bearingDeg(_myLat!, _myLng!, _target!.lat, _target!.lng)
        : null;
    final relativeAngle = (azimuth != null && _heading != null)
        ? (azimuth - _heading!) * math.pi / 180.0
        : 0.0;

    final secs = _remaining.inSeconds;
    final mm = (secs ~/ 60).toString().padLeft(2, '0');
    final ss = (secs % 60).toString().padLeft(2, '0');

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 8),
              const Text(
                'УБИТ',
                style: TextStyle(
                  fontSize: 56,
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                  letterSpacing: 4,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(_error!,
                    style: const TextStyle(color: Colors.orange, fontSize: 12)),
              ],
              const SizedBox(height: 32),

              // Стрелка-компас → мертвяк.
              if (hasTarget) ...[
                Expanded(
                  child: Center(
                    child: Transform.rotate(
                      angle: relativeAngle,
                      child: const Icon(
                        Icons.navigation,
                        size: 220,
                        color: Colors.greenAccent,
                      ),
                    ),
                  ),
                ),
                Text(
                  _target!.name,
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  '${distance!.round()} м · ${cardinal8(azimuth!)}',
                  style: const TextStyle(
                    color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600,
                  ),
                ),
              ] else ...[
                const Expanded(
                  child: Center(
                    child: Text(
                      'Точка возрождения не задана.\nЖди таймер и возвращайся.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 16),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 24),
              Text(
                _canRespawn ? 'Можно возрождаться' : 'Респаун через',
                style: const TextStyle(color: Colors.white54),
              ),
              Text(
                '$mm:$ss',
                style: TextStyle(
                  color: _canRespawn ? Colors.greenAccent : Colors.white,
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                  fontFeatures: const [],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        _canRespawn ? Colors.green.shade700 : Colors.grey.shade800,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _canRespawn ? _doRespawn : null,
                  child: Text(
                    _respawning ? 'Возрождаю…' : 'Возродиться',
                    style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
