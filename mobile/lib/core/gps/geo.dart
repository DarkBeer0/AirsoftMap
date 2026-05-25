import 'dart:math' as math;

/// Геодезические утилиты для тактической карты:
///   * distanceMeters — Гаверсина, ≤0.5% погрешности до 1000 км
///   * bearingDeg — азимут A→B, 0=север, 90=восток, 0..360
///   * cardinal8 — словесный кардинал для TTS («новая метка СВ, 120м»)
///   * destinationPoint — координата по азимуту и дистанции (для проверок/симуляции)
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double bearingDeg(double lat1, double lng1, double lat2, double lng2) {
  final phi1 = _rad(lat1);
  final phi2 = _rad(lat2);
  final dLng = _rad(lng2 - lng1);
  final y = math.sin(dLng) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dLng);
  final theta = math.atan2(y, x);
  return (theta * 180.0 / math.pi + 360.0) % 360.0;
}

/// Восемь кардинальных направлений (русские буквы) для TTS-шаблонов.
const _cardinals8 = ['С', 'СВ', 'В', 'ЮВ', 'Ю', 'ЮЗ', 'З', 'СЗ'];

String cardinal8(double bearing) {
  final idx = (((bearing + 22.5) % 360) / 45).floor() % 8;
  return _cardinals8[idx];
}

double _rad(double deg) => deg * math.pi / 180.0;

double _deg(double rad) => rad * 180.0 / math.pi;

/// Точка по азимуту и дистанции — пригодится для тестов / симуляции врагов.
({double lat, double lng}) destinationPoint(
  double lat, double lng, double bearing, double distanceM,
) {
  const r = 6371000.0;
  final d = distanceM / r;
  final brng = _rad(bearing);
  final phi1 = _rad(lat);
  final lambda1 = _rad(lng);

  final sinPhi2 =
      math.sin(phi1) * math.cos(d) + math.cos(phi1) * math.sin(d) * math.cos(brng);
  final phi2 = math.asin(sinPhi2);
  final y = math.sin(brng) * math.sin(d) * math.cos(phi1);
  final x = math.cos(d) - math.sin(phi1) * sinPhi2;
  final lambda2 = lambda1 + math.atan2(y, x);
  return (lat: _deg(phi2), lng: ((_deg(lambda2) + 540) % 360) - 180);
}
