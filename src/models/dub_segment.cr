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

  # Fetch cues for an episode, optionally with translations for a language.
  # When a language is requested, uses synth_start_sec/synth_duration for timing
  # (the dubbed audio has shifted timestamps due to TTS length differences).
  # Falls back to original start_sec/end_sec when synth timing is unavailable.
  def self.for_episode(episode_id : Int64, language : String?) : Array(DubSegmentCue)
    lang = language.presence || ""
    rows = AppDB.pool.query_all(
      "SELECT ds.idx, ds.start_sec, ds.end_sec, ds.text, dst.translated_text,
              dst.synth_start_sec, dst.synth_duration
       FROM dub_segments ds
       LEFT JOIN dub_segment_translations dst
         ON dst.segment_id = ds.id AND dst.language = $2
       WHERE ds.episode_id = $1
       ORDER BY ds.idx",
      episode_id, lang, as: {Int32, Float64, Float64, String, String?, Float64?, Float64?}
    )
    rows.compact_map do |row|
      idx, orig_start, orig_end, text, translation, synth_start, synth_dur = row
      # Use actual dubbed-audio timestamps when available.
      # For a dubbed language: skip segments without synth timing — they were
      # not included in the dubbed audio (synthesis failed) so their original
      # timestamps would cause drift if left in the cue list.
      start_sec, end_sec =
        if synth_start && synth_dur
          {synth_start, synth_start + synth_dur}
        elsif lang.empty?
          {orig_start, orig_end}
        else
          next  # dubbed language, no synth timing → omit from cue list
        end
      DubSegmentCue.new(idx: idx, start_sec: start_sec, end_sec: end_sec,
                        text: text, translated_text: translation)
    end
  end
end
