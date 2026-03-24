require "http/client"

module DubJob
  def self.process(dub_id : Int64, episode : Episode, telegram_id : Int64, language : String)
    DubbedEpisode.set_processing(dub_id)
    Log.info { "DubJob[#{dub_id}]: starting pipeline for episode #{episode.id} → #{language}" }

    Log.info { "DubJob[#{dub_id}]: transcribing with Whisper" }
    transcript = ReplicateClient.transcribe(episode.audio_url)
    Log.info { "DubJob[#{dub_id}]: transcript #{transcript.size} chars" }

    Log.info { "DubJob[#{dub_id}]: translating with DeepL → #{language}" }
    translated = DeepLClient.translate(transcript, language)
    Log.info { "DubJob[#{dub_id}]: translation #{translated.size} chars" }

    Log.info { "DubJob[#{dub_id}]: extracting voice clip" }
    speaker_wav = get_voice_clip_url(episode.audio_url)
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

    DubbedEpisode.set_done(dub_id, r2_url)

    BotClient.client.send_message(
      telegram_id,
      "🎙 Your dubbed episode is ready — open the player to listen in #{language.upcase}."
    )

    Log.info { "DubJob[#{dub_id}]: complete" }
  rescue ex
    Log.error { "DubJob[#{dub_id}]: failed — #{ex.message}" }
    DubbedEpisode.set_failed(dub_id, ex.message || "Unknown error")
  end

  private def self.get_voice_clip_url(audio_url : String) : String
    # Download first 3 MB (≈ 30s at 128 kbps)
    clip = IO::Memory.new
    HTTP::Client.get(audio_url, headers: HTTP::Headers{"Range" => "bytes=0-3145727"}) do |resp|
      IO.copy(resp.body_io, clip, 3_145_728)
    end
    clip.rewind

    # Upload to Replicate Files API to get a hosted URL
    boundary = "BuzzVoice#{Random::Secure.hex(8)}"
    form_body = IO::Memory.new
    builder = HTTP::FormData::Builder.new(form_body, boundary)
    builder.file(
      "content", clip,
      HTTP::FormData::FileMetadata.new(filename: "voice_ref.mp3"),
      HTTP::Headers{"Content-Type" => "audio/mpeg"}
    )
    builder.finish

    resp = HTTP::Client.post(
      "https://api.replicate.com/v1/files",
      headers: HTTP::Headers{
        "Authorization" => "Token #{Config.replicate_api_token}",
        "Content-Type"  => "multipart/form-data; boundary=#{boundary}",
      },
      body: form_body.to_s
    )
    raise "Replicate Files upload failed (#{resp.status_code}): #{resp.body[0, 200]}" unless resp.success?

    JSON.parse(resp.body)["urls"]["get"].as_s
  end
end
