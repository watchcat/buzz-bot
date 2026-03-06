require "ecr"

module Web::Routes::Inbox
  def self.register
    get "/inbox" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episodes      = Episode.for_inbox(user.id)
      completed_ids = Episode.completed_ids_for_user(user.id)
      feeds_map     = Feed.for_user(user.id).to_h { |f| {f.id, f.title || f.url} }

      env.response.content_type = "text/html"
      ECR.render "src/views/inbox.ecr"
    end
  end
end
