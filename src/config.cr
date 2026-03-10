module Config
  def self.bot_token : String
    ENV["BOT_TOKEN"]? || raise "BOT_TOKEN not set"
  end

  def self.webhook_url : String
    ENV["WEBHOOK_URL"]? || raise "WEBHOOK_URL not set"
  end

  def self.database_url : String
    ENV["DATABASE_URL"]? || raise "DATABASE_URL not set"
  end

  def self.port : Int32
    (ENV["PORT"]? || "3000").to_i
  end

  def self.base_url : String
    ENV["BASE_URL"]? || "http://localhost:#{port}"
  end

  # Optional self-hosted Telegram Bot API server endpoint.
  # When set, Tourmaline sends requests here instead of api.telegram.org,
  # enabling file transfers up to 2 GB.
  def self.telegram_api_server : String?
    ENV["TELEGRAM_API_SERVER"]?.presence
  end
end
