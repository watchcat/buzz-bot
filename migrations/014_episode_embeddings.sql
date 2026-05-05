-- migrations/014_episode_embeddings.sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE episode_embeddings (
  episode_id  BIGINT PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE,
  embedding   vector(384) NOT NULL,
  source      VARCHAR(20) NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX episode_embeddings_hnsw_idx
  ON episode_embeddings USING hnsw (embedding vector_cosine_ops);
