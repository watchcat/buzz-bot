require "ecr"
require "http/client"

module Web::Routes::App
  def self.register
    get "/app" do |env|
      env.response.content_type = "text/html"
      env.response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
      ECR.render "src/views/layout.ecr"
    end

    get "/" do |env|
      env.response.redirect "/app"
    end

    # Image proxy — serves external podcast artwork through our own origin to
    # satisfy Telegram WebApp's restrictive img-src CSP.
    get "/img-proxy" do |env|
      url = env.params.query["url"]?.to_s
      halt env, status_code: 400, response: "Bad Request" if url.empty?
      halt env, status_code: 400, response: "HTTPS only" unless url.starts_with?("https://")

      begin
        uri = URI.parse(url)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 5.seconds
        client.read_timeout = 15.seconds
        resp = client.get(uri.request_target)

        content_type = resp.headers["Content-Type"]? || "image/jpeg"
        env.response.content_type = content_type
        env.response.headers["Cache-Control"] = "public, max-age=86400"
        env.response.print(resp.body)
      rescue ex
        halt env, status_code: 502, response: "Bad Gateway"
      end
    end
  end
end
