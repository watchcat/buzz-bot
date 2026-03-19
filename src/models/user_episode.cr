struct UserEpisode
  include JSON::Serializable

  property episode_id : Int64
  property progress_seconds : Int32
  property completed : Bool
  property liked : Bool?

  @[JSON::Field(ignore: true)]
  property id : Int64
  @[JSON::Field(ignore: true)]
  property user_id : Int64
  @[JSON::Field(ignore: true)]
  property updated_at : Time

  def initialize(@id, @user_id, @episode_id, @progress_seconds, @completed, @liked, @updated_at)
  end

  private def self.from_rs(rs)
    new(
      rs.read(Int64),  # id
      rs.read(Int64),  # user_id
      rs.read(Int64),  # episode_id
      rs.read(Int32),  # progress_seconds
      rs.read(Bool),   # completed
      rs.read(Bool?),  # liked
      rs.read(Time)    # updated_at
    )
  end

  def self.upsert_progress(user_id : Int64, episode_id : Int64, progress_seconds : Int32, completed : Bool = false)
    AppDB.pool.exec(
      <<-SQL,
        INSERT INTO user_episodes (user_id, episode_id, progress_seconds, completed, updated_at)
        VALUES ($1, $2, $3, $4, NOW())
        ON CONFLICT (user_id, episode_id) DO UPDATE SET
          progress_seconds = EXCLUDED.progress_seconds,
          completed        = EXCLUDED.completed OR user_episodes.completed,
          updated_at       = NOW()
      SQL
      user_id, episode_id, progress_seconds, completed
    )
  end

  def self.toggle_like(user_id : Int64, episode_id : Int64)
    AppDB.pool.exec(
      <<-SQL,
        INSERT INTO user_episodes (user_id, episode_id, liked, updated_at)
        VALUES ($1, $2, true, NOW())
        ON CONFLICT (user_id, episode_id) DO UPDATE SET
          liked      = NOT COALESCE(user_episodes.liked, false),
          updated_at = NOW()
      SQL
      user_id, episode_id
    )
  end

  def self.upsert_signal(user_id : Int64, episode_id : Int64, liked : Bool)
    AppDB.pool.exec(
      <<-SQL,
        INSERT INTO user_episodes (user_id, episode_id, liked, updated_at)
        VALUES ($1, $2, $3, NOW())
        ON CONFLICT (user_id, episode_id) DO UPDATE SET
          liked      = EXCLUDED.liked,
          updated_at = NOW()
      SQL
      user_id, episode_id, liked
    )
  end

  def self.find_batch(user_id : Int64, episode_ids : Array(Int64)) : Hash(Int64, UserEpisode)
    return({} of Int64 => UserEpisode) if episode_ids.empty?
    result = {} of Int64 => UserEpisode
    AppDB.pool.query_each(
      <<-SQL,
        SELECT id, user_id, episode_id, progress_seconds, completed, liked, updated_at
        FROM user_episodes
        WHERE user_id = $1 AND episode_id = ANY($2)
      SQL
      user_id, episode_ids
    ) { |rs| ue = from_rs(rs); result[ue.episode_id] = ue }
    result
  end

  def self.find(user_id : Int64, episode_id : Int64) : UserEpisode?
    AppDB.pool.query_one?(
      <<-SQL,
        SELECT id, user_id, episode_id, progress_seconds, completed, liked, updated_at
        FROM user_episodes
        WHERE user_id = $1 AND episode_id = $2
      SQL
      user_id, episode_id
    ) { |rs| from_rs(rs) }
  end
end
