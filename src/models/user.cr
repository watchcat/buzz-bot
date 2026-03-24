struct User
  property id : Int64
  property telegram_id : Int64
  property username : String?
  property first_name : String?
  property last_name : String?
  property sub_type : String?
  property sub_expires_at : Time?
  property preferred_dub_language : String?

  def initialize(@id, @telegram_id, @username, @first_name, @last_name, @sub_type, @sub_expires_at, @preferred_dub_language = nil)
  end

  private def self.from_rs(rs)
    new(
      rs.read(Int64),   # id
      rs.read(Int64),   # telegram_id
      rs.read(String?), # username
      rs.read(String?), # first_name
      rs.read(String?), # last_name
      rs.read(String?), # sub_type
      rs.read(Time?),   # sub_expires_at
      rs.read(String?)  # preferred_dub_language
    )
  end

  def self.upsert(telegram_id : Int64, username : String?, first_name : String?, last_name : String?) : User
    AppDB.pool.query_one(
      <<-SQL,
        INSERT INTO users (telegram_id, username, first_name, last_name)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (telegram_id) DO UPDATE SET
          username   = EXCLUDED.username,
          first_name = EXCLUDED.first_name,
          last_name  = EXCLUDED.last_name
        RETURNING id, telegram_id, username, first_name, last_name, sub_type, sub_expires_at, preferred_dub_language
      SQL
      telegram_id, username, first_name, last_name
    ) { |rs| from_rs(rs) }
  end

  def self.find_by_telegram_id(telegram_id : Int64) : User?
    AppDB.pool.query_one?(
      <<-SQL,
        SELECT id, telegram_id, username, first_name, last_name, sub_type, sub_expires_at, preferred_dub_language
        FROM users
        WHERE telegram_id = $1
      SQL
      telegram_id
    ) { |rs| from_rs(rs) }
  end

  def subscribed? : Bool
    exp = sub_expires_at
    return false if exp.nil?
    exp > Time.utc
  end

  def self.update_subscription(id : Int64, sub_type : String, expires_at : Time)
    AppDB.pool.exec(
      "UPDATE users SET sub_type = $1, sub_expires_at = $2 WHERE id = $3",
      sub_type, expires_at, id
    )
  end
end
