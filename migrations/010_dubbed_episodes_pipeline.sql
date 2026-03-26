-- migrations/010_dubbed_episodes_pipeline.sql
BEGIN;

ALTER TABLE dubbed_episodes
  ADD COLUMN IF NOT EXISTS step VARCHAR(30) NOT NULL DEFAULT 'transcription',
  ADD COLUMN IF NOT EXISTS requester_telegram_id BIGINT;

-- Backfill existing rows
UPDATE dubbed_episodes SET step = 'complete' WHERE status IN ('done', 'expired');
UPDATE dubbed_episodes SET step = 'transcription' WHERE status IN ('pending', 'processing', 'failed');

-- Index for service polling queries
CREATE INDEX IF NOT EXISTS idx_dubbed_episodes_step ON dubbed_episodes (step) WHERE status NOT IN ('done', 'failed', 'expired');

COMMIT;
