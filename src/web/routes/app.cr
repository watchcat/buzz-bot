require "ecr"

module Web::Routes::App
  def self.register
    get "/app" do |env|
      env.response.content_type = "text/html"
      ECR.render "src/views/layout.ecr"
    end

    # Temporary test route for the SPA — serves the new HTML shell
    # Remove at cutover when GET /app is updated
    get "/app-spa" do |env|
      bot_username    = BotClient.username
      assets_version  = Assets::VERSION
      env.response.content_type = "text/html"
      <<-HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Buzz-Bot</title>
        <script src="/js/telegram-web-app.js"></script>
        <link rel="stylesheet" href="/css/app.css?v=#{assets_version}">
      </head>
      <body>
        <div id="app"></div>
        <script>window.BOT_USERNAME = '#{bot_username}';</script>
        <script src="/js/main.js?v=#{assets_version}"></script>
      </body>
      </html>
      HTML
    end

    get "/" do |env|
      env.response.redirect "/app"
    end
  end
end
