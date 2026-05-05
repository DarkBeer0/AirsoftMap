# AirsoftMap — Backend (Go)

## Bootstrap

```bash
cd backend
cp .env.example .env  # заполнить DATABASE_URL и SUPABASE_JWT_SECRET
go mod tidy
go run cmd/migrate/main.go
go run cmd/api/main.go
```

## Эндпоинты

См. корневой README. На текущем этапе хендлеры возвращают 501 — наполним по фазам.

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
