import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

class GamesTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get joinCode => text()();
  TextColumn get mapPackPath => text().nullable()();
  RealColumn get bboxMinLng => real().nullable()();
  RealColumn get bboxMinLat => real().nullable()();
  RealColumn get bboxMaxLng => real().nullable()();
  RealColumn get bboxMaxLat => real().nullable()();
  TextColumn get status => text().withDefault(const Constant('lobby'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

class MarkersTable extends Table {
  TextColumn get id => text()();
  TextColumn get gameId => text()();
  TextColumn get authorId => text()();
  TextColumn get kind => text()();
  TextColumn get visibility => text().withDefault(const Constant('side'))();
  RealColumn get lng => real()();
  RealColumn get lat => real()();
  TextColumn get label => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class EventsTable extends Table {
  TextColumn get id => text()(); // uuid v4 на клиенте → идемпотентность
  TextColumn get gameId => text()();
  TextColumn get type => text()(); // kill | respawn | objective_capture
  TextColumn get payload => text().nullable()(); // JSON
  DateTimeColumn get occurredAt => dateTime()();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [GamesTable, MarkersTable, EventsTable])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  @override
  int get schemaVersion => 1;

  // ─── Outbox событий (offline-first) ──────────────────────────────────────

  /// Положить событие в outbox (synced=false). Идемпотентно по id —
  /// повторный enqueue того же uuid не плодит дубли.
  Future<void> enqueueEvent({
    required String id,
    required String gameId,
    required String type,
    required DateTime occurredAt,
    String? payload,
  }) {
    return into(eventsTable).insert(
      EventsTableCompanion.insert(
        id: id,
        gameId: gameId,
        type: type,
        occurredAt: occurredAt,
        payload: Value(payload),
        synced: const Value(false),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// Несинхронизированные события игры, в порядке occurred_at.
  Future<List<EventsTableData>> pendingEvents(String gameId) {
    return (select(eventsTable)
          ..where((t) => t.gameId.equals(gameId) & t.synced.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.occurredAt)]))
        .get();
  }

  /// Пометить события синхронизированными после успешного POST /events/sync.
  Future<void> markSynced(List<String> ids) {
    if (ids.isEmpty) return Future.value();
    return (update(eventsTable)..where((t) => t.id.isIn(ids)))
        .write(const EventsTableCompanion(synced: Value(true)));
  }
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'airsoftmap.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

/// Единый экземпляр БД на приложение.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
