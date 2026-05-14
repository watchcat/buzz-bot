-- migrations/017_bge_m3_embeddings.sql
--
-- DESTRUCTIVE: Truncates all existing 384-dim embeddings.
-- The hourly /internal/embed cron will re-generate everything
-- with BGE-M3 (1024-dim dense, multilingual).

-- 1. Drop the HNSW index (must drop before altering column type)
DROP INDEX IF EXISTS episode_embeddings_hnsw_idx;

-- 2. Truncate — must happen before ALTER because existing 384-dim data
--    is incompatible with vector(1024) type constraint
TRUNCATE episode_embeddings;

-- 3. Widen vector column from 384 → 1024 dimensions
ALTER TABLE episode_embeddings ALTER COLUMN embedding TYPE vector(1024);

-- 4. Recreate HNSW index for cosine similarity
CREATE INDEX episode_embeddings_hnsw_idx
  ON episode_embeddings USING hnsw (embedding vector_cosine_ops);
