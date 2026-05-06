ALTER TABLE episode_embeddings ADD COLUMN topics TEXT[] NOT NULL DEFAULT '{}';
