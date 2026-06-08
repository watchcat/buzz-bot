require "json"
require "http/client"
require "uri"
require "../dub_dispatch"

module Web::Routes::Dub
  def self.register
    post "/episodes/:id/dub" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      unless user.subscribed?
        env.response.content_type = "application/json"
        env.response.status_code = 402
        next %({"error":"premium_required"})
      end

      episode_id = env.params.url["id"].to_i64
      episode = Episode.find(episode_id)
      halt env, status_code: 404, response: %({"error":"not_found"}) unless episode

      body = env.request.body.try(&.gets_to_end) || "{}"
      data = JSON.parse(body)
      language = data["language"]?.try(&.as_s?) || ""

      unless DUB_LANGUAGES.includes?(language)
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next %({"error":"unsupported_language"})
      end

      if Episode.original_language(episode_id) == language
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next %({"error":"already_original_language"})
      end

      if (dur = episode.duration_sec) && dur > 14400
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next %({"error":"episode_too_long"})
      end

      existing = DubbedEpisode.find(episode_id, language)

      if existing
        eff = existing.effective_status
        if eff == "processing" || eff == "pending"
          env.response.content_type = "application/json"
          next %({"id":#{existing.id},"status":"#{eff}"})
        elsif eff == "done"
          env.response.content_type = "application/json"
          next %({"id":#{existing.id},"status":"done","r2_url":#{existing.r2_url.to_json}})
        end
        # failed and expired fall through to upsert+spawn (retry)
      end

      dub_id = DubbedEpisode.upsert_pending(episode_id, language, user.telegram_id)

      begin
        bg_volume     = data["bg_volume"]?.try(&.as_f?) || 0.15
        job_id        = Random::Secure.hex(16)
        callback_base = Config.dub_callback_base

        if FeatureFlags.enabled?("dub_orchestrator")
          dispatch_body = Web::DubDispatch.dub_payload(
            job_id, dub_id, episode_id, episode.audio_url, language, bg_volume,
            "#{callback_base}/internal/dub_result")
          orch = HTTP::Client.new(URI.parse(Config.orch_base_url))
          orch.connect_timeout = 5.seconds
          orch.read_timeout = 10.seconds
          response = orch.post("/dispatch",
            headers: HTTP::Headers{
              "X-Dispatch-Token" => Config.orch_dispatch_secret,
              "Content-Type"     => "application/json"},
            body: dispatch_body)
          raise "Orchestrator dispatch error: #{response.status_code} #{response.body}" unless response.success?
          Log.info { "Dub[#{dub_id}]: dispatched to orchestrator (episode #{episode_id} → #{language})" }
        else
          payload = {
            job_id:       job_id,
            dub_id:       dub_id,
            episode_id:   episode_id,
            audio_url:    episode.audio_url,
            language:     language,
            bg_volume:    bg_volume,
            callback_url: "#{callback_base}/internal/dub_result",
          }.to_json
          runpod_payload = {input: JSON.parse(payload)}.to_json
          runpod_client = HTTP::Client.new(URI.parse("https://api.runpod.ai"))
          runpod_client.connect_timeout = 5.seconds
          runpod_client.read_timeout = 10.seconds
          response = runpod_client.post(
            "/v2/#{Config.runpod_endpoint_id}/run",
            headers: HTTP::Headers{
              "Authorization" => "Bearer #{Config.runpod_api_key}",
              "Content-Type"  => "application/json"
            },
            body: runpod_payload
          )
          raise "RunPod API error: #{response.status_code} #{response.body}" unless response.success?
          Log.info { "Dub[#{dub_id}]: job #{job_id} submitted to RunPod (episode #{episode_id} → #{language})" }
        end
      rescue ex
        Log.error { "Dub[#{dub_id}]: failed to enqueue — #{ex.message}" }
        DubbedEpisode.set_failed(dub_id, "Failed to enqueue job: #{ex.message}")
        env.response.content_type = "application/json"
        env.response.status_code = 500
        next %({"error":"enqueue_failed"})
      end

      env.response.content_type = "application/json"
      env.response.status_code = 202
      %({"id":#{dub_id},"status":"pending"})
    end

    get "/episodes/:id/dub/:language" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64
      language = env.params.url["language"]

      unless DUB_LANGUAGES.includes?(language)
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next %({"error":"unsupported_language"})
      end

      dub = DubbedEpisode.find(episode_id, language)
      halt env, status_code: 404, response: %({"error":"not_found"}) unless dub

      env.response.content_type = "application/json"
      eff = dub.effective_status
      case eff
      when "done"
        %({"status":"done","r2_url":#{dub.r2_url.to_json},"translation":#{dub.translation.to_json}})
      when "failed"
        %({"status":"failed","error":#{dub.error.to_json}})
      else
        %({"status":"#{eff}","step":#{dub.step.to_json}})
      end
    end

    # SSE stream: pushes step/status updates as JSON events until done or failed.
    get "/episodes/:id/dub/:language/events" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64
      lang       = env.params.url["language"]

      unless DUB_LANGUAGES.includes?(lang)
        halt env, status_code: 400, response: %({"error":"unsupported_language"})
      end

      env.response.content_type = "text/event-stream; charset=utf-8"
      env.response.headers["Cache-Control"]      = "no-cache"
      env.response.headers["X-Accel-Buffering"]  = "no"
      env.response.headers["Connection"]         = "keep-alive"

      dub = DubbedEpisode.find(episode_id, lang)
      unless dub
        env.response.print "data: {\"status\":\"not_found\"}\n\n"
        env.response.flush
        next nil
      end

      eff = dub.effective_status

      # Already terminal — send final state and close immediately.
      case eff
      when "done"
        env.response.print "data: {\"status\":\"done\",\"r2_url\":#{dub.r2_url.to_json},\"translation\":#{dub.translation.to_json}}\n\n"
        env.response.flush
        next nil
      when "failed"
        env.response.print "data: {\"status\":\"failed\",\"error\":#{dub.error.to_json}}\n\n"
        env.response.flush
        next nil
      end

      # In-flight — stream progress until terminal state.
      env.response.print "data: {\"status\":#{eff.to_json},\"step\":#{dub.step.to_json}}\n\n"
      env.response.flush

      key = "#{episode_id}:#{lang}"
      ch  = DubHub.instance.subscribe(key)

      done = false
      until done
        select
        when payload = ch.receive
          parts  = payload.split(":", 5)
          step   = parts[2]? || ""
          status = parts[3]? || ""
          pct    = parts[4]?.try(&.to_i?)
          case status
          when "done"
            row = DubbedEpisode.find(episode_id, lang)
            if row && row.status == "done"
              env.response.print "data: {\"status\":\"done\",\"r2_url\":#{row.r2_url.to_json},\"translation\":#{row.translation.to_json}}\n\n"
            else
              env.response.print "data: {\"status\":\"done\"}\n\n"
            end
            done = true
          when "failed"
            row = DubbedEpisode.find(episode_id, lang)
            err = row.try(&.error) || "Unknown error"
            env.response.print "data: {\"status\":\"failed\",\"error\":#{err.to_json}}\n\n"
            done = true
          else
            pct_field = pct ? ",\"pct\":#{pct}" : ""
            env.response.print "data: {\"status\":#{status.to_json},\"step\":#{step.to_json}#{pct_field}}\n\n"
          end
          env.response.flush
        when timeout(25.seconds)
          env.response.print ": keepalive\n\n"
          env.response.flush
        end
      end

      DubHub.instance.unsubscribe(key, ch)
      nil
    end

    put "/user/dub_language" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      unless user.subscribed?
        env.response.content_type = "application/json"
        env.response.status_code = 402
        next %({"error":"premium_required"})
      end

      body = env.request.body.try(&.gets_to_end) || "{}"
      data = JSON.parse(body)
      language = data["language"]?.try(&.as_s?) || ""

      unless DUB_LANGUAGES.includes?(language)
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next %({"error":"unsupported_language"})
      end

      AppDB.pool.exec(
        "UPDATE users SET preferred_dub_language = $1 WHERE id = $2",
        language, user.id
      )

      env.response.status_code = 204
      nil
    end
  end
end
