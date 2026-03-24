require "kemal"

module WebServer
  def self.setup
    # CORS headers for Mini App requests
    before_all do |env|
      env.response.headers["Access-Control-Allow-Origin"] = "*"
      env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, X-Init-Data"
      env.response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    end

    options "/*" do |env|
      env.response.status_code = 204
    end

    # Error handlers
    error 404 do |env|
      env.response.content_type = "text/html"
      "<h1>404 — Not Found</h1>"
    end

    error 500 do |env, err|
      Log.error { "Server error: #{err.message}" }
      env.response.content_type = "application/json"
      %({"error":"Internal server error"})
    end

    # Serve static files from /public
    serve_static({"gzip" => true, "dir_listing" => false})

    # Load all routes
    Web::Routes::Webhook.register
    Web::Routes::App.register
    Web::Routes::Feeds.register
    Web::Routes::Episodes.register
    Web::Routes::Inbox.register
    Web::Routes::Search.register
    Web::Routes::Discover.register
    Web::Routes::Dub.register
  end

  def self.run(port : Int32)
    Kemal.config.port = port
    Kemal.config.env = "production"
    Kemal.run
  end
end
