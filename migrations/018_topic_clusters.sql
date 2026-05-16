-- migrations/018_topic_clusters.sql
-- Topic-string vector cache + nightly global clustering result.
-- HNSW index on topic_vectors is deferred to 019 (only if in-db-crystal wins).

CREATE TABLE IF NOT EXISTS topic_vectors (
  topic      text PRIMARY KEY,
  embedding  vector(1024) NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS topic_clusters (
  topic      text PRIMARY KEY,
  cluster_id integer NOT NULL,
  label      text    NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS topic_clusters_label_idx
  ON topic_clusters (label);

CREATE INDEX IF NOT EXISTS episode_embeddings_topics_gin
  ON episode_embeddings USING gin (topics);
