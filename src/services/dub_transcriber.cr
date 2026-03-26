require "http/client"
require "../config"
require "../db"
require "../models/episode"
require "../models/dubbed_episode"
require "../dub/replicate_client"
require "../dub/r2_storage"

Log.setup_from_env

Log.info { "DubTranscriber: starting" }
DubbedEpisode.reset_in_flight("transcribing", "transcription")

loop do
  if (job = DubbedEpisode.claim_for_transcription)
    dub_id, episode_id, _language = job
    process(dub_id, episode_id, _language)
    sleep 100.milliseconds
  else
    sleep 5.seconds
  end
end

def process(dub_id : Int64, episode_id : Int64, _language : String)
  Log.info { "DubTranscriber[#{dub_id}]: claimed (episode #{episode_id} → #{_language})" }

  transcript = Episode.transcript(episode_id)
  if transcript
    Log.info { "DubTranscriber[#{dub_id}]: transcript cached (#{transcript.size} chars), skipping Whisper" }
  else
    episode = Episode.find(episode_id)
    raise "Episode #{episode_id} not found" unless episode

    Log.info { "DubTranscriber[#{dub_id}]: downloading full audio for Whisper" }
    audio_r2_url = upload_full_audio(dub_id, episode.audio_url)

    Log.info { "DubTranscriber[#{dub_id}]: transcribing with Whisper" }
    transcript, detected_lang = ReplicateClient.transcribe(audio_r2_url)

    Episode.save_transcript(episode_id, transcript)
    if detected_lang
      Episode.save_original_language(episode_id, detected_lang)
      Log.info { "DubTranscriber[#{dub_id}]: detected language: #{detected_lang}" }
    end
    Log.info { "DubTranscriber[#{dub_id}]: transcript saved (#{transcript.size} chars)" }
  end

  DubbedEpisode.advance_to_translation(dub_id)
  Log.info { "DubTranscriber[#{dub_id}]: advanced to translation" }
rescue ex
  Log.error { "DubTranscriber[#{dub_id}]: failed — #{ex.message}" }
  DubbedEpisode.set_failed(dub_id, ex.message || "Unknown error")
end

# Download full episode audio (following redirects) and upload to R2 temp storage.
# Returns the public R2 URL for Whisper to fetch.
private def upload_full_audio(dub_id : Int64, audio_url : String) : String
  buf = IO::Memory.new
  url = audio_url
  redirects = 0
  done = false
  until done
    HTTP::Client.get(url) do |resp|
      if resp.status.redirection?
        redirects += 1
        raise "Too many redirects fetching full audio" if redirects > 5
        url = resp.headers["Location"]? || raise "Full audio redirect missing Location header"
      else
        raise "Full audio download failed: HTTP #{resp.status_code}" unless resp.success?
        IO.copy(resp.body_io, buf)
        done = true
      end
    end
  end
  R2Storage.put("tmp/audio/#{dub_id}.mp3", buf.to_slice)
end
