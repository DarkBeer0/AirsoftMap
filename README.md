# AirsoftMap

Тактический трекер для страйкбола. Координация игроков, BMS-инструменты для организатора и командиров, интуитивная навигация для рядовых бойцов. Главное УТП — мгновенный старт по QR-коду без сложных настроек.

---

## Текущий статус

**Фаза 0 — проектирование (этот документ).** Кода пока нет.

---

## Концепция

### Роли

- **Организатор** — создаёт игру, нарезает карту полигона, настраивает стороны и точки возрождения, выдаёт QR-коды.
- **Командир стороны / лидер отряда** — раскидывает игроков по отрядам, ставит глобальные/тактические метки.
- **Боец** — сканирует QR, видит карту, союзников, свои метки, отмечает противника.

### Ключевой UX

1. **QR-вход за 5 секунд.** Сканер на главном экране → подключение к игре → фоновое скачивание карт-пака пока игрок ещё на базе с Wi-Fi.
2. **Audio-first.** Телефон в подсумке. Важные события озвучивает наушник через системный TTS: «Новая метка: противник, 100 метров, северо-запад».
3. **Боевая карта в 2D с изолиниями высот.** Высокая контрастность для чтения на солнце, низкое потребление батареи.
4. **Жёсткий статус «Убит».** Большая красная кнопка → метка игрока серая для союзников → экран показывает только маршрут до ближайшего мертвяка → опрос врагов прекращается (никаких подсказок «с того света») → GPS в режиме экономии до конца таймера возрождения.
5. **Offline-first.** В лесу нет связи. Карта, метки, маршрут к мертвяку, компас — всё работает локально. Координаты досылаются при появлении сети.

### Гибридная модель карт (важно)

У обычного организатора нет готового MBTiles полигона. Поэтому на этапе создания игры (на базе, есть интернет):

1. Организатор открывает мировую карту, **рисует прямоугольник вокруг полигона**.
2. Приложение скачивает топографические тайлы (OpenTopoMap) для выбранных зумов (12–17) и упаковывает их в **MBTiles SQLite**.
3. Файл загружается в **Supabase Storage** и привязывается к игре.
4. Игрок при сканировании QR качает .mbtiles (5–30MB) на устройство.
5. На устройстве MapLibre получает тайлы через **локальный HTTP-сервер** (`shelf` на 127.0.0.1) поверх MBTiles.
6. Дальше — полностью оффлайн.

Это снимает зависимость от уличной связи и от SLA публичных тайл-серверов.

---

## Технологический стек (Zero Budget)

### Mobile (Flutter)

| Компонент | Технология | Пакет / Ссылка |
|---|---|---|
| Фреймворк | **Flutter** (Dart) | https://flutter.dev |
| Карты | **MapLibre GL** (native, raster MBTiles) | `maplibre_gl` |
| Топо-тайлы (онлайн) | **OpenTopoMap** (изолинии встроены) | https://opentopomap.org |
| Оффлайн-тайлы | **MBTiles** + локальный HTTP-сервер | `shelf`, `sqlite3_flutter_libs` |
| QR-сканер | `mobile_scanner` (ML Kit) | pub.dev |
| QR-генерация | `qr_flutter` | pub.dev |
| Геолокация | `geolocator` + `flutter_foreground_task` | pub.dev |
| Компас / азимут | `flutter_compass` | pub.dev |
| Акселерометр (smart GPS) | `sensors_plus` | pub.dev |
| Голос (TTS, оффлайн) | **`flutter_tts`** (системный движок) | pub.dev |
| Стейт-менеджмент | **Riverpod** | `flutter_riverpod` |
| Локальный кэш | **Drift** (SQLite) | `drift` + `sqlite3_flutter_libs` |
| Авторизация | **Supabase Flutter** (анонимные сессии) | `supabase_flutter` |
| HTTP-клиент | **Dio** | `dio` |
| WebSocket | `web_socket_channel` | pub.dev |
| Push | **Firebase Cloud Messaging** | `firebase_messaging` |

### Backend (Go)

