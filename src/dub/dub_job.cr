require "http/client"

module DubJob
  def self.process(dub_id : Int64, episode : Episode, telegram_id : Int64, language : String)
    DubbedEpisode.set_processing(dub_id)
    Log.info { "DubJob[#{dub_id}]: starting pipeline for episode #{episode.id} → #{language}" }

    transcript = Episode.transcript(episode.id)
    if transcript
      Log.info { "DubJob[#{dub_id}]: reusing cached transcript (#{transcript.size} chars)" }
    else
      Log.info { "DubJob[#{dub_id}]: transcribing with Whisper" }
      transcript = ReplicateClient.transcribe(episode.audio_url)
      Episode.save_transcript(episode.id, transcript)
      Log.info { "DubJob[#{dub_id}]: transcript #{transcript.size} chars, saved to episode" }
    end

    Log.info { "DubJob[#{dub_id}]: translating with DeepL → #{language}" }
    translated = DeepLClient.translate(transcript, language)
    Log.info { "DubJob[#{dub_id}]: translation #{translated.size} chars" }

    Log.info { "DubJob[#{dub_id}]: extracting voice clip" }
    speaker_wav = get_voice_clip_url(dub_id, episode.audio_url)
    Log.info { "DubJob[#{dub_id}]: synthesizing with XTTS-v2" }
    mp3_url = ReplicateClient.synthesize(translated, speaker_wav, language)
    Log.info { "DubJob[#{dub_id}]: synthesis done, downloading MP3" }

    mp3_data = IO::Memory.new
    HTTP::Client.get(mp3_url) do |resp|
      raise "MP3 download failed: HTTP #{resp.status_code}" unless resp.success?
      IO.copy(resp.body_io, mp3_data)
    end
    Log.info { "DubJob[#{dub_id}]: downloaded #{mp3_data.size} bytes" }

    r2_key = "dubbed/#{episode.id}/#{language}.mp3"
    r2_url = R2Storage.put(r2_key, mp3_data.to_slice)
    Log.info { "DubJob[#{dub_id}]: uploaded to R2: #{r2_url}" }

    DubbedEpisode.set_done(dub_id, r2_url, translated)

    BotClient.client.send_message(
      telegram_id,
      "🎙 Your dubbed episode is ready — open the player to listen in #{language.upcase}."
    )

    Log.info { "DubJob[#{dub_id}]: complete" }
  rescue ex
    Log.error { "DubJob[#{dub_id}]: failed — #{ex.message}" }
    DubbedEpisode.set_failed(dub_id, ex.message || "Unknown error")
  end

  private def self.get_voice_clip_url(dub_id : Int64, audio_url : String) : String
    # Download first 3 MB (≈ 30s at 128 kbps), following redirects
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

    r2_key = "tmp/voice/#{dub_id}.mp3"
    R2Storage.put(r2_key, clip.to_slice)
  end
end
