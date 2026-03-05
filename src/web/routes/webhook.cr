require "json"
require "tourmaline"

module Web::Routes::Webhook
  def self.register
    post "/webhook" do |env|
      body = env.request.body.try(&.gets_to_end) || ""

      begin
        update = Tourmaline::Update.from_json(body)
        spawn { BotClient.handle_update(update) }
        env.response.status_code = 200
        "ok"
      rescue ex : JSON::ParseException
        Log.warn { "Webhook parse error: #{ex.message}" }
        env.response.status_code = 400
        "bad request"
      end
    end
  end
end
