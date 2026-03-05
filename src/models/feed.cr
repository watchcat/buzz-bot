struct Feed
  property id : Int64
  property url : String
  property title : String?
  property description : String?
  property image_url : String?
  property last_fetched_at : Time?
  property etag : String?
  property last_modified : String?
  property ttl_minutes : Int32?

  def initialize(@id, @url, @title, @description, @image_url, @last_fetched_at,
                 @etag, @last_modified, @ttl_minutes)
  end

  private def self.from_rs(rs)
    new(
      rs.read(Int64),   # id
      rs.read(String),  # url
      rs.read(String?), # title
      rs.read(String?), # description
      rs.read(String?), # image_url
      rs.read(Time?),   # last_fetched_at
      rs.read(String?), # etag
      rs.read(String?), # last_modified
      rs.read(Int32?)   # ttl_minutes
    )
  end

  def self.upsert(url : String, title : String?, description : String?, image_url : String?) : Feed
    AppDB.pool.query_one(
      <<-SQL,
        INSERT INTO feeds (url, title, description, image_url, last_fetched_at)
        VALUES ($1, $2, $3, $4, NOW())
        ON CONFLICT (url) DO UPDATE SET
          title           = COALESCE(EXCLUDED.title, feeds.title),
          description     = COALESCE(EXCLUDED.description, feeds.description),
          image_url       = COALESCE(EXCLUDED.image_url, feeds.image_url),
          last_fetched_at = NOW()
        RETURNING id, url, title, description, image_url, last_fetched_at,
                  etag, last_modified, ttl_minutes
      SQL
      url, title, description, image_url
    ) { |rs| from_rs(rs) }
  end

  def self.find(id : Int64) : Feed?
    AppDB.pool.query_one?(
      <<-SQL,
        SELECT id, url, title, description, image_url, last_fetched_at,
               etag, last_modified, ttl_minutes
        FROM feeds
        WHERE id = $1
      SQL
      id
    ) { |rs| from_rs(rs) }
  end

  def self.for_user(user_id : Int64) : Array(Feed)
    feeds = [] of Feed
    AppDB.pool.query_each(
      <<-SQL,
        SELECT f.id, f.url, f.title, f.description, f.image_url, f.last_fetched_at,
               f.etag, f.last_modified, f.ttl_minutes
        FROM feeds f
        JOIN user_feeds uf ON f.id = uf.feed_id
        WHERE uf.user_id = $1
        ORDER BY COALESCE(
          (SELECT MAX(e.published_at) FROM episodes e WHERE e.feed_id = f.id),
          f.last_fetched_at,
          uf.created_at
        ) DESC NULLS LAST
      SQL
      user_id
    ) { |rs| feeds << from_rs(rs) }
    feeds
  end

  def self.due_for_refresh : Array(Feed)
    feeds = [] of Feed
    AppDB.pool.query_each(
      <<-SQL
        SELECT f.id, f.url, f.title, f.description, f.image_url, f.last_fetched_at,
               f.etag, f.last_modified, f.ttl_minutes
        FROM feeds f
        WHERE EXISTS (SELECT 1 FROM user_feeds uf WHERE uf.feed_id = f.id)
          AND (
            f.last_fetched_at IS NULL
            OR f.last_fetched_at < NOW() - (COALESCE(f.ttl_minutes, 60) * INTERVAL '1 minute')
          )
        ORDER BY f.last_fetched_at ASC NULLS FIRST
      SQL
    ) { |rs| feeds << from_rs(rs) }
    feeds
  end

  def self.update_refresh_metadata(id : Int64, etag : String?, last_modified : String?, ttl_minutes : Int32?)
    AppDB.pool.exec(
      <<-SQL,
        UPDATE feeds SET
          last_fetched_at = NOW(),
          etag            = COALESCE($2, etag),
          last_modified   = COALESCE($3, last_modified),
          ttl_minutes     = COALESCE($4, ttl_minutes)
        WHERE id = $1
      SQL
      id, etag, last_modified, ttl_minutes
    )
  end

  def self.subscribe(user_id : Int64, feed_id : Int64)
    AppDB.pool.exec(
      "INSERT INTO user_feeds (user_id, feed_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
      user_id, feed_id
    )
  end

  def self.unsubscribe(user_id : Int64, feed_id : Int64)
    AppDB.pool.exec(
      "DELETE FROM user_feeds WHERE user_id = $1 AND feed_id = $2",
      user_id, feed_id
    )
  end
end
