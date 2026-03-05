struct UserEpisode
  property id : Int64
  property user_id : Int64
  property episode_id : Int64
  property progress_seconds : Int32
  property completed : Bool
  property liked : Bool?
  property updated_at : Time

  def initialize(@id, @user_id, @episode_id, @progress_seconds, @completed, @liked, @updated_at)
  end

  def self.upsert_progress(user_id : Int64, episode_id : Int64, progress_seconds : Int32, completed : Bool = false)
    AppDB.pool.exec(
      <<-SQL,
        INSERT INTO user_episodes (user_id, episode_id, progress_seconds, completed, updated_at)
        VALUES ($1, $2, $3, $4, NOW())
        ON CONFLICT (user_id, episode_id) DO UPDATE
          SET progress_seconds = EXCLUDED.progress_seconds,
              completed = EXCLUDED.completed OR user_episodes.completed,
              updated_at = NOW()
      SQL
      user_id, episode_id, progress_seconds, completed
    )
  end

  def self.upsert_signal(user_id : Int64, episode_id : Int64, liked : Bool)
    AppDB.pool.exec(
      <<-SQL,
        INSERT INTO user_episodes (user_id, episode_id, liked, updated_at)
        VALUES ($1, $2, $3, NOW())
        ON CONFLICT (user_id, episode_id) DO UPDATE
          SET liked = EXCLUDED.liked,
              updated_at = NOW()
      SQL
      user_id, episode_id, liked
    )
  end

  def self.find(user_id : Int64, episode_id : Int64) : UserEpisode?
    AppDB.pool.query_one?(
      "SELECT id, user_id, episode_id, progress_seconds, completed, liked, updated_at FROM user_episodes WHERE user_id = $1 AND episode_id = $2",
      user_id, episode_id
    ) do |rs|
      new(rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(Int32), rs.read(Bool), rs.read(Bool?), rs.read(Time))
    end
  end
end
