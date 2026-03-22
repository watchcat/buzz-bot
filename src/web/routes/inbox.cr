require "json"

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
  end
end
