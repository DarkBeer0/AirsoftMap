import 'package:flutter_test/flutter_test.dart';
import 'package:airsoftmap/core/gps/geo.dart';

void main() {
  group('distanceMeters (Haversine)', () {
    test('zero distance', () {
      expect(distanceMeters(55.75, 37.62, 55.75, 37.62), closeTo(0, 0.01));
    });

    test('Москва → Питер ≈ 633 км', () {
      // Опорные координаты Красной пл. и Дворцовой пл.
      final d = distanceMeters(55.7539, 37.6208, 59.9398, 30.3146);
      expect(d, closeTo(633000, 5000));
    });

    test('100 м к северу — округлённо 100±0.5 м', () {
      // 1 градус широты ≈ 111320 м → 100 м = 0.0008983 градусов
      final d = distanceMeters(55.75, 37.62, 55.75 + 0.0008983, 37.62);
      expect(d, closeTo(100, 0.5));
    });
  });

  group('bearingDeg', () {
    test('север', () {
      final b = bearingDeg(55.0, 37.0, 56.0, 37.0);
      expect(b, closeTo(0, 0.5));
    });

    test('восток', () {
      final b = bearingDeg(55.0, 37.0, 55.0, 38.0);
      expect(b, closeTo(90, 1.0));
    });

    test('юг', () {
      final b = bearingDeg(55.0, 37.0, 54.0, 37.0);
      expect(b, closeTo(180, 0.5));
    });

    test('запад', () {
      final b = bearingDeg(55.0, 37.0, 55.0, 36.0);
      expect(b, closeTo(270, 1.0));
    });

    test('возвращает 0..360', () {
      for (final dLng in [-2.0, -1.0, 0.5, 1.0, 2.5]) {
        final b = bearingDeg(55.0, 37.0, 55.5, 37.0 + dLng);
        expect(b, inInclusiveRange(0.0, 360.0));
      }
    });
  });

  group('cardinal8', () {
    test('север/восток/юг/запад', () {
      expect(cardinal8(0), 'С');
      expect(cardinal8(90), 'В');
      expect(cardinal8(180), 'Ю');
      expect(cardinal8(270), 'З');
    });

    test('диагонали', () {
      expect(cardinal8(45), 'СВ');
      expect(cardinal8(135), 'ЮВ');
      expect(cardinal8(225), 'ЮЗ');
      expect(cardinal8(315), 'СЗ');
    });

    test('границы секторов — 22.5° округляется в сторону СВ', () {
      // ровно середина между С и СВ — должно тяготеть к СВ (так удобнее
      // в TTS: «север-восток» лучше слышно чем «север»).
      expect(cardinal8(22.5), 'СВ');
      // 22.4° — ещё С
      expect(cardinal8(22.4), 'С');
    });

    test('360° → С (нормализация)', () {
      expect(cardinal8(360), 'С');
    });
  });

  group('destinationPoint', () {
    test('round-trip: смещение на N м обратно даёт исходную точку', () {
      const lat = 55.75, lng = 37.62;
      final p = destinationPoint(lat, lng, 90, 100);
      // обратное смещение
      final back = destinationPoint(p.lat, p.lng, 270, 100);
      expect(back.lat, closeTo(lat, 1e-6));
      expect(back.lng, closeTo(lng, 1e-6));
    });

    test('1 км на север даёт ≈+0.009 градусов широты', () {
      final p = destinationPoint(55.75, 37.62, 0, 1000);
      expect(p.lat - 55.75, closeTo(0.009, 0.0005));
      expect(p.lng, closeTo(37.62, 1e-6));
    });
  });
}
