require "json"

# Language allowlist — intersection of XTTS-v2 and DeepL supported languages.
DUB_LANGUAGES = %w[en es fr de it pt pl tr ru nl cs zh ja hu ko]

struct DubbedEpisode
  include JSON::Serializable

  property id         : Int64
  property episode_id : Int64
  property language   : String
  property status     : String   # "pending" | "processing" | "done" | "failed"
  property r2_url      : String?
  property translation : String?
  property error       : String?
  property expires_at  : Time?
  property created_at  : Time

  def initialize(@id, @episode_id, @language, @status, @r2_url, @translation, @error, @expires_at, @created_at)
  end

  def expired? : Bool
    status == "done" && (expires_at.try { |t| t < Time.utc } || false)
  end

  def effective_status : String
    expired? ? "expired" : status
  end

  private def self.from_rs(rs) : DubbedEpisode
    new(
      rs.read(Int64),   # id
      rs.read(Int64),   # episode_id
      rs.read(String),  # language
      rs.read(String),  # status
      rs.read(String?), # r2_url
      rs.read(String?), # translation
      rs.read(String?), # error
      rs.read(Time?),   # expires_at
      rs.read(Time)     # created_at
    )
  end

  def self.find(episode_id : Int64, language : String) : DubbedEpisode?
    AppDB.pool.query_one?(
      <<-SQL,
        SELECT id, episode_id, language, status, r2_url, translation, error, expires_at, created_at
        FROM dubbed_episodes
        WHERE episode_id = $1 AND language = $2
      SQL
      episode_id, language
    ) { |rs| from_rs(rs) }
  end

  def self.upsert_pending(episode_id : Int64, language : String) : Int64
    AppDB.pool.query_one(
      <<-SQL,
        INSERT INTO dubbed_episodes (episode_id, language, status)
        VALUES ($1, $2, 'pending')
        ON CONFLICT (episode_id, language) DO UPDATE
          SET status      = 'pending',
              r2_url      = NULL,
              translation = NULL,
              error       = NULL,
              expires_at  = NULL,
              created_at  = NOW()
        RETURNING id
      SQL
      episode_id, language, as: Int64
    )
  end

  def self.set_processing(id : Int64)
    AppDB.pool.exec(
      "UPDATE dubbed_episodes SET status = 'processing' WHERE id = $1",
      id
    )
  end

  def self.set_done(id : Int64, r2_url : String, translation : String)
    AppDB.pool.exec(
      <<-SQL,
        UPDATE dubbed_episodes
        SET status = 'done', r2_url = $2, translation = $3, expires_at = NOW() + INTERVAL '29 days'
        WHERE id = $1
      SQL
      id, r2_url, translation
    )
  end

  def self.set_failed(id : Int64, error : String)
    AppDB.pool.exec(
      "UPDATE dubbed_episodes SET status = 'failed', error = $2 WHERE id = $1",
      id, error
    )
  end

  def self.reset_stale_jobs
    count = AppDB.pool.exec(
      "UPDATE dubbed_episodes SET status = 'failed', error = 'Server restarted'
       WHERE status IN ('pending', 'processing')"
    ).rows_affected
    Log.info { "DubbedEpisode: reset #{count} stale jobs to failed" } if count > 0
  end
end
