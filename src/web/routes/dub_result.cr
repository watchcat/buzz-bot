require "json"
require "../../models/dubbed_episode"

module Web::Routes::DubResult
  private struct Result
    include JSON::Serializable
    getter job_id          : String
    getter dub_id          : Int64
    getter episode_id      : Int64?
    getter language        : String?
    getter success         : Bool
    getter r2_url          : String?
    getter duration_sec    : Float64?
    getter segment_count   : Int32?
    getter speaker_count   : Int32?
    getter speaker_samples : String?
    getter step            : String?
    getter error           : String?
  end

  def self.register
    # Internal endpoint — called by dub-pipeline, not the Mini App.
    # No auth: only reachable from within the cluster.
    post "/internal/dub_result" do |env|
      body   = env.request.body.try(&.gets_to_end) || ""
      result = Result.from_json(body)

      unless result.success
        Log.error { "DubResult[#{result.dub_id}]: job #{result.job_id} failed at step=#{result.step} — #{result.error}" }
        DubbedEpisode.set_failed(result.dub_id, result.error || "Pipeline failed")
        env.response.content_type = "application/json"
        next({ok: true}.to_json)
      end

      Log.info { "DubResult[#{result.dub_id}]: job #{result.job_id} done — #{result.r2_url}" }
      DubbedEpisode.set_complete(result.dub_id, result.r2_url, result.speaker_samples)

      if (dub = DubbedEpisode.find_by_id(result.dub_id))
        notify_user(
          dub_id:          result.dub_id,
          episode_id:      result.episode_id || dub.episode_id,
          language:        result.language   || dub.language,
          requester_tg_id: dub.requester_telegram_id
        )
      end

      env.response.content_type = "application/json"
      {ok: true}.to_json
    rescue ex : JSON::ParseException
      Log.error { "DubResult: malformed payload — #{ex.message}" }
      env.response.status_code = 400
      {error: "Invalid JSON"}.to_json
    rescue ex
      Log.error { "DubResult: #{ex.message}" }
      env.response.status_code = 500
      {error: "Internal error"}.to_json
    end
  end

  private def self.notify_user(dub_id : Int64, episode_id : Int64,
                                language : String, requester_tg_id : Int64?)
    return unless requester_tg_id
    app_url = "#{Config.base_url}/app?episode=#{episode_id}"
    BotClient.client.send_message(
      requester_tg_id,
      "🎙 Your dubbed episode is ready in #{language.upcase}.",
      reply_markup: Tourmaline::InlineKeyboardMarkup.new([[
        Tourmaline::InlineKeyboardButton.new(
          text: "▶️ Open Episode",
          web_app: Tourmaline::WebAppInfo.new(url: app_url)
        )
      ]])
    )
  rescue ex
    Log.warn { "DubResult[#{dub_id}]: Telegram notification failed — #{ex.message}" }
  end
end
