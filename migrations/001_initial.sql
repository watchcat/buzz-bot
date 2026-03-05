CREATE TABLE users (
  id          BIGSERIAL PRIMARY KEY,
  telegram_id BIGINT UNIQUE NOT NULL,
  username    VARCHAR(255),
  first_name  VARCHAR(255),
  last_name   VARCHAR(255),
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE feeds (
  id              BIGSERIAL PRIMARY KEY,
  url             TEXT UNIQUE NOT NULL,
  title           TEXT,
  description     TEXT,
  image_url       TEXT,
  last_fetched_at TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE user_feeds (
  user_id    BIGINT REFERENCES users(id) ON DELETE CASCADE,
  feed_id    BIGINT REFERENCES feeds(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (user_id, feed_id)
);

CREATE TABLE episodes (
  id           BIGSERIAL PRIMARY KEY,
  feed_id      BIGINT REFERENCES feeds(id) ON DELETE CASCADE,
  guid         TEXT UNIQUE NOT NULL,
  title        TEXT NOT NULL,
  description  TEXT,
  audio_url    TEXT NOT NULL,
  duration_sec INT,
  published_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE user_episodes (
  id               BIGSERIAL PRIMARY KEY,
  user_id          BIGINT REFERENCES users(id) ON DELETE CASCADE,
  episode_id       BIGINT REFERENCES episodes(id) ON DELETE CASCADE,
  progress_seconds INT DEFAULT 0,
  completed        BOOLEAN DEFAULT FALSE,
  liked            BOOLEAN,
  updated_at       TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, episode_id)
);

CREATE INDEX ON user_feeds(user_id);
CREATE INDEX ON episodes(feed_id);
CREATE INDEX ON user_episodes(user_id);
CREATE INDEX ON user_episodes(episode_id);
CREATE INDEX ON user_episodes(liked) WHERE liked IS NOT NULL;
