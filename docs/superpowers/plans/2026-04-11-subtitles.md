# Subtitles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store per-segment transcript + translation data from the dub pipeline in the DB, then display synchronized subtitles in the podcast player.

**Architecture:** The dub-pipeline sends segment data in its existing success callback; the buzz-bot server persists it; a new subtitles endpoint serves it; the CLJS player fetches it and renders the active cue in sync with `currentTime`.

**Tech Stack:** Crystal/Kemal backend, PostgreSQL (Neon), ClojureScript/re-frame/Reagent frontend, Python dub-pipeline worker.

**Spec:** `docs/superpowers/specs/2026-04-11-subtitles-design.md`

**Repos:**
- buzz-bot: `/Users/watchcat/work/crystal/buzz-bot`
- dub-pipeline: `/Users/watchcat/work/crystal/dub-pipeline`

---

## Task 1: Pipeline — send segments in success callback

**Files:**
- Modify: `dub-pipeline/src/worker.py` (lines ~174–184, the `_callback(...)` success call)

The pipeline currently discards all segment data after completing a job. This task adds segments to the callback and also fixes the missing `speaker_samples` field.

- [ ] **Step 1: Open `dub-pipeline/src/worker.py` and locate the success callback block**

  Look for this pattern around line 174:
  ```python
  _callback(callback_url, {
      "job_id":        job_id,
      ...
      "speaker_count": speaker_count,
  })
  ```

- [ ] **Step 2: Replace the success callback block**

  Replace the entire `_callback(callback_url, {...})` success call (lines ~174–184) with:

  ```python
  segment_data = [
      {
          "idx":             seg["idx"],
          "start_sec":       seg["start_sec"],
          "end_sec":         seg["end_sec"],
          "speaker_id":      seg.get("speaker"),
          "text":            seg.get("text", ""),
          "words":           seg.get("words"),
          "translated_text": seg.get("translated_text"),
          "synth_r2_key":    seg.get("synth_r2_key"),
          "synth_duration":  seg.get("synth_duration"),
      }
      for seg in segments
  ]

  _callback(callback_url, {
      "job_id":          job_id,
      "dub_id":          dub_id,
      "episode_id":      episode_id,
      "language":        language,
      "success":         True,
      "r2_url":          r2_url,
      "duration_sec":    round(duration_sec, 1),
      "segment_count":   segment_count,
      "speaker_count":   speaker_count,
      "speaker_samples": json.dumps(speaker_samples_r2),
      "segments":        segment_data,
  })
  ```

- [ ] **Step 3: Verify `json` is imported**

  Check the top of `worker.py`. The file already imports `json` (line 7). No change needed.

- [ ] **Step 4: Manual smoke test (no automated tests for pipeline)**

  Run the pipeline and confirm the callback payload in logs contains `segments` and `speaker_samples`. Or simply verify the JSON structure is valid:
  ```bash
  cd /Users/watchcat/work/crystal/dub-pipeline
  python3 -c "
  import json
  seg = {'idx':0,'start_sec':1.2,'end_sec':4.5,'speaker':'SPEAKER_00','text':'Hi','words':[],'translated_text':'Hola','synth_wav':None,'synth_duration':1.1,'synth_r2_key':'dub-stems/1/synth_es_0000.wav'}
  data = {'idx': seg['idx'], 'start_sec': seg['start_sec'], 'end_sec': seg['end_sec'], 'speaker_id': seg.get('speaker'), 'text': seg.get('text',''), 'words': seg.get('words'), 'translated_text': seg.get('translated_text'), 'synth_r2_key': seg.get('synth_r2_key'), 'synth_duration': seg.get('synth_duration')}
  print(json.dumps(data, indent=2))
  "
  ```
  Expected output: valid JSON with all 9 fields.

- [ ] **Step 5: Commit in dub-pipeline repo**

  ```bash
  cd /Users/watchcat/work/crystal/dub-pipeline
  git add src/worker.py
  git commit -m "feat: include segments and speaker_samples in dub_result callback"
  ```

---

## Task 2: Crystal model — `DubSegment`

**Files:**
- Create: `src/models/dub_segment.cr`

