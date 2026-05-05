import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/lobby/lobby_screen.dart';
import 'features/game_create/game_create_screen.dart';
import 'features/command/command_screen.dart';
import 'features/battle_map/battle_map_screen.dart';
import 'features/kill_state/kill_state_screen.dart';

final _router = GoRouter(
  initialLocation: '/lobby',
  routes: [
    GoRoute(path: '/lobby', builder: (_, __) => const LobbyScreen()),
    GoRoute(path: '/create', builder: (_, __) => const GameCreateScreen()),
    GoRoute(path: '/command', builder: (_, __) => const CommandScreen()),
    GoRoute(path: '/battle', builder: (_, __) => const BattleMapScreen()),
    GoRoute(path: '/dead', builder: (_, __) => const KillStateScreen()),
  ],
);

class AirsoftMapApp extends ConsumerWidget {
  const AirsoftMapApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'AirsoftMap',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF4CAF50),
      ),
      routerConfig: _router,
    );
  }
}
