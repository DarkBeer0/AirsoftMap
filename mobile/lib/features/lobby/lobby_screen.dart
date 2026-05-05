import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class LobbyScreen extends ConsumerStatefulWidget {
  const LobbyScreen({super.key});

  @override
  ConsumerState<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends ConsumerState<LobbyScreen> {
  bool _scanning = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              const Text(
                'AirsoftMap',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: _scanning ? _buildScanner() : _buildIdle(),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => context.go('/create'),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Создать игру', style: TextStyle(fontSize: 18)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIdle() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: () => setState(() => _scanning = true),
          icon: const Icon(Icons.qr_code_scanner, size: 32),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('Сканировать QR', style: TextStyle(fontSize: 22)),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _showCodeDialog,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('Ввести код'),
          ),
        ),
      ],
    );
  }

  Widget _buildScanner() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: MobileScanner(
        onDetect: (capture) {
          final code = capture.barcodes.firstOrNull?.rawValue;
          if (code == null) return;
          _onJoinCode(code);
        },
      ),
    );
  }

  Future<void> _showCodeDialog() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Код игры'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'XXXXXX'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Войти'),
          ),
        ],
      ),
    );
    if (code != null && code.isNotEmpty) _onJoinCode(code);
  }

  void _onJoinCode(String code) {
    setState(() => _scanning = false);
    // TODO: POST /games/join → загрузка map-pack → push /command
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('TODO: join $code')),
    );
  }
}