No new DB tables or migrations — `dub_segments` and `dub_segment_translations` already exist.

- [ ] **Step 1: Create `src/models/dub_segment.cr`**

  ```crystal
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
           ON CONFLICT DO NOTHING",
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
  ```

  Note: `String#presence` returns nil for empty strings — it's a Crystal stdlib method. If not available, use: `lang = (language.nil? || language.not_nil!.empty?) ? "" : language.not_nil!`

- [ ] **Step 2: Verify `String#presence` exists in Crystal**

  ```bash
  cd /Users/watchcat/work/crystal/buzz-bot
  crystal eval 'puts "hello".presence.inspect; puts "".presence.inspect'
  ```
  Expected: `"hello"` then `nil`. If this errors, use the inline nil-check version above.

- [ ] **Step 3: Add require to `src/buzz_bot.cr`**

  Open `src/buzz_bot.cr`. After the line `require "./models/dubbed_episode"` (line 13), add:
  ```crystal
  require "./models/dub_segment"
  ```

- [ ] **Step 4: Build to check Crystal compiles**

  ```bash
  cd /Users/watchcat/work/crystal/buzz-bot
  crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -30
  ```
  Expected: no output (or just warnings, no errors).

- [ ] **Step 5: Commit**

  ```bash
  git add src/models/dub_segment.cr src/buzz_bot.cr
  git commit -m "feat: add DubSegment model for transcript/translation storage"
  ```

---

## Task 3: Crystal backend — persist segments in `dub_result.cr`

**Files:**
- Modify: `src/web/routes/dub_result.cr`

The `Result` struct needs two new fields, and the success handler needs to call `DubSegment.bulk_upsert`.

- [ ] **Step 1: Read current `src/web/routes/dub_result.cr`**

  Note the `Result` struct (lines 7–21) and the success branch (lines 44–55).

- [ ] **Step 2: Add `segments` and fix `speaker_samples` fields in the `Result` struct**

  The current struct has `getter speaker_samples : String?` but it's never populated by the pipeline. Now it will be. Also add `segments`.

  In the `Result` struct, after `getter speaker_samples : String?` add:
  ```crystal
  getter segments : Array(JSON::Any)?
  ```

  The full updated struct (replace lines 7–21):
  ```crystal
  private struct Result
    include JSON::Serializable
    getter job_id          : String
    getter dub_id          : Int64
    getter episode_id      : Int64?
    getter language        : String?
    getter success         : Bool
    getter r2_url          : String?
    getter duration_sec    : Float64?
    getter segment_count   : Int32?
    getter speaker_count   : Int32?
    getter speaker_samples : String?
    getter step            : String?
    getter error           : String?
    getter segments        : Array(JSON::Any)?
  end
  ```

- [ ] **Step 3: Add `DubSegment.bulk_upsert` call in the success branch**

  In the success branch, after `DubbedEpisode.set_complete(result.dub_id, result.r2_url, result.speaker_samples)` (currently line 42), add:

  ```crystal
  if (segs = result.segments) && !segs.empty? &&
     (ep_id = result.episode_id) && (lang = result.language)
    begin
      DubSegment.bulk_upsert(ep_id, lang, segs)
      Log.info { "DubResult[#{result.dub_id}]: persisted #{segs.size} segments (lang=#{lang})" }
    rescue ex
      Log.warn { "DubResult[#{result.dub_id}]: segment persist failed — #{ex.message}" }
    end
  end
  ```

  This is best-effort (wrapped in rescue) so a segment DB failure doesn't break the dub completion flow.

- [ ] **Step 4: Build to check it compiles**

  ```bash
  cd /Users/watchcat/work/crystal/buzz-bot
  crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -30
  ```
  Expected: clean build.

- [ ] **Step 5: Commit**

  ```bash
  git add src/web/routes/dub_result.cr
  git commit -m "feat: persist dub segments to DB on successful dub_result callback"
  ```

---

## Task 4: Crystal backend — subtitles endpoint

**Files:**
- Create: `src/web/routes/subtitles.cr`
- Modify: `src/buzz_bot.cr`

