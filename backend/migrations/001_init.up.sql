-- profiles: 1:1 c auth.users, дополнительные поля
CREATE TABLE IF NOT EXISTS profiles (
    id          UUID PRIMARY KEY,
    callsign    TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- games
CREATE TABLE IF NOT EXISTS games (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organizer_id  UUID NOT NULL REFERENCES profiles(id),
    name          TEXT NOT NULL,
    join_code     TEXT NOT NULL UNIQUE,
    bbox_min_lng  DOUBLE PRECISION,
    bbox_min_lat  DOUBLE PRECISION,
    bbox_max_lng  DOUBLE PRECISION,
    bbox_max_lat  DOUBLE PRECISION,
    map_pack_url  TEXT,
    status        TEXT NOT NULL DEFAULT 'lobby',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_games_organizer ON games(organizer_id);
CREATE INDEX IF NOT EXISTS idx_games_status    ON games(status);

-- sides (стороны / команды)
CREATE TABLE IF NOT EXISTS sides (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id    UUID NOT NULL REFERENCES games(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    color      TEXT NOT NULL,
    join_code  TEXT UNIQUE
);

CREATE INDEX IF NOT EXISTS idx_sides_game ON sides(game_id);

-- spawn_points (мертвяки + базы)
CREATE TABLE IF NOT EXISTS spawn_points (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id   UUID NOT NULL REFERENCES games(id) ON DELETE CASCADE,
    side_id   UUID REFERENCES sides(id) ON DELETE CASCADE,
    name      TEXT NOT NULL,
    lng       DOUBLE PRECISION NOT NULL,
    lat       DOUBLE PRECISION NOT NULL,
    is_base   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_spawn_game ON spawn_points(game_id);
