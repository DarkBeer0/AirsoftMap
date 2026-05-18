import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/games_api.dart';

/// Состояние текущей игровой сессии. Заполняется после успешного join
/// и читается боевой картой / killscreen / WS-клиентом.
///
/// Очищается при выходе из игры (TODO: добавить кнопку «покинуть»).
class GameSessionNotifier extends Notifier<JoinResult?> {
  @override
  JoinResult? build() => null;

  void set(JoinResult result) => state = result;
  void clear() => state = null;
}

final gameSessionProvider =
    NotifierProvider<GameSessionNotifier, JoinResult?>(GameSessionNotifier.new);
