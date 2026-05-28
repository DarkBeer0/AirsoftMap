# AirsoftMap

Тактический трекер для страйкбола. Координация игроков, BMS-инструменты для организатора и командиров, интуитивная навигация для рядовых бойцов. Главное УТП — мгновенный старт по QR-коду без сложных настроек.

---

## Текущий статус

**Фазы 1–4 завершены, Фаза 5 в работе.** Полный flow: организатор создаёт игру (настраивает таймер респауна слайдером 30–300с) → опционально скачивает топо-пачку полигона в MBTiles и заливает в Supabase Storage → раздаёт QR-коды сторон → бойцы сканируют → у всех (включая организатора) на боевой карте показывается локальная топо-карта, собственная позиция (Kalman-сглаживание + smart-GPS), позиции союзников реал-тайм через WS и метки (с серверной фильтрацией по visibility). Организатор long-press'ом ставит точки возрождения (привязка к стороне, флаг «база») — они рисуются на карте и используются экраном мертвяка. Организатор и командиры сторон распределяют бойцов по отрядам через drag&drop. При нажатии «УБИТ» — экран мертвяка с таймером респауна (из настройки игры), стрелкой азимута до ближайшей точки возрождения своей стороны и системным TTS «Убит. Двигайся к мертвяку». Новые метки союзников озвучиваются голосом с дистанцией и кардиналом («Новая метка: противник, 120 метров, СВ»).

Что уже работает end-to-end:

- **Backend** (`backend/`, `go build ./...` + `go vet` чисты):
  - 5 миграций (games / sides / spawn_points / squads / game_members / markers / events + триггер `auth.users → profiles` + `games.respawn_seconds`)
  - `POST /api/v1/games` — атомарное создание игры + сторон + organizer-member в транзакции, генерация уникальных кодов (читаемый алфавит без `O/0/I/1/L`)
  - `POST /api/v1/games/join` — вход по коду стороны, идемпотентный upsert (повторный join сохраняет role/status)
  - `GET /api/v1/games/:id/members` — список с фильтром по правам: organizer / side_commander видят всех, остальные — только свою сторону; не-член получает 403
  - `POST /api/v1/games/:id/map-pack` — записать URL Storage и (опц.) bbox; доступно только организатору
  - `GET /api/v1/games/:id/sides` — список сторон (любой член игры)
  - `GET /api/v1/games/:id/squads` — список отрядов всех сторон
  - `POST /api/v1/games/:id/squads` — создать отряд (organizer / side_commander своей стороны)
  - `PATCH /api/v1/games/:id/members/:uid` — назначение `side_id` / `squad_id` / `role` / `callsign` с проверкой прав: organizer — всё, кроме понижения себя; side_commander — только свою сторону, не может выдать `organizer`-роль; squad должен принадлежать целевой стороне; инвалидирует WS-кэш членства
  - `POST /api/v1/games/:id/markers` — создать метку с серверной валидацией visibility (organizers-метку имеет право поставить только organizer), проверкой bbox игры (D1) и автоподстановкой side/squad автора; броадкаст в WS с фильтрацией по `MarkerService.CanSee`
  - `GET /api/v1/games/:id/markers` — список видимых текущему игроку (отфильтрованы истёкшие и недоступные по visibility)
  - `POST /api/v1/games/:id/spawn-points` — поставить точку возрождения (organizer-only, bbox-валидация); `GET` — список (любой член игры)
  - `POST /api/v1/games/:id/kills` — игрок отметил себя убитым: status=dead, respawn_until=now+60с, event-запись, WS-broadcast `kill` союзникам, инвалидация member-кэша
  - `POST /api/v1/games/:id/respawn` — снять статус мёртвого после таймера: status=alive, event, WS-broadcast `respawn`
  - `GET /api/v1/ws?game=...` — WS-хаб с in-memory кэшем `game_members` (warm на connect, инвалидация на assignment-update и kill/respawn); правила: organizer видит всё, dead не получает позиций живых, position между членами одной стороны, marker — через CanSee, kill/respawn — союзникам
  - JWT-валидация (HS256) на всех защищённых эндпоинтах
