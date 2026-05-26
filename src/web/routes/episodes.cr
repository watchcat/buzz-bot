require "ecr"
require "json"

module Web::Routes::Episodes
  # Global semaphore: bound concurrent in-flight audio_proxy fibers so a
  # stalled upstream CDN can't accumulate fibers without limit. Caps:
  # 64 globally (~21 MB worst-case RAM at 128 KB chunk + ~200 KB conn
  # state per fiber); 16 per upstream host so one bad CDN can't monopolise
  # the pool. Note: audio_proxy is ONLY used for the service worker's
  # background "save for offline" flow — actual listening streams direct
  # from the CDN and never traverses our pod. Crystal requires constants at
  # module/class body scope (not inside method bodies).
  LIMITER_AUDIO = ProxyHelpers::ProxyLimiter.new(global_cap: 64, per_host_cap: 16)

  def self.register
    # Fetch minimal metadata for a set of episode IDs (used by offline cache UI).
    # Query param: ids=1,2,3
    get "/episodes/meta" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      ids_str = env.params.query["ids"]?.to_s
      ids = ids_str.split(",").compact_map(&.to_i64?)
      halt env, status_code: 400, response: %({"error":"ids required"}) if ids.empty?

      rows = AppDB.pool.query_all(
        "SELECT e.id, e.title, e.image_url, f.title AS feed_title
         FROM episodes e JOIN feeds f ON f.id = e.feed_id
         WHERE e.id = ANY($1)",
        ids, as: {Int64, String, String?, String}
      )

      env.response.content_type = "application/json"
      rows.map { |id, title, img, ft|
        https_img = img.try { |u| u.starts_with?("http://") ? "https://" + u[7..] : u }
        {id: id, title: title, feed_title: ft, image_url: https_img}
      }.to_json
    end

    # List episodes for a feed
    get "/episodes" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feed_id = env.params.query["feed_id"]?.try(&.to_i64)
      halt env, status_code: 400, response: %({"error":"feed_id required"}) unless feed_id

      feed = Feed.find(feed_id)
      halt env, status_code: 404, response: %({"error":"Feed not found"}) unless feed

      # Default page size kept small: each row triggers an /img-proxy fetch
      # for its per-episode thumbnail, and the upstream feed CDN is often the
      # critical-path bottleneck. Client uses `load-more` (offset) for more.
      limit = (env.params.query["limit"]?.try(&.to_i32) || 20).clamp(1, 500)
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

      episode_id = env.params.url["id"].to_i64
      episode = Episode.find(episode_id)
      halt env, status_code: 404, response: %({"error":"Episode not found"}) unless episode

      feed = Feed.find(episode.feed_id)
      user_episode = UserEpisode.find(user.id, episode_id)
      order = env.params.query["order"]? == "asc" ? "asc" : "desc"
      next_id = Episode.next_in_feed(episode.feed_id, episode_id, order)
      next_title = next_id ? Episode.find(next_id).try(&.title) : nil
      is_subscribed = Feed.subscribed?(user.id, episode.feed_id)
      is_premium = user.subscribed?
      recs_raw = Episode.recommended_for_episode(episode_id)

      rec_feeds = Feed.find_many(recs_raw.map(&.episode.feed_id).uniq)
      recs = recs_raw.map { |r|
        ft = rec_feeds[r.episode.feed_id]?.try(&.title) || ""
        Web::RecJson.new(r, ft)
      }

      ep_json = Web::EpisodeJson.new(
        episode,
        feed.try(&.title) || "",
        feed.try(&.image_url),
        user_episode
      )

      dub_statuses      = DubbedEpisode.statuses_for_episode(episode_id)
      original_language = Episode.original_language(episode_id)

      env.response.content_type = "application/json"
      {
        episode:           ep_json,
        feed:              feed,
        user_episode:      user_episode,
        next_id:           next_id,
        next_title:        next_title,
        recs:              recs,
        is_subscribed:     is_subscribed,
        is_premium:        is_premium,
        dub_statuses:      dub_statuses,
        original_language: original_language,
      }.to_json
    end

    # Save progress
    put "/episodes/:id/progress" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64
      raw = env.request.body.try(&.gets_to_end) || ""
      data = raw.empty? ? JSON.parse("{}") : JSON.parse(raw)

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

      raw = env.request.body.try(&.gets_to_end) || ""
      data = raw.empty? ? JSON.parse("{}") : JSON.parse(raw)
      dubbed = data["dubbed"]?.try(&.as_bool?) || false
      lang = data["language"]?.try(&.as_s?)

      override_url = if dubbed && lang
                       dub = DubbedEpisode.find(episode_id, lang)
                       unless dub && dub.effective_status == "done"
                         env.response.content_type = "application/json"
                         env.response.status_code = 409
                         next %({"error":"dub_not_ready"})
                       end
                       dub.r2_url
                     end

      # Fire-and-forget — handler returns immediately; result arrives via bot message
      spawn { AudioSender.send_to_user(user.telegram_id, episode, feed, override_url) }

      env.response.content_type = "application/json"
      %({"sent":true})
    end

    # Stream episode audio via server-side proxy (follows redirects, auth-gated).
    # Only used for background download (the audio element plays from the direct
    # CDN URL). After IO.copy we call env.response.close so that:
    #   - chunked responses get the "0\r\n\r\n" terminator before Kemal's
    #     post-processing runs (without this, Kemal raising "Headers already sent"
    #     would close the socket without the terminator, the browser sees an
    #     incomplete response and discards the download)
    #   - Content-Length responses are cleanly finalised
    # The rescue only fires for errors that occur BEFORE headers are sent; once
    # streaming has started we let the connection close naturally.
    get "/episodes/:id/audio_proxy" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64
      episode = Episode.find(episode_id)
      halt env, status_code: 404, response: "Episode not found" unless episode

      url = episode.audio_url.sub(/^http:\/\//i, "https://")
      redirects_left = 5
      streaming_started = false

      while redirects_left > 0
        redirects_left -= 1
        uri = URI.parse(url)
        begin
          LIMITER_AUDIO.with_slot(uri.host || "") do
            HTTP::Client.get(url) do |resp|
              if resp.status_code.in?(301, 302, 303, 307, 308)
                loc = resp.headers["Location"]? || break
                url = loc.starts_with?("http") ? loc : "#{uri.scheme}://#{uri.host}#{loc}"
              else
                env.response.status_code = 200
                env.response.content_type = "audio/mpeg"
                env.response.headers["X-Accel-Buffering"] = "no"
                env.response.headers["Cache-Control"] = "no-store"
                if cl = resp.headers["Content-Length"]?
                  env.response.headers["Content-Length"] = cl
                end
                env.response.flush
                streaming_started = true
                begin
                  IO.copy(resp.body_io, env.response, 128 * 1024)
                rescue IO::Error
                  Log.debug { "audio_proxy client disconnected mid-stream" }
                end
                env.response.close
              end
            end
          end
          break if streaming_started
        rescue ex : ProxyHelpers::ProxyLimiter::CapExceeded
          # CapExceeded fires before any header is written, so the response
          # is still mutable.
          Log.info { "audio_proxy 503 — #{ex.message}" }
          env.response.headers["Retry-After"] = "2"
          halt env, status_code: 503, response: "Busy"
        end
      end
      nil
    rescue ex
      # Only log/respond if streaming hadn't started yet; once we've flushed
      # headers and begun sending bytes, any exception is a Kemal housekeeping
      # artefact — the stream was already properly closed above.
      next if streaming_started
      Log.error { "audio_proxy error: #{ex.message}" }
      "Proxy error"
    end

    # Toggle like signal
    put "/episodes/:id/signal" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64
      UserEpisode.toggle_like(user.id, episode_id)
      user_episode = UserEpisode.find(user.id, episode_id)
      liked = user_episode.try(&.liked) == true

      env.response.content_type = "application/json"
      {liked: liked}.to_json
    end
  end
end
