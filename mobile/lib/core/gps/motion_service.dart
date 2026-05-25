import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensors_plus/sensors_plus.dart';

enum MotionState { moving, still }

/// MotionService — детектор активности по линейному (без g) ускорению.
///
/// Окно 3с, считаем средний |a|. Гистерезис нужен, чтобы боец в засаде
/// не «оживал» от случайной дрожи камеры:
///   * MOVING  → STILL: <0.2 м/с² 10с подряд
///   * STILL   → MOVING: ≥0.6 м/с² за 1.5с
///
/// Из этого собираем подходящий GpsMode (см. GpsService).
class MotionService {
  static const _stillThreshold = 0.2; // м/с²
  static const _movingThreshold = 0.6; // м/с²
  static const _stillNeededSec = 10;
  static const _movingNeededSec = 2; // быстрая реакция на старт

  StreamSubscription<UserAccelerometerEvent>? _sub;
  final _out = StreamController<MotionState>.broadcast();
  MotionState _state = MotionState.moving; // оптимистично — пусть GPS успеет греться

  DateTime? _stillSince;
  DateTime? _movingSince;

  Stream<MotionState> get stream => _out.stream;
  MotionState get current => _state;

  void start() {
    _sub ??= userAccelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen(_onSample);
  }

  void _onSample(UserAccelerometerEvent e) {
    final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final now = DateTime.now();

    if (mag < _stillThreshold) {
      _stillSince ??= now;
      _movingSince = null;
      if (_state != MotionState.still &&
          now.difference(_stillSince!).inSeconds >= _stillNeededSec) {
        _emit(MotionState.still);
      }
    } else if (mag >= _movingThreshold) {
      _movingSince ??= now;
      _stillSince = null;
      if (_state != MotionState.moving &&
          now.difference(_movingSince!).inSeconds >= _movingNeededSec) {
        _emit(MotionState.moving);
      }
    } else {
      // нейтральная зона: ничего не сбрасываем, просто ждём следующего
      // явного сигнала. Это и есть гистерезис.
    }
  }

  void _emit(MotionState s) {
    _state = s;
    _out.add(s);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _stillSince = null;
    _movingSince = null;
  }
}

final motionServiceProvider = Provider<MotionService>((ref) {
  final svc = MotionService();
  ref.onDispose(svc.stop);
  return svc;
});
