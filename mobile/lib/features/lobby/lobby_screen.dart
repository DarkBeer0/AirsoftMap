import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/api/games_api.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/map/map_pack_cache.dart';
import '../../core/session/game_session.dart';

class LobbyScreen extends ConsumerStatefulWidget {
  const LobbyScreen({super.key});

  @override
  ConsumerState<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends ConsumerState<LobbyScreen> {
  bool _scanning = false;
  bool _joining = false;

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
                onPressed: _joining ? null : () => context.go('/create'),
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
    if (_joining) {
      return const Center(child: CircularProgressIndicator());
    }
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
        title: const Text('Код стороны'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'XXXXX'),
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

  Future<void> _onJoinCode(String code) async {
    if (_joining) return; // защита от двойного срабатывания сканера
    setState(() {
      _scanning = false;
      _joining = true;
    });

    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    try {
      // 1. Гарантируем анонимную Supabase-сессию → JWT для нашего API.
      await ref.read(authServiceProvider).ensureSignedIn();

      // 2. POST /games/join — код может прийти как deeplink airsoftmap://join/CODE
      //    (если организатор сгенерировал QR с префиксом) или как голый код.
      final cleanCode = _extractCode(code);
      final result =
          await ref.read(gamesApiProvider).joinBySideCode(cleanCode);

      // 3. Сохраняем сессию — её прочитают battle_map / ws / kill_state.
      ref.read(gameSessionProvider.notifier).setFromJoin(result);

      messenger.showSnackBar(SnackBar(
        content: Text(
          'Подключено: ${result.gameName} / ${result.sideName} · ${result.callsign}',
        ),
      ));

      // 4. Префетч map-pack в фоне (без await) — пока пользователь идёт на
      // /battle, скачивание уже стартовало. battle_map увидит файл на диске.
      final mapUrl = result.mapPackUrl;
      if (mapUrl != null && mapUrl.isNotEmpty) {
        unawaited(
          ref.read(mapPackCacheProvider).ensure(
                gameId: result.gameId,
                url: mapUrl,
              ),
        );
      }

      router.go('/battle');
    } on DioException catch (e) {
      final msg = switch (e.response?.statusCode) {
        404 => 'Неверный код',
        401 => 'Ошибка авторизации',
        _ => 'Ошибка соединения: ${e.message ?? e.type.name}',
      };
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  /// Принимает как голый код (`ABCDE`), так и deeplink `airsoftmap://join/ABCDE`.
  /// Если ничего не распознано — возвращает trimmed-uppercase исходник, а
  /// валидацию переложит на сервер (404 invalid join code).
  String _extractCode(String raw) {
    final m = RegExp(
      r'airsoftmap://join/([A-Za-z0-9]+)',
      caseSensitive: false,
    ).firstMatch(raw);
    final code = m?.group(1) ?? raw;
    return code.trim().toUpperCase();
  }
}
