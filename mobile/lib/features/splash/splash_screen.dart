import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Внутренний splash на стороне Flutter. Поверх него на Android/iOS
/// показывается нативный splash из flutter_native_splash (тот висит, пока
/// движок Flutter ещё грузится). Этот экран — мост: подсвечивает бренд,
/// даёт ~1.2 секунды на доинициализацию Riverpod-провайдеров и
/// переходит на /lobby.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  static const _holdDuration = Duration(milliseconds: 1200);

  @override
  void initState() {
    super.initState();
    // post-frame, чтобы router был полностью смонтирован.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleNext());
  }

  Future<void> _scheduleNext() async {
    await Future.delayed(_holdDuration);
    if (!mounted) return;
    context.go('/lobby');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B5E20), // dark green — фирменный фон
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _Monogram(),
              const SizedBox(height: 24),
              const Text(
                'AirsoftMap',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Тактический трекер',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 48),
              const SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Простая монограмма «AM» в круге — используется и как fallback для
/// нативной иконки, если генерация PNG ещё не отработала.
class _Monogram extends StatelessWidget {
  const _Monogram();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 128,
      height: 128,
      decoration: BoxDecoration(
        color: const Color(0xFF4CAF50),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: const Text(
        'AM',
        style: TextStyle(
          fontSize: 56,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          letterSpacing: -2,
        ),
      ),
    );
  }
}
