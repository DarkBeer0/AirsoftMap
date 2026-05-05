import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CommandScreen extends ConsumerWidget {
  const CommandScreen({super.key});

  // TODO: Список members с pull-to-refresh, drag&drop в отряды,
  // назначение ролей (organizer / side_commander / squad_leader / soldier).

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Распределение')),
      body: const Center(
        child: Text('TODO: drag&drop members → squads + роли'),
      ),
    );
  }
}
