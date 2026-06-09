# src/web/routes/transcribe.cr
require "json"
require "http/client"
require "uri"
require "../../models/episode"
require "../../models/transcript_job"
require "../dub_dispatch"

module Web::Routes::Transcribe
  def self.register
    # Free for all users: generate the source-language transcript for an episode.
    post "/episodes/:id/transcribe" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64
      episode = Episode.find(episode_id)
      halt env, status_code: 404, response: %({"error":"not_found"}) unless episode

      if (existing = TranscriptJob.find(episode_id))
        status, _ = existing
        if status == "done"
          env.response.content_type = "application/json"
          next %({"status":"done"})
        elsif status == "pending"
          env.response.content_type = "application/json"
          next %({"status":"pending"})
        end
      end

      unless FeatureFlags.enabled?("dub_orchestrator")
        env.response.content_type = "application/json"
        env.response.status_code = 503
        next %({"error":"transcribe_unavailable"})
      end

      run_id = Random::Secure.hex(16)
      unless TranscriptJob.claim(episode_id, run_id)
        env.response.content_type = "application/json"
        next %({"status":"pending"})
      end

      begin
        body = Web::DubDispatch.transcribe_payload(
          run_id, episode_id, episode.audio_url,
          "#{Config.dub_callback_base}/internal/transcript_result")
        orch = HTTP::Client.new(URI.parse(Config.orch_base_url))
        orch.connect_timeout = 5.seconds
        orch.read_timeout = 10.seconds
        response = orch.post("/dispatch",
          headers: HTTP::Headers{
            "X-Dispatch-Token" => Config.orch_dispatch_secret,
            "Content-Type"     => "application/json"},
          body: body)
        raise "Orchestrator dispatch error: #{response.status_code} #{response.body}" unless response.success?
        Log.info { "Transcribe[ep=#{episode_id}]: dispatched run #{run_id}" }
      rescue ex
        Log.error { "Transcribe[ep=#{episode_id}]: enqueue failed — #{ex.message}" }
        TranscriptJob.set_failed(episode_id)
        env.response.content_type = "application/json"
        env.response.status_code = 500
        next %({"error":"enqueue_failed"})
      end

      env.response.content_type = "application/json"
      env.response.status_code = 202
      %({"status":"pending"})
    end
  end
end
