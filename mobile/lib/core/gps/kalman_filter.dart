import 'dart:math' as math;

/// 1D Калман-фильтр на lat/lng — порт из TurfStep с тактическими твиками
/// под страйкбол: drift detection чуть строже (15м вместо 20м), gap reset
/// мягче (warmup 3 чтения, не сбрасывает variance в ноль).
///
/// Правила:
///   * adaptive measurement noise: variance измерения = max(accuracy², minVar)
///   * speed check: >12 м/с (≈43 км/ч — фастер любого пешего) → отбрасываем
///   * gap detection: >30c пауза → soft reset (теряем старое значение
///     variance, начинаем заново), warmup 3 чтения отдают warming=true
///   * drift detection: окно 6 точек, если net-displacement <15м и средняя
///     accuracy >14м — игрок стационарен; возвращаем «остановленный» median
///     центр, варианта показывается прежняя (нет иллюзии движения)
class GpsKalmanFilter {
  static const _maxSpeedMps = 12.0;
  static const _gapResetSec = 30;
  static const _warmupReads = 3;
  static const _driftWindow = 6;
  static const _driftMaxDisplacementM = 15.0;
  static const _driftMinAccuracyM = 14.0;
  static const _minMeasurementVar = 4.0; // (2м)² — пол шума для GPS

  double? _lat;
  double? _lng;
  double _variance = -1;
  DateTime? _lastTs;
  int _warmupRemaining = 0;

  final List<_Sample> _window = [];

  KalmanPoint? update({
    required double lat,
    required double lng,
    required double accuracy,
    required DateTime ts,
  }) {
    // Gap → soft reset. Старая variance больше не отражает реальность
    // (могли перейти из леса в открытое поле и обратно). Лат/лнг/lastTs тоже
    // сбрасываем — иначе speed-фильтр ниже отбросит первую точку после паузы
    // как «прыжок 1 км за 60с».
    if (_lastTs != null && ts.difference(_lastTs!).inSeconds > _gapResetSec) {
      _variance = -1;
      _warmupRemaining = _warmupReads;
      _window.clear();
      _lat = null;
      _lng = null;
      _lastTs = null;
    }

    // Speed check — отбрасываем «прыжок» (типичный артефакт A-GPS при холодном старте).
    if (_lat != null && _lng != null && _lastTs != null) {
      final dt = ts.difference(_lastTs!).inMilliseconds / 1000.0;
      if (dt > 0) {
        final distM = _haversineMeters(_lat!, _lng!, lat, lng);
        if (distM / dt > _maxSpeedMps) {
          // молча игнорируем — клиент получит следующую точку
          return null;
        }
      }
    }

    final r = math.max(accuracy * accuracy, _minMeasurementVar);

    if (_variance < 0) {
      _lat = lat;
      _lng = lng;
      _variance = r;
      _lastTs = ts;
      _warmupRemaining = _warmupReads;
      _pushSample(lat, lng, accuracy);
      return KalmanPoint(
        lat: lat, lng: lng, ts: ts,
        warming: true, stationary: false, accuracy: accuracy,
      );
    }

    final k = _variance / (_variance + r);
    _lat = _lat! + k * (lat - _lat!);
    _lng = _lng! + k * (lng - _lng!);
    _variance = (1 - k) * _variance;
    _lastTs = ts;
    if (_warmupRemaining > 0) _warmupRemaining--;

    _pushSample(_lat!, _lng!, accuracy);

    final stationary = _detectStationary();
    if (stationary != null) {
      // Замораживаем выход: возвращаем медианный центр окна. Так на карте
      // игрок не «дрожит» в засаде. Variance не трогаем — следующая реальная
      // точка нормально обновит фильтр.
      return KalmanPoint(
        lat: stationary.lat,
        lng: stationary.lng,
        ts: ts,
        warming: _warmupRemaining > 0,
        stationary: true,
        accuracy: accuracy,
      );
    }

    return KalmanPoint(
      lat: _lat!,
      lng: _lng!,
      ts: ts,
      warming: _warmupRemaining > 0,
      stationary: false,
      accuracy: accuracy,
    );
  }

  void _pushSample(double lat, double lng, double acc) {
    _window.add(_Sample(lat: lat, lng: lng, accuracy: acc));
    if (_window.length > _driftWindow) {
      _window.removeAt(0);
    }
  }

  _LatLng? _detectStationary() {
    if (_window.length < _driftWindow) return null;
    final first = _window.first;
    final last = _window.last;
    final disp = _haversineMeters(first.lat, first.lng, last.lat, last.lng);
    if (disp >= _driftMaxDisplacementM) return null;

    final avgAcc =
        _window.map((s) => s.accuracy).reduce((a, b) => a + b) / _window.length;
    if (avgAcc < _driftMinAccuracyM) return null;

    // Медиана по lat/lng — устойчивее среднего к одиночному выбросу.
    final lats = _window.map((s) => s.lat).toList()..sort();
    final lngs = _window.map((s) => s.lng).toList()..sort();
    final mid = _window.length ~/ 2;
    return _LatLng(lat: lats[mid], lng: lngs[mid]);
  }

  void reset() {
    _lat = null;
    _lng = null;
    _variance = -1;
    _lastTs = null;
    _warmupRemaining = 0;
    _window.clear();
  }
}

class KalmanPoint {
  final double lat;
  final double lng;
  final DateTime ts;
  final bool warming;
  final bool stationary;
  final double accuracy;
  KalmanPoint({
    required this.lat,
    required this.lng,
    required this.ts,
    required this.warming,
    required this.stationary,
    required this.accuracy,
  });
}

class _Sample {
  final double lat;
  final double lng;
  final double accuracy;
  _Sample({required this.lat, required this.lng, required this.accuracy});
}

class _LatLng {
  final double lat;
  final double lng;
  _LatLng({required this.lat, required this.lng});
}

double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return r * c;
}

double _rad(double deg) => deg * math.pi / 180.0;
