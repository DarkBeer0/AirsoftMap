import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/supabase_config.dart';
import 'features/voice/tts_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
  );

  // TTS инициализируется один раз. Игнорируем ошибку (некоторые эмуляторы
  // не имеют системного движка) — приложение работает молча.
  final container = ProviderContainer();
  try {
    await container.read(ttsServiceProvider).init();
  } catch (_) {/* нет TTS — продолжаем */}

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const AirsoftMapApp(),
    ),
  );
}
