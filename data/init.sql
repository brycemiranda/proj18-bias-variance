CREATE TABLE IF NOT EXISTS mealie_events (
    id           SERIAL PRIMARY KEY,
    user_id      VARCHAR(50)  NOT NULL,
    recipe_id    VARCHAR(50)  NOT NULL,
    event_type   VARCHAR(20)  NOT NULL,
    rating       INTEGER,
    weight       FLOAT        NOT NULL,
    timestamp    TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS tag_vectors (
    tag          VARCHAR(200) PRIMARY KEY,
    vector       JSONB        NOT NULL,
    updated_at   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS user_vectors (
    user_id      VARCHAR(50)  PRIMARY KEY,
    vector       JSONB        NOT NULL,
    updated_at   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_events_user_id   ON mealie_events(user_id);
CREATE INDEX IF NOT EXISTS idx_events_timestamp  ON mealie_events(timestamp);
