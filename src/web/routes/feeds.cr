require "ecr"
require "json"

module Web::Routes::Feeds
  def self.register
    # List user's feeds (HTMX fragment)
    get "/feeds" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feeds = Feed.for_user(user.id)

      # Refresh feeds that are past their TTL in the background.
      # The user sees current data immediately; new episodes appear on next load.
      FeedRefresher.refresh_for_user(user.id)

      env.response.content_type = "text/html"
      ECR.render "src/views/feeds_list.ecr"
    end

    # Subscribe to a feed by URL
    post "/feeds" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      url = env.params.body["url"]?.try(&.strip)
      halt env, status_code: 400, response: "URL required" unless url && !url.empty?

      begin
        parsed = RSS.fetch_and_parse(url)
        feed = Feed.upsert(parsed.url, parsed.title, parsed.description, parsed.image_url)
        Feed.subscribe(user.id, feed.id)

        # Upsert episodes in background
        spawn do
          parsed.episodes.each do |ep|
            Episode.upsert(feed.id, ep.guid, ep.title, ep.description, ep.audio_url, ep.duration_sec, ep.published_at)
          rescue ex
            Log.warn { "Episode upsert error: #{ex.message}" }
          end
        end

        feeds = Feed.for_user(user.id)
        env.response.content_type = "text/html"
        ECR.render "src/views/feeds_list.ecr"
      rescue ex
        env.response.status_code = 422
        env.response.content_type = "text/html"
        %(<div class="error">Failed to load feed: #{HTML.escape(ex.message || "unknown error")}</div>)
      end
    end

    # Import feeds from OPML
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

        env.response.content_type = "text/html"
        %(<div class="success">Importing #{imported} feeds in the background. Refresh in a moment.</div>)
      rescue ex
        env.response.status_code = 422
        %(<div class="error">Failed to parse OPML: #{HTML.escape(ex.message || "unknown error")}</div>)
      end
    end

    # Unsubscribe from a feed
    delete "/feeds/:id" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feed_id = env.params.url["id"].to_i64
      Feed.unsubscribe(user.id, feed_id)

      feeds = Feed.for_user(user.id)
      env.response.content_type = "text/html"
      ECR.render "src/views/feeds_list.ecr"
    end
  end
end
