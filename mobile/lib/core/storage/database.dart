import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
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
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'airsoftmap.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