- **Mobile** (требует локально `flutter pub get` + `dart run build_runner build` + `supabase_config.dart` + Storage bucket `map-packs`):
  - Лобби с QR-сканером (deeplink `airsoftmap://join/<code>`) и ручным вводом → анонимная Supabase-сессия → `POST /games/join` → сохранение в Riverpod-сессии → переход на боевую карту
  - Экран создания игры: имя + 1..8 сторон с палитрой, опциональный switch «Оффлайн-карта» (центр через GPS + slider 0.5–5 км, оценка тайлов и MB с предупреждением >70 MB) → POST → прогресс скачивания тайлов → upload в Supabase Storage → PATCH → QR-коды сторон (`qr_flutter`, deeplink + копирование в буфер)
  - `TileDownloader` с очередью worker-ов на shared iterator, User-Agent, exp-backoff retry, batched INSERT в одной транзакции, MBTiles metadata (bounds/minzoom/maxzoom/attribution)
  - `MbtilesServer` (shelf на loopback) поднимается из боевой карты, MapLibre рендерит raster через `http://127.0.0.1:{port}/tiles/{z}/{x}/{y}.png`; при ошибке оффлайн-пачки — fallback на онлайн OpenTopoMap с баннером
  - Боевая карта: динамический style (offline/online), нативный GPS-маркер с трекингом и компасом, плашка `сторона / позывной / роль` (organizer — серая точка + имя игры), атрибуция CC-BY-SA, кнопка «УБИТ» → переключение GPS в low-power lock и переход на экран мертвяка
  - GPS-разрешения запрашиваются с retry-баннером при отказе
  - Полный Kalman-фильтр (gap reset >30с с warmup на 3 чтения, drift detection 6 точек/15м/14м-acc → stationary medium, speed >12 м/с → дроп) + adaptive measurement noise по accuracy
  - `MotionService` (sensors_plus, акселерометр без g) — гистерезис 0.2/0.6 м/с², пересылка → `GpsService.setMode(battle|stationary)`; dead имеет приоритет
  - WS-клиент `WsService`: exp-backoff 1→2→4→8→16→30с с jitter, heartbeat ping 25с, watchdog 60с без incoming → forced reconnect; троттлинг позиций 3с; стрим `connectionState` показывается баннером
  - В боевой карте: WS подключается на входе, входящие `position` → круги союзников (цвет = стороны); long-press по карте → bottom-sheet (тип метки + visibility + label) → POST → broadcast → круги меток. Компас (`flutter_compass`) показывает розу севера в углу
  - `MarkersApi` — типизированные `MarkerKind` / `MarkerVisibility` + DTO; начальная загрузка через GET, далее обновления через WS
  - `EventsApi` — POST /kills, POST /respawn, GET/POST /spawn-points (типизированные DTO `KillResult` / `SpawnPointInfo`)
  - `TtsService` (`flutter_tts`, ru-RU): очередь с приоритетами `critical | tactical | info`, инициализация в `main` через `ProviderContainer`. На входящий WS-marker (от союзника) клиент формирует фразу `Новая метка: <тип>, <дистанция>, <кардинал>` (или без азимута, если своя позиция ещё не получена). На kill/respawn — `Союзник убит / возродился`. Свои события не озвучиваются
  - Экран `/dead`: при входе POST /kills → `GpsService.markDead()` → подгрузка spawn-points → выбор ближайшего к моей стороне (или общего, side_id == null) → крутящаяся стрелка азимута (компас минус bearing), под ней дистанция + кардинал. Таймер обратного отсчёта из respawn_until сервера; при потере связи — локальный 60-секундный fallback с пометкой. По кнопке/таймеру → POST /respawn → `markAlive()` → `/battle`. Критические TTS-фразы прерывают очередь
  - `GameSession` (Riverpod) — единая доменная модель для soldier/organizer; `setMapPack` обновляет URL после upload
  - Лобби после join делает фоновый prefetch map-pack через `MapPackCache` (общий для lobby/battle_map/game_create — идемпотентный `ensure(gameId, url)`)
  - Командирский экран `/command`: tabs по сторонам (organizer видит все, side_commander — только свою), карточки отрядов как `DragTarget`, члены как `LongPressDraggable` chips с иконкой роли; tap → ModalBottomSheet с выбором новой роли; кнопка «+ Отряд»; auto-refresh после каждого изменения

Открытые риски (Фаза 5): нет foreground-сервиса для GPS и shelf-сервера (C6/C7) — Android прибьёт WS/shelf при долгом backgrounding; нет батч-синхронизации событий при отсутствии связи (kill/respawn пока теряются, если сервер недоступен); таймер респауна (60с) хардкоден — фаза 5 вынесет в game.respawn_seconds; UI для постановки spawn-points (organizer кладёт их через POST, через UI пока нет — фаза 5 добавит long-press опцию «точка возрождения» рядом с метками).

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

- [x] Flutter-проект, Riverpod, базовая навигация (Lobby / Create / Battle)
- [x] Supabase Auth (анонимные сессии)
- [x] Drift схемы (games, markers, events) — *локально требует `dart run build_runner build` для `database.g.dart`*
- [x] MapLibre + онлайн OpenTopoMap (без оффлайна)
- [x] Экран создания игры: форма + стороны + QR-коды (через `qr_flutter`)
- [x] Экран создания игры: bbox (через GPS-центр + size) → загрузка тайлов → MBTiles
- [x] `shelf`-сервер на localhost для отдачи MBTiles
- [x] Переключение MapLibre на локальный источник
- [x] Go-бэкенд: миграции (4 шт) + модели games/sides/members/markers/events
- [x] Эндпоинты: `POST /games`, `POST /games/join`, `GET /games/:id/members`, `POST /games/:id/map-pack`
- [x] Загрузка MBTiles в Supabase Storage

