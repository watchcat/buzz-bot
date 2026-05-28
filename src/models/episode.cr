struct Episode
  property id : Int64
  property feed_id : Int64
  property guid : String
  property title : String
  property description : String?
  property audio_url : String
  property duration_sec : Int32?
  property published_at : Time?
  property image_url : String?

  def initialize(@id, @feed_id, @guid, @title, @description, @audio_url, @duration_sec, @published_at, @image_url = nil)
  end

  private def self.from_rs(rs)
    new(
      rs.read(Int64),   # id
      rs.read(Int64),   # feed_id
      rs.read(String),  # guid
      rs.read(String),  # title
      rs.read(String?), # description
      rs.read(String),  # audio_url
      rs.read(Int32?),  # duration_sec
      rs.read(Time?),   # published_at
      rs.read(String?)  # image_url
    )
  end

  record UpsertResult, episode : Episode, was_inserted : Bool

  # Insert-or-update an episode. Returns nil only if neither path runs
  # (current SQL guarantees a row either way; the nil branch is for safety
  # against future schema/constraint changes). The `was_inserted` flag uses
  # the standard Postgres trick: `xmax` is 0 on a fresh INSERT and set to
  # the deleter's xid on an UPDATE-from-conflict.
  def self.upsert(feed_id : Int64, guid : String, title : String, description : String?, audio_url : String, duration_sec : Int32?, published_at : Time?, image_url : String? = nil) : UpsertResult?
    AppDB.pool.query_one?(
      <<-SQL,
        INSERT INTO episodes (feed_id, guid, title, description, audio_url, duration_sec, published_at, image_url)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        ON CONFLICT (feed_id, guid) DO UPDATE SET
          title        = EXCLUDED.title,
          description  = EXCLUDED.description,
          audio_url    = EXCLUDED.audio_url,
          duration_sec = COALESCE(EXCLUDED.duration_sec, episodes.duration_sec),
          published_at = COALESCE(episodes.published_at, EXCLUDED.published_at),
          image_url    = COALESCE(EXCLUDED.image_url, episodes.image_url)
        RETURNING id, feed_id, guid, title, description, audio_url, duration_sec, published_at, image_url,
                  (xmax = 0) AS was_inserted
      SQL
      feed_id, guid, title, description, audio_url, duration_sec, published_at, image_url
    ) do |rs|
      ep = from_rs(rs)
      UpsertResult.new(episode: ep, was_inserted: rs.read(Bool))
    end
  end

  def self.find(id : Int64) : Episode?
    AppDB.pool.query_one?(
      <<-SQL,
        SELECT id, feed_id, guid, title, description, audio_url, duration_sec, published_at, image_url
        FROM episodes
        WHERE id = $1
      SQL
      id
    ) { |rs| from_rs(rs) }
  end

  def self.for_feed(feed_id : Int64, limit : Int32 = 50, offset : Int32 = 0, order : String = "desc") : Array(Episode)
    dir = order == "asc" ? "ASC" : "DESC"
    episodes = [] of Episode
    AppDB.pool.query_each(
      <<-SQL,
        SELECT id, feed_id, guid, title, description, audio_url, duration_sec, published_at, image_url
        FROM episodes
        WHERE feed_id = $1
        ORDER BY COALESCE(published_at, created_at) #{dir}
        LIMIT $2 OFFSET $3
      SQL
      feed_id, limit, offset
    ) { |rs| episodes << from_rs(rs) }
    episodes
  end

  def self.completed_ids(user_id : Int64, feed_id : Int64) : Set(Int64)
    ids = Set(Int64).new
    AppDB.pool.query_each(
      <<-SQL,
        SELECT ue.episode_id
        FROM user_episodes ue
        JOIN episodes e ON e.id = ue.episode_id
        WHERE ue.user_id = $1
          AND e.feed_id  = $2
          AND ue.completed = TRUE
      SQL
      user_id, feed_id
    ) { |rs| ids << rs.read(Int64) }
    ids
  end

  def self.for_inbox(user_id : Int64, limit : Int32 = 100, offset : Int32 = 0) : Array(Episode)
    episodes = [] of Episode
    AppDB.pool.query_each(
      <<-SQL,
        SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url
        FROM episodes e
        JOIN user_feeds uf ON uf.feed_id = e.feed_id
        WHERE uf.user_id = $1
        ORDER BY COALESCE(e.published_at, e.created_at) DESC
        LIMIT $2 OFFSET $3
      SQL
      user_id, limit, offset
    ) { |rs| episodes << from_rs(rs) }
    episodes
  end

  def self.for_inbox_semantic(user_id : Int64, query_vec : Array(Float64), limit : Int32 = 100, offset : Int32 = 0) : Array(Episode)
    vector_str = "[#{query_vec.join(",")}]"
    episodes = [] of Episode
    AppDB.pool.query_each(
      <<-SQL,
        SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url
        FROM episodes e
        JOIN user_feeds uf ON uf.feed_id = e.feed_id
        LEFT JOIN episode_embeddings ee ON ee.episode_id = e.id
        WHERE uf.user_id = $1
        ORDER BY (1 - (ee.embedding <=> $2::vector)) DESC NULLS LAST
        LIMIT $3 OFFSET $4
      SQL
      user_id, vector_str, limit, offset
    ) { |rs| episodes << from_rs(rs) }
    episodes
  end

  def self.for_topic(user_id : Int64, tag : String, limit : Int32 = 100, offset : Int32 = 0) : Array(Episode)
    episodes = [] of Episode
    AppDB.pool.query_each(
      <<-SQL,
        SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url
        FROM episodes e
        JOIN user_feeds uf ON uf.feed_id = e.feed_id
        JOIN episode_embeddings ee ON ee.episode_id = e.id
        WHERE uf.user_id = $1
          AND ee.topics && COALESCE(
            (SELECT array_agg(topic) FROM topic_clusters WHERE label = $2),
            ARRAY[$2]::text[])
        ORDER BY COALESCE(e.published_at, e.created_at) DESC
        LIMIT $3 OFFSET $4
      SQL
      user_id, tag, limit, offset
    ) { |rs| episodes << from_rs(rs) }
    episodes
  end

  def self.completed_ids_for_user(user_id : Int64) : Set(Int64)
    ids = Set(Int64).new
    AppDB.pool.query_each(
      "SELECT episode_id FROM user_episodes WHERE user_id = $1 AND completed = TRUE",
      user_id
    ) { |rs| ids << rs.read(Int64) }
    ids
  end

  def self.in_progress_for_user(user_id : Int64) : {Episode, Int32}?
    AppDB.pool.query_one?(
      <<-SQL,
        SELECT e.id, e.feed_id, e.guid, e.title, e.description,
               e.audio_url, e.duration_sec, e.published_at, e.image_url,
               ue.progress_seconds
        FROM episodes e
        JOIN user_episodes ue ON e.id = ue.episode_id
        WHERE ue.user_id = $1
          AND ue.progress_seconds > 0
          AND ue.completed = FALSE
        ORDER BY ue.updated_at DESC
        LIMIT 1
      SQL
      user_id
    ) do |rs|
      ep = from_rs(rs)
      progress = rs.read(Int32)
      {ep, progress}
    end
  end

  def self.liked_for_user(user_id : Int64, limit : Int32 = 50, offset : Int32 = 0) : Array(Episode)
    episodes = [] of Episode
    AppDB.pool.query_each(
      <<-SQL,
        SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url
        FROM episodes e
        JOIN user_episodes ue ON e.id = ue.episode_id
        WHERE ue.user_id = $1 AND ue.liked = TRUE
        ORDER BY ue.updated_at DESC
        LIMIT $2 OFFSET $3
      SQL
      user_id, limit, offset
    ) { |rs| episodes << from_rs(rs) }
    episodes
  end

  def self.search_for_user(user_id : Int64, query : String, limit : Int32 = 30) : Array(Episode)
    pattern = "%#{query}%"
    episodes = [] of Episode
    AppDB.pool.query_each(
      <<-SQL,
        SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url
        FROM episodes e
        JOIN user_feeds uf ON uf.feed_id = e.feed_id
        WHERE uf.user_id = $1
          AND (e.title ILIKE $2 OR e.description ILIKE $2)
        ORDER BY COALESCE(e.published_at, e.created_at) DESC
        LIMIT $3
      SQL
      user_id, pattern, limit
    ) { |rs| episodes << from_rs(rs) }
    episodes
  end

  record ScoredEpisode, episode : Episode, vector_score : Float64, collab_score : Float64, score : Float64, matching_topics : Array(String), total_matching : Int32

  # pgvector hnsw.ef_search for the recs kNN. 200 gives ~near-exact recall@20
  # on the current corpus; pinned by scripts/verify-recs-hnsw.sh. Code literal
  # (SET LOCAL takes no bind params) — not user input.
  EF_SEARCH = 200

  private def self.build_scored(rs) : ScoredEpisode
    ep                  = from_rs(rs)
    vector_score        = rs.read(Float64)
    collab_score        = rs.read(Float64)
    score               = rs.read(Float64)
    matching_topics_raw = rs.read(Array(String))
    total_matching      = rs.read(Int32)
    ScoredEpisode.new(ep, vector_score, collab_score, score, matching_topics_raw, total_matching)
  end

  def self.recommended_for_episode(episode_id : Int64, limit : Int32 = 5) : Array(ScoredEpisode)
    results = [] of ScoredEpisode

    target = AppDB.pool.query_one?(
      "SELECT embedding::text FROM episode_embeddings WHERE episode_id = $1",
      episode_id, as: String)

    if target.nil?
      # No embedding yet → collab-only. Reproduces today's behaviour exactly:
      # previously CROSS JOIN target produced no rows, so vector_recs was empty
      # and `combined` fell back to collab via FULL OUTER JOIN + COALESCE.
      AppDB.pool.query_each(
        <<-SQL,
          WITH collab_recs AS (
            SELECT ue.episode_id AS id, COUNT(*)::float AS collab_score
            FROM user_episodes ue
            WHERE ue.liked = TRUE
              AND ue.user_id IN (
                SELECT user_id FROM user_episodes
                WHERE episode_id = $1 AND liked = TRUE
              )
              AND ue.episode_id != $1
            GROUP BY ue.episode_id
          ),
          combined AS (
            SELECT
              c.id AS id,
              0.0::float AS vector_score,
              COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) AS collab_score,
              COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) * 0.3 AS score
            FROM collab_recs c
          )
          SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url,
                 cb.vector_score, cb.collab_score, cb.score,
                 COALESCE((SELECT array_agg(t) FROM (SELECT unnest(src_ee.topics) INTERSECT SELECT unnest(rec_ee.topics) LIMIT 3) x(t)), '{}') AS matching_topics,
                 COALESCE((SELECT count(*)::int FROM (SELECT unnest(src_ee.topics) INTERSECT SELECT unnest(rec_ee.topics)) x(t)), 0) AS total_matching
          FROM episodes e
          JOIN combined cb ON e.id = cb.id
          LEFT JOIN episode_embeddings rec_ee ON rec_ee.episode_id = e.id
          LEFT JOIN episode_embeddings src_ee ON src_ee.episode_id = $1
          ORDER BY cb.score DESC
          LIMIT $2
        SQL
        episode_id, limit
      ) { |rs| results << build_scored(rs) }
      return results
    end

    # Target embedding present → HNSW-eligible kNN. SET LOCAL scopes
    # hnsw.ef_search to this txn so it cannot leak onto other pooled-connection
    # users; the read-only txn is otherwise side-effect free.
    AppDB.pool.transaction do |tx|
      conn = tx.connection
      conn.exec("SET LOCAL hnsw.ef_search = #{EF_SEARCH}")
      conn.query_each(
        <<-SQL,
          WITH vector_recs AS (
            SELECT ee.episode_id AS id, 1 - (ee.embedding <=> $2::vector) AS sim_score
            FROM episode_embeddings ee
            WHERE ee.episode_id != $1
            ORDER BY ee.embedding <=> $2::vector
            LIMIT 20
          ),
          collab_recs AS (
            SELECT ue.episode_id AS id, COUNT(*)::float AS collab_score
            FROM user_episodes ue
            WHERE ue.liked = TRUE
              AND ue.user_id IN (
                SELECT user_id FROM user_episodes
                WHERE episode_id = $1 AND liked = TRUE
              )
              AND ue.episode_id != $1
            GROUP BY ue.episode_id
          ),
          combined AS (
            SELECT
              COALESCE(v.id, c.id) AS id,
              COALESCE(v.sim_score, 0) AS vector_score,
              COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) AS collab_score,
              COALESCE(v.sim_score, 0) * 0.7
                + COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) * 0.3
                AS score
            FROM vector_recs v
            FULL OUTER JOIN collab_recs c ON v.id = c.id
          )
          SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url,
                 cb.vector_score, cb.collab_score, cb.score,
                 COALESCE((SELECT array_agg(t) FROM (SELECT unnest(src_ee.topics) INTERSECT SELECT unnest(rec_ee.topics) LIMIT 3) x(t)), '{}') AS matching_topics,
                 COALESCE((SELECT count(*)::int FROM (SELECT unnest(src_ee.topics) INTERSECT SELECT unnest(rec_ee.topics)) x(t)), 0) AS total_matching
          FROM episodes e
          JOIN combined cb ON e.id = cb.id
          LEFT JOIN episode_embeddings rec_ee ON rec_ee.episode_id = e.id
          LEFT JOIN episode_embeddings src_ee ON src_ee.episode_id = $1
          ORDER BY cb.score DESC
          LIMIT $3
        SQL
        episode_id, target, limit
      ) { |rs| results << build_scored(rs) }
    end

    results
  end

  def self.next_in_feed(feed_id : Int64, current_id : Int64, order : String = "desc") : Int64?
    dir = order == "asc" ? "ASC" : "DESC"
    AppDB.pool.query_one?(
      <<-SQL,
        WITH ranked AS (
          SELECT id,
                 LEAD(id) OVER (ORDER BY COALESCE(published_at, created_at) #{dir}) AS next_id
          FROM episodes
          WHERE feed_id = $1
        )
        SELECT next_id
        FROM ranked
        WHERE id = $2
      SQL
      feed_id, current_id,
      as: Int64?
    )
  end

  def self.transcript(id : Int64) : String?
    AppDB.pool.query_one?(
      "SELECT transcript FROM episodes WHERE id = $1",
      id, as: String?
    )
  end

  def self.save_transcript(id : Int64, text : String)
    AppDB.pool.exec("UPDATE episodes SET transcript = $1 WHERE id = $2", text, id)
  end

  def self.original_language(id : Int64) : String?
    AppDB.pool.query_one?("SELECT original_language FROM episodes WHERE id = $1", id, as: String?)
  end

  def self.save_original_language(id : Int64, lang_code : String)
    AppDB.pool.exec("UPDATE episodes SET original_language = $1 WHERE id = $2", lang_code, id)
  end

  def duration_display : String
    return "--:--" unless (sec = @duration_sec)
    hours   = sec // 3600
    minutes = (sec % 3600) // 60
    seconds = sec % 60
    if hours > 0
      "%d:%02d:%02d" % {hours, minutes, seconds}
    else
      "%d:%02d" % {minutes, seconds}
    end
  end
end
