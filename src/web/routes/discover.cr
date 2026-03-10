require "ecr"

module Web::Routes::Discover
  def self.register
    # Full discover tab — liked episodes by default
    get "/discover" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      limit           = 50
      offset          = 0
      next_offset     = limit
      liked_episodes  = Episode.liked_for_user(user.id, limit, offset)
      feed_ids        = liked_episodes.map(&.feed_id).uniq
      feeds_map       = feed_ids.each_with_object({} of Int64 => String) do |fid, h|
        h[fid] = Feed.find(fid).try(&.title) || ""
      end

      env.response.content_type = "text/html"
      ECR.render "src/views/discover.ecr"
    end

    # Search results fragment (also used for liked list when q is blank)
    get "/discover/search" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      query = env.params.query["q"]?.try(&.strip) || ""

      if query.empty?
        limit          = 50
        offset         = env.params.query["offset"]?.try(&.to_i32) || 0
        next_offset    = offset + limit
        episodes       = Episode.liked_for_user(user.id, limit, offset)
        section_title  = "❤️ Liked episodes"
      else
        limit          = 30
        offset         = 0
        next_offset    = limit
        episodes       = Episode.search_for_user(user.id, query, limit)
        section_title  = "Search results"
      end

      feed_ids  = episodes.map(&.feed_id).uniq
      feeds_map = feed_ids.each_with_object({} of Int64 => String) do |fid, h|
        h[fid] = Feed.find(fid).try(&.title) || ""
      end

      env.response.content_type = "text/html"
      ECR.render "src/views/discover_results.ecr"
    end
  end
end
