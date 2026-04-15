require "ecr"
require "http/client"

module Web::Routes::App
  # In-memory image cache — keyed by URL, value is {body_bytes, content_type}.
  # Podcast artwork rarely changes; 500-entry cap keeps memory bounded (~50 MB
  # at ~100 KB per image). Oldest entry is evicted when the cap is reached.
  CACHE_MAX   = 500
  CACHE_MUTEX = Mutex.new
  CACHE       = {} of String => {Bytes, String}

  private def self.cache_get(url : String) : {Bytes, String}?
    CACHE_MUTEX.synchronize { CACHE[url]? }
  end

  private def self.cache_set(url : String, body : Bytes, ct : String)
    CACHE_MUTEX.synchronize do
      CACHE.delete(CACHE.first_key) if CACHE.size >= CACHE_MAX
      CACHE[url] = {body, ct}
    end
  end

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
    # Responses are cached in memory to avoid blocking on slow CDNs.
    get "/img-proxy" do |env|
      url = env.params.query["url"]?.to_s
      halt env, status_code: 400, response: "Bad Request" if url.empty?
      halt env, status_code: 400, response: "HTTPS only" unless url.starts_with?("https://")

      body_bytes, content_type =
        if cached = cache_get(url)
          cached
        else
          begin
            uri = URI.parse(url)
            client = HTTP::Client.new(uri)
            client.connect_timeout = 5.seconds
            client.read_timeout = 15.seconds
            resp = client.get(uri.request_target)
            ct = resp.headers["Content-Type"]? || "image/jpeg"
            bytes = resp.body.to_slice.dup
            cache_set(url, bytes, ct)
            {bytes, ct}
          rescue ex
            halt env, status_code: 502, response: "Bad Gateway"
          end
        end

      env.response.content_type = content_type
      env.response.headers["Cache-Control"] = "public, max-age=86400"
      env.response.write(body_bytes)
    end
  end
end
