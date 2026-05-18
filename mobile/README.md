# AirsoftMap — Mobile (Flutter)

## Bootstrap

Платформенные папки (`android/`, `ios/`, ...) пока не созданы — их генерирует `flutter create`. Из директории `mobile/`:

```bash
flutter create --org com.airsoftmap --project-name airsoftmap .
flutter pub get
```

Это сгенерирует нативные обёртки, не трогая существующие `lib/`, `pubspec.yaml`, `analysis_options.yaml`.

## Конфиг

Скопируй `lib/core/config/supabase_config.dart.example` → `supabase_config.dart` и подставь свои значения:

```dart
class SupabaseConfig {
  static const String url = '<твой-supabase-url>';
  static const String anonKey = '<твой-anon-key>';
  static const String apiBaseUrl = 'http://10.0.2.2:8080'; // Android emulator → host
  static const String wsBaseUrl  = 'ws://10.0.2.2:8080';
}
```

`supabase_config.dart` — в `.gitignore`, секреты не коммитим.

Также в Supabase Auth → Providers → **Anonymous Sign-Ins** должно быть включено (мы используем анонимные сессии при join).

## Запуск

```bash
flutter run
```

## Кодген (Drift)

После любого изменения `lib/core/storage/database.dart`:

```bash
dart run build_runner build --delete-conflicting-outputs
```
