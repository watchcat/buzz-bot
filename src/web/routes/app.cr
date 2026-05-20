require "ecr"
require "http/client"

module Web::Routes::App
  # 5 MB ceiling on /img-proxy responses. Defends against HTML error pages
  # mis-served as images and accidental huge artwork. All sampled podcast
  # artwork in the corpus is < 2 MB; raise if a legitimate feed exceeds.
  IMG_PROXY_MAX_BYTES = 5_i64 * 1024 * 1024

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
    # satisfy Telegram WebApp's restrictive img-src CSP. Streams the body
    # through via HTTP::Client block form (no buffering); aborts with 502 if
    # the upstream declares (or streams) more than IMG_PROXY_MAX_BYTES. No
    # in-process cache — we rely on Cache-Control for browser + SW shell.
    get "/img-proxy" do |env|
      url = env.params.query["url"]?.to_s
      halt env, status_code: 400, response: "Bad Request" if url.empty?
      halt env, status_code: 400, response: "HTTPS only" unless url.starts_with?("https://")

      headers_sent = false
      begin
        ProxyHelpers::ProxyStreamer.stream_through(
          url, env.response,
          max_bytes: IMG_PROXY_MAX_BYTES,
          on_headers: ->(resp : HTTP::Client::Response) do
            env.response.content_type = resp.headers["Content-Type"]? || "image/jpeg"
            env.response.headers["Cache-Control"] = "public, max-age=86400, immutable"
            env.response.flush
            headers_sent = true
          end,
        )
      rescue ex : ProxyHelpers::ProxyStreamer::TooLarge
        if headers_sent
          Log.warn { "img-proxy mid-stream TooLarge url=#{url}: #{ex.message}" }
          env.response.close
        else
          halt env, status_code: 502, response: "Upstream too large"
        end
      rescue ex
        if headers_sent
          Log.warn { "img-proxy mid-stream error url=#{url} #{ex.class}: #{ex.message}" }
          env.response.close
        else
          Log.warn { "img-proxy error url=#{url} #{ex.class}: #{ex.message}" }
          halt env, status_code: 502, response: "Bad Gateway"
        end
      end
    end
  end
end
