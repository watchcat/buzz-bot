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
