require "dotenv"
require "db"
require "pg"

Dotenv.load if File.exists?(".env")

db_url = ENV["DATABASE_URL"]? || abort("DATABASE_URL not set")

puts "Connecting to database..."
DB.open(db_url) do |db|
  Dir.glob("migrations/*.sql").sort.each do |file|
    puts "Running #{file}..."
    sql = File.read(file)
    # Split on semicolons, skip empty statements
    sql.split(";").map(&.strip).reject(&.empty?).each do |stmt|
      db.exec(stmt)
    end
    puts "  OK"
  end
end

puts "Migrations complete."
