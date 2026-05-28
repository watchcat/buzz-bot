require "json"

# Language allowlist — intersection of XTTS-v2 and DeepL supported languages.
DUB_LANGUAGES = %w[en es fr de it pt pl tr ru nl cs zh ja hu ko]

struct DubbedEpisode
  include JSON::Serializable

  property id                    : Int64
  property episode_id            : Int64
  property language              : String
  property status                : String
  property step                  : String
  property r2_url                : String?
  property translation           : String?
  property error                 : String?
  property expires_at            : Time?
  property created_at            : Time
  property requester_telegram_id : Int64?

  def initialize(@id, @episode_id, @language, @status, @step, @r2_url,
                 @translation, @error, @expires_at, @created_at, @requester_telegram_id)
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
      rs.read(String),  # step
      rs.read(String?), # r2_url
      rs.read(String?), # translation
      rs.read(String?), # error
      rs.read(Time?),   # expires_at
      rs.read(Time),    # created_at
      rs.read(Int64?)   # requester_telegram_id
    )
  end

  def self.find(episode_id : Int64, language : String) : DubbedEpisode?
    AppDB.pool.query_one?(
      <<-SQL,
        SELECT id, episode_id, language, status, step, r2_url, translation,
               error, expires_at, created_at, requester_telegram_id
        FROM dubbed_episodes
        WHERE episode_id = $1 AND language = $2
      SQL
      episode_id, language
    ) { |rs| from_rs(rs) }
  end

  def self.find_by_id(id : Int64) : DubbedEpisode?
    AppDB.pool.query_one?(
      <<-SQL,
        SELECT id, episode_id, language, status, step, r2_url, translation,
               error, expires_at, created_at, requester_telegram_id
        FROM dubbed_episodes WHERE id = $1
      SQL
      id
    ) { |rs| from_rs(rs) }
  end

  def self.upsert_pending(episode_id : Int64, language : String, requester_telegram_id : Int64) : Int64
    AppDB.pool.query_one(
      <<-SQL,
        INSERT INTO dubbed_episodes (episode_id, language, status, step, requester_telegram_id)
        VALUES ($1, $2, 'pending', 'queued', $3)
        ON CONFLICT (episode_id, language) DO UPDATE
          SET status                = 'pending',
              step                  = 'queued',
              r2_url                = NULL,
              translation           = NULL,
              error                 = NULL,
              expires_at            = NULL,
              requester_telegram_id = $3,
              created_at            = NOW()
        RETURNING id
      SQL
      episode_id, language, requester_telegram_id, as: Int64
    )
  end

  def self.set_processing(id : Int64)
    AppDB.pool.exec(
      "UPDATE dubbed_episodes SET status = 'processing' WHERE id = $1",
      id
    )
  end

  def self.set_step(id : Int64, step : String)
    # Refuse to overwrite step once the row reached a terminal state.
    # Late progress reports (e.g. the post-result "complete" POST seen in
    # prod logs, or out-of-order reports from the pipeline's per-event
    # daemon threads) would otherwise flip step backwards and trigger a
    # spurious PG NOTIFY → DubHub fanout that the UI would interpret as
    # "back to processing".
    AppDB.pool.exec(
      "UPDATE dubbed_episodes SET step = $2 WHERE id = $1 AND status NOT IN ('done', 'failed')",
      id, step
    )
    # The dub_update_notify PG trigger fires automatically on every UPDATE,
    # fanning out a 'dub_status' NOTIFY to DubHub → SSE clients.
  end

  def self.set_failed(id : Int64, error : String)
    AppDB.pool.exec(
      "UPDATE dubbed_episodes SET status = 'failed', error = $2 WHERE id = $1",
      id, error
    )
  end

  def self.set_complete(id : Int64, r2_url : String?, speaker_samples : String? = nil)
    AppDB.pool.exec(
      <<-SQL,
        UPDATE dubbed_episodes
        SET step = 'complete', status = 'done', r2_url = $2,
            speaker_samples = $3::jsonb,
            completed_at = NOW(),
            expires_at = NOW() + INTERVAL '29 days'
        WHERE id = $1
      SQL
      id, r2_url, speaker_samples
    )
  end

  # Returns a map of language → {status, step, r2_url?, translation?} for all dubs of an episode.
  def self.statuses_for_episode(episode_id : Int64)
    rows = AppDB.pool.query_all(
      "SELECT language, status, step, r2_url, translation, expires_at FROM dubbed_episodes WHERE episode_id = $1",
      episode_id, as: {String, String, String, String?, String?, Time?}
    )
    rows.each_with_object({} of String => NamedTuple(status: String, step: String, r2_url: String?, translation: String?)) do |row, h|
      lang, status, step, r2_url, translation, expires_at = row
      eff = status == "done" && (expires_at.try { |t| t < Time.utc } || false) ? "expired" : status
      h[lang] = {status: eff, step: step, r2_url: r2_url, translation: translation}
    end
  end
end
