require "ecr"
require "json"

module Web::Routes::Episodes
  def self.register
    # List episodes for a feed (HTMX fragment)
    get "/episodes" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feed_id = env.params.query["feed_id"]?.try(&.to_i64)
      halt env, status_code: 400, response: "feed_id required" unless feed_id

      feed = Feed.find(feed_id)
      halt env, status_code: 404, response: "Feed not found" unless feed

      episodes = Episode.for_feed(feed_id)
      completed_ids = Episode.completed_ids(user.id, feed_id)
      env.response.content_type = "text/html"
      ECR.render "src/views/episode_list.ecr"
    end

    # Get player for a single episode
    get "/episodes/:id/player" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64
      episode = Episode.find(episode_id)
      halt env, status_code: 404, response: "Episode not found" unless episode

      feed            = Feed.find(episode.feed_id)
      user_episode    = UserEpisode.find(user.id, episode_id)
      next_episode_id = Episode.next_in_feed(episode.feed_id, episode_id)
      should_autoplay = env.params.query["autoplay"]? == "1"
      from_inbox      = env.params.query["from"]? == "inbox"
      recs            = Episode.recommended_for_episode(episode_id)
      rec_feeds_map   = recs.map(&.feed_id).uniq.each_with_object({} of Int64 => String) do |fid, h|
        h[fid] = Feed.find(fid).try(&.title) || ""
      end
      env.response.content_type = "text/html"
      ECR.render "src/views/player.ecr"
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

      # Fire-and-forget — handler returns immediately; result arrives via bot message
      spawn { AudioSender.send_to_user(user.telegram_id, episode, feed) }

      env.response.content_type = "text/html"
      %(<div class="send-result info">📤 Sending to your chat&hellip; it will arrive in a moment.</div>)
    end

    # Save like/dislike signal
    put "/episodes/:id/signal" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64

      liked = case env.params.body["liked"]?
              when "true"  then true
              when "false" then false
              else
                halt env, status_code: 400, response: "liked field required"
                next
              end

      UserEpisode.upsert_signal(user.id, episode_id, liked)

      episode = Episode.find(episode_id)
      halt env, status_code: 404, response: "Episode not found" unless episode
      user_episode = UserEpisode.find(user.id, episode_id)

      env.response.content_type = "text/html"
      ECR.render "src/views/like_buttons.ecr"
    end
  end
end