| Компонент | Технология | Ссылка |
|---|---|---|
| Язык | **Go** | https://go.dev |
| HTTP-фреймворк | **Gin** | `github.com/gin-gonic/gin` |
| WebSocket-хаб | **coder/websocket** | `github.com/coder/websocket` |
| ORM / SQL | **sqlx** | `github.com/jmoiron/sqlx` |
| Миграции | Кастомный мигратор (`cmd/migrate`) | — |

WS-хаб написан вручную, а не через Supabase Realtime, чтобы держать на сервере жёсткую фильтрацию: «убитый игрок не получает позиции врагов», «игрок видит только свою сторону», «организатор видит всех».

### Инфраструктура (всё бесплатно)

| Компонент | Сервис | Лимиты Free Tier |
|---|---|---|
| Хостинг API | **Oracle Cloud Free Tier** | 2 ARM VM, 4 CPU, 24GB RAM — навсегда бесплатно |
| База данных | **Supabase Free** (PostgreSQL 17 + PostGIS) | 500MB, 50k MAU |
| Auth | **Supabase Auth** (анонимные сессии + ES256 JWT) | Бесплатно |
| Файлы / карт-паки | **Supabase Storage** | 1GB |
| Push | **Firebase Cloud Messaging** | Без лимитов |
| CI/CD | **GitHub Actions** | 2000 мин/мес |

### Возможные траты

| Что | Стоимость | Когда |
|---|---|---|
| Google Play | $25 разово | При публикации |
| Apple Developer | $99/год | Можно отложить |
| Домен | ~$10/год | Опционально |

---

## Архитектура

```
┌────────────────────────────────────────────┐
│             Flutter App                    │
│  MapLibre GL ← localhost:NNNN/{z}/{x}/{y} │
│         ↑                                   │
│  shelf-сервер ← MBTiles (Drift/SQLite)    │
│  GPS + Kalman + drift detection            │
│  flutter_tts (offline voice events)        │
│  WS-клиент / REST через Dio                │
└──────────┬─────────────────────────────────┘
           │ HTTPS + WebSocket
           v
┌────────────────────────────────────────────┐
│   Go API (Gin)                             │
│   REST + WebSocket hub                     │
│   JWT валидация (ES256 / Supabase JWKS)    │
│   Фильтрация WS broadcast по правилам:     │
│   - сторона / отряд                        │
│   - "убит" → не получает позиции врагов   │
│   - метка с visibility → roles             │
└──────┬─────────────────────────────────────┘
       │
       v
┌────────────────────────────────────────────┐
│  Supabase PostgreSQL 17 + PostGIS          │
│  ──────────────────────────────────────── │
│  profiles, games, sides, squads,           │
│  game_members (role, callsign, status),    │
│  spawn_points, markers (visibility),       │
│  events (kills, respawns, captures)        │
│                                            │
│  Supabase Storage:                         │
│  /map-packs/{game_id}.mbtiles              │
└────────────────────────────────────────────┘
```

### Основные API эндпоинты

**Публичные:**

| Метод | Путь | Описание |
|---|---|---|
| GET | `/health` | Health check |
| POST | `/api/v1/games/join` | Вход по коду/QR (возвращает game_id, side, map_pack_url) |

**Защищённые (Bearer JWT):**

| Метод | Путь | Описание |
|---|---|---|
| POST | `/api/v1/games` | Создать игру |
| PATCH | `/api/v1/games/:id` | Изменить настройки (стороны, мертвяки) |
| POST | `/api/v1/games/:id/map-pack` | Загрузить ссылку на MBTiles в Storage |
| POST | `/api/v1/games/:id/qr` | Сгенерировать пригласительный код |
| GET | `/api/v1/games/:id/members` | Список подключившихся (для распределения) |
| PATCH | `/api/v1/games/:id/members/:uid` | Назначить отряд / роль |
| POST | `/api/v1/games/:id/markers` | Создать метку (с visibility) |
| GET | `/api/v1/games/:id/markers` | Видимые метки (фильтрация на сервере) |
| POST | `/api/v1/games/:id/kills` | Зафиксировать «убит» |
| POST | `/api/v1/games/:id/respawn` | Зафиксировать возрождение |
| GET | `/api/v1/ws?game=...` | WebSocket (позиции + события) |

