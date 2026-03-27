# DubHub — bridges PostgreSQL LISTEN/NOTIFY to in-process SSE subscribers.
#
# The main server process listens on the 'dub_status' PG channel (one shared
# connection, started at boot).  SSE route handlers subscribe/unsubscribe per
# request via a key of the form "episode_id:lang".  When a notification arrives
# the hub fans it out to every matching subscriber channel, waking the SSE fiber.

class DubHub
  @@instance : DubHub?

  def self.instance : DubHub
    @@instance ||= new
  end

  def initialize
    @subs = {} of String => Array(Channel(String))
    @mu   = Mutex.new
  end

  def subscribe(key : String) : Channel(String)
    ch = Channel(String).new(8)
    @mu.synchronize { (@subs[key] ||= [] of Channel(String)) << ch }
    ch
  end

  def unsubscribe(key : String, ch : Channel(String))
    @mu.synchronize { @subs[key]?.try(&.delete(ch)) }
  end

  def publish(key : String, payload : String)
    @mu.synchronize do
      @subs[key]?.try do |arr|
        arr.each { |ch| ch.send(payload) rescue nil }
      end
    end
  end

  # Start the PG LISTEN loop in a background fiber.
  # Must be called once at server boot.
  def start
    spawn do
      PG.connect_listen(Config.database_url_direct, "dub_status") do |notif|
        # payload: "episode_id:lang:step:status"
        parts = notif.payload.split(":", 4)
        next unless parts.size == 4
        key = "#{parts[0]}:#{parts[1]}"
        publish(key, notif.payload)
      end
    end
    Log.info { "DubHub: listening on dub_status" }
  end
end
