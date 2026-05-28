import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/events_api.dart';
import '../storage/database.dart';

/// EventSyncService — durable-слой для kill/respawn (offline-first).
///
/// Поток:
///   1. Игрок умирает/возрождается → `enqueue*` пишет событие в Drift-outbox
///      (synced=false) с клиентским uuid. Это переживает оффлайн и краш.
///   2. `flush` (вызывается после успешного online-действия и на WS-reconnect)
///      батчем шлёт несинхронизированное на POST /events/sync и помечает synced.
///
/// Сервер идемпотентен по uuid: если online-путь (/kills с тем же event_id)
/// уже применил событие, sync его просто пропустит — без двойного учёта.
class EventSyncService {
  final AppDatabase _db;
  final EventsApi _api;
  bool _flushing = false;

  EventSyncService(this._db, this._api);

  Future<void> enqueueKill({
    required String gameId,
    required String eventId,
    required DateTime occurredAt,
  }) {
    return _db.enqueueEvent(
      id: eventId,
      gameId: gameId,
      type: 'kill',
      occurredAt: occurredAt,
    );
  }

  Future<void> enqueueRespawn({
    required String gameId,
    required String eventId,
    required DateTime occurredAt,
  }) {
    return _db.enqueueEvent(
      id: eventId,
      gameId: gameId,
      type: 'respawn',
      occurredAt: occurredAt,
    );
  }

  /// Слить outbox на сервер. Безопасно вызывать часто — повторный вызов во
  /// время активного флаша игнорируется, ошибки сети глотаются (попробуем позже).
  Future<void> flush(String gameId) async {
    if (_flushing) return;
    _flushing = true;
    try {
      final pending = await _db.pendingEvents(gameId);
      if (pending.isEmpty) return;

      final batch = pending
          .map((e) => OutboxEvent(
                id: e.id,
                type: e.type,
                occurredAt: e.occurredAt,
                payload: _decode(e.payload),
              ))
          .toList();

      await _api.syncEvents(gameId, batch);
      // Сервер идемпотентен: что принято и что уже было — всё равно считаем
      // доставленным, помечаем synced, чтобы не слать повторно.
      await _db.markSynced(pending.map((e) => e.id).toList());
    } catch (_) {
      // Нет связи / 5xx — оставляем в outbox, повторим на следующем flush.
    } finally {
      _flushing = false;
    }
  }

  Map<String, dynamic>? _decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final v = jsonDecode(payload);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}

final eventSyncServiceProvider = Provider<EventSyncService>((ref) {
  return EventSyncService(
    ref.read(appDatabaseProvider),
    ref.read(eventsApiProvider),
  );
});
