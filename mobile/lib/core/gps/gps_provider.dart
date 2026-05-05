import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import 'kalman_filter.dart';

/// Режим энергопотребления GPS. Меняется по статусу игрока и активности
/// акселерометра (умное снижение частоты при стационарности и в статусе "Убит").
enum GpsMode { battle, stationary, dead }

class GpsService {
  final _filter = GpsKalmanFilter();
  StreamSubscription<Position>? _sub;
  final _out = StreamController<KalmanPoint>.broadcast();
  GpsMode _mode = GpsMode.battle;

  Stream<KalmanPoint> get stream => _out.stream;

  Future<bool> ensurePermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  Future<void> start({GpsMode mode = GpsMode.battle}) async {
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
  }

  Future<void> setMode(GpsMode mode) async {
    if (_mode == mode) return;
    await start(mode: mode);
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
    _filter.reset();
  }
}

final gpsServiceProvider = Provider<GpsService>((ref) {
  final svc = GpsService();
  ref.onDispose(svc.stop);
  return svc;
});
