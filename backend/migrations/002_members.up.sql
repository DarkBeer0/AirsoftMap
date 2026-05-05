CREATE TABLE IF NOT EXISTS squads (
    id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    side_id  UUID NOT NULL REFERENCES sides(id) ON DELETE CASCADE,
    name     TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_squads_side ON squads(side_id);

CREATE TABLE IF NOT EXISTS game_members (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id         UUID NOT NULL REFERENCES games(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES profiles(id),
    side_id         UUID REFERENCES sides(id),
    squad_id        UUID REFERENCES squads(id),
    callsign        TEXT NOT NULL,
    role            TEXT NOT NULL DEFAULT 'soldier',
    status          TEXT NOT NULL DEFAULT 'alive',
    respawn_until   TIMESTAMPTZ,
    last_lng        DOUBLE PRECISION,
    last_lat        DOUBLE PRECISION,
    last_update     TIMESTAMPTZ,
    UNIQUE (game_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_members_game ON game_members(game_id);
CREATE INDEX IF NOT EXISTS idx_members_side ON game_members(side_id);
CREATE INDEX IF NOT EXISTS idx_members_status ON game_members(game_id, status);
