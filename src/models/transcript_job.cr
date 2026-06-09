# src/models/transcript_job.cr
require "../db"

# Coalescing status for transcribe-only runs, keyed by episode (transcripts have
# no target language). `claim` returns true only when the caller should dispatch.
module TranscriptJob
  def self.find(episode_id : Int64) : {String, String?}?
    AppDB.pool.query_one?(
      "SELECT status, run_id FROM transcript_jobs WHERE episode_id = $1",
      episode_id, as: {String, String?})
  end

  # Insert a pending job, or revive a previously-failed one. Returns true when a
  # row was created/revived (→ dispatch), false when one is already pending/done.
  def self.claim(episode_id : Int64, run_id : String) : Bool
    AppDB.pool.exec(
      "INSERT INTO transcript_jobs (episode_id, status, run_id)
       VALUES ($1, 'pending', $2)
       ON CONFLICT (episode_id) DO UPDATE
         SET status = 'pending', run_id = $2, updated_at = now()
         WHERE transcript_jobs.status = 'failed'",
      episode_id, run_id).rows_affected > 0
  end

  def self.set_done(episode_id : Int64)
    AppDB.pool.exec(
      "UPDATE transcript_jobs SET status = 'done', updated_at = now() WHERE episode_id = $1",
      episode_id)
  end

  def self.set_failed(episode_id : Int64)
    AppDB.pool.exec(
      "UPDATE transcript_jobs SET status = 'failed', updated_at = now() WHERE episode_id = $1",
      episode_id)
  end
end
