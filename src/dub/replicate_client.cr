require "http/client"
require "json"

module ReplicateClient
  BASE_URL      = "https://api.replicate.com/v1"
  POLL_INTERVAL = 5.seconds
  MAX_POLLS     = 240  # 20 minutes

  def self.transcribe(audio_url : String) : String
    output = run_model("openai", "whisper", {
      "audio" => audio_url,
      "model" => "large-v3",
      "task"  => "transcribe",
    })
    output["text"]?.try(&.as_s?) || raise "Whisper returned no text in output"
  end

  def self.synthesize(text : String, speaker_wav : String, language : String) : String
    output = run_model("lucataco", "xtts-v2", {
      "text"        => text,
      "speaker_wav" => speaker_wav,
      "language"    => language,
    })
    output.as_s? || raise "XTTS-v2 returned unexpected output format: #{output}"
  end

  private def self.run_model(owner : String, name : String, input : Hash(String, String)) : JSON::Any
    body = {"input" => input}.to_json
    resp = HTTP::Client.post(
      "#{BASE_URL}/models/#{owner}/#{name}/predictions",
      headers: auth_headers,
      body: body
    )
    raise "Replicate submit failed (#{resp.status_code}): #{resp.body}" unless resp.success?

    pred = JSON.parse(resp.body)
    id   = pred["id"].as_s

    MAX_POLLS.times do
      sleep POLL_INTERVAL
      poll_resp = HTTP::Client.get("#{BASE_URL}/predictions/#{id}", headers: auth_headers)
      unless poll_resp.success?
        raise "Replicate poll failed (#{poll_resp.status_code}): #{poll_resp.body}" if poll_resp.status_code < 500
        Log.warn { "Replicate poll returned #{poll_resp.status_code}, retrying..." }
        next
      end
      pred   = JSON.parse(poll_resp.body)
      status = pred["status"].as_s
      case status
      when "succeeded"
        return pred["output"]
      when "failed", "canceled"
        err = pred["error"]?.try(&.as_s?) || "unknown"
        raise "Replicate prediction #{id} #{status}: #{err}"
      end
    end
    raise "Replicate prediction #{id} timed out after 20 minutes"
  end

  private def self.auth_headers : HTTP::Headers
    HTTP::Headers{
      "Authorization" => "Token #{Config.replicate_api_token}",
      "Content-Type"  => "application/json",
    }
  end
end
