require "ecr"

module Web::Routes::App
  def self.register
    get "/app" do |env|
      env.response.content_type = "text/html"
      ECR.render "src/views/layout.ecr"
    end

    get "/" do |env|
      env.response.redirect "/app"
    end
  end
end
