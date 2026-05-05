/// 1D Калман-фильтр на lat/lng (по аналогии с TurfStep).
///
/// TODO: портировать полную версию из TurfStep:
///   - адаптивный measurement noise по accuracy
///   - gap detection (>30c → soft reset + warmup 3 чтения)
///   - drift detection (6 точек, net-displacement <15м, accuracy >14м → stationary)
///   - speed check (>12 м/с → отбрасывание точки)
class GpsKalmanFilter {
  double? _lat;
  double? _lng;
  double _variance = -1; // -1 = uninitialized

  /// Минимальный вариант: возвращает сглаженную точку или null до warmup.
  KalmanPoint? update({
    required double lat,
    required double lng,
    required double accuracy,
    required DateTime ts,
  }) {
    if (_variance < 0) {
      _lat = lat;
      _lng = lng;
      _variance = accuracy * accuracy;
      return KalmanPoint(lat: lat, lng: lng, ts: ts, warming: true);
    }

    final r = accuracy * accuracy;
    final k = _variance / (_variance + r);
    _lat = _lat! + k * (lat - _lat!);
    _lng = _lng! + k * (lng - _lng!);
    _variance = (1 - k) * _variance;

    return KalmanPoint(lat: _lat!, lng: _lng!, ts: ts, warming: false);
  }

  void reset() {
    _lat = null;
    _lng = null;
    _variance = -1;
  }
}

class KalmanPoint {
  final double lat;
  final double lng;
  final DateTime ts;
  final bool warming;
  KalmanPoint({
    required this.lat,
    required this.lng,
    required this.ts,
    required this.warming,
  });
}
