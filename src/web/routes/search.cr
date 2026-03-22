require "http/client"
require "json"

module Web::Routes::Search
  APPLE_SEARCH_API = "https://itunes.apple.com/search"

  struct PodcastResult
    include JSON::Serializable
    property name          : String
    property author        : String
    property feed_url      : String
    property artwork_url   : String?
    property genre         : String?
    property episode_count : Int32?

    def initialize(@name, @author, @feed_url, @artwork_url, @genre, @episode_count)
    end
  end

  def self.register
    # Search Apple Podcasts catalog — returns JSON
    get "/search" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      query = env.params.query["q"]?.try(&.strip)

      if query.nil? || query.empty?
        env.response.content_type = "application/json"
        next {results: [] of PodcastResult}.to_json
      end

      begin
        results = query_apple(query)
        env.response.content_type = "application/json"
        {results: results}.to_json
      rescue ex
        Log.warn { "Apple search error: #{ex.message}" }
        env.response.status_code = 422
        env.response.content_type = "application/json"
        {error: ex.message || "unknown error"}.to_json
      end
    end

    # Subscribe from search results
    post "/search/subscribe" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      url = env.params.body["url"]?.try(&.strip)
      halt env, status_code: 400, response: %({"error":"URL required"}) unless url && !url.empty?

      begin
        parsed = RSS.fetch_and_parse(url)
        feed = Feed.upsert(parsed.url, parsed.title, parsed.description, parsed.image_url)
        Feed.subscribe(user.id, feed.id)

        spawn do
          parsed.episodes.each do |ep|
            Episode.upsert(feed.id, ep.guid, ep.title, ep.description, ep.audio_url, ep.duration_sec, ep.published_at)
          rescue
          end
        end

        env.response.content_type = "application/json"
        {feed: feed}.to_json
      rescue ex
        env.response.status_code = 422
        env.response.content_type = "application/json"
        {error: ex.message || "unknown error"}.to_json
      end
    end
  end

  private def self.query_apple(query : String, limit : Int32 = 12) : Array(PodcastResult)
    qs = HTTP::Params.encode({
      "term"   => query,
      "media"  => "podcast",
      "entity" => "podcast",
      "limit"  => limit.to_s,
    })

    full_url = "#{APPLE_SEARCH_API}?#{qs}"
    uri      = URI.parse(full_url)
    client   = HTTP::Client.new(uri)
    client.read_timeout = 10.seconds
    req_path = uri.query ? "#{uri.path}?#{uri.query}" : uri.path
    resp = client.get(req_path)
    raise "Apple API returned HTTP #{resp.status_code}" unless resp.success?

    results = [] of PodcastResult
    JSON.parse(resp.body)["results"].as_a.each do |item|
      feed_url = item["feedUrl"]?.try(&.as_s?)
      next unless feed_url && !feed_url.empty?

      results << PodcastResult.new(
        name:          item["trackName"]?.try(&.as_s?)    || "Unknown",
        author:        item["artistName"]?.try(&.as_s?)   || "",
        feed_url:      feed_url,
        artwork_url:   item["artworkUrl600"]?.try(&.as_s?),
        genre:         item["primaryGenreName"]?.try(&.as_s?),
        episode_count: item["trackCount"]?.try(&.as_i?)
      )
    end
    results
  end
end
