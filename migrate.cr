require "dotenv"
require "db"
require "pg"

Dotenv.load if File.exists?(".env")

db_url = ENV["DATABASE_URL"]? || abort("DATABASE_URL not set")

puts "Connecting to database..."
DB.open(db_url) do |db|
  # Track which migrations have already run
  db.exec(<<-SQL)
    CREATE TABLE IF NOT EXISTS schema_migrations (
      filename TEXT PRIMARY KEY,
      applied_at TIMESTAMPTZ DEFAULT NOW()
    )
  SQL

  Dir.glob("migrations/*.sql").sort.each do |file|
    filename = File.basename(file)
    already_applied = db.query_one?(
      "SELECT 1 FROM schema_migrations WHERE filename = $1", filename, as: Int32
    )
    if already_applied
      puts "Skipping #{file} (already applied)"
      next
    end

    puts "Running #{file}..."
    sql = File.read(file)
    sql.split(";").map(&.strip).reject(&.empty?).each do |stmt|
      db.exec(stmt)
    end
    db.exec("INSERT INTO schema_migrations (filename) VALUES ($1)", filename)
    puts "  OK"
  end
end

puts "Migrations complete."
