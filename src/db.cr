require "db"
require "pg"

module AppDB
  @@pool : DB::Database?

  def self.pool : DB::Database
    @@pool ||= DB.open(Config.database_url)
  end

  def self.query(sql : String, *args, &block)
    pool.query(sql, *args) do |rs|
      block.call(rs)
    end
  end

  def self.exec(sql : String, *args)
    pool.exec(sql, *args)
  end

  def self.scalar(sql : String, *args)
    pool.scalar(sql, *args)
  end
end
