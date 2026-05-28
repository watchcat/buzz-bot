require "json"
require "../../models/user_feed"

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

    patch "/feeds/:id/delivery_mode" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feed_id = env.params.url["id"].to_i64?
      halt env, status_code: 400, response: %({"error":"bad_feed_id"}) unless feed_id

      body = env.request.body.try(&.gets_to_end) || "{}"
      data = JSON.parse(body) rescue halt env, status_code: 400, response: %({"error":"invalid_json"})
      mode = data["mode"]?.try(&.as_s?) || ""

      unless UserFeed::VALID_DELIVERY_MODES.includes?(mode)
        env.response.status_code = 400
        env.response.content_type = "application/json"
        next %({"error":"invalid_mode","allowed":["off","notify","mp3"]})
      end

      # Premium gate for mp3 mode — matches the manual Send-to-Chat gate at
      # POST /episodes/:id/send. Without this, auto-delivery would trivially
      # bypass the existing manual-feature premium gate.
      if mode == "mp3" && !user.subscribed?
        env.response.status_code = 402
        env.response.content_type = "application/json"
        next %({"error":"premium_required"})
      end

      updated = UserFeed.set_delivery_mode(user.id, feed_id, mode)
      unless updated
        env.response.status_code = 404
        env.response.content_type = "application/json"
        next %({"error":"not_subscribed"})
      end

      env.response.status_code = 204
      nil
    end
  end
end
