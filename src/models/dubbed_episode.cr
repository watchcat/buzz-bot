require "json"

# Language allowlist — intersection of XTTS-v2 and DeepL supported languages.
DUB_LANGUAGES = %w[en es fr de it pt pl tr ru nl cs zh ja hu ko]

struct DubbedEpisode
  include JSON::Serializable

  property id                   : Int64
  property episode_id           : Int64
  property language             : String
  property status               : String
  property step                 : String
  property r2_url               : String?
  property translation          : String?
  property error                : String?
  property expires_at           : Time?
  property created_at           : Time
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

  def self.upsert_pending(episode_id : Int64, language : String, requester_telegram_id : Int64) : Int64
    AppDB.pool.query_one(
      <<-SQL,
        WITH row AS (
          INSERT INTO dubbed_episodes (episode_id, language, status, step, requester_telegram_id)
          VALUES ($1, $2, 'pending', 'transcription', $3)
          ON CONFLICT (episode_id, language) DO UPDATE
            SET status                = 'pending',
                step                  = 'transcription',
                r2_url                = NULL,
                translation           = NULL,
                error                 = NULL,
                expires_at            = NULL,
                requester_telegram_id = $3,
                created_at            = NOW()
          RETURNING id
        ),
        _notify AS (SELECT pg_notify('dub_transcription', id::text) FROM row)
        SELECT id FROM row
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

  def self.set_failed(id : Int64, error : String)
    AppDB.pool.exec(
      "UPDATE dubbed_episodes SET status = 'failed', error = $2 WHERE id = $1",
      id, error
    )
  end

  # Returns a map of language → {status, r2_url?, translation?} for all dubs of an episode.
  def self.statuses_for_episode(episode_id : Int64)
    rows = AppDB.pool.query_all(
      "SELECT language, status, r2_url, translation, expires_at FROM dubbed_episodes WHERE episode_id = $1",
      episode_id, as: {String, String, String?, String?, Time?}
    )
    rows.each_with_object({} of String => NamedTuple(status: String, r2_url: String?, translation: String?)) do |row, h|
      lang, status, r2_url, translation, expires_at = row
      eff = status == "done" && (expires_at.try { |t| t < Time.utc } || false) ? "expired" : status
      h[lang] = {status: eff, r2_url: r2_url, translation: translation}
    end
  end

  def self.reset_stale_jobs
    count = AppDB.pool.exec(
      <<-SQL
        UPDATE dubbed_episodes
        SET status = 'failed', error = 'Server restarted'
        WHERE status IN ('pending', 'processing')
          AND step = 'transcription'
      SQL
    ).rows_affected
    Log.info { "DubbedEpisode: reset #{count} stale jobs to failed" } if count > 0
  end

  # Claimed by dub-transcriber.  Returns {dub_id, episode_id, language} or nil.
  def self.claim_for_transcription : {Int64, Int64, String}?
    AppDB.pool.query_one?(
      <<-SQL,
        UPDATE dubbed_episodes
        SET step = 'transcribing', status = 'processing'
        WHERE id = (
          SELECT id FROM dubbed_episodes
          WHERE step = 'transcription'
          ORDER BY created_at
          LIMIT 1
          FOR UPDATE SKIP LOCKED
        )
        RETURNING id, episode_id, language
      SQL
      as: {Int64, Int64, String}
    )
  end

  # Claimed by dub-translator.  Returns {dub_id, episode_id, language} or nil.
  def self.claim_for_translation : {Int64, Int64, String}?
    AppDB.pool.query_one?(
      <<-SQL,
        UPDATE dubbed_episodes
        SET step = 'translating'
        WHERE id = (
          SELECT id FROM dubbed_episodes
          WHERE step = 'translation' AND status = 'processing'
          ORDER BY created_at
          LIMIT 1
          FOR UPDATE SKIP LOCKED
        )
        RETURNING id, episode_id, language
      SQL
      as: {Int64, Int64, String}
    )
  end

  # Claimed by dub-synthesizer.  Returns {dub_id, episode_id, language, translation, requester_telegram_id} or nil.
  def self.claim_for_synthesis : {Int64, Int64, String, String, Int64?}?
    AppDB.pool.query_one?(
      <<-SQL,
        UPDATE dubbed_episodes
        SET step = 'synthesizing'
        WHERE id = (
          SELECT id FROM dubbed_episodes
          WHERE step = 'synthesis' AND status = 'processing'
          ORDER BY created_at
          LIMIT 1
          FOR UPDATE SKIP LOCKED
        )
        RETURNING id, episode_id, language, translation, requester_telegram_id
      SQL
      as: {Int64, Int64, String, String, Int64?}
    )
  end

  def self.advance_to_translation(id : Int64)
    AppDB.pool.exec(
      <<-SQL, id
        WITH upd AS (UPDATE dubbed_episodes SET step = 'translation' WHERE id = $1 RETURNING id)
        SELECT pg_notify('dub_translation', id::text) FROM upd
      SQL
    )
  end

  def self.advance_to_synthesis(id : Int64, translation : String)
    AppDB.pool.exec(
      <<-SQL, id, translation
        WITH upd AS (
          UPDATE dubbed_episodes SET step = 'synthesis', translation = $2 WHERE id = $1 RETURNING id
        )
        SELECT pg_notify('dub_synthesis', id::text) FROM upd
      SQL
    )
  end

  def self.set_complete(id : Int64, r2_url : String)
    AppDB.pool.exec(
      <<-SQL,
        UPDATE dubbed_episodes
        SET step = 'complete', status = 'done', r2_url = $2,
            expires_at = NOW() + INTERVAL '29 days'
        WHERE id = $1
      SQL
      id, r2_url
    )
  end

  # On service start: reset in-flight jobs back to the claimable step.
  # E.g. reset_in_flight("transcribing", "transcription")
  def self.reset_in_flight(from_step : String, to_step : String)
    n = AppDB.pool.exec(
      "UPDATE dubbed_episodes SET step = $1 WHERE step = $2",
      to_step, from_step
    ).rows_affected
    Log.info { "DubbedEpisode: reset #{n} stale '#{from_step}' jobs to '#{to_step}'" } if n > 0
  end
end
