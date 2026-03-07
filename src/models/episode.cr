struct Episode
  property id : Int64
  property feed_id : Int64
  property guid : String
  property title : String
  property description : String?
  property audio_url : String
  property duration_sec : Int32?
  property published_at : Time?

  def initialize(@id, @feed_id, @guid, @title, @description, @audio_url, @duration_sec, @published_at)
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
      rs.read(Time?)    # published_at
    )
  end

  def self.upsert(feed_id : Int64, guid : String, title : String, description : String?, audio_url : String, duration_sec : Int32?, published_at : Time?) : Episode?
    AppDB.pool.query_one?(
      <<-SQL,
        INSERT INTO episodes (feed_id, guid, title, description, audio_url, duration_sec, published_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        ON CONFLICT (feed_id, guid) DO UPDATE SET
          title        = EXCLUDED.title,
          description  = EXCLUDED.description,
          audio_url    = EXCLUDED.audio_url,
          duration_sec = COALESCE(EXCLUDED.duration_sec, episodes.duration_sec),
          published_at = COALESCE(episodes.published_at, EXCLUDED.published_at)
        RETURNING id, feed_id, guid, title, description, audio_url, duration_sec, published_at
      SQL
      feed_id, guid, title, description, audio_url, duration_sec, published_at
    ) { |rs| from_rs(rs) }
  end

  def self.find(id : Int64) : Episode?
    AppDB.pool.query_one?(
      <<-SQL,
        SELECT id, feed_id, guid, title, description, audio_url, duration_sec, published_at
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
        SELECT id, feed_id, guid, title, description, audio_url, duration_sec, published_at
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
        SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at
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
               e.audio_url, e.duration_sec, e.published_at,
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

  def self.recommended_for_episode(episode_id : Int64, limit : Int32 = 5) : Array(Episode)
    episodes = [] of Episode
    AppDB.pool.query_each(
      <<-SQL,
        WITH liked_users AS (
          SELECT user_id
          FROM user_episodes
          WHERE episode_id = $1 AND liked = TRUE
        ),
        candidates AS (
          SELECT ue.episode_id, COUNT(*) AS score
          FROM user_episodes ue
          JOIN liked_users lu ON ue.user_id = lu.user_id
          WHERE ue.liked = TRUE AND ue.episode_id != $1
          GROUP BY ue.episode_id
          ORDER BY score DESC
          LIMIT $2
        )
        SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at
        FROM episodes e
        JOIN candidates c ON e.id = c.episode_id
        ORDER BY c.score DESC
      SQL
      episode_id, limit
    ) { |rs| episodes << from_rs(rs) }
    episodes
  end

  def self.next_in_feed(feed_id : Int64, current_id : Int64) : Int64?
    AppDB.pool.query_one?(
      <<-SQL,
        WITH ranked AS (
          SELECT id,
                 LEAD(id) OVER (ORDER BY COALESCE(published_at, created_at) DESC) AS next_id
          FROM episodes
          WHERE feed_id = $1
        )
        SELECT next_id
        FROM ranked
        WHERE id = $2
      SQL
      feed_id, current_id,
      as: Int64
    )
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
