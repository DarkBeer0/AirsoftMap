CREATE TABLE IF NOT EXISTS markers (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id     UUID NOT NULL REFERENCES games(id) ON DELETE CASCADE,
    author_id   UUID NOT NULL REFERENCES profiles(id),
    kind        TEXT NOT NULL,
    visibility  TEXT NOT NULL DEFAULT 'side',
    side_id     UUID REFERENCES sides(id),
    squad_id    UUID REFERENCES squads(id),
    lng         DOUBLE PRECISION NOT NULL,
    lat         DOUBLE PRECISION NOT NULL,
    label       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_markers_game ON markers(game_id);
CREATE INDEX IF NOT EXISTS idx_markers_visibility ON markers(game_id, visibility);

-- events: id генерится клиентом (uuid v4) → идемпотентная отправка батчем при синке.
CREATE TABLE IF NOT EXISTS events (
    id           UUID PRIMARY KEY,
    game_id      UUID NOT NULL REFERENCES games(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES profiles(id),
    type         TEXT NOT NULL,
    payload      JSONB,
    occurred_at  TIMESTAMPTZ NOT NULL,
    received_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_events_game ON events(game_id);
CREATE INDEX IF NOT EXISTS idx_events_user ON events(user_id);
