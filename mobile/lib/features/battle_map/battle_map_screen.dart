import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class BattleMapScreen extends ConsumerWidget {
  const BattleMapScreen({super.key});

  // TODO:
  //  - MapLibreMapController с raster source = MbtilesServer.tileUrl
  //  - Слой: позиции союзников (подписаны WS)
  //  - Слой: метки (фильтр visibility на сервере)
  //  - Long-press → создать метку (выбор kind + visibility)
  //  - Компас + азимут до выбранной точки
  //  - Большая красная "УБИТ" → /dead

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Stack(
        children: [
          const Center(child: Text('TODO: MapLibre + слои меток/позиций')),
          Positioned(
            right: 16,
            bottom: 32,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              ),
              onPressed: () => context.go('/dead'),
              child: const Text(
                'УБИТ',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
