require "openssl/hmac"
require "uri"

module Auth
  # Validates Telegram Mini App initData using HMAC-SHA256
  # Returns the parsed params if valid, nil if invalid
  def self.validate_init_data(init_data : String) : Hash(String, String)?
    params = URI::Params.parse(init_data)
    hash = params["hash"]?
    return nil unless hash

    # Build data check string: all params except hash, sorted, joined by \n
    data_check_string = params
      .to_h
      .reject { |k, _| k == "hash" }
      .to_a
      .sort_by { |k, _| k }
      .map { |k, v| "#{k}=#{v}" }
      .join("\n")

    secret_key = OpenSSL::HMAC.digest(:sha256, "WebAppData", Config.bot_token)
    computed = OpenSSL::HMAC.hexdigest(:sha256, secret_key, data_check_string)

    return nil unless computed == hash

    result = {} of String => String
    params.each do |k, v|
      result[k] = v
    end
    result
  end

  # Extract telegram_id from validated initData params
  def self.telegram_id_from(params : Hash(String, String)) : Int64?
    user_json = params["user"]?
    return nil unless user_json
    # Simple extraction without full JSON parsing dependency
    match = user_json.match(/"id"\s*:\s*(\d+)/)
    match.try { |m| m[1].to_i64 }
  end

  # Middleware helper: validate request and return user or halt
  def self.current_user(env : HTTP::Server::Context) : User?
    init_data = env.request.headers["X-Init-Data"]? ||
                env.request.query_params["initData"]?
    return nil unless init_data

    validated = validate_init_data(init_data)
    return nil unless validated

    telegram_id = telegram_id_from(validated)
    return nil unless telegram_id

    User.find_by_telegram_id(telegram_id)
  end
end
