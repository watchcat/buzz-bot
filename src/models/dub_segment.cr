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
      synth_duration = seg["synth_duration"]?.try(&.as_f?)
      synth_r2_key   = seg["synth_r2_key"]?.try(&.as_s?)

      AppDB.pool.exec(
        "INSERT INTO dub_segment_translations (segment_id, language, translated_text, synth_r2_key, synth_duration)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (segment_id, language) DO NOTHING",
        seg_id, language, translated, synth_r2_key, synth_duration
      )
    end
  end

  # Fetch cues for an episode, optionally with translations for a language.
  # When language is nil or empty, translated_text will always be nil.
  def self.for_episode(episode_id : Int64, language : String?) : Array(DubSegmentCue)
    lang = language.presence || ""
    rows = AppDB.pool.query_all(
      "SELECT ds.idx, ds.start_sec, ds.end_sec, ds.text, dst.translated_text
       FROM dub_segments ds
       LEFT JOIN dub_segment_translations dst
         ON dst.segment_id = ds.id AND dst.language = $2
       WHERE ds.episode_id = $1
       ORDER BY ds.idx",
      episode_id, lang, as: {Int32, Float64, Float64, String, String?}
    )
    rows.map { |row| DubSegmentCue.new(idx: row[0], start_sec: row[1], end_sec: row[2], text: row[3], translated_text: row[4]) }
  end
end
