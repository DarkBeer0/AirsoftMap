import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class KillStateScreen extends ConsumerWidget {
  const KillStateScreen({super.key});

  // TODO:
  //  - GpsService.setMode(GpsMode.dead) — экономия батареи
  //  - WS: сервер уже не шлёт нам позиции врагов (фильтрация на сервере)
  //  - Маршрут до ближайшего spawn_point (по прямой + азимут)
  //  - Таймер возрождения (organiser-set)
  //  - По истечении → POST /respawn → context.go('/battle')

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'УБИТ',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'Маршрут до мертвяка',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, color: Colors.white70),
              ),
              const SizedBox(height: 16),
              const Center(
                child: Icon(Icons.navigation, size: 120, color: Colors.white54),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => context.go('/battle'),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Возродиться (TODO: таймер)'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
