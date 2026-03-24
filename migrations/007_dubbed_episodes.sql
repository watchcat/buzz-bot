ALTER TABLE users ADD COLUMN preferred_dub_language VARCHAR(10);

CREATE TABLE dubbed_episodes (
  id           BIGSERIAL PRIMARY KEY,
  episode_id   BIGINT NOT NULL REFERENCES episodes(id),
  language     VARCHAR(10) NOT NULL,
  status       VARCHAR(20) NOT NULL DEFAULT 'pending',
  r2_url       TEXT,
  error        TEXT,
  expires_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (episode_id, language)
);

CREATE INDEX dubbed_episodes_episode_id_idx ON dubbed_episodes(episode_id);