- [ ] **Step 1: Create `src/web/routes/subtitles.cr`**

  ```crystal
  require "json"
  require "../../models/dub_segment"

  module Web::Routes::Subtitles
    def self.register
      get "/episodes/:id/subtitles" do |env|
        user = Auth.current_user(env)
        halt env, status_code: 401, response: "Unauthorized" unless user

        episode_id = env.params.url["id"].to_i64
        language   = env.params.query["language"]?

        cues = DubSegment.for_episode(episode_id, language)

        env.response.content_type = "application/json"
        JSON.build do |j|
          j.object do
            j.field "cues" do
              j.array do
                cues.each do |c|
                  j.object do
                    j.field "idx",   c.idx
                    j.field "start", c.start_sec
                    j.field "end",   c.end_sec
                    j.field "text",  c.text
                    j.field "translation", c.translated_text if c.translated_text
                  end
                end
              end
            end
          end
        end
      rescue ex
        Log.error { "Subtitles: #{ex.message}" }
        env.response.status_code = 500
        %({"error":"Internal error"})
      end
    end
  end
  ```

- [ ] **Step 2: Register route in `src/buzz_bot.cr`**

  After `require "./web/routes/dub"` (line 33), add:
  ```crystal
  require "./web/routes/subtitles"
  ```

  In `src/web/server.cr`, routes are registered by calling `register` on each route module. Find where `Web::Routes::Dub.register` is called (likely in `src/web/server.cr`) and add `Web::Routes::Subtitles.register` nearby.

  Actually, check how routes are registered — search for `\.register` in `src/web/server.cr`:
  ```bash
  grep -n "\.register" /Users/watchcat/work/crystal/buzz-bot/src/web/server.cr
  ```

  Add `Web::Routes::Subtitles.register` in the same place.

- [ ] **Step 3: Build**

  ```bash
  cd /Users/watchcat/work/crystal/buzz-bot
  crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -30
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add src/web/routes/subtitles.cr src/buzz_bot.cr src/web/server.cr
  git commit -m "feat: add GET /episodes/:id/subtitles endpoint"
  ```

---

## Task 5: CLJS — subtitle state, events, and subscriptions

**Files:**
- Modify: `src/cljs/buzz_bot/db.cljs`
- Modify: `src/cljs/buzz_bot/subs.cljs`
- Modify: `src/cljs/buzz_bot/events.cljs`
- Modify: `src/cljs/buzz_bot/events/dub.cljs`

- [ ] **Step 1: Add `:subtitles` to default-db in `src/cljs/buzz_bot/db.cljs`**

  After the `:dub` entry (currently the last line before `:offline`), add:
  ```clojure
  :subtitles {:ep-id nil
              :cues  []
              :lang  :off}
  ```

  The full default-db `:dub` + `:subtitles` section should read:
  ```clojure
  :dub {:statuses   {}
        :active-lang nil}
  :subtitles {:ep-id nil
              :cues  []
              :lang  :off}
  ```

- [ ] **Step 2: Add subtitle subscriptions to `src/cljs/buzz_bot/subs.cljs`**

  At the end of the file, add:
  ```clojure
  ;; Subtitles
  (rf/reg-sub ::subtitles          (fn [db _] (:subtitles db)))
  (rf/reg-sub ::subtitle-cues      :<- [::subtitles] (fn [s _] (:cues s)))
  (rf/reg-sub ::subtitle-lang      :<- [::subtitles] (fn [s _] (:lang s)))
  (rf/reg-sub ::subtitles-available?
    :<- [::subtitle-cues]
    (fn [cues _] (pos? (count cues))))
  (rf/reg-sub ::translation-available?
    :<- [::subtitle-cues]
    (fn [cues _] (boolean (some :translation cues))))
  (rf/reg-sub ::current-subtitle-cue
    :<- [::subtitle-cues]
    :<- [::subtitle-lang]
    :<- [::audio-current-time]
    (fn [[cues lang t] _]
      (when (and (not= lang :off) (pos? (count cues)))
        (some (fn [c]
                (when (and (<= (:start c) t) (< t (:end c)))
                  c))
              cues))))
  ```