---

## Ключевые алгоритмы

### Скачивание тайлов и упаковка в MBTiles

1. Организатор рисует bbox на карте мира, выбирает диапазон зумов (по умолчанию 12–17).
2. Считаем ожидаемое число тайлов (для 5 км² и зумов 12–17 ≈ 1500–4000 тайлов).
3. Если оценка > 50 MB — предупреждаем и предлагаем сократить зум.
4. Скачиваем через Dio батчами (concurrency 4), сохраняем в MBTiles SQLite по схеме `tiles(zoom_level, tile_column, tile_row, tile_data BLOB)`.
5. PUT в Supabase Storage `/map-packs/{game_id}.mbtiles`.
6. Игроки качают по подписанному URL при join.
7. На устройстве `shelf` поднимает локальный HTTP-сервер, отдающий тайлы из BLOB → MapLibre конфигурируется на `http://127.0.0.1:{port}/{z}/{x}/{y}.png`.

Лицензия OpenTopoMap (CC BY-SA 3.0) разрешает кэширование тайлов для офлайн-использования при соблюдении атрибуции — её показываем в углу карты.

### GPS-фильтрация (порт из TurfStep)

Перенос как есть: 1D-Калман на lat/lng, gap detection (>30с пауза → soft reset + warmup 3 чтения), drift detection (6 точек, net-displacement <15м + accuracy >14м → stationary), speed check (>12 м/с → отбрасывание).

### Smart GPS (энергосбережение)

- Активное движение (acc magnitude > 1.2g за 3с) → `LocationAccuracy.best`, интервал 1с.
- Стационарное состояние (засада, акселерометр спит) → `LocationAccuracy.balanced`, интервал 10с.
- Статус «Убит» → интервал 30с + позиции врагов не запрашиваются.
- Экран можно гасить — foreground service Android держит GPS и TTS.

### Real-time фильтрация на сервере

Каждое WS-сообщение перед broadcast проходит через middleware:

```go
// псевдокод
func canSee(receiver Member, packet Packet) bool {
    if receiver.Role == OrganizerRole { return true }
    if packet.Type == PositionPacket {
        if receiver.Status == Dead { return false } // никаких подсказок
        return packet.Author.Side == receiver.Side
    }
    if packet.Type == MarkerPacket {
        return matchesVisibility(packet.Marker.Visibility, receiver)
    }
    return false
}
```

### Audio-first события

Очередь TTS-сообщений с приоритетами:
- `critical` (организатор объявил отбой, ты убит) — прерывает всё
- `tactical` (новая метка противника, командир назначил сбор) — стандарт
- `info` (союзник возродился) — низкий, может быть пропущен

Сообщение собирается шаблоном с подстановкой азимута/дистанции относительно текущей позиции игрока.

### Offline-first и синхронизация

- События (kill, respawn, marker) пишутся в Drift с флагом `synced=false`.
- При появлении сети — батч `POST /events/sync`.
- Сервер применяет события идемпотентно (uuid v4 на клиенте).
- Конфликты: server wins для статусов (организатор может «оживить» вручную), client merge для меток.

---

## Структура проекта

