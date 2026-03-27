require "json"

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

      if (dur = episode.duration_sec) && dur > 3600
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
          parts  = payload.split(":", 4)
          step   = parts[2]? || ""
          status = parts[3]? || ""
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
            env.response.print "data: {\"status\":#{status.to_json},\"step\":#{step.to_json}}\n\n"
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
