require "http/client"

# FeedRefresher runs as two concurrent fibers:
#
#   1. Per-user scan  — triggered from GET /feeds whenever a user opens the
#                        app; refreshes only that user's feeds that are past
#                        their TTL. Returns immediately (work done in a fiber).
#   2. Periodic loop  — wakes every CHECK_EVERY minutes and refreshes all
#                        subscribed feeds whose TTL has elapsed globally.
#
# Per-feed improvements:
#   - Conditional GET: sends If-None-Match / If-Modified-Since so servers
#     that support it can reply 304 Not Modified, saving bandwidth.
#   - TTL from <ttl>: each feed declares its preferred refresh interval in
#     minutes; stored in feeds.ttl_minutes and honoured by both scan paths.
#     Clamped to [MIN_TTL, MAX_TTL] to guard against extreme values.
#   - Stagger: a short delay between spawning each refresh fiber avoids
#     thundering-herd requests to remote podcast servers.

module FeedRefresher
  MIN_TTL       =   15  # minutes — never refresh more often than this
  MAX_TTL       = 1440  # minutes — never wait longer than 24 h
  CHECK_EVERY   =    1.hour
  STAGGER_DELAY =    2.seconds
  HTTP_TIMEOUT  =   15.seconds

  @@periodic_running = false

  # Start the background periodic loop. Call once at boot.
  def self.start
    spawn(name: "feed-refresher-loop") { periodic_loop }
  end

  # Refresh feeds belonging to a specific user that are past their TTL.
  # Spawns a fiber and returns immediately — safe to call from a request handler.
  def self.refresh_for_user(user_id : Int64)
    feeds = Feed.for_user(user_id)
    due   = feeds.select { |f| due?(f) }
    return if due.empty?
    Log.info { "FeedRefresher: user #{user_id} — #{due.size}/#{feeds.size} feeds due for refresh" }
    spawn(name: "feed-refresh-user-#{user_id}") { run_batch(due) }
  end

  # --------------------------------------------------------------------------
  # Periodic loop — covers feeds whose owner hasn't opened the app recently
  # --------------------------------------------------------------------------

  private def self.periodic_loop
    loop do
      sleep CHECK_EVERY

      if @@periodic_running
        Log.warn { "FeedRefresher: periodic scan skipped — previous run still in progress" }
        next
      end

      @@periodic_running = true
      begin
        feeds = Feed.due_for_refresh
        unless feeds.empty?
          Log.info { "FeedRefresher: periodic — #{feeds.size} feeds due for refresh" }
          run_batch(feeds)
        end
      ensure
        @@periodic_running = false
      end
    end
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  private def self.due?(feed : Feed) : Bool
    lf = feed.last_fetched_at
    return true if lf.nil?
    ttl = clamp_ttl(feed.ttl_minutes)
    Time.utc >= lf + ttl.minutes
  end

  private def self.clamp_ttl(ttl : Int32?) : Int32
    (ttl || 60).clamp(MIN_TTL, MAX_TTL)
  end

  # --------------------------------------------------------------------------
  # Batch runner — stagger-spawns one fiber per feed
  # --------------------------------------------------------------------------

  private def self.run_batch(feeds : Array(Feed))
    feeds.each_with_index do |feed, i|
      sleep STAGGER_DELAY if i > 0
      spawn(name: "feed-refresh-#{feed.id}") { refresh(feed) }
    end
  end

  # --------------------------------------------------------------------------
  # Single feed refresh
  # --------------------------------------------------------------------------

  private def self.refresh(feed : Feed)
    headers = HTTP::Headers{"User-Agent" => "BuzzBot/1.0 (podcast aggregator)"}
    feed.etag.try          { |v| headers["If-None-Match"]     = v }
    feed.last_modified.try { |v| headers["If-Modified-Since"] = v }

    uri    = URI.parse(feed.url)
    client = HTTP::Client.new(uri)
    client.read_timeout = HTTP_TIMEOUT
    req_path = uri.query ? "#{uri.path}?#{uri.query}" : uri.path
    resp = client.get(req_path, headers: headers)

    if resp.status_code == 304
      Feed.update_refresh_metadata(feed.id, nil, nil, nil)
      Log.debug { "FeedRefresher: feed #{feed.id} — 304 Not Modified" }
      return
    end

    unless resp.success?
      Log.warn { "FeedRefresher: feed #{feed.id} — HTTP #{resp.status_code} (#{feed.url})" }
      return
    end

    new_etag     = resp.headers["ETag"]?
    new_last_mod = resp.headers["Last-Modified"]?

    parsed      = RSS.parse(feed.url, resp.body)
    clamped_ttl = parsed.ttl_minutes.try { |t| t.clamp(MIN_TTL, MAX_TTL) }

    Feed.update_refresh_metadata(feed.id, new_etag, new_last_mod, clamped_ttl)

    new_count = 0
    parsed.episodes.each do |ep|
      result = Episode.upsert(
        feed.id, ep.guid, ep.title, ep.description,
        ep.audio_url, ep.duration_sec, ep.published_at, ep.image_url
      )
      new_count += 1 if result
    rescue ex
      Log.warn { "FeedRefresher: episode upsert error (feed #{feed.id}): #{ex.message}" }
    end

    label = feed.title || feed.url
    Log.info { "FeedRefresher: feed #{feed.id} \"#{label}\" — #{new_count} new/updated episodes" }
  rescue ex
    Log.error { "FeedRefresher: error refreshing feed #{feed.id}: #{ex.message}" }
  end
end
