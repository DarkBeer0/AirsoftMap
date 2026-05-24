import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/games_api.dart';
import '../../core/session/game_session.dart';

/// Композитное состояние экрана распределения.
class CommandData {
  final List<SideInfo> sides;
  final List<SquadInfo> squads;
  final List<MemberInfo> members;
  const CommandData({
    required this.sides,
    required this.squads,
    required this.members,
  });
}

class CommandDataNotifier
    extends FamilyAsyncNotifier<CommandData, String> {
  @override
  Future<CommandData> build(String gameId) => _load(gameId);

  Future<CommandData> _load(String gameId) async {
    final api = ref.read(gamesApiProvider);
    final results = await Future.wait([
      api.listSides(gameId),
      api.listSquads(gameId),
      api.listMembers(gameId),
    ]);
    return CommandData(
      sides: results[0] as List<SideInfo>,
      squads: results[1] as List<SquadInfo>,
      members: results[2] as List<MemberInfo>,
    );
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _load(arg));
  }
}

final commandDataProvider = AsyncNotifierProvider.family<
    CommandDataNotifier, CommandData, String>(CommandDataNotifier.new);

class CommandScreen extends ConsumerWidget {
  const CommandScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(gameSessionProvider);
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Распределение')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Нет активной игры'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => context.go('/lobby'),
                child: const Text('В лобби'),
              ),
            ],
          ),
        ),
      );
    }
    final asyncData = ref.watch(commandDataProvider(session.gameId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Распределение'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.read(commandDataProvider(session.gameId).notifier).refresh(),
          ),
          IconButton(
            tooltip: 'На карту',
            icon: const Icon(Icons.map_outlined),
            onPressed: () => context.go('/battle'),
          ),
        ],
      ),
      body: asyncData.when(
        data: (data) => _CommandBody(session: session, data: data),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorView(
          message: '$e',
          onRetry: () => ref
              .read(commandDataProvider(session.gameId).notifier)
              .refresh(),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.white54),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Повторить')),
          ],
        ),
      ),
    );
  }
}

