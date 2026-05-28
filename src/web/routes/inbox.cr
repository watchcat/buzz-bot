require "json"
require "http/client"
require "../../models/dubbed_episode"

module Web::Routes::Inbox
  def self.register
    get "/inbox" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      limit    = (env.params.query["limit"]?.try(&.to_i32) || 100).clamp(1, 500)
      offset   = env.params.query["offset"]?.try(&.to_i32) || 0
      episodes = Episode.for_inbox(user.id, limit + 1, offset)
      has_more = episodes.size > limit
      episodes = episodes.first(limit) if has_more

      items = Web.build_episode_list(episodes, user.id)

      env.response.content_type = "application/json"
      {episodes: items, has_more: has_more}.to_json
    end

    # Recently-completed dubs — drives the "Latest dubbed" widget at the
    # top of the inbox. Empty array when there are no done dubs; the client
    # hides the entire widget in that case.
    get "/inbox/dubbed" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      limit = (env.params.query["limit"]?.try(&.to_i32) || 12).clamp(1, 50)
      items = DubbedEpisode.recent_for_inbox(user.id, limit)

      env.response.content_type = "application/json"
      {items: items}.to_json
    end

    get "/inbox/search" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      query = env.params.query["q"]?.to_s.strip
      halt env, status_code: 400, response: %({"error":"q required"}) if query.empty?

      limit  = (env.params.query["limit"]?.try(&.to_i32) || 100).clamp(1, 500)
      offset = env.params.query["offset"]?.try(&.to_i32) || 0

      # Call embed sidecar to get query vector
      sidecar_url = Config.embed_sidecar_url
      sidecar_resp = HTTP::Client.post(
        "#{sidecar_url}/embed",
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: {text: query}.to_json
      )

      unless sidecar_resp.success?
        Log.error { "Embed sidecar failed: #{sidecar_resp.status_code}" }
        halt env, status_code: 502, response: %({"error":"Embedding service unavailable"})
      end

      query_vec = JSON.parse(sidecar_resp.body)["vector"].as_a.map(&.as_f)

      episodes = Episode.for_inbox_semantic(user.id, query_vec, limit + 1, offset)
      has_more = episodes.size > limit
      episodes = episodes.first(limit) if has_more

      items = Web.build_episode_list(episodes, user.id)

      env.response.content_type = "application/json"
      {episodes: items, has_more: has_more}.to_json
    end
  end
end
