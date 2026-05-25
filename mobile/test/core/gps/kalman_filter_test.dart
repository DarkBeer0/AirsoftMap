import 'package:flutter_test/flutter_test.dart';
import 'package:airsoftmap/core/gps/kalman_filter.dart';
import 'package:airsoftmap/core/gps/geo.dart';

void main() {
  group('GpsKalmanFilter — базовое сглаживание', () {
    test('первая точка возвращает warming=true и сами координаты', () {
      final f = GpsKalmanFilter();
      final p = f.update(
        lat: 55.75, lng: 37.62, accuracy: 5,
        ts: DateTime(2024, 1, 1, 12),
      );
      expect(p, isNotNull);
      expect(p!.warming, isTrue);
      expect(p.lat, 55.75);
      expect(p.lng, 37.62);
    });

    test('после warmup warming=false', () {
      final f = GpsKalmanFilter();
      final t = DateTime(2024, 1, 1, 12);
      for (var i = 0; i < 4; i++) {
        f.update(
          lat: 55.75, lng: 37.62, accuracy: 5,
          ts: t.add(Duration(seconds: i)),
        );
      }
      final p = f.update(
        lat: 55.75, lng: 37.62, accuracy: 5,
        ts: t.add(const Duration(seconds: 5)),
      );
      expect(p!.warming, isFalse);
    });

    test('фильтр гасит шум вокруг истинной точки', () {
      final f = GpsKalmanFilter();
      final t = DateTime(2024, 1, 1, 12);
      const trueLat = 55.75, trueLng = 37.62;
      // jitter ±5м в lat (≈4.5e-5 градусов)
      final noisy = [
        [trueLat + 4e-5, trueLng - 3e-5],
        [trueLat - 4e-5, trueLng + 2e-5],
        [trueLat + 3e-5, trueLng + 1e-5],
        [trueLat - 2e-5, trueLng - 2e-5],
        [trueLat + 1e-5, trueLng + 1e-5],
      ];
      KalmanPoint? last;
      for (var i = 0; i < noisy.length; i++) {
        last = f.update(
          lat: noisy[i][0], lng: noisy[i][1], accuracy: 5,
          ts: t.add(Duration(seconds: i)),
        );
      }
      // отклонение сглаженной точки от истинной < 5 м
      final err = distanceMeters(last!.lat, last.lng, trueLat, trueLng);
      expect(err, lessThan(5));
    });
  });

  group('GpsKalmanFilter — speed reject', () {
    test('прыжок 1 км за 1 сек (1000 м/с) отбрасывается', () {
      final f = GpsKalmanFilter();
      final t = DateTime(2024, 1, 1, 12);
      f.update(lat: 55.75, lng: 37.62, accuracy: 5, ts: t);
      final jump = f.update(
        lat: 55.76, lng: 37.62, accuracy: 5,
        ts: t.add(const Duration(seconds: 1)),
      );
      expect(jump, isNull, reason: 'прыжок должен быть отброшен (>12 м/с)');
    });

    test('ходовая скорость 5 м/с не отбрасывается', () {
      final f = GpsKalmanFilter();
      final t = DateTime(2024, 1, 1, 12);
      f.update(lat: 55.75, lng: 37.62, accuracy: 5, ts: t);
      // +5 м к северу через 1с
      final next = destinationPoint(55.75, 37.62, 0, 5);
      final p = f.update(
        lat: next.lat, lng: next.lng, accuracy: 5,
        ts: t.add(const Duration(seconds: 1)),
      );
      expect(p, isNotNull);
    });
  });

  group('GpsKalmanFilter — gap detection', () {
    test('пауза >30с сбрасывает variance и заново warmup', () {
      final f = GpsKalmanFilter();
      final t = DateTime(2024, 1, 1, 12);
      // прогрев
      for (var i = 0; i < 5; i++) {
        f.update(
          lat: 55.75, lng: 37.62, accuracy: 5,
          ts: t.add(Duration(seconds: i)),
        );
      }
      // gap 60с
      final afterGap = f.update(
        lat: 55.76, lng: 37.63, accuracy: 5,
        ts: t.add(const Duration(seconds: 65)),
      );
      // первая точка после gap — warming=true и она сама же
      expect(afterGap!.warming, isTrue);
      expect(afterGap.lat, 55.76);
      expect(afterGap.lng, 37.63);
    });
  });

  group('GpsKalmanFilter — drift detection (засада)', () {
    test('6 шумных точек в радиусе <15м с плохим accuracy → stationary=true', () {
      final f = GpsKalmanFilter();
      final t = DateTime(2024, 1, 1, 12);
      const baseLat = 55.75, baseLng = 37.62;
      // 6 точек в радиусе ~5м с accuracy 20м (типично для засады в густом лесу)
      final samples = [
        [baseLat + 2e-5, baseLng - 2e-5],
        [baseLat - 1e-5, baseLng + 3e-5],
        [baseLat + 3e-5, baseLng + 1e-5],
        [baseLat - 2e-5, baseLng - 1e-5],
        [baseLat + 1e-5, baseLng + 2e-5],
        [baseLat - 3e-5, baseLng - 2e-5],
      ];
      KalmanPoint? last;
      for (var i = 0; i < samples.length; i++) {
        last = f.update(
          lat: samples[i][0], lng: samples[i][1], accuracy: 20,
          ts: t.add(Duration(seconds: i * 2)),
        );
      }
      expect(last!.stationary, isTrue,
          reason: 'после 6 близких точек с плохим accuracy должен сработать drift detect');
      // позиция близка к центру кластера
      expect(distanceMeters(last.lat, last.lng, baseLat, baseLng),
          lessThan(5));
    });

    test('движение по прямой 50м не считается stationary', () {
      final f = GpsKalmanFilter();
      final t = DateTime(2024, 1, 1, 12);
      const startLat = 55.75, startLng = 37.62;
      KalmanPoint? last;
      // 6 точек, по 10м на север, accuracy 5м (открытое поле)
      for (var i = 0; i < 6; i++) {
        final p = destinationPoint(startLat, startLng, 0, i * 10.0);
        last = f.update(
          lat: p.lat, lng: p.lng, accuracy: 5,
          ts: t.add(Duration(seconds: i * 2)),
        );
      }
      expect(last!.stationary, isFalse,
          reason: '50м прямого хода — точно не засада');
    });

    test('хороший accuracy не триггерит drift даже при малом смещении', () {
      // Сценарий: игрок реально стоит, но GPS точный (5м). Тогда метка
      // на карте может «дрожать» — это терпимо. Drift нужен только когда
      // accuracy плохой и движения нет.
      final f = GpsKalmanFilter();
      final t = DateTime(2024, 1, 1, 12);
      const baseLat = 55.75, baseLng = 37.62;
      KalmanPoint? last;
      for (var i = 0; i < 6; i++) {
        last = f.update(
          lat: baseLat + (i.isEven ? 1e-5 : -1e-5),
          lng: baseLng + (i.isEven ? 1e-5 : -1e-5),
          accuracy: 5, // хороший
          ts: t.add(Duration(seconds: i * 2)),
        );
      }
      expect(last!.stationary, isFalse);
    });
  });

  group('GpsKalmanFilter — reset', () {
    test('reset очищает состояние', () {
      final f = GpsKalmanFilter();
      final t = DateTime(2024, 1, 1, 12);
      for (var i = 0; i < 5; i++) {
        f.update(
          lat: 55.75, lng: 37.62, accuracy: 5,
          ts: t.add(Duration(seconds: i)),
        );
      }
      f.reset();
      final p = f.update(
        lat: 56.0, lng: 38.0, accuracy: 5,
        ts: t.add(const Duration(seconds: 100)),
      );
      expect(p!.warming, isTrue);
      expect(p.lat, 56.0);
    });
  });
}
