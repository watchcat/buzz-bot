module Web::Routes::Flags
  def self.register
    get "/flags" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user
      halt env, status_code: 403, response: "Forbidden" unless Config.admin_user_ids.includes?(user.telegram_id)

      env.response.content_type = "application/json"
      FeatureFlags.all.to_json
    end
  end
end
