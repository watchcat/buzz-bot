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
          duration_sec = COALESCE(EXCLUDED.duration_sec, episodes.duration_sec)
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

  def self.for_feed(feed_id : Int64, limit : Int32 = 50) : Array(Episode)
    episodes = [] of Episode
    AppDB.pool.query_each(
      <<-SQL,
        SELECT id, feed_id, guid, title, description, audio_url, duration_sec, published_at
        FROM episodes
        WHERE feed_id = $1
        ORDER BY published_at DESC NULLS LAST
        LIMIT $2
      SQL
      feed_id, limit
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

  def self.recommended_for(user_id : Int64, limit : Int32 = 20) : Array(Episode)
    episodes = [] of Episode
    AppDB.pool.query_each(
      <<-SQL,
        WITH my_liked AS (
          SELECT episode_id
          FROM user_episodes
          WHERE user_id = $1 AND liked = TRUE
        ),
        similar_users AS (
          SELECT DISTINCT ue.user_id
          FROM user_episodes ue
          JOIN my_liked ml ON ue.episode_id = ml.episode_id
          WHERE ue.liked = TRUE AND ue.user_id != $1
        ),
        candidate_episodes AS (
          SELECT ue.episode_id, COUNT(*) AS score
          FROM user_episodes ue
          JOIN similar_users su ON ue.user_id = su.user_id
          WHERE ue.liked = TRUE
            AND ue.episode_id NOT IN (
              SELECT episode_id FROM user_episodes WHERE user_id = $1
            )
          GROUP BY ue.episode_id
          ORDER BY score DESC
          LIMIT $2
        )
        SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at
        FROM episodes e
        JOIN candidate_episodes ce ON e.id = ce.episode_id
        ORDER BY ce.score DESC
      SQL
      user_id, limit
    ) { |rs| episodes << from_rs(rs) }
    episodes
  end

  def self.next_in_feed(feed_id : Int64, current_id : Int64) : Int64?
    AppDB.pool.query_one?(
      <<-SQL,
        WITH ranked AS (
          SELECT id,
                 LEAD(id) OVER (ORDER BY published_at DESC NULLS LAST, id DESC) AS next_id
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
