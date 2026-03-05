require "ecr"

module Web::Routes::Recommendations
  def self.register
    get "/recommendations" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episodes = Episode.recommended_for(user.id)
      env.response.content_type = "text/html"
      ECR.render "src/views/recommendations.ecr"
    end
  end
end
