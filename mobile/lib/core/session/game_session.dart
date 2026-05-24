import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/games_api.dart';

/// Доменная модель текущей сессии. Унифицирует случаи «соldier по QR» и
/// «organizer после создания игры» — на боевой карте нам нужно одно и то же:
/// gameId/callsign/role + опциональная сторона.
class GameSession {
  final String gameId;
  final String gameName;
  final String callsign;
  final String role; // organizer | side_commander | squad_leader | soldier

  /// У организатора стороны нет — поля null.
  final String? sideId;
  final String? sideName;
  final String? sideColor;

  final String? mapPackUrl;

  const GameSession({
    required this.gameId,
    required this.gameName,
    required this.callsign,
    required this.role,
    this.sideId,
    this.sideName,
    this.sideColor,
    this.mapPackUrl,
  });

  bool get isOrganizer => role == 'organizer';
  bool get hasSide => sideId != null;

  factory GameSession.fromJoin(JoinResult r) => GameSession(
        gameId: r.gameId,
        gameName: r.gameName,
        callsign: r.callsign,
        role: r.role,
        sideId: r.sideId,
        sideName: r.sideName,
        sideColor: r.sideColor,
        mapPackUrl: r.mapPackUrl,
      );

  factory GameSession.forOrganizer(CreatedGame g) => GameSession(
        gameId: g.id,
        gameName: g.name,
        callsign: 'Organizer',
        role: 'organizer',
      );
}

/// Состояние текущей игры. Заполняется после join (soldier) или после
/// Create (organizer); очищается при выходе.
class GameSessionNotifier extends Notifier<GameSession?> {
  @override
  GameSession? build() => null;

  void setFromJoin(JoinResult result) => state = GameSession.fromJoin(result);
  void setForOrganizer(CreatedGame g) => state = GameSession.forOrganizer(g);
  void clear() => state = null;
}

final gameSessionProvider =
    NotifierProvider<GameSessionNotifier, GameSession?>(GameSessionNotifier.new);
