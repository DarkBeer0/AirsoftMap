import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import 'kalman_filter.dart';
import 'motion_service.dart';

/// Режим энергопотребления GPS. Меняется по статусу игрока («Убит»
/// принудительно роняет частоту) и активности (засада → редкие апдейты).
enum GpsMode { battle, stationary, dead }

class GpsService {
  final _filter = GpsKalmanFilter();
  StreamSubscription<Position>? _sub;
  StreamSubscription<MotionState>? _motionSub;
  final _out = StreamController<KalmanPoint>.broadcast();

  GpsMode _mode = GpsMode.battle;
  bool _deadLock = false; // dead имеет приоритет над любым motion-сигналом

  Stream<KalmanPoint> get stream => _out.stream;
  GpsMode get mode => _mode;

  Future<bool> ensurePermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  Future<void> start({
    GpsMode mode = GpsMode.battle,
    MotionService? motion,
  }) async {
    _mode = mode;
    await _sub?.cancel();
    _sub = Geolocator.getPositionStream(
      locationSettings: _settingsFor(mode),
    ).listen((pos) {
      final p = _filter.update(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracy: pos.accuracy,
        ts: pos.timestamp,
      );
      if (p != null) _out.add(p);
    });

    // Авторегулировка по акселерометру. Если боец «лёг» — режим stationary,
    // в движении — battle. Dead-lock держим выше: пока респаун таймер
    // не истёк, физическая активность не должна возвращать battle (батарея).
    await _motionSub?.cancel();
    if (motion != null) {
      motion.start();
      _motionSub = motion.stream.listen((s) {
        if (_deadLock) return;
        final target = s == MotionState.moving ? GpsMode.battle : GpsMode.stationary;
        setMode(target);
      });
    }
  }

  /// markDead/markAlive используются экраном «Убит»: пока статус мёртв,
  /// GPS работает в режиме экономии и не повышается по motion.
  Future<void> markDead() async {
    _deadLock = true;
    await setMode(GpsMode.dead);
  }

  Future<void> markAlive() async {
    _deadLock = false;
    await setMode(GpsMode.battle);
  }

  Future<void> setMode(GpsMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    // Переподписываемся с новыми LocationSettings; Kalman НЕ ресетим,
    // мы по-прежнему в той же сессии и тот же сенсор.
    await _sub?.cancel();
    _sub = Geolocator.getPositionStream(
      locationSettings: _settingsFor(mode),
    ).listen((pos) {
      final p = _filter.update(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracy: pos.accuracy,
        ts: pos.timestamp,
      );
      if (p != null) _out.add(p);
    });
  }

  LocationSettings _settingsFor(GpsMode mode) {
    switch (mode) {
      case GpsMode.battle:
        return const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 2,
        );
      case GpsMode.stationary:
        return const LocationSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 10,
        );
      case GpsMode.dead:
        return const LocationSettings(
          accuracy: LocationAccuracy.low,
          distanceFilter: 25,
        );
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _motionSub?.cancel();
    _motionSub = null;
    _filter.reset();
  }
}

final gpsServiceProvider = Provider<GpsService>((ref) {
  final svc = GpsService();
  ref.onDispose(svc.stop);
  return svc;
});