- [ ] **Step 3: Add subtitle events to `src/cljs/buzz_bot/events.cljs`**

  Add a new section after the bookmarks section:

  ```clojure
  ;; ── Subtitles ─────────────────────────────────────────────────────────────

  (rf/reg-event-fx
   ::fetch-subtitles
   (fn [_ [_ ep-id language]]
     (let [url (if language
                 (str "/episodes/" ep-id "/subtitles?language=" language)
                 (str "/episodes/" ep-id "/subtitles"))]
       {::buzz-bot.fx/http-fetch {:method :get :url url
                                  :on-ok  [::subtitles-loaded ep-id]
                                  :on-err [::noop]}})))

  (rf/reg-event-db
   ::subtitles-loaded
   (fn [db [_ ep-id resp]]
     (let [cues (mapv (fn [c]
                        {:idx         (:idx c)
                         :start       (:start c)
                         :end         (:end c)
                         :text        (:text c)
                         :translation (:translation c)})
                      (:cues resp []))]
       (-> db
           (assoc-in [:subtitles :ep-id] ep-id)
           (assoc-in [:subtitles :cues]  cues)))))

  (rf/reg-event-db
   ::cycle-subtitle-lang
   (fn [db _]
     (let [lang              (get-in db [:subtitles :lang])
           has-translation?  (boolean (some :translation (get-in db [:subtitles :cues])))]
       (assoc-in db [:subtitles :lang]
                 (case lang
                   :off      :original
                   :original (if has-translation? :translated :off)
                   :translated :off
                   :off)))))

  (rf/reg-event-db
   ::clear-subtitles
   (fn [db _]
     (assoc db :subtitles {:ep-id nil :cues [] :lang :off})))
  ```

- [ ] **Step 4: Dispatch `::fetch-subtitles` from `::init-statuses` in `events/dub.cljs`**

  In `::init-statuses`, after building the `statuses` map and before the `cond->`, find the first `:done` language and dispatch subtitle fetch.

  Replace the current `::init-statuses` event:
  ```clojure
  (rf/reg-event-fx
   ::init-statuses
   (fn [{:keys [db]} [_ episode-id statuses-map]]
     (let [statuses (reduce-kv
                      (fn [m lang v]
                        (assoc m (name lang) {:status      (keyword (:status v))
                                              :step        (:step v)
                                              :r2-url      (:r2_url v)
                                              :translation (:translation v)}))
                      {}
                      statuses-map)
           in-flight (first (keep (fn [[lang {:keys [status]}]]
                                    (when (#{:pending :processing} status) lang))
                                  statuses))
           done-lang (first (keep (fn [[lang {:keys [status]}]]
                                    (when (= :done status) lang))
                                  statuses))]
       (cond-> {:db (assoc-in db [:dub :statuses] statuses)}
         in-flight
         (assoc ::fx/open-dub-sse {:episode-id episode-id :lang in-flight})
         done-lang
         (assoc :dispatch [::buzz-bot.events/fetch-subtitles episode-id done-lang])))))
  ```

- [ ] **Step 5: Dispatch `::fetch-subtitles` from `::sse-event` when dub completes**

  In `::sse-event`, in the `:done` branch, add a subtitle fetch dispatch.

  Replace `::sse-event`:
  ```clojure
  (rf/reg-event-fx
   ::sse-event
   (fn [{:keys [db]} [_ episode-id lang data]]
     (when (= (str episode-id) (str (get-in db [:player :data :episode :id])))
       (let [status (keyword (:status data))]
         (cond-> {:db (-> db
                          (assoc-in [:dub :statuses lang :status] status)
                          (assoc-in [:dub :statuses lang :step]   (:step data))
                          (cond-> (= status :done)
                            (-> (assoc-in [:dub :statuses lang :r2-url]      (:r2_url data))
                                (assoc-in [:dub :statuses lang :translation] (:translation data))))
                          (cond-> (= status :failed)
                            (assoc-in [:dub :statuses lang :error] (:error data))))}
           (= status :done)
           (assoc :dispatch [::buzz-bot.events/fetch-subtitles episode-id lang]))))))
  ```