```
airsoftmap/
├── mobile/                              # Flutter
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app.dart
│   │   ├── features/
│   │   │   ├── lobby/                   # QR-сканер, ввод кода, фоновое скачивание
│   │   │   ├── game_create/             # Bbox на карте, нарезка тайлов, стороны
│   │   │   ├── command/                 # Распределение по отрядам, роли
│   │   │   ├── battle_map/              # Боевая карта, метки, компас, азимут
│   │   │   ├── kill_state/              # Экран "убит" → маршрут до мертвяка
│   │   │   └── voice/                   # TTS-очередь, шаблоны фраз
│   │   └── core/
│   │       ├── auth/                    # Supabase anon sessions
│   │       ├── api/                     # Dio + JWT
│   │       ├── ws/                      # WS-клиент с переподключением
│   │       ├── gps/                     # Kalman + smart polling
│   │       ├── map/
│   │       │   ├── mbtiles_server.dart  # shelf-сервер на localhost
│   │       │   ├── tile_downloader.dart # пакетное скачивание
│   │       │   └── offline_cache.dart   # Drift для тайлов
│   │       └── storage/                 # Drift схемы
│   └── pubspec.yaml
│
├── backend/                             # Go API
│   ├── Dockerfile
│   ├── cmd/
│   │   ├── api/main.go
│   │   └── migrate/main.go
│   ├── internal/
│   │   ├── handler/                     # games, members, markers, kills, ws
│   │   ├── service/                     # бизнес-логика, фильтрация WS
│   │   ├── repository/
│   │   ├── model/
│   │   ├── middleware/                  # JWT (Supabase JWKS)
│   │   └── websocket/                   # hub + правила видимости
│   ├── migrations/
│   │   ├── 001_init.up.sql              # profiles, games, sides, squads
│   │   ├── 002_members.up.sql           # game_members, roles, status
│   │   └── 003_markers_events.up.sql
│   └── go.mod
│
└── .gitignore
```

---

## План разработки по фазам

### Фаза 1 — Каркас + одиночный flow (MVP организатора)

- [ ] Flutter-проект, Riverpod, базовая навигация (Lobby / Create / Battle)
- [ ] Supabase Auth (анонимные сессии)
- [ ] Drift схемы (games, members, markers, events, tiles)
- [ ] MapLibre + онлайн OpenTopoMap (без оффлайна)
- [ ] Экран создания игры: bbox на карте → загрузка тайлов → MBTiles
- [ ] `shelf`-сервер на localhost для отдачи MBTiles
- [ ] Переключение MapLibre на локальный источник
- [ ] Go-бэкенд: миграции, модели games/members
- [ ] Эндпоинты создания/получения игры
- [ ] Загрузка MBTiles в Supabase Storage

### Фаза 2 — Лобби, QR, распределение

- [ ] Сканер QR (`mobile_scanner`)
- [ ] Генерация QR (`qr_flutter`)
- [ ] Эндпоинт `/games/join` по коду
- [ ] Фоновое скачивание map-pack из Storage сразу после join
- [ ] Экран распределения (drag&drop, роли)
- [ ] Командирский экран

### Фаза 3 — Боевая карта + real-time

- [ ] GPS + Kalman (порт из TurfStep)
- [ ] Компас + азимут до точки
- [ ] WS-клиент с переподключением
- [ ] WS-хаб на Go с фильтрацией по сторонам/ролям/статусу
- [ ] Метки с visibility
- [ ] Smart-GPS на основе акселерометра

### Фаза 4 — Статус «Убит» + аудио

- [ ] Экран «Убит» с маршрутом до ближайшего мертвяка
- [ ] Серверная фильтрация: dead → не шлём позиции врагов
- [ ] `flutter_tts` с очередью приоритетов
- [ ] Шаблоны фраз для событий
- [ ] Hands-free режим (экран гаснет, голос работает)

### Фаза 5 — Полировка и публикация

- [ ] Push (FCM) для зова на сбор / отбоя игры
- [ ] Оффлайн-режим: батч-синхронизация событий
- [ ] Темная тема для OLED
- [ ] Деплой Go API на Oracle Cloud
- [ ] Публикация в Google Play

---

## Локальный запуск

### Backend

```bash
cd backend
cp .env.example .env  # DATABASE_URL, SUPABASE_JWT_SECRET, PORT
go run cmd/migrate/main.go
go run cmd/api/main.go
```

### Mobile

```bash
cd mobile
flutter pub get
# настроить Supabase ключи в lib/core/config/supabase_config.dart
flutter run
```

---

## Оценка проекта

| Параметр | Значение |
|---|---|
| Оригинальность | 7/10 (своя ниша — страйкбол-BMS) |
| Сложность | 8/10 (offline-карты, real-time фильтрация, audio-first) |
| Минимальная команда | 1 разработчик |
| Срок MVP | 2–3 месяца |
| Бюджет на старте | $0 |
