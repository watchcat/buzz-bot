require "json"

module Web::Routes::Topics
  def self.register
    get "/topics" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      tag        = env.params.query["tag"]?.try(&.strip)
      limit      = (env.params.query["limit"]?.try(&.to_i32) || 100).clamp(1, 500)
      offset     = env.params.query["offset"]?.try(&.to_i32) || 0
      tag_limit  = (env.params.query["tag_limit"]?.try(&.to_i32) || 20).clamp(1, 500)
      tag_offset = env.params.query["tag_offset"]?.try(&.to_i32) || 0

      tags = EpisodeEmbedding.top_tags_for_user(user.id, tag_limit + 1, tag_offset)
      has_more_tags = tags.size > tag_limit
      tags = tags.first(tag_limit) if has_more_tags

      episodes = if tag && !tag.empty?
                   Episode.for_topic(user.id, tag, limit + 1, offset)
                 else
                   Episode.for_inbox(user.id, limit + 1, offset)
                 end

      has_more = episodes.size > limit
      episodes = episodes.first(limit) if has_more

      items = Web.build_episode_list(episodes, user.id)

      env.response.content_type = "application/json"
      {tags: tags, episodes: items, has_more: has_more, has_more_tags: has_more_tags}.to_json
    end

    post "/topics/hide" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      body = env.request.body.try(&.gets_to_end) || ""
      parsed = JSON.parse(body)
      tag = parsed["tag"]?.try(&.as_s)
      unless tag
        env.response.status_code = 400
        next({error: "Missing tag"}.to_json)
      end

      EpisodeEmbedding.hide_topic(user.id, tag)

      env.response.content_type = "application/json"
      {ok: true}.to_json
    end
  end
end
