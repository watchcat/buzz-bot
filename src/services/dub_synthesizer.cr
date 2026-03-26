require "http/client"
require "../config"
require "../db"
require "../models/episode"
require "../models/dubbed_episode"
require "../dub/replicate_client"
require "../dub/r2_storage"
require "../bot/client"

Log.setup_from_env

Log.info { "DubSynthesizer: starting" }
DubbedEpisode.reset_in_flight("synthesizing", "synthesis")

loop do
  if (job = DubbedEpisode.claim_for_synthesis)
    dub_id, episode_id, language, translation, requester_tg_id = job
    process(dub_id, episode_id, language, translation, requester_tg_id)
    sleep 100.milliseconds
  else
    sleep 5.seconds
  end
end

def process(dub_id : Int64, episode_id : Int64, language : String,
            translation : String, requester_tg_id : Int64?)
  Log.info { "DubSynthesizer[#{dub_id}]: claimed (episode #{episode_id} → #{language})" }

  episode = Episode.find(episode_id)
  raise "Episode #{episode_id} not found" unless episode

  Log.info { "DubSynthesizer[#{dub_id}]: extracting voice clip" }
  speaker_wav = upload_voice_clip(dub_id, episode.audio_url)

  Log.info { "DubSynthesizer[#{dub_id}]: synthesizing with XTTS-v2" }
  mp3_url = ReplicateClient.synthesize(translation, speaker_wav, language)

  Log.info { "DubSynthesizer[#{dub_id}]: downloading MP3" }
  mp3_data = IO::Memory.new
  HTTP::Client.get(mp3_url) do |resp|
    raise "MP3 download failed: HTTP #{resp.status_code}" unless resp.success?
    IO.copy(resp.body_io, mp3_data)
  end
  Log.info { "DubSynthesizer[#{dub_id}]: downloaded #{mp3_data.size} bytes" }

  r2_key = "dubbed/#{episode_id}/#{language}.mp3"
  r2_url  = R2Storage.put(r2_key, mp3_data.to_slice)
  Log.info { "DubSynthesizer[#{dub_id}]: uploaded to R2: #{r2_url}" }

  DubbedEpisode.set_complete(dub_id, r2_url)
  Log.info { "DubSynthesizer[#{dub_id}]: complete" }

  if requester_tg_id
    begin
      BotClient.client.send_message(
        requester_tg_id,
        "🎙 Your dubbed episode is ready — open the player to listen in #{language.upcase}."
      )
    rescue ex
      Log.warn { "DubSynthesizer[#{dub_id}]: Telegram notification failed — #{ex.message}" }
    end
  end
rescue ex
  Log.error { "DubSynthesizer[#{dub_id}]: failed — #{ex.message}" }
  DubbedEpisode.set_failed(dub_id, ex.message || "Unknown error")
end

# Download first 3 MB of episode audio (voice sample for XTTS-v2), upload to R2.
private def upload_voice_clip(dub_id : Int64, audio_url : String) : String
  clip = IO::Memory.new
  url = audio_url
  redirects = 0
  done = false
  until done
    HTTP::Client.get(url, headers: HTTP::Headers{"Range" => "bytes=0-3145727"}) do |resp|
      if resp.status.redirection?
        redirects += 1
        raise "Too many redirects fetching voice clip" if redirects > 5
        url = resp.headers["Location"]? || raise "Voice clip redirect missing Location header"
      else
        raise "Voice clip download failed: HTTP #{resp.status_code}" unless resp.success? || resp.status_code == 206
        IO.copy(resp.body_io, clip, 3_145_728)
        done = true
      end
    end
  end
  R2Storage.put("tmp/voice/#{dub_id}.mp3", clip.to_slice)
end