class _CommandBody extends ConsumerWidget {
  final GameSession session;
  final CommandData data;
  const _CommandBody({required this.session, required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Какие стороны показывать: organizer — все; side_commander — свою;
    // остальные — только свою (с ограниченным UI «ты в отряде …»).
    final visibleSides = session.isOrganizer
        ? data.sides
        : data.sides.where((s) => s.id == session.sideId).toList();

    if (visibleSides.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Ты ещё не привязан к стороне.\nПопроси организатора назначить.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return DefaultTabController(
      length: visibleSides.length,
      child: Column(
        children: [
          if (visibleSides.length > 1)
            TabBar(
              isScrollable: true,
              tabs: visibleSides
                  .map((s) => Tab(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: _parseHex(s.color) ?? Colors.grey,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(s.name),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          Expanded(
            child: TabBarView(
              children: visibleSides
                  .map((side) => _SideView(
                        session: session,
                        side: side,
                        data: data,
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _SideView extends ConsumerWidget {
  final GameSession session;
  final SideInfo side;
  final CommandData data;
  const _SideView({
    required this.session,
    required this.side,
    required this.data,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final squads = data.squads.where((sq) => sq.sideId == side.id).toList();
    final sideMembers =
        data.members.where((m) => m.sideId == side.id).toList();
    final unassigned = sideMembers.where((m) => m.squadId == null).toList();
    final color = _parseHex(side.color) ?? Colors.green;

    final canManage = session.isOrganizer ||
        (session.role == 'side_commander' && session.sideId == side.id);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _SquadCard(
          title: 'Без отряда',
          color: color,
          members: unassigned,
          squadId: null,
          gameId: session.gameId,
          accent: false,
          canDrop: canManage,
          session: session,
        ),
        for (final sq in squads)
          _SquadCard(
            title: sq.name,
            color: color,
            members: sideMembers.where((m) => m.squadId == sq.id).toList(),
            squadId: sq.id,
            gameId: session.gameId,
            accent: true,
            canDrop: canManage,
            session: session,
          ),
        if (canManage) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _addSquadDialog(context, ref),
            icon: const Icon(Icons.group_add),
            label: const Text('Новый отряд'),
          ),
        ],
      ],
    );
  }

  Future<void> _addSquadDialog(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Отряд в «${side.name}»'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Название отряда'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(gamesApiProvider)
          .createSquad(session.gameId, sideId: side.id, name: name);
      await ref
          .read(commandDataProvider(session.gameId).notifier)
          .refresh();
    } on DioException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Ошибка: ${e.response?.statusCode ?? e.message}'),
      ));
    }
  }
}

class _SquadCard extends ConsumerWidget {
  final String title;
  final Color color;
  final List<MemberInfo> members;
  final String? squadId; // null → «Без отряда»
  final String gameId;
  final bool accent;
  final bool canDrop;
  final GameSession session;

  const _SquadCard({
    required this.title,
    required this.color,
    required this.members,
    required this.squadId,
    required this.gameId,
    required this.accent,
    required this.canDrop,
    required this.session,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = DragTarget<MemberInfo>(
      onWillAcceptWithDetails: (details) =>
          canDrop && details.data.squadId != squadId,
      onAcceptWithDetails: (details) =>
          _onAccept(context, ref, details.data),
      builder: (ctx, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: hovering
                ? color.withOpacity(0.25)
                : Colors.black.withOpacity(0.25),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: hovering ? color : (accent ? color : Colors.white24),
              width: hovering ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (accent)
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  if (accent) const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '· ${members.length}',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (members.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '—',
                    style: TextStyle(color: Colors.white38),
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: members
                      .map((m) => _MemberChip(
                            member: m,
                            color: color,
                            draggable: canDrop,
                            onTap: () => _showActions(context, ref, m),
                          ))
                      .toList(),
                ),
            ],
          ),
        );
      },
    );
    return card;
  }

  Future<void> _onAccept(
      BuildContext context, WidgetRef ref, MemberInfo m) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // squadId=null → присвоить empty string на бэке = "не менять".
      // Для backend-семантики COALESCE мы не можем «снять» squad через PATCH
      // (это feature долга, фаза 3). На MVP — если перетаскиваем в «Без отряда»,
      // делаем noop с уведомлением.
      if (squadId == null) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Снятие из отряда — TODO (бэк не поддерживает null squad)'),
        ));
        return;
      }
      await ref.read(gamesApiProvider).updateMember(
            gameId,
            m.id,
            squadId: squadId,
          );
      await ref.read(commandDataProvider(gameId).notifier).refresh();
    } on DioException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Не удалось: ${e.response?.statusCode ?? e.message}'),
      ));
    }
  }

  Future<void> _showActions(
      BuildContext context, WidgetRef ref, MemberInfo m) async {
    if (!canDrop) return;
    final isOrganizer = session.isOrganizer;
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(m.callsign, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Текущая роль: ${m.role}'),
            ),
            const Divider(height: 1),
            if (isOrganizer)
              ListTile(
                leading: const Icon(Icons.stars),
                title: const Text('Сделать командиром стороны'),
                onTap: () => Navigator.pop(ctx, 'side_commander'),
              ),
            ListTile(
              leading: const Icon(Icons.military_tech),
              title: const Text('Сделать лидером отряда'),
              onTap: () => Navigator.pop(ctx, 'squad_leader'),
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Сбросить в бойца'),
              onTap: () => Navigator.pop(ctx, 'soldier'),
            ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(gamesApiProvider)
          .updateMember(gameId, m.id, role: selected);
      await ref.read(commandDataProvider(gameId).notifier).refresh();
    } on DioException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Не удалось: ${e.response?.statusCode ?? e.message}'),
      ));
    }
  }
}

class _MemberChip extends StatelessWidget {
  final MemberInfo member;
  final Color color;
  final bool draggable;
  final VoidCallback onTap;
  const _MemberChip({
    required this.member,
    required this.color,
    required this.draggable,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final chip = _buildChip(context);
    if (!draggable) return chip;
    return LongPressDraggable<MemberInfo>(
      data: member,
      feedback: Material(
        color: Colors.transparent,
        child: Transform.scale(scale: 1.05, child: _buildChip(context, dragging: true)),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: chip),
      child: chip,
    );
  }

  Widget _buildChip(BuildContext context, {bool dragging = false}) {
    final icon = switch (member.role) {
      'organizer' => Icons.shield,
      'side_commander' => Icons.stars,
      'squad_leader' => Icons.military_tech,
      _ => Icons.person,
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: dragging ? color : color.withOpacity(0.85),
          borderRadius: BorderRadius.circular(20),
          boxShadow: dragging
              ? const [BoxShadow(color: Colors.black54, blurRadius: 6)]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 14),
            const SizedBox(width: 6),
            Text(
              member.callsign,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (member.status != 'alive') ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  member.status,
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Color? _parseHex(String hex) {
  final s = hex.replaceAll('#', '').trim();
  if (s.length == 6) return Color(int.parse('FF$s', radix: 16));
  if (s.length == 8) return Color(int.parse(s, radix: 16));
  return null;
}
