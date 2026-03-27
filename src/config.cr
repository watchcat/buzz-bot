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

  # Direct (non-pooler) URL for LISTEN/NOTIFY connections.
  # pgbouncer doesn't support LISTEN; strip "-pooler" from the host.
  def self.database_url_direct : String
    database_url.sub("-pooler.", ".")
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

  def self.replicate_api_token : String
    ENV["REPLICATE_API_TOKEN"]? || raise "REPLICATE_API_TOKEN not set"
  end

  def self.deepl_api_key : String
    ENV["DEEPL_API_KEY"]? || raise "DEEPL_API_KEY not set"
  end

  def self.r2_account_id : String
    ENV["R2_ACCOUNT_ID"]? || raise "R2_ACCOUNT_ID not set"
  end

  def self.r2_access_key_id : String
    ENV["R2_ACCESS_KEY_ID"]? || raise "R2_ACCESS_KEY_ID not set"
  end

  def self.r2_secret_access_key : String
    ENV["R2_SECRET_ACCESS_KEY"]? || raise "R2_SECRET_ACCESS_KEY not set"
  end

  def self.r2_bucket : String
    ENV["R2_BUCKET"]? || raise "R2_BUCKET not set"
  end

  def self.r2_public_url : String
    ENV["R2_PUBLIC_URL"]? || raise "R2_PUBLIC_URL not set"
  end
end
