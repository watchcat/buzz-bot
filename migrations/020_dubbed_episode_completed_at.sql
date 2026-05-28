-- 020_dubbed_episode_completed_at.sql
-- Track when a dub finished. Today only created_at (request time) and
-- expires_at (= completed_at + 29 days) exist, forcing read-side offset math.

ALTER TABLE dubbed_episodes
  ADD COLUMN completed_at TIMESTAMPTZ;

-- Backfill from the existing 29-day expiry contract for already-done rows.
UPDATE dubbed_episodes
SET completed_at = expires_at - INTERVAL '29 days'
WHERE status = 'done' AND expires_at IS NOT NULL;

-- Partial index for the latest-dubbed widget:
--   ORDER BY completed_at DESC NULLS LAST LIMIT 12 WHERE status = 'done'
CREATE INDEX dubbed_episodes_recent_done
  ON dubbed_episodes (completed_at DESC NULLS LAST)
  WHERE status = 'done';
