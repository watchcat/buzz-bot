require "http/client"
require "json"
require "uri"

# AudioSender handles sending podcast episodes to a user's Telegram chat.
#
# Strategy:
#   1. Fast path — pass the episode URL directly to Telegram's sendAudio.
#      Telegram fetches the file on its side. Works for publicly accessible
#      URLs up to ~20 MB.
#   2. Slow path — stream-download the file to a tempfile, then upload it
#      as multipart/form-data. Handles up to 50 MB (Telegram Bot API limit).
#   3. If the file exceeds 50 MB, notify the user via the bot.
#
# Both paths run inside a spawned fiber so the HTTP handler returns
# immediately with a "Sending…" response.

module AudioSender
  TELEGRAM_API    = "#{Config.telegram_api_server || "https://api.telegram.org"}/bot#{Config.bot_token}"
  MAX_UPLOAD_SIZE = Config.telegram_api_server ? 2000 * 1024 * 1024 : 50 * 1024 * 1024
  URL_SEND_TIMEOUT = 60.seconds

  def self.send_to_user(telegram_id : Int64, episode : Episode, feed : Feed?, override_url : String? = nil)
    audio_url = override_url || episode.audio_url
    if try_url_send(telegram_id, episode, feed, audio_url)
      Log.info { "AudioSender: sent episode #{episode.id} by URL to #{telegram_id}" }
      return
    end

    # URL path failed — check size before attempting download+upload
    size = probe_content_length(audio_url)
    if size && size > MAX_UPLOAD_SIZE
      limit_mb = mb(MAX_UPLOAD_SIZE)
      BotClient.client.send_message(
        telegram_id,
        "⚠️ \"#{episode.title}\" is too large to send (#{mb(size)} MB). " \
        "Maximum supported file size is #{limit_mb} MB."
      )
      return
    end

    download_and_upload(telegram_id, episode, feed, audio_url)
  rescue ex
    Log.error { "AudioSender unhandled error for episode #{episode.id}: #{ex.message}" }
    notify_failure(telegram_id, episode.title, ex.message)
  end

  # --------------------------------------------------------------------------
  # Fast path: send by URL
  # --------------------------------------------------------------------------
  private def self.try_url_send(telegram_id : Int64, episode : Episode, feed : Feed?, audio_url : String) : Bool
    body = JSON.build do |j|
      j.object do
        j.field "chat_id", telegram_id
        j.field "audio",   audio_url
        j.field "title",   episode.title
        j.field "performer", feed.try(&.title) || ""
        episode.duration_sec.try { |d| j.field "duration", d }
      end
    end

    uri    = URI.parse("#{TELEGRAM_API}/sendAudio")
    client = HTTP::Client.new(uri)
    client.read_timeout = URL_SEND_TIMEOUT
    resp = client.post(uri.path, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body)
    JSON.parse(resp.body)["ok"]?.try(&.as_bool?) || false
  rescue ex
    Log.warn { "AudioSender URL send failed: #{ex.message}" }
    false
  end

  # --------------------------------------------------------------------------
  # Slow path: stream-download then multipart-upload
  # --------------------------------------------------------------------------
  private def self.download_and_upload(telegram_id : Int64, episode : Episode, feed : Feed?, audio_url : String)
    tempfile = File.tempfile("buzz-episode", ".mp3")
    downloaded = 0_i64

    begin
      url = audio_url
      redirects = 0
      done = false
      until done
        HTTP::Client.get(url) do |resp|
          if resp.status.redirection?
            redirects += 1
            raise "Too many redirects" if redirects > 5
            location = resp.headers["Location"]? || raise "Redirect without Location header"
            url = absolute_url(url, location)
          else
            raise "Remote returned HTTP #{resp.status_code}" unless resp.success?
            buf = Bytes.new(65_536)
            while (n = resp.body_io.read(buf)) > 0
              tempfile.write(buf[0, n])
              downloaded += n
              if downloaded > MAX_UPLOAD_SIZE
                raise "File exceeds #{mb(MAX_UPLOAD_SIZE)} MB Telegram limit " \
                      "(stopped at #{mb(downloaded)} MB)"
              end
            end
            done = true
          end
        end
      end

      tempfile.rewind
      upload_multipart(telegram_id, episode, feed, tempfile)
      Log.info { "AudioSender: uploaded episode #{episode.id} (#{mb(downloaded)} MB) to #{telegram_id}" }
    rescue ex
      Log.error { "AudioSender download/upload failed for episode #{episode.id}: #{ex.message}" }
      notify_failure(telegram_id, episode.title, ex.message)
    ensure
      tempfile.delete
    end
  end

  private def self.upload_multipart(telegram_id : Int64, episode : Episode, feed : Feed?, file : File)
    boundary = "BuzzBot#{Random::Secure.hex(10)}"
    # Write multipart to a temp file so we can stream it to Telegram
    # without holding the entire audio in memory.
    tmp = File.tempfile("buzz-multipart", ".bin")
    begin
      builder = HTTP::FormData::Builder.new(tmp, boundary)
      builder.field("chat_id",   telegram_id.to_s)
      builder.field("title",     episode.title)
      builder.field("performer", feed.try(&.title) || "")
      episode.duration_sec.try { |d| builder.field("duration", d.to_s) }
      builder.file(
        "audio", file,
        HTTP::FormData::FileMetadata.new(filename: "episode.mp3"),
        HTTP::Headers{"Content-Type" => "audio/mpeg"}
      )
      builder.finish

      content_length = tmp.pos
      tmp.rewind

      resp = HTTP::Client.post(
        "#{TELEGRAM_API}/sendAudio",
        headers: HTTP::Headers{
          "Content-Type"   => "multipart/form-data; boundary=#{boundary}",
          "Content-Length" => content_length.to_s,
        },
        body: tmp
      )
      result = JSON.parse(resp.body)
      unless result["ok"]?.try(&.as_bool?)
        raise result["description"]?.try(&.as_s?) || "Telegram returned ok=false"
      end
    ensure
      tmp.delete
    end
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------
  private def self.probe_content_length(url : String) : Int64?
    5.times do
      resp = HTTP::Client.head(url)
      if resp.status.redirection?
        url = absolute_url(url, resp.headers["Location"]? || return nil)
        next
      end
      return resp.headers["Content-Length"]?.try(&.to_i64?)
    end
    nil
  rescue
    nil
  end

  private def self.absolute_url(base : String, location : String) : String
    loc_uri = URI.parse(location)
    return location if loc_uri.scheme
    base_uri = URI.parse(base)
    URI.new(base_uri.scheme, base_uri.host, base_uri.port, location).to_s
  end

  private def self.notify_failure(telegram_id : Int64, title : String, reason : String?)
    BotClient.client.send_message(
      telegram_id,
      "❌ Failed to send \"#{title}\": #{reason || "unknown error"}"
    )
  rescue
  end

  private def self.mb(bytes) : String
    "%.1f" % (bytes / 1_048_576.0)
  end
end
