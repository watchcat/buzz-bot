struct User
  property id : Int64
  property telegram_id : Int64
  property username : String?
  property first_name : String?
  property last_name : String?

  def initialize(@id, @telegram_id, @username, @first_name, @last_name)
  end

  def self.upsert(telegram_id : Int64, username : String?, first_name : String?, last_name : String?) : User
    AppDB.pool.query_one(
      <<-SQL,
        INSERT INTO users (telegram_id, username, first_name, last_name)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (telegram_id) DO UPDATE
          SET username = EXCLUDED.username,
              first_name = EXCLUDED.first_name,
              last_name = EXCLUDED.last_name
        RETURNING id, telegram_id, username, first_name, last_name
      SQL
      telegram_id, username, first_name, last_name
    ) do |rs|
      new(rs.read(Int64), rs.read(Int64), rs.read(String?), rs.read(String?), rs.read(String?))
    end
  end

  def self.find_by_telegram_id(telegram_id : Int64) : User?
    AppDB.pool.query_one?(
      "SELECT id, telegram_id, username, first_name, last_name FROM users WHERE telegram_id = $1",
      telegram_id
    ) do |rs|
      new(rs.read(Int64), rs.read(Int64), rs.read(String?), rs.read(String?), rs.read(String?))
    end
  end
end
