import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class GameCreateScreen extends ConsumerStatefulWidget {
  const GameCreateScreen({super.key});

  @override
  ConsumerState<GameCreateScreen> createState() => _GameCreateScreenState();
}

class _GameCreateScreenState extends ConsumerState<GameCreateScreen> {
  // TODO: Шаги:
  //  1) MapLibre с онлайн-OpenTopoMap, выбор bbox (рисование прямоугольника).
  //  2) TileDownloader.tilesForBbox + предупреждение если > 50 MB.
  //  3) downloadToMbtiles → файл во временной директории.
  //  4) PUT в Supabase Storage /map-packs/{game_id}.mbtiles.
  //  5) POST /games (организатор + bbox + map_pack_url).
  //  6) Настройка сторон, мертвяков → POST /games/:id/sides, /spawn-points.
  //  7) Генерация QR через qr_flutter.

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Создание игры')),
      body: const Center(
        child: Text('TODO: bbox → tile download → стороны → QR'),
      ),
    );
  }
}
