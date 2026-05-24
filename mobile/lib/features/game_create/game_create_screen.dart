import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api/games_api.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/session/game_session.dart';

/// Создание игры организатором.
///
/// Двухшаговый flow:
///   1. _Step.form     — название + список сторон с цветами.
///   2. _Step.created  — QR-коды join_code'ов сторон для раздачи на базе.
///
/// Bbox и map-pack — задача Фазы 2 (TileDownloader + Supabase Storage),
/// пока создаём игру «голой» и переходим на боевую карту с онлайн OpenTopoMap.
class GameCreateScreen extends ConsumerStatefulWidget {
  const GameCreateScreen({super.key});

  @override
  ConsumerState<GameCreateScreen> createState() => _GameCreateScreenState();
}

enum _Step { form, created }

class _SideDraft {
  final TextEditingController name;
  Color color;
  _SideDraft({required String initialName, required this.color})
      : name = TextEditingController(text: initialName);
  void dispose() => name.dispose();
}

class _GameCreateScreenState extends ConsumerState<GameCreateScreen> {
  static const _palette = <Color>[
    Color(0xFFE53935), // red
    Color(0xFF1E88E5), // blue
    Color(0xFF43A047), // green
    Color(0xFFFB8C00), // orange
    Color(0xFF8E24AA), // purple
    Color(0xFFFDD835), // yellow
    Color(0xFF00ACC1), // cyan
    Color(0xFFEC407A), // pink
  ];

  final _nameCtrl = TextEditingController(text: 'Игра');
  final _formKey = GlobalKey<FormState>();
  late final List<_SideDraft> _sides;

  _Step _step = _Step.form;
  bool _submitting = false;
  CreatedGame? _created;

  @override
  void initState() {
    super.initState();
    _sides = [
      _SideDraft(initialName: 'Красные', color: _palette[0]),
      _SideDraft(initialName: 'Синие', color: _palette[1]),
    ];
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final s in _sides) {
      s.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_step == _Step.form ? 'Создание игры' : 'Игра создана'),
        leading: BackButton(
          onPressed: () => context.go('/lobby'),
        ),
      ),
      body: switch (_step) {
        _Step.form => _buildForm(),
        _Step.created => _buildCreated(),
      },
    );
  }

  // --- Form ---

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Название игры',
              border: OutlineInputBorder(),
            ),
            maxLength: 80,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Укажите название' : null,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Стороны',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_sides.length < 8)
                TextButton.icon(
                  onPressed: _addSide,
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ..._sides.asMap().entries.map((e) => _buildSideRow(e.key, e.value)),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: _submitting
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Создать игру', style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }

  Widget _buildSideRow(int index, _SideDraft side) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _pickColor(index),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: side.color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 2),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: side.name,
              decoration: const InputDecoration(
                labelText: 'Название стороны',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLength: 40,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Имя стороны' : null,
            ),
          ),
          if (_sides.length > 1)
            IconButton(
              tooltip: 'Удалить сторону',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _removeSide(index),
            ),
        ],
      ),
    );
  }

  void _addSide() {
    final usedColors = _sides.map((s) => s.color).toSet();
    final nextColor = _palette.firstWhere(
      (c) => !usedColors.contains(c),
      orElse: () => _palette[_sides.length % _palette.length],
    );
    setState(() {
      _sides.add(_SideDraft(
        initialName: 'Сторона ${_sides.length + 1}',
        color: nextColor,
      ));
    });
  }

  void _removeSide(int index) {
    final removed = _sides.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  Future<void> _pickColor(int index) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Цвет стороны'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _palette
              .map(
                (c) => GestureDetector(
                  onTap: () => Navigator.pop(ctx, c),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() => _sides[index].color = picked);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 1. Гарантируем JWT — без него Create вернёт 401.
      await ref.read(authServiceProvider).ensureSignedIn();

      // 2. POST /games.
      final game = await ref.read(gamesApiProvider).create(
            name: _nameCtrl.text.trim(),
            sides: _sides
                .map((s) => SideInput(
                      name: s.name.text.trim(),
                      color: _hex(s.color),
                    ))
                .toList(),
          );

      // 3. Сохраняем organizer-сессию (без стороны), её прочитает battle_map.
      ref.read(gameSessionProvider.notifier).setForOrganizer(game);

      if (!mounted) return;
      setState(() {
        _created = game;
        _step = _Step.created;
      });
    } on DioException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Ошибка создания: ${e.response?.statusCode ?? e.message}'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // --- Created (QR-коды) ---

  Widget _buildCreated() {
    final created = _created!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          created.name,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'Код игры: ${created.joinCode}',
          style: const TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 16),
        const Text(
          'Покажи QR-коды бойцам:',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        ...created.sides.map(_sideQrCard),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => context.go('/battle'),
          icon: const Icon(Icons.map_outlined),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('На карту', style: TextStyle(fontSize: 18)),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => context.go('/lobby'),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('В лобби'),
          ),
        ),
      ],
    );
  }

  Widget _sideQrCard(CreatedSide side) {
    final color = _parseHex(side.color) ?? Colors.green;
    final code = side.joinCode ?? '—';
    // Deeplink, который lobby умеет распарсить; на случай старых сканеров
    // под код подписан сам raw-код тоже.
    final qrData = 'airsoftmap://join/$code';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    side.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Скопировать код',
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () => _copy(code),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: Colors.white,
                child: QrImageView(
                  data: qrData,
                  size: 220,
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Код скопирован')),
    );
  }

  // --- helpers ---

  String _hex(Color c) =>
      '#${c.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

Color? _parseHex(String hex) {
  final s = hex.replaceAll('#', '').trim();
  if (s.length == 6) return Color(int.parse('FF$s', radix: 16));
  if (s.length == 8) return Color(int.parse(s, radix: 16));
  return null;
}
