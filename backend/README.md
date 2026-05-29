# AirsoftMap — Backend (Go)

## Bootstrap

```bash
cd backend
cp .env.example .env  # заполнить переменные (см. ниже)
go mod tidy
go run cmd/migrate/main.go   # применит все migrations/*.up.sql по порядку
go run cmd/api/main.go
```

Проверка перед коммитом: `go build ./... && go vet ./...`.

## Переменные окружения

| Переменная | Обязательна | Описание |
|---|---|---|
| `DATABASE_URL` | да | DSN PostgreSQL (Supabase), напр. `postgres://...` |
| `SUPABASE_JWT_SECRET` | да | Shared secret для валидации JWT (HS256) |
| `SUPABASE_JWKS_URL` | нет | Задел под ES256/JWKS (пока не используется) |
| `PORT` | нет | Порт HTTP-сервера (по умолчанию `8080`) |
| `MIGRATIONS_DIR` | нет | Каталог миграций для `cmd/migrate` (по умолчанию `migrations`) |

## Эндпоинты

Полный перечень с описанием и статусом — в корневом `README.md` (раздел
«Основные API эндпоинты»). Реализованы все, кроме `PATCH /games/:id` (501,
зарезервировано) и `POST /games/:id/qr` (QR генерится на клиенте из join_code).

WS-хаб держит in-memory кэш членства и применяет правила видимости на сервере:
organizer видит всё; убитый не получает позиции живых; position — внутри своей
стороны; marker — по visibility (`MarkerService.CanSee`); kill/respawn — союзникам.

## Миграции

Кастомный forward-only мигратор (`cmd/migrate`): применяет `migrations/*.up.sql`
по алфавиту, фиксирует применённые в `schema_migrations`. Откатов нет — новые
изменения добавляются новым файлом `NNN_*.up.sql`.

## Docker

```bash
docker build -t airsoftmap-api:latest .
docker run -d -p 8080:8080 \
  -e DATABASE_URL='...' \
  -e SUPABASE_JWT_SECRET='...' \
  airsoftmap-api:latest

# Миграции:
docker run --rm -e DATABASE_URL='...' --entrypoint /app/migrate airsoftmap-api:latest
```
