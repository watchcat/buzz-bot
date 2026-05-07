# src/web/routes/embeddings.cr
require "json"
require "http/client"
require "../../models/episode_embedding"
require "../../config"

module Web::Routes::Embeddings
  Log = ::Log.for("embeddings")

  private struct EmbeddingResult
    include JSON::Serializable
    getter id : Int64
    getter vector : Array(Float64)
    getter topics : Array(String) = [] of String
  end

  private struct CallbackPayload
    include JSON::Serializable
    getter embeddings : Array(EmbeddingResult)
    getter source : String
  end

  def self.register
    # Triggered by k8s CronJob. Finds un-embedded episodes, dispatches to RunPod.
    post "/internal/embed" do |env|
      endpoint_id = Config.embed_endpoint_id
      unless endpoint_id
        Log.warn { "EMBED_ENDPOINT_ID not configured, skipping" }
        env.response.status_code = 503
        next({error: "Embedding service not configured"}.to_json)
      end

      episodes = EpisodeEmbedding.unembedded_episode_ids(500)

      # If no new episodes to embed, backfill topics for existing embeddings
      if episodes.empty?
        episodes = EpisodeEmbedding.untopicked_episode_ids(500)
        if episodes.empty?
          env.response.content_type = "application/json"
          next({ok: true, dispatched: 0}.to_json)
        end
      end

      payload = episodes.map do |ep|
        text = String.build do |s|
          s << ep[:title]
          if desc = ep[:description]
            # Strip HTML tags
            stripped = desc.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip
            s << "\n\n" << stripped unless stripped.empty?
          end
        end
        {id: ep[:id], text: text}
      end

      callback_url = "#{Config.dub_callback_base}/internal/embeddings_result"
      secret = Config.internal_webhook_secret

      runpod_input = {
        episodes:     payload,
        callback_url: callback_url,
        secret:       secret,
        source:       "description",
      }.to_json
      runpod_payload = {input: JSON.parse(runpod_input)}.to_json

      runpod_client = HTTP::Client.new(URI.parse("https://api.runpod.ai"))
      runpod_client.connect_timeout = 5.seconds
      runpod_client.read_timeout = 10.seconds
      response = runpod_client.post(
        "/v2/#{endpoint_id}/run",
        headers: HTTP::Headers{
          "Authorization" => "Bearer #{Config.runpod_api_key}",
          "Content-Type"  => "application/json",
        },
        body: runpod_payload
      )

      unless response.success?
        Log.error { "RunPod embed dispatch failed: #{response.status_code} #{response.body}" }
        env.response.status_code = 502
        next({error: "RunPod dispatch failed"}.to_json)
      end

      Log.info { "Dispatched #{episodes.size} episodes for embedding" }
      env.response.content_type = "application/json"
      {ok: true, dispatched: episodes.size}.to_json
    end

    # Callback from RunPod embedding worker.
    post "/internal/embeddings_result" do |env|
      # Validate shared secret
      if (expected = Config.internal_webhook_secret)
        auth = env.request.headers["Authorization"]?
        unless auth == "Bearer #{expected}"
          env.response.status_code = 401
          next({error: "Unauthorized"}.to_json)
        end
      end

      body = env.request.body.try(&.gets_to_end) || ""
      payload = CallbackPayload.from_json(body)

      count = 0
      payload.embeddings.each do |item|
        next if item.vector.size != 384
        EpisodeEmbedding.upsert(item.id, item.vector, payload.source, item.topics)
        count += 1
      end

      Log.info { "Stored #{count} embeddings (source=#{payload.source})" }
      env.response.content_type = "application/json"
      {ok: true, stored: count}.to_json
    rescue ex : JSON::ParseException
      Log.error { "EmbeddingsResult: malformed payload — #{ex.message}" }
      env.response.status_code = 400
      {error: "Invalid JSON"}.to_json
    rescue ex
      Log.error { "EmbeddingsResult: #{ex.message}" }
      env.response.status_code = 500
      {error: "Internal error"}.to_json
    end
  end
end