- [ ] **Step 6: Add `::clear-subtitles` dispatch to `::navigate` in `events.cljs`**

  In the `::navigate` event, when navigating away from `:player`, dispatch `::clear-subtitles`.

  Find the line that builds the `fetch-event` based on `view`. After the existing `fetch-event` dispatch-n logic, add a clear-subtitles dispatch when leaving the player:

  In `::navigate`, in the `cond->` that builds the effects map, after any existing `fetch-event` dispatch, add:
  ```clojure
  (= cur-view :player)
  (update :dispatch-n (fnil conj []) [::clear-subtitles])
  ```

  The relevant section in navigate (around lines 49–57 of events.cljs):
  ```clojure
  (cond-> {:db (-> db
                   (assoc :view view)
                   ...)}
    fetch-event (assoc :dispatch-n (cond-> [fetch-event]
                                      (= view :player)
                                      (conj [::dub-events/reset])))
    (= cur-view :player)
    (update :dispatch-n (fnil conj []) [::clear-subtitles]))
  ```

- [ ] **Step 7: Build CLJS to verify compilation**

  ```bash
  cd /Users/watchcat/work/crystal/buzz-bot
  npx shadow-cljs compile app 2>&1 | tail -20
  ```
  Expected: `Build completed.` with no errors.

- [ ] **Step 8: Commit**

  ```bash
  git add src/cljs/buzz_bot/db.cljs src/cljs/buzz_bot/subs.cljs \
          src/cljs/buzz_bot/events.cljs src/cljs/buzz_bot/events/dub.cljs
  git commit -m "feat: add subtitle state, events, and subscriptions"
  ```

---

## Task 6: Player UI — CC button and subtitle display

**Files:**
- Modify: `src/cljs/buzz_bot/views/player.cljs`
- Modify: `public/css/app.css`

- [ ] **Step 1: Add subtitle subscriptions to the `view` function in `player.cljs`**

  In the inner `fn []` body of `view` (around lines 67–83), add these subscription bindings alongside the existing ones:

  ```clojure
  subtitle-lang  @(rf/subscribe [::subs/subtitle-lang])
  subtitle-avail? @(rf/subscribe [::subs/subtitles-available?])
  subtitle-cue   @(rf/subscribe [::subs/current-subtitle-cue])
  ```

- [ ] **Step 2: Add subtitle display div in `player.cljs`**

  The subtitle display goes in the `:player-card` div, **before** the `:player-controls` div. Find this section:

  ```clojure
  [:div.player-controls
   [:div.player-progress-row
  ```

  Insert before it:
  ```clojure
  ;; Subtitle cue display — shown when CC is active and a cue is in range
  (when (and (not= subtitle-lang :off) subtitle-cue)
    [:div.subtitle-cue
     (if (= subtitle-lang :original)
       (:text subtitle-cue)
       (or (:translation subtitle-cue) (:text subtitle-cue)))])
  ```

- [ ] **Step 3: Add CC button to the `player-speed-row` in `player.cljs`**

  Find the `:player-speed-row` div (currently contains speed button and bookmark button):
  ```clojure
  [:div.player-speed-row
   [:button#player-speed-btn.btn-speed ...]
   [:button.btn-bookmark ...]]
  ```

  Add the CC button between speed and bookmark:
  ```clojure
  [:div.player-speed-row
   [:button#player-speed-btn.btn-speed
    {:class    (when (not= rate 1) "btn-speed--active")
     :on-click #(rf/dispatch [::events/cycle-speed])}
    (if (= rate 1) "1×" (str rate "×"))]
   [:button.btn-cc
    {:class    (when (not= subtitle-lang :off) "btn-cc--active")
     :disabled (not subtitle-avail?)
     :title    (case subtitle-lang
                 :off        "Turn on subtitles"
                 :original   "Showing original text"
                 :translated "Showing translation")
     :on-click #(rf/dispatch [::events/cycle-subtitle-lang])}
    "CC"]
   [:button.btn-bookmark
    {:class    (when liked? "active")
     :title    (if liked? "Remove bookmark" "Bookmark")
     :on-click #(rf/dispatch [::events/toggle-bookmark (:id episode)])}
    [:svg {:viewBox "0 0 24 24" :xmlns "http://www.w3.org/2000/svg"}
     (if liked?
       [:path {:d "M17 3H7c-1.1 0-2 .9-2 2v16l7-3 7 3V5c0-1.1-.9-2-2-2z"}]
       [:path {:d "M17 3H7c-1.1 0-2 .9-2 2v16l7-3 7 3V5c0-1.1-.9-2-2-2zm0 15-5-2.18L7 18V5h10v13z"}])]]]
  ```

