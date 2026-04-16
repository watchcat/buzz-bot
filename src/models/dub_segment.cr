require "json"

record DubSegmentCue,
  idx             : Int32,
  start_sec       : Float64,
  end_sec         : Float64,
  text            : String,
  translated_text : String?

module DubSegment
  # Persist transcript segments and (optionally) translations for one dub job.
  # Safe to call multiple times — uses ON CONFLICT DO NOTHING everywhere.
  def self.bulk_upsert(episode_id : Int64, language : String, segments : Array(JSON::Any))
    # ── Step 1: Insert segment rows ────────────────────────────────────────
    segments.each do |seg|
      idx    = seg["idx"]?.try(&.as_i?) || next
      text   = seg["text"]?.try(&.as_s?) || ""
      next if text.empty?

      start_sec  = seg["start_sec"]?.try(&.as_f?) || next
      end_sec    = seg["end_sec"]?.try(&.as_f?) || next
      speaker_id = seg["speaker_id"]?.try(&.as_s?)
      words_json = seg["words"]?.try(&.to_json)

      AppDB.pool.exec(
        "INSERT INTO dub_segments (episode_id, idx, speaker_id, start_sec, end_sec, text, words)
         VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)
         ON CONFLICT (episode_id, idx) DO NOTHING",
        episode_id, idx, speaker_id, start_sec, end_sec, text, words_json
      )
    end

    # ── Step 2: Fetch id map (idx → id) ────────────────────────────────────
    id_map = {} of Int32 => Int64
    AppDB.pool.query_all(
      "SELECT id, idx FROM dub_segments WHERE episode_id = $1",
      episode_id, as: {Int64, Int32}
    ).each { |row| id_map[row[1]] = row[0] }

    # ── Step 3: Insert translations ────────────────────────────────────────
    segments.each do |seg|
      translated = seg["translated_text"]?.try(&.as_s?) || ""
      next if translated.empty?
      idx    = seg["idx"]?.try(&.as_i?) || next
      seg_id = id_map[idx]? || next
      synth_duration  = seg["synth_duration"]?.try(&.as_f?)
      synth_r2_key    = seg["synth_r2_key"]?.try(&.as_s?)
      synth_start_sec = seg["synth_start_sec"]?.try(&.as_f?)

      AppDB.pool.exec(
        "INSERT INTO dub_segment_translations (segment_id, language, translated_text, synth_r2_key, synth_duration, synth_start_sec)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (segment_id, language) DO NOTHING",
        seg_id, language, translated, synth_r2_key, synth_duration, synth_start_sec
      )
    end
  end

  # Fetch cues for an episode.
  #
  # text_lang  — which language's translation to include in each cue
  #              (nil/empty = include no translation, show original text only)
  # audio_lang — which language's synth timestamps to use for timing
  #              (nil/empty = use original timestamps, for original audio playback)
  #
  # Separating these allows e.g. playing original audio while showing a
  # translation, or playing Russian dubbed audio while showing English subs.
  def self.for_episode(episode_id : Int64, text_lang : String?, audio_lang : String?) : Array(DubSegmentCue)
    tl = text_lang.presence || ""
    al = audio_lang.presence || ""
    rows = AppDB.pool.query_all(
      "SELECT ds.idx, ds.start_sec, ds.end_sec, ds.text,
              text_t.translated_text,
              time_t.synth_start_sec, time_t.synth_duration
       FROM dub_segments ds
       LEFT JOIN dub_segment_translations text_t
         ON text_t.segment_id = ds.id AND text_t.language = $2
       LEFT JOIN dub_segment_translations time_t
         ON time_t.segment_id = ds.id AND time_t.language = $3
       WHERE ds.episode_id = $1
       ORDER BY ds.idx",
      episode_id, tl, al,
      as: {Int32, Float64, Float64, String, String?, Float64?, Float64?}
    )
    rows.compact_map do |row|
      idx, orig_start, orig_end, text, translation, synth_start, synth_dur = row
      start_sec, end_sec =
        if synth_start && synth_dur
          # Dubbed audio requested and synth timing available — use it.
          {synth_start, synth_start + synth_dur}
        elsif al.empty?
          # Original audio — original timestamps are always correct.
          {orig_start, orig_end}
        else
          # Dubbed audio requested but this segment has no synth timing
          # (synthesis failed) — omit to prevent timestamp drift.
          next
        end
      DubSegmentCue.new(idx: idx, start_sec: start_sec, end_sec: end_sec,
                        text: text, translated_text: translation)
    end
  end
end
