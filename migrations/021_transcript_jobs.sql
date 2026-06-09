-- migrations/021_transcript_jobs.sql
CREATE TABLE IF NOT EXISTS transcript_jobs (
    episode_id BIGINT PRIMARY KEY,
    status     TEXT NOT NULL DEFAULT 'pending',  -- pending | done | failed
    run_id     TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
