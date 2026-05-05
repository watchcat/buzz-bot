require "json"
require "../../models/dubbed_episode"
require "../../models/dub_segment"
require "../../models/episode"
require "../../models/episode_embedding"
require "../../models/feed"

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
    getter segments        : Array(JSON::Any)?
    getter source_lang     : String?
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
        if (dub = DubbedEpisode.find_by_id(result.dub_id))
          key = "#{dub.episode_id}:#{dub.language}"
          DubHub.instance.publish(key, "#{dub.episode_id}:#{dub.language}:#{result.step || ""}:failed")
        end
        env.response.content_type = "application/json"
        next({ok: true}.to_json)
      end

      Log.info { "DubResult[#{result.dub_id}]: job #{result.job_id} done — #{result.r2_url}" }
      DubbedEpisode.set_complete(result.dub_id, result.r2_url, result.speaker_samples)

      if (ep_id = result.episode_id) && (src = result.source_lang.presence)
        Episode.save_original_language(ep_id, src)
      end

      if (segs = result.segments) && !segs.empty? &&
         (ep_id = result.episode_id) && (lang = result.language)
        begin
          DubSegment.bulk_upsert(ep_id, lang, segs)
          Log.info { "DubResult[#{result.dub_id}]: persisted #{segs.size} segments (lang=#{lang})" }
        rescue ex
          Log.warn { "DubResult[#{result.dub_id}]: segment persist failed (ep=#{ep_id} lang=#{lang}) — #{ex.message}" }
        end
      end

      # Upgrade embedding with transcript if embed endpoint is configured.
      if (embed_eid = Config.embed_endpoint_id) && (ep_id = result.episode_id) &&
         (segs = result.segments) && !segs.empty?
        if (ep = Episode.find(ep_id))
          transcript_text = segs.map { |s| s["text"]?.try(&.as_s?) || "" }.join(" ").strip
          unless transcript_text.empty?
            spawn do
              begin
                text = "#{ep.title}\n\n#{transcript_text}"
                callback_url = "#{Config.dub_callback_base}/internal/embeddings_result"
                secret = Config.internal_webhook_secret
                runpod_input = {
                  episodes:     [{id: ep_id, text: text}],
                  callback_url: callback_url,
                  secret:       secret,
                  source:       "transcript",
                }.to_json
                runpod_payload = {input: JSON.parse(runpod_input)}.to_json
                runpod_client = HTTP::Client.new(URI.parse("https://api.runpod.ai"))
                runpod_client.connect_timeout = 5.seconds
                runpod_client.read_timeout = 10.seconds
                runpod_client.post(
                  "/v2/#{embed_eid}/run",
                  headers: HTTP::Headers{
                    "Authorization" => "Bearer #{Config.runpod_api_key}",
                    "Content-Type"  => "application/json",
                  },
                  body: runpod_payload
                )
                Log.info { "DubResult[#{result.dub_id}]: dispatched transcript embedding upgrade for ep=#{ep_id}" }
              rescue ex
                Log.warn { "DubResult[#{result.dub_id}]: embed upgrade failed — #{ex.message}" }
              end
            end
          end
        end
      end

      if (dub = DubbedEpisode.find_by_id(result.dub_id))
        # Fan out done status to any open SSE connections directly.
        key = "#{dub.episode_id}:#{dub.language}"
        DubHub.instance.publish(key, "#{dub.episode_id}:#{dub.language}::done")

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
    episode     = Episode.find(episode_id)
    feed        = episode.try { |ep| Feed.find(ep.feed_id) }
    ep_title    = episode.try(&.title) || "Episode"
    feed_title  = feed.try(&.title)
    app_url     = "#{Config.base_url}/app?episode=#{episode_id}"

    text = if feed_title
      "🎙 *#{feed_title}*\n#{ep_title}\n\nDubbed to #{language.upcase} and ready to play."
    else
      "🎙 *#{ep_title}*\n\nDubbed to #{language.upcase} and ready to play."
    end

    BotClient.client.send_message(
      requester_tg_id,
      text,
      parse_mode: Tourmaline::ParseMode::Markdown,
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
