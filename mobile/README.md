# AirsoftMap — Mobile (Flutter)

## Bootstrap

Платформенные папки (`android/`, `ios/`, ...) пока не созданы — их генерирует `flutter create`. Из директории `mobile/`:

```bash
flutter create --org com.airsoftmap --project-name airsoftmap .
flutter pub get
```

Это сгенерирует нативные обёртки, не трогая существующие `lib/`, `pubspec.yaml`, `analysis_options.yaml`.

## Конфиг

Создай `lib/core/config/supabase_config.dart` (он в `.gitignore` как пример):

```dart
class SupabaseConfig {
  static const String url = '<твой-supabase-url>';
  static const String anonKey = '<твой-anon-key>';
  static const String apiBaseUrl = 'http://10.0.2.2:8080'; // Android emulator → host
}
```

## Запуск

```bash
flutter run
```

## Кодген (Drift)

```bash
dart run build_runner build --delete-conflicting-outputs
```
