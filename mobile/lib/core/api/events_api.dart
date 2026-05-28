import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';

class KillResult {
  final String status;
  final DateTime respawnUntil;
  const KillResult({required this.status, required this.respawnUntil});
  factory KillResult.fromJson(Map<String, dynamic> j) => KillResult(
        status: j['status'] as String,
        respawnUntil: DateTime.parse(j['respawn_until'] as String),
      );
}

class SpawnPointInfo {
  final String id;
  final String gameId;
  final String? sideId;
  final String name;
  final double lng;
  final double lat;
  final bool isBase;

  const SpawnPointInfo({
    required this.id,
    required this.gameId,
    required this.name,
    required this.lng,
    required this.lat,
    required this.isBase,
    this.sideId,
  });

  factory SpawnPointInfo.fromJson(Map<String, dynamic> j) => SpawnPointInfo(
        id: j['id'] as String,
        gameId: j['game_id'] as String,
        sideId: j['side_id'] as String?,
        name: j['name'] as String,
        lng: (j['lng'] as num).toDouble(),
        lat: (j['lat'] as num).toDouble(),
        isBase: (j['is_base'] as bool?) ?? false,
      );
}

class EventsApi {
  final Dio _dio;
  EventsApi(this._dio);

  /// POST /games/:id/kills. Сервер выставит status=dead + respawn_until,
  /// сделает broadcast type=kill союзникам. eventId — общий с outbox uuid,
  /// чтобы последующий /events/sync не задвоил событие.
  Future<KillResult> kill(String gameId, {String? eventId}) async {
    final res = await _dio.post('/games/$gameId/kills', data: {
      if (eventId != null) 'event_id': eventId,
    });
    return KillResult.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST /games/:id/respawn. После таймера или организаторского решения.
  Future<void> respawn(String gameId, {String? eventId}) async {
    await _dio.post('/games/$gameId/respawn', data: {
      if (eventId != null) 'event_id': eventId,
    });
  }

  Future<List<SpawnPointInfo>> listSpawnPoints(String gameId) async {
    final res = await _dio.get('/games/$gameId/spawn-points');
    final raw = (res.data['spawn_points'] as List).cast<Map<String, dynamic>>();
    return raw.map(SpawnPointInfo.fromJson).toList(growable: false);
  }

  /// Только organizer. Если sideId == null — точка нейтральная (общая).
  Future<SpawnPointInfo> createSpawnPoint(
    String gameId, {
    String? sideId,
    required String name,
    required double lng,
    required double lat,
    bool isBase = false,
  }) async {
    final res = await _dio.post('/games/$gameId/spawn-points', data: {
      if (sideId != null) 'side_id': sideId,
      'name': name,
      'lng': lng,
      'lat': lat,
      'is_base': isBase,
    });
    return SpawnPointInfo.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST /games/:id/events/sync — батч офлайн-событий из outbox.
  /// Сервер применяет идемпотентно (по uuid), возвращает число принятых.
  Future<int> syncEvents(String gameId, List<OutboxEvent> events) async {
    if (events.isEmpty) return 0;
    final res = await _dio.post('/games/$gameId/events/sync', data: {
      'events': events.map((e) => e.toJson()).toList(),
    });
    return (res.data['accepted'] as num?)?.toInt() ?? 0;
  }
}

/// Сериализуемое представление события для batch-sync.
class OutboxEvent {
  final String id;
  final String type;
  final DateTime occurredAt;
  final Map<String, dynamic>? payload;
  const OutboxEvent({
    required this.id,
    required this.type,
    required this.occurredAt,
    this.payload,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'occurred_at': occurredAt.toUtc().toIso8601String(),
        if (payload != null) 'payload': payload,
      };
}

final eventsApiProvider = Provider<EventsApi>((ref) {
  return EventsApi(ref.read(apiClientProvider).dio);
});
