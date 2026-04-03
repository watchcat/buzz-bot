require "http/client"
require "json"

module ReplicateClient
  BASE_URL      = "https://api.replicate.com/v1"
  POLL_INTERVAL = 5.seconds
  MAX_POLLS     = 240  # 20 minutes

  WHISPER_LANG_CODES = {
    "afrikaans" => "af", "arabic" => "ar", "armenian" => "hy",
    "azerbaijani" => "az", "belarusian" => "be", "bosnian" => "bs",
    "bulgarian" => "bg", "catalan" => "ca", "chinese" => "zh",
    "croatian" => "hr", "czech" => "cs", "danish" => "da",
    "dutch" => "nl", "english" => "en", "estonian" => "et",
    "finnish" => "fi", "french" => "fr", "galician" => "gl",
    "german" => "de", "greek" => "el", "hebrew" => "he",
    "hindi" => "hi", "hungarian" => "hu", "icelandic" => "is",
    "indonesian" => "id", "italian" => "it", "japanese" => "ja",
    "kannada" => "kn", "kazakh" => "kk", "korean" => "ko",
    "latvian" => "lv", "lithuanian" => "lt", "macedonian" => "mk",
    "malay" => "ms", "marathi" => "mr", "maori" => "mi",
    "nepali" => "ne", "norwegian" => "no", "persian" => "fa",
    "polish" => "pl", "portuguese" => "pt", "romanian" => "ro",
    "russian" => "ru", "serbian" => "sr", "slovak" => "sk",
    "slovenian" => "sl", "spanish" => "es", "swahili" => "sw",
    "swedish" => "sv", "tagalog" => "tl", "tamil" => "ta",
    "thai" => "th", "turkish" => "tr", "ukrainian" => "uk",
    "urdu" => "ur", "vietnamese" => "vi", "welsh" => "cy",
  }

  # Returns {text, language_code?}
  def self.transcribe(audio_url : String) : {String, String?}
    output = run_model("openai", "whisper", {
      "audio" => audio_url,
      "model" => "large-v3",
      "task"  => "transcribe",
    })
    text = output["transcription"]?.try(&.as_s?) ||
           output["text"]?.try(&.as_s?) ||
           raise "Whisper returned no transcription in output: #{output}"
    lang_name = output["detected_language"]?.try(&.as_s?)
    lang_code = lang_name ? WHISPER_LANG_CODES[lang_name.downcase]? : nil
    {text, lang_code}
  end

  # XTTS-v2 hard-limits input to ~400 tokens (~280 words).
  # Split long translations into sentence-bounded chunks, synthesize each,
  # then concatenate the WAV files into a single audio stream.
  MAX_WORDS_PER_CHUNK = 280

  # Returns raw WAV bytes of the synthesized audio.
  def self.synthesize(text : String, speaker_wav : String, language : String) : Bytes
    chunks = split_into_chunks(text, MAX_WORDS_PER_CHUNK)
    Log.info { "XTTS: #{chunks.size} chunk(s), #{text.split.size} words total" }
    wav_slices = chunks.map { |chunk| download_bytes(synthesize_chunk(chunk, speaker_wav, language)) }
    concat_wavs(wav_slices)
  end

  private def self.synthesize_chunk(text : String, speaker_wav : String, language : String) : String
    output = run_model("lucataco", "xtts-v2", {
      "text"     => text,
      "speaker"  => speaker_wav,
      "language" => language,
    })
    output.as_s? || raise "XTTS-v2 returned unexpected output format: #{output}"
  end

  # Split text on sentence boundaries, accumulating up to max_words per chunk.
  private def self.split_into_chunks(text : String, max_words : Int32) : Array(String)
    sentences = text.split(/(?<=[.!?…])\s+/)
    chunks = [] of String
    current = [] of String
    current_words = 0
    sentences.each do |sentence|
      words = sentence.split(/\s+/).reject(&.empty?).size
      if current_words + words > max_words && !current.empty?
        chunks << current.join(" ")
        current = [sentence]
        current_words = words
      else
        current << sentence
        current_words += words
      end
    end
    chunks << current.join(" ") unless current.empty?
    chunks
  end

  private def self.download_bytes(url : String) : Bytes
    buf = IO::Memory.new
    HTTP::Client.get(url) do |resp|
      raise "WAV download failed: HTTP #{resp.status_code}" unless resp.success?
      IO.copy(resp.body_io, buf)
    end
    buf.to_slice
  end

  # Concatenate WAV files by extracting PCM data from each and rebuilding a
  # single RIFF/WAVE with the combined data chunk.
  private def self.concat_wavs(wavs : Array(Bytes)) : Bytes
    return wavs[0] if wavs.size == 1
    sample_rate, channels, bits = parse_wav_format(wavs[0])
    pcm_parts = wavs.map { |wav| extract_wav_pcm(wav) }
    total_pcm = pcm_parts.sum(&.size)

    out = IO::Memory.new
    out.write("RIFF".to_slice)
    out.write_bytes((36 + total_pcm).to_u32, IO::ByteFormat::LittleEndian)
    out.write("WAVE".to_slice)
    out.write("fmt ".to_slice)
    out.write_bytes(16_u32,  IO::ByteFormat::LittleEndian)
    out.write_bytes(1_u16,   IO::ByteFormat::LittleEndian)  # PCM
    out.write_bytes(channels.to_u16,    IO::ByteFormat::LittleEndian)
    out.write_bytes(sample_rate.to_u32, IO::ByteFormat::LittleEndian)
    out.write_bytes((sample_rate * channels * bits // 8).to_u32, IO::ByteFormat::LittleEndian)
    out.write_bytes((channels * bits // 8).to_u16, IO::ByteFormat::LittleEndian)
    out.write_bytes(bits.to_u16, IO::ByteFormat::LittleEndian)
    out.write("data".to_slice)
    out.write_bytes(total_pcm.to_u32, IO::ByteFormat::LittleEndian)
    pcm_parts.each { |pcm| out.write(pcm) }
    out.to_slice
  end

  # Scan RIFF chunks to find fmt and return {sample_rate, channels, bits}.
  # Falls back to XTTS-v2 defaults (24 kHz, mono, 16-bit) if parsing fails.
  private def self.parse_wav_format(wav : Bytes) : {Int32, Int32, Int32}
    i = 12
    while i + 8 <= wav.size
      chunk_id   = String.new(wav[i, 4])
      chunk_size = IO::ByteFormat::LittleEndian.decode(UInt32, wav[i + 4, 4]).to_i32
      if chunk_id == "fmt " && chunk_size >= 16
        channels    = IO::ByteFormat::LittleEndian.decode(UInt16, wav[i + 10, 2]).to_i32
        sample_rate = IO::ByteFormat::LittleEndian.decode(UInt32, wav[i + 12, 4]).to_i32
        bits        = IO::ByteFormat::LittleEndian.decode(UInt16, wav[i + 22, 2]).to_i32
        return {sample_rate, channels, bits}
      end
      i += 8 + chunk_size + (chunk_size & 1)  # WAV chunks are word-aligned
    end
    {24000, 1, 16}
  end

  # Scan RIFF chunks to find the "data" chunk and return its raw PCM bytes.
  private def self.extract_wav_pcm(wav : Bytes) : Bytes
    i = 12
    while i + 8 <= wav.size
      chunk_id   = String.new(wav[i, 4])
      chunk_size = IO::ByteFormat::LittleEndian.decode(UInt32, wav[i + 4, 4]).to_i32
      return wav[i + 8, chunk_size] if chunk_id == "data"
      i += 8 + chunk_size + (chunk_size & 1)
    end
    wav[44..]  # fallback: skip standard 44-byte header
  end

  private def self.latest_version(owner : String, name : String) : String
    resp = HTTP::Client.get("#{BASE_URL}/models/#{owner}/#{name}/versions", headers: auth_headers)
    raise "Failed to fetch versions for #{owner}/#{name} (#{resp.status_code}): #{resp.body}" unless resp.success?
    JSON.parse(resp.body)["results"][0]["id"].as_s
  end

  private def self.run_model(owner : String, name : String, input : Hash(String, String)) : JSON::Any
    version_id = latest_version(owner, name)
    body = {"version" => version_id, "input" => input}.to_json
    resp = HTTP::Client.post(
      "#{BASE_URL}/predictions",
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
