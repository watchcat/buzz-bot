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
        ORDER BY e.published_at DESC NULLS LAST
        LIMIT $1
      SQL
      limit
    ) do |rs|
      results << {id: rs.read(Int64), title: rs.read(String), description: rs.read(String?)}
    end
    results
  end
end