### Фаза 2 — Лобби, QR, распределение

- [x] Сканер QR (`mobile_scanner`)
- [x] Генерация QR (`qr_flutter`)
- [x] Эндпоинт `/games/join` по коду
- [x] Фоновое скачивание map-pack из Storage сразу после join
- [x] Экран распределения (drag&drop, роли)
- [x] Командирский экран (`/command` — tabs по сторонам, drag&drop в отряды)

### Фаза 3 — Боевая карта + real-time

- [x] GPS + Kalman (порт из TurfStep — gap/drift/speed/adaptive noise)
- [x] Компас + азимут до точки (`flutter_compass` + `geo.dart` утилиты bearing/cardinal8/distanceMeters)
- [x] WS-клиент с переподключением (exp-backoff + heartbeat + watchdog)
- [x] WS-хаб на Go с фильтрацией по сторонам/ролям/статусу (+ in-memory кэш членства)
- [x] Метки с visibility (backend + mobile UI: long-press → bottom-sheet → POST → broadcast)
- [x] Smart-GPS на основе акселерометра (`MotionService` → автоматическое переключение режимов)

### Фаза 4 — Статус «Убит» + аудио

- [x] Экран «Убит» с маршрутом до ближайшего мертвяка (стрелка-компас + дистанция + таймер, fallback при потере связи)
- [x] Серверная фильтрация: dead → не шлём позиции врагов (в WS-хабе через member-кэш)
- [x] `flutter_tts` с очередью приоритетов (critical/tactical/info, critical прерывает текущее)
- [x] Шаблоны фраз для событий (markers / kill / respawn / убит-критикал)
- [ ] Hands-free режим (экран гаснет, голос работает) — нужен foreground-service, в Фазе 5

### Фаза 5 — Полировка и публикация

- [x] Конфигурируемое время респауна (game.respawn_seconds, слайдер в создании игры)
- [x] UI постановки точек возрождения (organizer long-press → spawn) + отрисовка на карте
- [ ] Push (FCM) для зова на сбор / отбоя игры
- [ ] Оффлайн-режим: батч-синхронизация событий
- [ ] Foreground-service для GPS/WS/shelf (C6/C7) + hands-free
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
dart run build_runner build          # сгенерирует database.g.dart (он в .gitignore)
cp lib/core/config/supabase_config.dart.example lib/core/config/supabase_config.dart
# отредактировать supabase_config.dart с твоими ключами
flutter run
```

Если нужно перегенерировать иконки и splash после изменения исходных PNG:

```bash
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

Дополнительно в Supabase:

- Auth → Providers → **Anonymous Sign-Ins** = enabled
- Storage → New bucket → **`map-packs`**, public = yes (иначе организатор не сможет залить .mbtiles)
- Если миграция `004_profiles_trigger.up.sql` упала на правах — прогнать её через **SQL Editor** под ролью postgres

Permissions уже прописаны в `mobile/android/app/src/main/AndroidManifest.xml`: `INTERNET`, `ACCESS_FINE_LOCATION`/`ACCESS_BACKGROUND_LOCATION`, `CAMERA`, `FOREGROUND_SERVICE_LOCATION`, `WAKE_LOCK`, плюс `<intent-filter>` для deeplink `airsoftmap://join/<code>`. На iOS в `Info.plist` доустанови `NSLocationWhenInUseUsageDescription` и `NSCameraUsageDescription` при первой публикации.

---

## Установка debug-APK на телефон

Для быстрого тест-прогона без сборки руками:

```bash
cd mobile
flutter build apk --debug
# готовый файл: mobile/build/app/outputs/flutter-apk/app-debug.apk (~200 MB)
```

Перенос на телефон:

1. На устройстве: **Настройки → Безопасность → Установка из неизвестных источников** → разрешить для проводника/мессенджера, через который копируешь APK.
2. Залить APK любым способом — USB-кабель, Telegram «Saved messages», Google Drive, Bluetooth, `adb install`.
3. Открыть APK на телефоне, подтвердить установку.
4. Запустить **AirsoftMap** (зелёная иконка «AM»). Загрузится тёмно-зелёный splash, потом лобби.

Перед реальным использованием в коде должен быть прописан `supabase_config.dart` с боевыми ключами Supabase. В debug-сборке без них работают только UI и оффлайн-карта; авторизация / Storage / сервер вернут ошибку соединения.

Размер 200 MB у debug-APK — это норма (включены JIT, debug-символы, все ABI). Для боевой раздачи нужна release-сборка: `flutter build apk --release --split-per-abi` даст 3 файла по 30–50 MB.

---

## Оценка проекта

| Параметр | Значение |
|---|---|
| Оригинальность | 7/10 (своя ниша — страйкбол-BMS) |
| Сложность | 8/10 (offline-карты, real-time фильтрация, audio-first) |
| Минимальная команда | 1 разработчик |
| Срок MVP | 2–3 месяца |
| Бюджет на старте | $0 |
