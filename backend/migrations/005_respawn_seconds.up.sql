-- Конфигурируемое организатором время респауна (секунды). По умолчанию 60с,
-- как было захардкожено в EventService.DefaultRespawnSeconds.
ALTER TABLE games
    ADD COLUMN IF NOT EXISTS respawn_seconds INT NOT NULL DEFAULT 60;
