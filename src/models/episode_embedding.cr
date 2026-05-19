# src/models/episode_embedding.cr
require "../db"

module EpisodeEmbedding
  def self.upsert(episode_id : Int64, embedding : Array(Float64), source : String, topics : Array(String) = [] of String)
    vector_str = "[#{embedding.join(",")}]"
    topics_literal = "{#{topics.map { |t| "\"#{t.gsub("\\", "\\\\").gsub("\"", "\\\"")}\"" }.join(",")}}"
    AppDB.pool.exec(
      <<-SQL,
        INSERT INTO episode_embeddings (episode_id, embedding, source, topics, updated_at)
        VALUES ($1, $2::vector, $3, $4::text[], now())
        ON CONFLICT (episode_id) DO UPDATE SET
          embedding  = EXCLUDED.embedding,
          source     = EXCLUDED.source,
          topics     = EXCLUDED.topics,
          updated_at = now()
      SQL
      episode_id, vector_str, source, topics_literal
    )
  end

  def self.upsert_batch(items : Array(NamedTuple(episode_id: Int64, embedding: Array(Float64), source: String)))
    items.each { |item| upsert(item[:episode_id], item[:embedding], item[:source]) }
  end

  def self.exists?(episode_id : Int64) : Bool
    AppDB.pool.query_one(
      "SELECT EXISTS(SELECT 1 FROM episode_embeddings WHERE episode_id = $1)",
      episode_id, as: Bool
    )
  end

  # Returns episode IDs that have no embedding yet (for batch processing).
  def self.unembedded_episode_ids(limit : Int32 = 100) : Array(NamedTuple(id: Int64, title: String, description: String?))
    results = [] of NamedTuple(id: Int64, title: String, description: String?)
    AppDB.pool.query_each(
      <<-SQL,
        SELECT e.id, e.title, e.description
        FROM episodes e
        WHERE e.id NOT IN (SELECT episode_id FROM episode_embeddings)
        ORDER BY e.published_at DESC NULLS LAST
        LIMIT $1
      SQL
      limit
    ) do |rs|
      results << {id: rs.read(Int64), title: rs.read(String), description: rs.read(String?)}
    end
    results
  end

  # Returns episode IDs that have embeddings but no topics (for backfill).
  def self.untopicked_episode_ids(limit : Int32 = 100) : Array(NamedTuple(id: Int64, title: String, description: String?))
    results = [] of NamedTuple(id: Int64, title: String, description: String?)
    AppDB.pool.query_each(
      <<-SQL,
        SELECT e.id, e.title, e.description
        FROM episodes e
        JOIN episode_embeddings ee ON ee.episode_id = e.id
        WHERE ee.topics = '{}'
          -- source='title' + empty topics = "already processed by the current
          -- pipeline, legitimately no topics" (e.g. all-noise/all-stopword
          -- content after #90), NOT "awaiting topic backfill". Without this,
          -- a few permanently-empty episodes are re-dispatched every cron run
          -- and starve the source='description' re-extract queue forever
          -- (untopicked is checked before stale in /internal/embed).
          AND ee.source <> 'title'
        ORDER BY e.published_at DESC NULLS LAST
        LIMIT $1
      SQL
      limit
    ) do |rs|
      results << {id: rs.read(Int64), title: rs.read(String), description: rs.read(String?)}
    end
    results
  end

  # Returns episodes with stale embeddings (source != 'title' and not transcript) for re-embedding.
  def self.stale_source_episode_ids(limit : Int32 = 100) : Array(NamedTuple(id: Int64, title: String, description: String?))
    results = [] of NamedTuple(id: Int64, title: String, description: String?)
    AppDB.pool.query_each(
      <<-SQL,
        SELECT e.id, e.title, e.description
        FROM episodes e
        JOIN episode_embeddings ee ON ee.episode_id = e.id
        WHERE ee.source = 'description'
        ORDER BY e.published_at DESC NULLS LAST
        LIMIT $1
      SQL
      limit
    ) do |rs|
      results << {id: rs.read(Int64), title: rs.read(String), description: rs.read(String?)}
    end
    results
  end

  record TagCount, tag : String, count : Int32 do
    include JSON::Serializable
  end

  def self.top_tags_for_user(user_id : Int64, limit : Int32 = 100, offset : Int32 = 0) : Array(TagCount)
    results = [] of TagCount
    AppDB.pool.query_each(
      <<-SQL,
        SELECT COALESCE(tc.label, t) AS tag, COUNT(DISTINCT e.id)::int AS count
        FROM episodes e
        JOIN user_feeds uf ON uf.feed_id = e.feed_id
        JOIN episode_embeddings ee ON ee.episode_id = e.id,
             unnest(ee.topics) AS t
        LEFT JOIN topic_clusters tc ON tc.topic = t
        WHERE uf.user_id = $1
          AND COALESCE(tc.label, t) NOT IN (
            SELECT topic FROM user_hidden_topics WHERE user_id = $1)
          AND COALESCE(tc.label, t) !~ '^[0-9 :./-]+$'
          AND COALESCE(tc.label, t) !~* '^20[0-9]{2}( (год|году|year|jaar))?$'
        GROUP BY COALESCE(tc.label, t)
        ORDER BY count DESC
        LIMIT $2 OFFSET $3
      SQL
      user_id, limit, offset
    ) do |rs|
      results << TagCount.new(rs.read(String), rs.read(Int32))
    end
    results
  end

  def self.hide_topic(user_id : Int64, topic : String)
    AppDB.pool.exec(
      <<-SQL,
        INSERT INTO user_hidden_topics (user_id, topic)
        VALUES ($1, $2)
        ON CONFLICT DO NOTHING
      SQL
      user_id, topic
    )
  end
end
