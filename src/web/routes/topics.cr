require "json"

module Web::Routes::Topics
  def self.register
    get "/topics" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      tag    = env.params.query["tag"]?.try(&.strip)
      limit  = (env.params.query["limit"]?.try(&.to_i32) || 100).clamp(1, 500)
      offset = env.params.query["offset"]?.try(&.to_i32) || 0

      tags = EpisodeEmbedding.top_tags_for_user(user.id)

      episodes = if tag && !tag.empty?
                   Episode.for_topic(user.id, tag, limit + 1, offset)
                 else
                   Episode.for_inbox(user.id, limit + 1, offset)
                 end

      has_more = episodes.size > limit
      episodes = episodes.first(limit) if has_more

      items = Web.build_episode_list(episodes, user.id)

      env.response.content_type = "application/json"
      {tags: tags, episodes: items, has_more: has_more}.to_json
    end
  end
end
