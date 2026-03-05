require "tourmaline"

module BotClient
  @@client : Tourmaline::Client?

  def self.client : Tourmaline::Client
    @@client ||= Tourmaline::Client.new(Config.bot_token)
  end

  def self.register_webhook
    client.set_webhook(Config.webhook_url)
    Log.info { "Webhook registered at #{Config.webhook_url}" }
  rescue ex
    Log.error { "Failed to register webhook: #{ex.message}" }
    raise ex
  end

  def self.handle_update(update : Tourmaline::Update)
    Bot::Handlers.dispatch(update)
  end
end
