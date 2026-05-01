# Subtitles Feature — Design Spec

## Problem

The dub pipeline already produces per-segment transcript and translation data (with timestamps), but this data is held in memory and discarded after the job. Users have no way to view synchronized subtitles while listening.

## Goal

Store transcript and translation data per-segment in the DB, then display synchronized subtitles in the podcast player — in the original language and/or the dubbed language.

---

## Data Model

The DB tables already exist (migration 012). We just need to populate them:

### `dub_segments` (episode-level, language-independent)
```sql
id          BIGSERIAL PRIMARY KEY
episode_id  BIGINT REFERENCES episodes(id)
idx         INT                          -- 0-based segment order
speaker_id  TEXT                         -- e.g. "SPEAKER_00"
start_sec   FLOAT NOT NULL               -- cue-in time
end_sec     FLOAT NOT NULL               -- cue-out time
text        TEXT NOT NULL                -- original transcript text
words       JSONB                        -- [{word, start, end, score}] word-level timestamps
UNIQUE (episode_id, idx)
```

### `dub_segment_translations`
```sql
segment_id      BIGINT REFERENCES dub_segments(id) ON DELETE CASCADE
language        TEXT                     -- ISO 639-1 code, e.g. "es"
translated_text TEXT NOT NULL
synth_r2_key    TEXT                     -- R2 key for the synthesized audio segment
synth_duration  FLOAT                    -- duration of synthesized audio
PRIMARY KEY (segment_id, language)
```

---

## Data Flow

```
dub-pipeline worker
  → transcribe step  → segments with {idx, start_sec, end_sec, speaker, text, words}
  → translate step   → adds translated_text to each segment
  → synthesize step  → adds synth_wav, synth_duration to each segment
  → upload step      → adds synth_r2_key to each segment
  → success callback (POST /internal/dub_result) includes "segments" array
       → buzz-bot dub_result.cr persists to dub_segments + dub_segment_translations

User opens episode player
  → GET /episodes/:id/subtitles?language=es
  → Returns [{idx, start, end, text, translation?}]
  → Stored in CLJS app-db under [:subtitles ep-id]

During playback
  → audio-tick fires with currentTime
  → Derived subscription finds active cue (start <= t < end)
  → Player renders current cue text
  → CC button cycles: off → original → translated → off
```

---

## API

### `GET /episodes/:id/subtitles`

**Auth:** Required (`X-Init-Data` header)

**Query params:**
- `language` (optional) — ISO 639-1 code; if provided, includes `translation` field

**Response:**
```json
{
  "cues": [
    {
      "idx": 0,
      "start": 1.2,
      "end": 4.5,
      "text": "Hello world.",
      "translation": "Hola mundo."
    }
  ]
}
```

- `translation` only present when `?language=` is provided AND a translation exists for that segment
- Returns `{"cues": []}` when no segments exist for this episode (no dub completed yet)

---

## Pipeline Changes

The success callback payload gains a `segments` array. Local-only fields (`synth_wav`) are excluded:

```python
segment_data = [
    {
        "idx":             seg["idx"],
        "start_sec":       seg["start_sec"],
        "end_sec":         seg["end_sec"],
        "speaker_id":      seg.get("speaker"),
        "text":            seg.get("text", ""),
        "words":           seg.get("words"),          # may be None
        "translated_text": seg.get("translated_text"), # may be None
        "synth_duration":  seg.get("synth_duration"),  # may be None
    }
    for seg in segments
]
```

Also adds `speaker_samples` (currently missing from callback):
```python
"speaker_samples": json.dumps(speaker_samples_r2),
"segments":        segment_data,
```

---

## Crystal Backend Changes

### New: `src/models/dub_segment.cr`

```crystal
record Cue, idx : Int32, start_sec : Float64, end_sec : Float64,
            text : String, translated_text : String?

module DubSegment
  def self.bulk_upsert(episode_id : Int64, language : String, segments : Array(JSON::Any))
    # Step 1: INSERT INTO dub_segments ON CONFLICT (episode_id, idx) DO NOTHING
    # Step 2: SELECT id, idx FROM dub_segments WHERE episode_id = $1  → id_map
    # Step 3: INSERT INTO dub_segment_translations ON CONFLICT DO NOTHING

  def self.for_episode(episode_id : Int64, language : String?) : Array(Cue)
    # SELECT ds.idx, ds.start_sec, ds.end_sec, ds.text, dst.translated_text
    # FROM dub_segments ds
    # LEFT JOIN dub_segment_translations dst
    #   ON dst.segment_id = ds.id AND dst.language = $2
    # WHERE ds.episode_id = $1
    # ORDER BY ds.idx
    # (pass empty string for language when nil → no translations match)
end
```

### Modified: `src/web/routes/dub_result.cr`

In the success branch, after `DubbedEpisode.set_complete(...)`:
```crystal
if (segs = result.segments) && !segs.empty?
  DubSegment.bulk_upsert(result.dub_id_episode, result.language, segs)
end
```

The `Result` struct gains:
```crystal
getter segments       : Array(JSON::Any)?
getter speaker_samples : String?   # already exists but not sent by pipeline — now it is
```

Note: `episode_id` needs to be passed to `bulk_upsert`; use `result.episode_id || dub.episode_id`.

### New: `src/web/routes/subtitles.cr`

```crystal
module Web::Routes::Subtitles
  def self.register
    get "/episodes/:id/subtitles" do |env|
      user = Auth.current_user(env); halt 401 unless user
      episode_id = env.params.url["id"].to_i64
      language   = env.params.query["language"]?
      cues = DubSegment.for_episode(episode_id, language)
      env.response.content_type = "application/json"
      # JSON build: {cues: [{idx, start, end, text, translation?}]}
    end
  end
end
```

