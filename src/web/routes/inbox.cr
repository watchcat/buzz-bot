require "ecr"

module Web::Routes::Inbox
  def self.register
    get "/inbox" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      limit         = 100
      offset        = env.params.query["offset"]?.try(&.to_i32) || 0
      next_offset   = offset + limit
      episodes      = Episode.for_inbox(user.id, limit, offset)
      completed_ids = Episode.completed_ids_for_user(user.id)
      feeds_map     = Feed.for_user(user.id).to_h { |f| {f.id, f.title || f.url} }

      env.response.content_type = "text/html"
      if offset > 0
        ECR.render "src/views/inbox_items.ecr"
      else
        ECR.render "src/views/inbox.ecr"
      end
    end
  end
end
