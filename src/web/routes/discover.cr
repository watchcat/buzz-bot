require "json"

module Web::Routes::Discover
  def self.register
    get "/bookmarks" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      limit    = (env.params.query["limit"]?.try(&.to_i32) || 50).clamp(1, 500)
      episodes = Episode.liked_for_user(user.id, limit, 0)
      items    = Web.build_episode_list(episodes, user.id)

      env.response.content_type = "application/json"
      {episodes: items, has_more: false}.to_json
    end

    get "/bookmarks/search" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      query    = env.params.query["q"]?.try(&.strip) || ""
      episodes = query.empty? ?
        Episode.liked_for_user(user.id, 50, 0) :
        Episode.search_for_user(user.id, query, 30)
      items = Web.build_episode_list(episodes, user.id)

      env.response.content_type = "application/json"
      {episodes: items}.to_json
    end
  end
end