- [ ] **Step 4: Add CSS for subtitle display and CC button to `public/css/app.css`**

  Append at the end of the file:
  ```css
  /* ── Subtitles ──────────────────────────────────────────────────────────── */

  .subtitle-cue {
    margin: 10px 0 4px;
    padding: 6px 12px;
    background: color-mix(in srgb, var(--text-color) 8%, transparent);
    border-radius: 8px;
    font-size: 14px;
    line-height: 1.5;
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
    letter-spacing: 0.05em;
    cursor: pointer;
    -webkit-tap-highlight-color: transparent;
    transition: color 0.2s, border-color 0.2s;
  }

  .btn-cc--active {
    border-color: var(--button-color);
    color: var(--button-color);
  }

  .btn-cc:disabled {
    opacity: 0.3;
    cursor: default;
  }

  .btn-cc:active:not(:disabled) { opacity: 0.7; }
  ```

- [ ] **Step 5: Build CLJS**

  ```bash
  cd /Users/watchcat/work/crystal/buzz-bot
  npx shadow-cljs compile app 2>&1 | tail -20
  ```
  Expected: `Build completed.` no errors.

- [ ] **Step 6: Commit**

  ```bash
  git add src/cljs/buzz_bot/views/player.cljs public/css/app.css
  git commit -m "feat: add CC button and synchronized subtitle display to player"
  ```

---

## Task 7: Push all changes

- [ ] **Step 1: Push buzz-bot changes to main**

  ```bash
  cd /Users/watchcat/work/crystal/buzz-bot
  git log --oneline -6
  git push origin main
  ```

- [ ] **Step 2: Push dub-pipeline changes to main**

  ```bash
  cd /Users/watchcat/work/crystal/dub-pipeline
  git log --oneline -3
  git push origin main
  ```

---

## Self-Review

### Spec coverage check

| Spec requirement | Task |
|-----------------|------|
| Pipeline sends segments in callback | Task 1 |
| `speaker_samples` fix | Task 1 |
| `DubSegment.bulk_upsert` persists segments | Task 2 |
| `DubSegment.for_episode` queries with LEFT JOIN | Task 2 |
| `dub_result.cr` calls bulk_upsert | Task 3 |
| `GET /episodes/:id/subtitles` endpoint | Task 4 |
| 401 auth on subtitles endpoint | Task 4 |
| `:subtitles` in default-db | Task 5 |
| `::current-subtitle-cue` derived sub | Task 5 |
| `::cycle-subtitle-lang` off→orig→translated→off | Task 5 |
| Fetch subtitles on player load when dub done | Task 5 |
| Fetch subtitles when SSE completes | Task 5 |
| Clear subtitles on navigate away | Task 5 |
| CC button in speed row, disabled when no subs | Task 6 |
| Subtitle cue display above controls | Task 6 |
| Falls back to `:text` when translation missing | Task 6 (step 2, the `or`) |
| CSS for `.subtitle-cue` and `.btn-cc` | Task 6 |

### No placeholders: all steps have actual code.

### Type consistency:
- `DubSegmentCue` record defined in Task 2, used in Task 4's route.
- `::fetch-subtitles` defined in Task 5 step 3, dispatched in Tasks 5 step 4+5+6.
- `::cycle-subtitle-lang` defined in Task 5 step 3, dispatched in Task 6 step 3.
- `::clear-subtitles` defined in Task 5 step 3, dispatched in Task 5 step 6.
- Subscription `::current-subtitle-cue` defined in Task 5 step 2, consumed in Task 6 step 1.
- CSS classes `.btn-cc`, `.btn-cc--active` defined in Task 6 step 4, used in Task 6 step 3.
