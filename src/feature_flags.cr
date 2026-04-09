module FeatureFlags
  DEFAULTS = {
    "offline_caching" => true,
    "stall_recovery"  => true,
    "img_proxy"       => true,
    "dub_translation" => true,
    "dub_synthesis"   => true,
  }

  @@flags : Hash(String, Bool) = DEFAULTS.dup

  # Create the table if needed and load current values from DB.
  def self.setup!
    AppDB.pool.exec <<-SQL
      CREATE TABLE IF NOT EXISTS feature_flags (
        name       TEXT PRIMARY KEY,
        enabled    BOOLEAN NOT NULL DEFAULT true,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    SQL
    load!
  end

  def self.load!
    rows = AppDB.pool.query_all("SELECT name, enabled FROM feature_flags",
                                as: {String, Bool})
    merged = DEFAULTS.dup
    rows.each { |name, val| merged[name] = val }
    @@flags = merged
  rescue ex
    Log.error { "FeatureFlags.load! failed: #{ex.message}" }
  end

  def self.all : Hash(String, Bool)
    @@flags
  end

  def self.enabled?(name : String) : Bool
    @@flags.fetch(name) { DEFAULTS.fetch(name, true) }
  end

  def self.set!(name : String, enabled : Bool)
    AppDB.pool.exec(
      "INSERT INTO feature_flags (name, enabled) VALUES ($1, $2)
       ON CONFLICT (name) DO UPDATE SET enabled = $2, updated_at = now()",
      name, enabled
    )
    @@flags[name] = enabled
  end
end
