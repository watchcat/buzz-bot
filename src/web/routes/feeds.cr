require "json"

module Web::Routes::Feeds
  def self.register
    get "/feeds" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feeds = Feed.for_user(user.id)
      FeedRefresher.refresh_for_user(user.id)

      env.response.content_type = "application/json"
      {feeds: feeds}.to_json
    end

    post "/feeds" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      url = env.params.body["url"]?.try(&.strip)
      halt env, status_code: 400, response: %({"error":"URL required"}) unless url && !url.empty?

      begin
        parsed = RSS.fetch_and_parse(url)
        feed   = Feed.upsert(parsed.url, parsed.title, parsed.description, parsed.image_url)
        Feed.subscribe(user.id, feed.id)

        spawn do
          parsed.episodes.each do |ep|
            Episode.upsert(feed.id, ep.guid, ep.title, ep.description,
                           ep.audio_url, ep.duration_sec, ep.published_at)
          rescue ex
            Log.warn { "Episode upsert error: #{ex.message}" }
          end
        end

        env.response.content_type = "application/json"
        {feed: feed}.to_json
      rescue ex
        env.response.status_code = 422
        env.response.content_type = "application/json"
        {error: ex.message || "unknown error"}.to_json
      end
    end

    # OPML import — unchanged (deferred)
    post "/feeds/opml" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      file = env.params.files["opml"]?
      halt env, status_code: 400, response: "OPML file required" unless file

      begin
        urls = RSS.parse_opml(file.tempfile.gets_to_end)
        imported = 0

        urls.each do |url|
          spawn do
            begin
              parsed = RSS.fetch_and_parse(url)
              feed = Feed.upsert(parsed.url, parsed.title, parsed.description, parsed.image_url)
              Feed.subscribe(user.id, feed.id)
              parsed.episodes.each do |ep|
                Episode.upsert(feed.id, ep.guid, ep.title, ep.description, ep.audio_url, ep.duration_sec, ep.published_at)
              rescue
              end
            rescue ex
              Log.warn { "OPML feed import error for #{url}: #{ex.message}" }
            end
          end
          imported += 1
        end

        env.response.content_type = "application/json"
        {imported: imported}.to_json
      rescue ex
        env.response.status_code = 422
        env.response.content_type = "application/json"
        {error: ex.message || "unknown error"}.to_json
      end
    end

    post "/feeds/:id/subscribe" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feed_id = env.params.url["id"].to_i64
      Feed.subscribe(user.id, feed_id)

      feed = Feed.find(feed_id)
      env.response.content_type = "application/json"
      {feed: feed}.to_json
    end

    delete "/feeds/:id" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feed_id = env.params.url["id"].to_i64
      Feed.unsubscribe(user.id, feed_id)

      env.response.status_code = 204
      nil
    end
  end
end
