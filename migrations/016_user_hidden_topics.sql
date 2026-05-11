CREATE TABLE user_hidden_topics (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  topic   TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, topic)
)