require "json"
require "../../models/dubbed_episode"

module Web::Routes::DubProgress
  private struct Payload
    include JSON::Serializable
    getter dub_id : Int64
    getter step   : String
    getter pct    : Float64?
  end

  def self.register
    # Internal endpoint — called by dub-pipeline to report intermediate step changes.
    # The dub_update_notify PG trigger fires on every UPDATE to dubbed_episodes,
    # fanning out a 'dub_status' NOTIFY to DubHub → SSE clients automatically.
    post "/internal/dub_progress" do |env|
      body    = env.request.body.try(&.gets_to_end) || ""
      payload = Payload.from_json(body)

      DubbedEpisode.set_step(payload.dub_id, payload.step)
      Log.info { "DubProgress[#{payload.dub_id}]: step=#{payload.step}#{payload.pct ? " (#{payload.pct}%)" : ""}" }

      # Fan out to any open SSE connections directly — don't rely on PG NOTIFY
      # which is unreliable on Neon serverless across connections.
      # Skip if the row is already terminal: a late progress event
      # (out-of-order / post-result) would otherwise emit a "processing"
      # SSE payload to a client that had already advanced to done/failed.
      if (dub = DubbedEpisode.find_by_id(payload.dub_id)) &&
         (dub.status == "pending" || dub.status == "processing")
        key      = "#{dub.episode_id}:#{dub.language}"
        pct_part = payload.pct.try { |p| ":#{p.to_i}" } || ""
        DubHub.instance.publish(key, "#{dub.episode_id}:#{dub.language}:#{payload.step}:processing#{pct_part}")
      end

      env.response.content_type = "application/json"
      {ok: true}.to_json
    rescue ex : JSON::ParseException
      Log.error { "DubProgress: malformed payload — #{ex.message}" }
      env.response.status_code = 400
      {error: "Invalid JSON"}.to_json
    rescue ex
      Log.error { "DubProgress: #{ex.message}" }
      env.response.status_code = 500
      {error: "Internal error"}.to_json
    end
  end
end