### Modified: `src/buzz_bot.cr`

Add requires for `dub_segment` model and `subtitles` route. Register `Web::Routes::Subtitles`.

---

## CLJS App State

### `db.cljs` default-db addition
```clojure
:subtitles {:ep-id nil
            :cues  []      ;; [{:idx :start :end :text :translation}]
            :lang  :off}   ;; :off | :original | :translated
```

### New subscriptions (`subs.cljs`)
```clojure
::subtitles            ;; whole :subtitles slice
::subtitle-cues        ;; :cues
::subtitle-lang        ;; :lang (:off/:original/:translated)
::subtitles-available? ;; (pos? (count cues))
::translation-available? ;; any cue has :translation
::current-subtitle-cue ;; derived: cue where start <= current-time < end
```

`::current-subtitle-cue` is derived from `::subtitle-cues`, `::subtitle-lang`, and `::audio-current-time`. Returns `nil` when `:lang` is `:off`.

### New events (`events.cljs` or `events/subtitles.cljs`)
```clojure
::fetch-subtitles  [ep-id language?]   ;; GET /episodes/:id/subtitles?language=
::subtitles-loaded [ep-id resp]        ;; store cues in [:subtitles]
::cycle-subtitle-lang []               ;; off → original → translated → off
::clear-subtitles  []                  ;; called on navigate away from player
```

### Trigger points
- **`events/dub.cljs` `::init-statuses`**: after storing statuses, dispatch `::fetch-subtitles` if any dub is `:done` (pass that language)
- **`events/dub.cljs` `::sse-event`**: when status becomes `:done`, dispatch `::fetch-subtitles` with that language
- **`events.cljs` `::navigate`**: when navigating away from `:player`, dispatch `::clear-subtitles`

---

## Player UI

### CC Button

Placed in `.player-speed-row` (between speed and bookmark buttons):

```clojure
[:button.btn-cc
  {:class    (when (not= lang :off) "btn-cc--active")
   :disabled (not subtitles-available?)
   :on-click #(rf/dispatch [::events/cycle-subtitle-lang])}
  "CC"]
```

Label shows current state:
- `:off` → `"CC"` (dim/inactive style)
- `:original` → `"CC"` with active style + small indicator
- `:translated` → `"CC"` with active style (different color or label)

### Subtitle Display

Between the dub section and the cover image:

```clojure
(when (and (not= lang :off) current-cue)
  [:div.subtitle-cue
   (if (= lang :original)
     (:text current-cue)
     (or (:translation current-cue) (:text current-cue)))])
```

Falls back to `:text` if translation missing for a cue (handles mixed coverage).

### CSS

```css
.subtitle-cue {
  margin: 10px 0 4px;
  padding: 6px 12px;
  background: color-mix(in srgb, var(--text-color) 8%, transparent);
  border-radius: 8px;
  font-size: 14px;
  line-height: 1.4;
  text-align: center;
  color: var(--text-color);
  min-height: 42px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.btn-cc {
  padding: 5px 10px;
  background: none;
  border: 1.5px solid rgba(128,128,128,0.35);
  border-radius: 20px;
  color: var(--hint-color);
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  letter-spacing: 0.05em;
  -webkit-tap-highlight-color: transparent;
}

.btn-cc--active {
  border-color: var(--button-color);
  color: var(--button-color);
}

.btn-cc:disabled {
  opacity: 0.3;
  cursor: default;
}
```

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| No dub completed yet | `GET /subtitles` → `{cues: []}` → CC button disabled |
| Source == target language (copy verbatim) | `translated_text` == `text`; `:translated` mode shows same text |
| Language not dubbed | `?language=` produces LEFT JOIN misses → `translation` absent → fall back to `:text` |
| Segment has no translation (synth skipped) | Translation absent in that cue → fall back to `:text` |
| User seeks past a cue | Sub recomputes immediately on next audio-tick |
| Between cues (gap) | `current-cue` is nil → no subtitle shown (blank, not hidden) |
| Navigating to new episode | `::clear-subtitles` resets `[:subtitles]` on navigate away from player |

---

## Files Summary

| File | Action |
|------|--------|
| `dub-pipeline/src/worker.py` | Add `segments` + `speaker_samples` to success callback |
| `src/models/dub_segment.cr` | New: `bulk_upsert`, `for_episode` → `Array(Cue)` |
| `src/web/routes/dub_result.cr` | Parse `segments` from callback → call `DubSegment.bulk_upsert` |
| `src/web/routes/subtitles.cr` | New: `GET /episodes/:id/subtitles` |
| `src/buzz_bot.cr` | Add requires + route registration |
| `src/cljs/buzz_bot/db.cljs` | Add `:subtitles` to default-db |
| `src/cljs/buzz_bot/subs.cljs` | Add subtitle subs including `::current-subtitle-cue` |
| `src/cljs/buzz_bot/events.cljs` | Add `::fetch-subtitles`, `::subtitles-loaded`, `::cycle-subtitle-lang`, `::clear-subtitles` |
| `src/cljs/buzz_bot/events/dub.cljs` | Dispatch `::fetch-subtitles` on `:done` status |
| `src/cljs/buzz_bot/views/player.cljs` | Add CC button + subtitle display |
| `public/css/app.css` | Add `.subtitle-cue`, `.btn-cc`, `.btn-cc--active`, `.btn-cc:disabled` |
