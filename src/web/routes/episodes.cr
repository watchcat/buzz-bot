require "ecr"
require "json"

module Web::Routes::Episodes
  def self.register
    # List episodes for a feed
    get "/episodes" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feed_id = env.params.query["feed_id"]?.try(&.to_i64)
      halt env, status_code: 400, response: %({"error":"feed_id required"}) unless feed_id

      feed = Feed.find(feed_id)
      halt env, status_code: 404, response: %({"error":"Feed not found"}) unless feed

      limit  = (env.params.query["limit"]?.try(&.to_i32) || 50).clamp(1, 500)
      offset = env.params.query["offset"]?.try(&.to_i32) || 0

      order_param = env.params.query["order"]?
      if order_param
        order = order_param == "asc" ? "asc" : "desc"
        AppDB.pool.exec(
          "UPDATE user_feeds SET episode_order = $1 WHERE user_id = $2 AND feed_id = $3",
          order, user.id, feed_id
        )
      else
        saved = AppDB.pool.query_one?(
          "SELECT episode_order FROM user_feeds WHERE user_id = $1 AND feed_id = $2",
          user.id, feed_id, as: String
        )
        order = saved || "desc"
      end

      # If seeking to a specific episode, extend the limit to include its position.
      seek_to_id = env.params.query["seek_to_id"]?.try(&.to_i64)
      if seek_to_id
        dir = order == "asc" ? "ASC" : "DESC"
        pos = AppDB.pool.query_one?(<<-SQL, feed_id, seek_to_id, as: Int64?)
          SELECT rn FROM (
            SELECT id,
                   ROW_NUMBER() OVER (ORDER BY COALESCE(published_at, created_at) #{dir}, id #{dir}) AS rn
            FROM episodes
            WHERE feed_id = $1
          ) t WHERE id = $2
        SQL
        limit = [limit, pos.try(&.to_i32) || limit].max.clamp(1, 500)
      end

      episodes = Episode.for_feed(feed_id, limit + 1, offset, order)
      has_more = episodes.size > limit
      episodes = episodes.first(limit) if has_more

      items = Web.build_episode_list(episodes, user.id)

      env.response.content_type = "application/json"
      {episodes: items, has_more: has_more, episode_order: order}.to_json
    end

    # Get player data for a single episode
    get "/episodes/:id/player" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id   = env.params.url["id"].to_i64
      episode      = Episode.find(episode_id)
      halt env, status_code: 404, response: %({"error":"Episode not found"}) unless episode

      feed          = Feed.find(episode.feed_id)
      user_episode  = UserEpisode.find(user.id, episode_id)
      order         = env.params.query["order"]? == "asc" ? "asc" : "desc"
      next_id       = Episode.next_in_feed(episode.feed_id, episode_id, order)
      next_title    = next_id ? Episode.find(next_id).try(&.title) : nil
      is_subscribed = Feed.subscribed?(user.id, episode.feed_id)
      is_premium    = user.subscribed?
      recs_raw      = Episode.recommended_for_episode(episode_id)

      rec_feeds_map = recs_raw.map(&.feed_id).uniq.each_with_object({} of Int64 => String) do |fid, h|
        h[fid] = Feed.find(fid).try(&.title) || ""
      end
      recs = recs_raw.map { |r| Web::RecJson.new(r, rec_feeds_map[r.feed_id]? || "") }

      ep_json = Web::EpisodeJson.new(
        episode,
        feed.try(&.title) || "",
        feed.try(&.image_url),
        user_episode
      )

      env.response.content_type = "application/json"
      {
        episode:      ep_json,
        feed:         feed,
        user_episode: user_episode,
        next_id:      next_id,
        next_title:   next_title,
        recs:         recs,
        is_subscribed: is_subscribed,
        is_premium:    is_premium,
      }.to_json
    end

    # Save progress
    put "/episodes/:id/progress" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64
      body = env.request.body.try(&.gets_to_end) || "{}"
      data = JSON.parse(body)

      seconds = data["seconds"]?.try(&.as_i) || 0
      completed = data["completed"]?.try(&.as_bool) || false

      UserEpisode.upsert_progress(user.id, episode_id, seconds, completed)
      env.response.status_code = 204
      nil
    end

    # Send episode audio to the user's Telegram chat
    post "/episodes/:id/send" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64
      episode = Episode.find(episode_id)
      halt env, status_code: 404, response: "Episode not found" unless episode

      feed = Feed.find(episode.feed_id)

      unless user.subscribed?
        env.response.content_type = "application/json"
        env.response.status_code = 402
        next %({"error":"premium_required"})
      end

      # Fire-and-forget — handler returns immediately; result arrives via bot message
      spawn { AudioSender.send_to_user(user.telegram_id, episode, feed) }

      env.response.content_type = "application/json"
      %({"sent":true})
    end

    # Stream episode audio via server-side proxy (follows redirects, auth-gated)
    get "/episodes/:id/audio_proxy" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64
      episode = Episode.find(episode_id)
      halt env, status_code: 404, response: "Episode not found" unless episode

      url = episode.audio_url.sub(/^http:\/\//i, "https://")
      streamed = false
      redirects_left = 5

      while redirects_left > 0 && !streamed
        redirects_left -= 1
        uri = URI.parse(url)
        HTTP::Client.get(url) do |resp|
          if resp.status_code.in?(301, 302, 303, 307, 308)
            loc = resp.headers["Location"]? || break
            url = loc.starts_with?("http") ? loc : "#{uri.scheme}://#{uri.host}#{loc}"
          else
            env.response.status_code = resp.status_code
            env.response.content_type = resp.content_type || "audio/mpeg"
            begin
              IO.copy(resp.body_io, env.response)
            rescue IO::Error
              # Upstream closed early or client disconnected — headers already sent,
              # nothing we can do except stop copying. Don't let the exception
              # propagate to Kemal's rescue block (which would cause a TCP RST).
            end
            streamed = true
          end
        end
      end
      nil
    rescue ex
      Log.error { "audio_proxy error: #{ex.message}" }
      env.response.status_code = 502 unless streamed
      "Proxy error"
    end

    # Toggle like signal
    put "/episodes/:id/signal" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id   = env.params.url["id"].to_i64
      UserEpisode.toggle_like(user.id, episode_id)
      user_episode = UserEpisode.find(user.id, episode_id)
      liked        = user_episode.try(&.liked) == true

      env.response.content_type = "application/json"
      {liked: liked}.to_json
    end
  end
end
