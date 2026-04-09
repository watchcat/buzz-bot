-- migrations/012_dubbing_v2.sql
-- Dubbing pipeline v2: stems, segments, per-segment translations, speaker samples.

BEGIN;

-- Episode-level audio stems (language-independent, reused across dubs)
CREATE TABLE dub_stems (
  episode_id        BIGINT PRIMARY KEY REFERENCES episodes(id),
  vocals_r2_key     TEXT NOT NULL,
  background_r2_key TEXT NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- WhisperX transcript segments (episode-level, language-independent)
CREATE TABLE dub_segments (
  id          BIGSERIAL PRIMARY KEY,
  episode_id  BIGINT NOT NULL REFERENCES episodes(id),
  idx         INT NOT NULL,
  speaker_id  TEXT,
  start_sec   FLOAT NOT NULL,
  end_sec     FLOAT NOT NULL,
  text        TEXT NOT NULL,
  words       JSONB,
  UNIQUE (episode_id, idx)
);

CREATE INDEX idx_dub_segments_episode_id ON dub_segments (episode_id);

-- Per-language segment translations and synthesised audio
CREATE TABLE dub_segment_translations (
  segment_id      BIGINT NOT NULL REFERENCES dub_segments(id) ON DELETE CASCADE,
  language        TEXT NOT NULL,
  translated_text TEXT NOT NULL,
  synth_r2_key    TEXT,
  synth_duration  FLOAT,
  PRIMARY KEY (segment_id, language)
);

-- New columns on dubbed_episodes
ALTER TABLE dubbed_episodes
  ADD COLUMN IF NOT EXISTS speaker_samples JSONB,
  ADD COLUMN IF NOT EXISTS bg_volume       FLOAT NOT NULL DEFAULT 0.15;

-- Update step check values to match v2 step names.
-- Old step names (transcription, translating, etc.) are replaced; existing
-- in-flight or failed rows are reset so they can be retried cleanly.
UPDATE dubbed_episodes
  SET status = 'failed',
      error  = 'Reset for pipeline v2 upgrade',
      step   = 'queued'
  WHERE status IN ('pending', 'processing');

COMMIT;
