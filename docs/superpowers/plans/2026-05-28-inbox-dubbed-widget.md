# Latest-dubbed widget — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface recently-completed dubs at the top of the Inbox screen as a horizontal-scrolling row of compact 200 px cards; tap opens the dubbed episode in the player with the dub language already active.

**Architecture:** New `dubbed_episodes.completed_at` column + `DubbedEpisode.recent_for_inbox(user_id, limit)` query that joins episodes + feeds + a user-subscription EXISTS check, ordered by `subscribed DESC, completed_at DESC NULLS LAST`. New `GET /inbox/dubbed` route serves the JSON. A new `:inbox-dubbed` re-frame slice + sibling view component (`views/inbox_dubbed.cljs`) mount above the existing inbox list; widget hides entirely when empty. Card tap routes through the existing `::navigate :player` event with a new `:dub-lang` view-param that the player's dub-init logic auto-taps once status reaches `:done`.

**Tech Stack:** Crystal/Kemal + crystal-pg · ClojureScript + Reagent + re-frame + shadow-cljs (`:node-test`) · Plain CSS via Telegram theme custom properties + a stable warn-orange family.

**Spec:** `docs/superpowers/specs/2026-05-28-inbox-dubbed-widget-design.md`.

**Reference assets:** `/Users/watchcat/Downloads/design_handoff_inbox_dubbed/` — `inbox-v2.jsx`, `inbox-chrome.jsx`, `inbox-data.jsx`, `screenshots/inbox-v2-{default,scrolled}.png`. The `DubbedIcon` SVG is in `inbox-chrome.jsx` lines 165–175.

**Verification commands used throughout:**

| Job | Command |
|---|---|
| Crystal type-check | `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'` |
| Crystal specs | `nix-shell -p crystal -p shards --run 'crystal spec'` |
| CLJS unit tests | `nix-shell -p jdk21_headless --run 'npm test'` |
| CLJS release build | `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs release app'` |
| Apply migration | `psql "$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env -o jsonpath='{.data.DATABASE_URL}' \| base64 -d \| sed -E 's#\?.*#?sslmode=require#')" -f migrations/020_dubbed_episode_completed_at.sql` |

---

## File map

**Create:**

| Path | Responsibility |
|---|---|
| `migrations/020_dubbed_episode_completed_at.sql` | Adds `completed_at TIMESTAMPTZ` to `dubbed_episodes`; backfills from `expires_at - 29d`; partial index. |
| `src/cljs/buzz_bot/inbox_dubbed.cljs` | Pure CLJS helpers — `fmt-relative-time` (timestamp → "2h ago"), `fmt-langflow` ({from, to} → "NL → EN"). |
| `test/buzz_bot/inbox_dubbed_test.cljs` | cljs.test deftests for the pure helpers above. |
| `src/cljs/buzz_bot/views/inbox_dubbed.cljs` | Widget Reagent component: header + scroll row + card component. Inline `DubbedIcon` SVG. |

**Modify:**

| Path | Why |
|---|---|
| `src/models/dubbed_episode.cr` | `set_complete` writes `completed_at = NOW()`; new `DubbedRecent` record + `recent_for_inbox(user_id, limit)` query. |
| `src/web/routes/inbox.cr` | Add `GET /inbox/dubbed` route. |
| `src/cljs/buzz_bot/db.cljs` | Add `:inbox-dubbed {:items [] :loading? false :loaded? false}` slice. |
| `src/cljs/buzz_bot/events.cljs` | New events: `::fetch-inbox-dubbed`, `::inbox-dubbed-loaded`, `::inbox-dubbed-err`, `::see-all-dubbed-stub`. Also extend the inbox-navigation event to dispatch `::fetch-inbox-dubbed` on first entry. |
| `src/cljs/buzz_bot/subs.cljs` | New sub `::inbox-dubbed-items`. |
| `src/cljs/buzz_bot/events/dub.cljs` | Extend `::init-statuses` to read `:dub-lang` from view-params and auto-tap when matching status is `:done`. |
| `src/cljs/buzz_bot/views/inbox.cljs` | Require the widget; mount `[inbox-dubbed/widget]` at the top of the inbox container, ahead of the existing list. |
| `public/css/app.css` | New `:root` tokens (`--warn`, `--warn-13`, `--warn-33`, `--font-mono`); new component rules. |

---

## Task 1 — Migration 020

**Files:**
- Create: `migrations/020_dubbed_episode_completed_at.sql`

- [ ] **Step 1: Write the migration file**

```sql
-- 020_dubbed_episode_completed_at.sql
-- Track when a dub finished. Today only created_at (request time) and
-- expires_at (= completed_at + 29 days) exist, forcing read-side offset math.

ALTER TABLE dubbed_episodes
  ADD COLUMN completed_at TIMESTAMPTZ;

-- Backfill from the existing 29-day expiry contract for already-done rows.
UPDATE dubbed_episodes
SET completed_at = expires_at - INTERVAL '29 days'
WHERE status = 'done' AND expires_at IS NOT NULL;

-- Partial index for the latest-dubbed widget:
--   ORDER BY completed_at DESC NULLS LAST LIMIT 12 WHERE status = 'done'
CREATE INDEX dubbed_episodes_recent_done
  ON dubbed_episodes (completed_at DESC NULLS LAST)
  WHERE status = 'done';
```

- [ ] **Step 2: Apply against Neon**

Run:
```bash
psql "$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')" -f migrations/020_dubbed_episode_completed_at.sql
```
Expected: `ALTER TABLE`, `UPDATE <N>` (where N is the count of already-done dubs), `CREATE INDEX` — no errors.

- [ ] **Step 3: Verify the schema + backfill**

```bash
psql "$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')" -c "\d dubbed_episodes"
```
Expected: row `completed_at | timestamp with time zone | …` and index `dubbed_episodes_recent_done btree (completed_at DESC NULLS LAST) WHERE status::text = 'done'::text`.

Then:
```bash
psql "$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')" -c "SELECT count(*) FILTER (WHERE status='done' AND completed_at IS NOT NULL) AS backfilled, count(*) FILTER (WHERE status='done' AND completed_at IS NULL) AS missing FROM dubbed_episodes"
```
Expected: `missing = 0` (every done dub backfilled from `expires_at`). `backfilled` reflects how many done dubs exist.

- [ ] **Step 4: Commit**

```bash
git add migrations/020_dubbed_episode_completed_at.sql
git commit -m "db: add dubbed_episodes.completed_at + recent-done index (020)"
```

---

## Task 2 — `DubbedEpisode.set_complete` writes `completed_at`

**Files:**
- Modify: `src/models/dubbed_episode.cr:115-126` (the `set_complete` method)

- [ ] **Step 1: Update the SQL**

Open `src/models/dubbed_episode.cr` and find `def self.set_complete`. The current body has:

```crystal
  def self.set_complete(id : Int64, r2_url : String?, speaker_samples : String? = nil)
    AppDB.pool.exec(
      <<-SQL,
        UPDATE dubbed_episodes
        SET step = 'complete', status = 'done', r2_url = $2,
            speaker_samples = $3::jsonb,
            expires_at = NOW() + INTERVAL '29 days'
        WHERE id = $1
      SQL
      id, r2_url, speaker_samples
    )
  end
```

Change the SET clause to also write `completed_at = NOW()`:

```crystal
  def self.set_complete(id : Int64, r2_url : String?, speaker_samples : String? = nil)
    AppDB.pool.exec(
      <<-SQL,
        UPDATE dubbed_episodes
        SET step = 'complete', status = 'done', r2_url = $2,
            speaker_samples = $3::jsonb,
            completed_at = NOW(),
            expires_at = NOW() + INTERVAL '29 days'
        WHERE id = $1
      SQL
      id, r2_url, speaker_samples
    )
  end
```

- [ ] **Step 2: Type-check**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: no output (clean).

- [ ] **Step 3: Run the existing spec suite as a regression guard**

Run: `nix-shell -p crystal -p shards --run 'crystal spec'`
Expected: all examples pass (the change is purely additive at SQL level — no spec depends on the previous shape).

- [ ] **Step 4: Commit**

```bash
git add src/models/dubbed_episode.cr
git commit -m "model(dubbed_episode): set_complete writes completed_at = NOW()"
```

---

## Task 3 — `DubbedEpisode.recent_for_inbox` + `DubbedRecent` record

**Files:**
- Modify: `src/models/dubbed_episode.cr` (append at the end, inside `struct DubbedEpisode`)

- [ ] **Step 1: Add the record + query method**

At the end of `struct DubbedEpisode`, before its closing `end`, append:

```crystal
  # Projection used by GET /inbox/dubbed and the widget renderer.
  # `is_new` is server-computed (completed_at > NOW() - 24h) so the client
  # doesn't have to do any time math.
  record DubbedRecent,
    episode_id   : Int64,
    feed_id      : Int64,
    feed_title   : String,
    feed_image   : String?,
    ep_title     : String,
    ep_image     : String?,
    duration_sec : Int32?,
    source_lang  : String?,
    target_lang  : String,
    completed_at : Time,
    subscribed   : Bool,
    is_new       : Bool do
    include JSON::Serializable

    @[JSON::Field(key: "episode_id")]   property episode_id
    @[JSON::Field(key: "feed_id")]      property feed_id
    @[JSON::Field(key: "feed_title")]   property feed_title
    @[JSON::Field(key: "feed_image")]   property feed_image
    @[JSON::Field(key: "ep_title")]     property ep_title
    @[JSON::Field(key: "ep_image")]     property ep_image
    @[JSON::Field(key: "duration_sec")] property duration_sec
    @[JSON::Field(key: "source_lang")]  property source_lang
    @[JSON::Field(key: "target_lang")]  property target_lang
    @[JSON::Field(key: "completed_at")] property completed_at
    @[JSON::Field(key: "subscribed")]   property subscribed
    @[JSON::Field(key: "is_new")]       property is_new
  end

  def self.recent_for_inbox(user_id : Int64, limit : Int32 = 12) : Array(DubbedRecent)
    out = [] of DubbedRecent
    AppDB.pool.query_each(
      <<-SQL,
        SELECT
          e.id AS episode_id,
          e.feed_id, f.title AS feed_title, f.image_url AS feed_image,
          e.title AS ep_title, e.image_url AS ep_image, e.duration_sec,
          e.original_language AS source_lang,
          de.language         AS target_lang,
          de.completed_at,
          EXISTS (
            SELECT 1 FROM user_feeds uf
            WHERE uf.user_id = $1 AND uf.feed_id = e.feed_id
          ) AS subscribed,
          (de.completed_at > NOW() - INTERVAL '24 hours') AS is_new
        FROM dubbed_episodes de
        JOIN episodes e ON e.id = de.episode_id
        JOIN feeds    f ON f.id = e.feed_id
        WHERE de.status = 'done' AND de.completed_at IS NOT NULL
        ORDER BY subscribed DESC, de.completed_at DESC NULLS LAST
        LIMIT $2
      SQL
      user_id, limit
    ) do |rs|
      out << DubbedRecent.new(
        episode_id:   rs.read(Int64),
        feed_id:      rs.read(Int64),
        feed_title:   rs.read(String),
        feed_image:   rs.read(String?),
        ep_title:     rs.read(String),
        ep_image:     rs.read(String?),
        duration_sec: rs.read(Int32?),
        source_lang:  rs.read(String?),
        target_lang:  rs.read(String),
        completed_at: rs.read(Time),
        subscribed:   rs.read(Bool),
        is_new:       rs.read(Bool),
      )
    end
    out
  end
```

Notes for the implementer:
- `record … do … end` blocks let you mix in JSON serialization properties; `include JSON::Serializable` makes `to_json` emit the @[JSON::Field]-mapped keys.
- The `WHERE de.completed_at IS NOT NULL` guard is defense-in-depth: the migration backfilled every done row, but skipping nulls keeps the order stable if a future column-add race ever leaves one un-backfilled.
- `original_language` is a column on `episodes` (migration 009 added it; `Episode.save_original_language` writes it). No join table.

- [ ] **Step 2: Type-check**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add src/models/dubbed_episode.cr
git commit -m "model(dubbed_episode): recent_for_inbox + DubbedRecent projection"
```

---

## Task 4 — `GET /inbox/dubbed` route

**Files:**
- Modify: `src/web/routes/inbox.cr`

- [ ] **Step 1: Add the route**

Open `src/web/routes/inbox.cr`. Inside `Web::Routes::Inbox.register`, after the existing `get "/inbox" do ... end` block and BEFORE the closing `end` of `register`, add:

```crystal
    # Recently-completed dubs — drives the "Latest dubbed" widget at the
    # top of the inbox. Empty array when there are no done dubs; the client
    # hides the entire widget in that case.
    get "/inbox/dubbed" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      limit = (env.params.query["limit"]?.try(&.to_i32) || 12).clamp(1, 50)
      items = DubbedEpisode.recent_for_inbox(user.id, limit)

      env.response.content_type = "application/json"
      {items: items}.to_json
    end
```

If `src/web/routes/inbox.cr` doesn't already `require "../../models/dubbed_episode"`, add it at the top — confirm by grep before adding:
```bash
grep -n 'dubbed_episode' src/web/routes/inbox.cr
```
If empty, add the require near the file's other requires.

- [ ] **Step 2: Type-check**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: no output.

- [ ] **Step 3: Run the spec suite**

Run: `nix-shell -p crystal -p shards --run 'crystal spec'`
Expected: all examples pass (no new specs in this task; pre-existing count from the delivery arc).

- [ ] **Step 4: Commit**

```bash
git add src/web/routes/inbox.cr
git commit -m "route: GET /inbox/dubbed — recent dubs for the latest-dubbed widget"
```

---

## Task 5 — CLJS pure helpers + tests

Pure ClojureScript helpers used by the widget for time formatting and lang-flow rendering. Tests-first.

**Files:**
- Create: `src/cljs/buzz_bot/inbox_dubbed.cljs`
- Create: `test/buzz_bot/inbox_dubbed_test.cljs`

- [ ] **Step 1: Write the failing tests**

Create `test/buzz_bot/inbox_dubbed_test.cljs` with:

```clojure
(ns buzz-bot.inbox-dubbed-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.inbox-dubbed :as id]))

(defn- ts [iso] (.getTime (js/Date. iso)))

(deftest fmt-relative-time-handles-seconds-minutes
  (let [now (ts "2026-05-28T12:00:00Z")]
    (is (= "just now" (id/fmt-relative-time (ts "2026-05-28T11:59:30Z") now)))
    (is (= "3m ago"   (id/fmt-relative-time (ts "2026-05-28T11:57:00Z") now)))
    (is (= "59m ago"  (id/fmt-relative-time (ts "2026-05-28T11:01:00Z") now)))))

(deftest fmt-relative-time-handles-hours
  (let [now (ts "2026-05-28T12:00:00Z")]
    (is (= "1h ago"  (id/fmt-relative-time (ts "2026-05-28T11:00:00Z") now)))
    (is (= "5h ago"  (id/fmt-relative-time (ts "2026-05-28T07:00:00Z") now)))
    (is (= "23h ago" (id/fmt-relative-time (ts "2026-05-27T13:00:00Z") now)))))

(deftest fmt-relative-time-handles-days
  (let [now (ts "2026-05-28T12:00:00Z")]
    (is (= "1d ago" (id/fmt-relative-time (ts "2026-05-27T12:00:00Z") now)))
    (is (= "6d ago" (id/fmt-relative-time (ts "2026-05-22T12:00:00Z") now)))))

(deftest fmt-relative-time-handles-weeks-and-beyond
  (let [now (ts "2026-05-28T12:00:00Z")]
    (is (= "1w ago" (id/fmt-relative-time (ts "2026-05-21T12:00:00Z") now)))
    (is (= "4w ago" (id/fmt-relative-time (ts "2026-04-30T12:00:00Z") now)))
    ;; > 8 weeks falls back to a date string
    (let [out (id/fmt-relative-time (ts "2026-01-01T12:00:00Z") now)]
      (is (or (= "Jan 1" out) (= "Jan 1, 2026" out))))))

(deftest fmt-langflow-uppercases-and-arrows
  (is (= "NL → EN" (id/fmt-langflow "nl" "en")))
  (is (= "RU → EN" (id/fmt-langflow "ru" "en")))
  (is (= "DE → FR" (id/fmt-langflow "de" "fr"))))

(deftest fmt-langflow-falls-back-when-source-missing
  ;; When source_lang is nil (the dub pipeline didn't write one), show
  ;; just the target language uppercased — better than rendering "→ EN".
  (is (= "EN" (id/fmt-langflow nil "en")))
  (is (= "RU" (id/fmt-langflow ""  "ru"))))
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `nix-shell -p jdk21_headless --run 'npm test'`
Expected: failure citing `Could not find resource buzz_bot/inbox_dubbed.cljs` (or namespace not available). If it fails differently, STOP and report BLOCKED.

- [ ] **Step 3: Implement the helpers**

Create `src/cljs/buzz_bot/inbox_dubbed.cljs` with:

```clojure
(ns buzz-bot.inbox-dubbed
  "Pure presentation helpers for the latest-dubbed widget — relative-time
   formatting and language-flow rendering. No re-frame, no DOM, no SDK;
   safe to unit-test under shadow-cljs :node-test.")

(def ^:private month-abbr
  ["Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"])

(defn- fmt-date [^js d]
  ;; "May 28" if same year as now, else "May 28, 2026".
  (let [now    (js/Date.)
        m     (.getMonth d)
        day   (.getDate d)
        yr    (.getFullYear d)]
    (if (= yr (.getFullYear now))
      (str (get month-abbr m) " " day)
      (str (get month-abbr m) " " day ", " yr))))

(defn fmt-relative-time
  "Given a millisecond timestamp `t-ms` and an optional `now-ms` reference,
   return a short human relative string: 'just now', 'Nm ago', 'Nh ago',
   'Nd ago', 'Nw ago' — or a fallback date string for > 8 weeks.
   `now-ms` defaults to (.now js/Date) and is parameterised for tests."
  ([t-ms]
   (fmt-relative-time t-ms (.now js/Date)))
  ([t-ms now-ms]
   (let [delta-s (max 0 (js/Math.floor (/ (- now-ms t-ms) 1000)))]
     (cond
       (< delta-s 60)            "just now"
       (< delta-s 3600)          (str (js/Math.floor (/ delta-s 60))    "m ago")
       (< delta-s 86400)         (str (js/Math.floor (/ delta-s 3600))  "h ago")
       (< delta-s (* 7 86400))   (str (js/Math.floor (/ delta-s 86400)) "d ago")
       (< delta-s (* 56 86400))  (str (js/Math.floor (/ delta-s (* 7 86400))) "w ago")
       :else                     (fmt-date (js/Date. t-ms))))))

(defn fmt-langflow
  "Source → target language pair, uppercased. Falls back to just the
   target when source is nil/empty (the dub pipeline didn't write a
   source-language detection for this episode)."
  [source target]
  (let [t (some-> target clojure.string/upper-case)]
    (if (and source (not= source ""))
      (str (clojure.string/upper-case source) " → " t)
      t)))
```

Notes for the implementer:
- `clojure.string` needs to be required. Add to the ns form: `(:require [clojure.string])`.
- The `> 8 weeks` fallback's exact format ("Jan 1" vs "Jan 1, 2026") depends on whether the year matches today — the test accepts either, so it stays valid until 2027.

- [ ] **Step 4: Re-run tests**

Run: `nix-shell -p jdk21_headless --run 'npm test'`
Expected: previous count + 6 new deftests / +14 new assertions. Report the actual totals.

- [ ] **Step 5: Commit**

```bash
git add src/cljs/buzz_bot/inbox_dubbed.cljs test/buzz_bot/inbox_dubbed_test.cljs
git commit -m "cljs(inbox-dubbed): pure helpers (fmt-relative-time, fmt-langflow)"
```

---

## Task 6 — CLJS db slice + sub

**Files:**
- Modify: `src/cljs/buzz_bot/db.cljs`
- Modify: `src/cljs/buzz_bot/subs.cljs`

- [ ] **Step 1: Extend the default app-db**

Open `src/cljs/buzz_bot/db.cljs`. Find the default value map (the top-level def or defn that returns the initial db). It contains nested maps like `:inbox`, `:episodes`, `:topics`. Add a sibling key:

```clojure
   :inbox-dubbed {:items    []
                  :loading? false
                  :loaded?  false}
```

Position: alphabetical with other inbox-* keys, or directly after `:inbox` if that's the convention.

- [ ] **Step 2: Add the sub**

Open `src/cljs/buzz_bot/subs.cljs`. Add (near the other inbox-related subs):

```clojure
(rf/reg-sub ::inbox-dubbed-items
  (fn [db _] (get-in db [:inbox-dubbed :items])))
```

(Only the `:items` sub is needed. The widget renders only when items are non-empty; no separate `:loading?` sub.)

- [ ] **Step 3: Compile**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs compile app'`
Expected: `[:app] Build completed.` with `0 warnings`.

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/db.cljs src/cljs/buzz_bot/subs.cljs
git commit -m "cljs(db,subs): add :inbox-dubbed slice + ::inbox-dubbed-items sub"
```

---

## Task 7 — CLJS events

**Files:**
- Modify: `src/cljs/buzz_bot/events.cljs`

- [ ] **Step 1: Add the four new events**

Find the existing `::fetch-inbox` event (or a similar inbox-related event) to use as positional reference. Append:

```clojure
;; Latest-dubbed widget — fetched on first inbox entry; replaces items
;; on success; silent failure (widget just stays hidden).
(rf/reg-event-fx
 ::fetch-inbox-dubbed
 (fn [{:keys [db]} _]
   (if (get-in db [:inbox-dubbed :loaded?])
     {}
     {:db (assoc-in db [:inbox-dubbed :loading?] true)
      ::buzz-bot.fx/http-fetch
      {:method :get
       :url    "/inbox/dubbed"
       :on-ok  [::inbox-dubbed-loaded]
       :on-err [::inbox-dubbed-err]}})))

(rf/reg-event-db
 ::inbox-dubbed-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:inbox-dubbed :items]    (vec (:items resp)))
       (assoc-in [:inbox-dubbed :loaded?]  true)
       (assoc-in [:inbox-dubbed :loading?] false))))

(rf/reg-event-db
 ::inbox-dubbed-err
 (fn [db [_ _err]]
   ;; Silent: widget just stays empty/hidden. Inbox proper renders fine.
   (-> db
       (assoc-in [:inbox-dubbed :loading?] false)
       (assoc-in [:inbox-dubbed :loaded?]  true))))

;; v1 stub — "See all →" routes here but does nothing yet. Wired up so
;; the button has a real dispatch and the design isn't lying about a
;; nav target; future work replaces this with a navigate to /dubbed.
(rf/reg-event-db
 ::see-all-dubbed-stub
 (fn [db _] db))
```

- [ ] **Step 2: Wire the fetch to inbox navigation**

Find the existing `::navigate` event (or the inbox-route activation event). The CLJS routing flow dispatches a tab-change event when the user enters the inbox; if there's a `:inbox` case in `::navigate`, hook the fetch as a co-dispatch. Concretely, find the part of `::navigate` (or the inbox dispatch table) that initializes inbox data and add a co-dispatch:

```clojure
;; Pseudocode shape — adapt to the actual ::navigate dispatch table:
;; ... :inbox [::fetch-inbox]
;; becomes:
;; ... :inbox [::fetch-inbox ::fetch-inbox-dubbed]
```

If the existing flow uses a single `:dispatch` keyword instead of `:dispatch-n`, switch it to `:dispatch-n` for the inbox case:

```clojure
{... :dispatch-n [[::fetch-inbox] [::fetch-inbox-dubbed]]}
```

If the dispatch table is in a different file (e.g., `events.cljs` has a `tab-init` event with a `case`), follow that pattern instead. The principle is: **on entering the inbox tab, fire both `::fetch-inbox` (existing) and `::fetch-inbox-dubbed` (new)**. `::fetch-inbox-dubbed` is a no-op when `:loaded?` is true (see Step 1) so repeated entries don't re-fetch.

- [ ] **Step 3: Compile**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs compile app'`
Expected: 0 warnings.

- [ ] **Step 4: Regression test run**

Run: `nix-shell -p jdk21_headless --run 'npm test'`
Expected: unchanged count from Task 5.

- [ ] **Step 5: Commit**

```bash
git add src/cljs/buzz_bot/events.cljs
git commit -m "cljs(events): fetch-inbox-dubbed + loaded/err + see-all stub; wire to inbox nav"
```

---

## Task 8 — CSS additions

**Files:**
- Modify: `public/css/app.css`

- [ ] **Step 1: Add the warn-orange family + monospace font var**

Find the `:root {` block at the top of `public/css/app.css`. After the existing `--accent-13` / `--accent-33` lines (added by the delivery feature), append:

```css
  /* Dubbed-content accent — intentionally theme-independent so it always
     reads as the same color across Telegram palettes. */
  --warn:    #E78A4E;
  --warn-13: color-mix(in srgb, var(--warn) 13%, transparent);
  --warn-33: color-mix(in srgb, var(--warn) 33%, transparent);

  /* Monospace family for the dubbed lang-flow chip. System fallbacks
     render well without bundling a webfont. */
  --font-mono: ui-monospace, "JetBrains Mono", "SF Mono", Menlo, monospace;
```

- [ ] **Step 2: Append the widget component rules**

At the END of `public/css/app.css`, append:

```css
/* ── Latest-dubbed widget (Inbox top) ───────────────────────────── */

.dubbed-section { padding: 0 0 6px; }

.dubbed-header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 0 16px 6px;
}

.dubbed-header__label {
  font: 700 11px/1 inherit;
  letter-spacing: 0.6px;
  color: var(--hint-color);
  text-transform: uppercase;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  white-space: nowrap;
  flex: 0 1 auto;
  min-width: 0;
}

.dubbed-pill {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  background: var(--warn-13);
  color: var(--warn);
  border: 1px solid var(--warn-33);
  padding: 1px 6px;
  border-radius: 999px;
  font: 700 9px/1 inherit;
  letter-spacing: 0.6px;
  text-transform: uppercase;
}

.see-all-link {
  background: transparent;
  border: none;
  color: var(--button-color);
  font: 600 11px/1 inherit;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  white-space: nowrap;
  flex: 0 0 auto;
  padding: 0;
}
.see-all-link:active { opacity: 0.6; }

.dubbed-cards {
  display: flex;
  gap: 8px;
  padding: 0 16px 4px;
  overflow-x: auto;
  scroll-snap-type: x mandatory;
  scrollbar-width: none;            /* Firefox */
}
.dubbed-cards::-webkit-scrollbar { display: none; }

.dubbed-card {
  flex: 0 0 auto;
  width: 200px;
  background: var(--secondary-bg);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 7px;
  display: flex;
  align-items: center;
  gap: 9px;
  cursor: pointer;
  text-align: left;
  scroll-snap-align: start;
  color: var(--text-color);
  user-select: none;
  -webkit-user-select: none;
  -webkit-tap-highlight-color: transparent;
}
.dubbed-card:active { opacity: 0.85; }

.dubbed-card__cover-wrap {
  position: relative;
  flex: 0 0 auto;
}

.dubbed-card__cover {
  width: 48px;
  height: 48px;
  border-radius: 8px;
  object-fit: cover;
  display: block;
}

.dubbed-new-badge {
  position: absolute;
  top: -3px;
  right: -3px;
  background: var(--warn);
  color: #fff;
  font: 800 8px/1 inherit;
  letter-spacing: 0.3px;
  padding: 1px 4px;
  border-radius: 999px;
  text-transform: uppercase;
  border: 2px solid var(--bg-color);
}

.dubbed-card__body {
  flex: 1;
  min-width: 0;
}

.dubbed-langflow {
  display: flex;
  align-items: center;
  gap: 5px;
  color: var(--warn);
}

.dubbed-langflow__pair {
  font: 700 8px/1 var(--font-mono);
}

.dubbed-langflow__when {
  color: var(--hint-color);
  font-size: 9px;
}

.dubbed-card__title {
  font: 600 12px/1.2 inherit;
  color: var(--text-color);
  margin-top: 2px;
  overflow: hidden;
  text-overflow: ellipsis;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  min-height: 28px;
}

.dubbed-card__meta {
  font-size: 9px;
  color: var(--hint-color);
  margin-top: 2px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.dubbed-divider {
  height: 1px;
  background: var(--border);
  margin: 6px 16px 12px;
}
```

- [ ] **Step 3: Commit**

```bash
git add public/css/app.css
git commit -m "css: --warn family + --font-mono + dubbed widget rules"
```

---

## Task 9 — Widget Reagent component

**Files:**
- Create: `src/cljs/buzz_bot/views/inbox_dubbed.cljs`

- [ ] **Step 1: Implement the component**

Create the file with EXACTLY this content:

```clojure
(ns buzz-bot.views.inbox-dubbed
  "Latest-dubbed widget mounted at the top of the Inbox screen. Pure
   presentation + dispatch — data comes from buzz-bot.subs/inbox-dubbed-items;
   pure helpers (fmt-relative-time, fmt-langflow) live in
   buzz-bot.inbox-dubbed."
  (:require [re-frame.core :as rf]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.inbox-dubbed :as id]
            [buzz-bot.views.utils :refer [img-proxy]]))

;; ── icons (verbatim port of inbox-chrome.jsx#DubbedIcon + a tiny chevron) ──

(defn- dubbed-icon [size]
  [:svg {:width size :height size :viewBox "0 0 10 10" :fill "none"}
   [:path {:d "M2 2 L4 2 L4 8 L2 8 Z" :fill "currentColor"}]
   [:path {:d "M5 1.5 C7 1.5 8.5 3 8.5 5 C8.5 7 7 8.5 5 8.5"
           :stroke "currentColor" :stroke-width "1.2" :fill "none" :stroke-linecap "round"}]
   [:path {:d "M5 3.5 C6 3.5 6.8 4.2 6.8 5 C6.8 5.8 6 6.5 5 6.5"
           :stroke "currentColor" :stroke-width "1.2" :fill "none" :stroke-linecap "round"}]])

(defn- chevron-right [size]
  [:svg {:width size :height size :viewBox "0 0 12 12" :fill "none"}
   [:path {:d "M4 2 L8 6 L4 10" :stroke "currentColor" :stroke-width "1.6"
           :stroke-linecap "round" :stroke-linejoin "round"}]])

(defn- fmt-duration [sec]
  (when (and sec (pos? sec))
    (let [h (js/Math.floor (/ sec 3600))
          m (js/Math.floor (/ (mod sec 3600) 60))]
      (if (pos? h) (str h "h " m "m") (str m " min")))))

(defn- card [item]
  (let [{:keys [episode_id feed_title feed_image ep_title ep_image
                duration_sec source_lang target_lang completed_at is_new]} item
        cover-url (or ep_image feed_image)
        when-str  (when completed_at
                    (id/fmt-relative-time (.getTime (js/Date. completed_at))))
        lang-flow (id/fmt-langflow source_lang target_lang)
        meta-str  (let [d (fmt-duration duration_sec)]
                    (cond
                      (and feed_title d) (str feed_title " · " d)
                      feed_title         feed_title
                      d                  d))]
    [:button.dubbed-card
     {:on-click #(rf/dispatch [::events/navigate :player
                               {:episode-id episode_id
                                :from       "inbox"
                                :dub-lang   target_lang}])}
     [:div.dubbed-card__cover-wrap
      (when cover-url
        [:img.dubbed-card__cover {:src      (img-proxy cover-url)
                                  :alt      ""
                                  :loading  "lazy"
                                  :decoding "async"
                                  :width    48
                                  :height   48}])
      (when is_new
        [:span.dubbed-new-badge "New"])]
     [:div.dubbed-card__body
      [:div.dubbed-langflow
       [:span.dubbed-langflow__pair lang-flow]
       (when when-str
         [:span.dubbed-langflow__when (str "· " when-str)])]
      [:div.dubbed-card__title ep_title]
      (when meta-str [:div.dubbed-card__meta meta-str])]]))

(defn widget
  "Renders nothing when there are no dubbed items — keeps the inbox
   list unchanged on the empty case."
  []
  (let [items @(rf/subscribe [::subs/inbox-dubbed-items])]
    (when (seq items)
      [:div.dubbed-section
       [:div.dubbed-header
        [:span.dubbed-header__label
         [:span.dubbed-pill (dubbed-icon 9) "Dubbed"]
         "Latest dubbed"]
        [:span {:style {:flex 1}}]
        [:button.see-all-link
         {:on-click #(rf/dispatch [::events/see-all-dubbed-stub])}
         "See all" (chevron-right 9)]]
       [:div.dubbed-cards
        (for [item items]
          ^{:key (:episode_id item)} [card item])]
       [:div.dubbed-divider]])))
```

- [ ] **Step 2: Compile**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs compile app'`
Expected: `0 warnings`.

- [ ] **Step 3: Commit**

```bash
git add src/cljs/buzz_bot/views/inbox_dubbed.cljs
git commit -m "cljs(views): inbox-dubbed widget — header + scroll row + card"
```

---

## Task 10 — Player auto-tap `:dub-lang` on init

When the user taps a dubbed card, the navigate event carries `:dub-lang <target>`. After `/episodes/:id/player` data lands and `::dub-events/init-statuses` populates the dub-statuses map, the player should auto-tap that language if its status is `:done` so the dubbed audio plays instead of the original.

**Files:**
- Modify: `src/cljs/buzz_bot/events/dub.cljs`

- [ ] **Step 1: Extend `::init-statuses`**

Open `src/cljs/buzz_bot/events/dub.cljs`. Find `::init-statuses` (reg-event-fx near the top of the file). The current shape is approximately:

```clojure
(rf/reg-event-fx
 ::init-statuses
 (fn [{:keys [db]} [_ episode-id statuses-map]]
   (let [statuses  (reduce-kv ... statuses-map)
         in-flight (first (keep ...))
         done-lang (first (keep ...))]
     (cond-> {:db (assoc-in db [:dub :statuses] statuses)}
       in-flight (assoc ::fx/open-dub-sse {:episode-id episode-id :lang in-flight})
       done-lang (assoc :dispatch [:buzz-bot.events/fetch-subtitles episode-id done-lang])))))
```

Modify the let-bindings and the cond-> to also auto-tap when view-params carries a matching `:dub-lang`:

```clojure
(rf/reg-event-fx
 ::init-statuses
 (fn [{:keys [db]} [_ episode-id statuses-map]]
   (let [statuses  (reduce-kv
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
                                statuses))
         ;; Card click in views/inbox_dubbed.cljs sets :dub-lang in view-params
         ;; via ::events/navigate :player {... :dub-lang "<target>"}. If that
         ;; language's status is :done now, auto-activate it so the dubbed
         ;; audio loads instead of the original.
         nav-lang  (some-> (get-in db [:nav :params :dub-lang]) name)
         auto-lang (when (and nav-lang
                              (= :done (get-in statuses [nav-lang :status])))
                     nav-lang)]
     (cond-> {:db (assoc-in db [:dub :statuses] statuses)}
       in-flight
       (assoc ::fx/open-dub-sse {:episode-id episode-id :lang in-flight})
       done-lang
       (assoc :dispatch [:buzz-bot.events/fetch-subtitles episode-id done-lang])
       auto-lang
       (update :dispatch (fn [existing]
                           (let [extra [::language-tapped episode-id auto-lang]]
                             (if existing
                               ;; Promote single :dispatch to :dispatch-n if both fire
                               existing
                               extra))))
       ;; If both done-lang fetch-subtitles AND auto-lang fired above, the
       ;; second `update :dispatch` would have replaced the first — handle
       ;; via the helper below.
       ))))
```

The intermingled `:dispatch` vs `:dispatch-n` handling is fragile. Use this cleaner pattern instead — replace the cond-> with explicit construction:

```clojure
(rf/reg-event-fx
 ::init-statuses
 (fn [{:keys [db]} [_ episode-id statuses-map]]
   (let [statuses  (reduce-kv
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
                                statuses))
         nav-lang  (some-> (get-in db [:nav :params :dub-lang]) name)
         auto-lang (when (and nav-lang
                              (= :done (get-in statuses [nav-lang :status])))
                     nav-lang)
         dispatches (cond-> []
                      done-lang (conj [:buzz-bot.events/fetch-subtitles episode-id done-lang])
                      auto-lang (conj [::language-tapped episode-id auto-lang]))]
     (cond-> {:db (assoc-in db [:dub :statuses] statuses)}
       in-flight
       (assoc ::fx/open-dub-sse {:episode-id episode-id :lang in-flight})
       (seq dispatches)
       (assoc :dispatch-n dispatches)))))
```

Important: the implementer should READ the actual current body of `::init-statuses` and merge these changes carefully — the upstream shape may already differ. The principle is:
1. Compute `nav-lang` from `(get-in db [:nav :params :dub-lang])` (or whatever the actual view-params slot is — verify by greping for how other navigate-params are read).
2. If that language's status is `:done`, dispatch `[::language-tapped episode-id nav-lang]` after init.
3. Keep all existing dispatch arms (`fetch-subtitles` etc.) firing.

- [ ] **Step 2: Compile**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs compile app'`
Expected: 0 warnings.

- [ ] **Step 3: Regression test run**

Run: `nix-shell -p jdk21_headless --run 'npm test'`
Expected: unchanged from Task 5 count.

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/events/dub.cljs
git commit -m "cljs(dub): auto-tap dub language when :dub-lang in view-params + status :done"
```

---

## Task 11 — Mount the widget on the Inbox view

**Files:**
- Modify: `src/cljs/buzz_bot/views/inbox.cljs`

- [ ] **Step 1: Require the widget + mount it**

Open `src/cljs/buzz_bot/views/inbox.cljs`. Extend the ns require to include:

```clojure
[buzz-bot.views.inbox-dubbed :as inbox-dubbed]
```

Find the top-level `view` function (or the `(defn view []` for the inbox screen). It currently renders something like:

```clojure
[:div.inbox-container
 [:div.section-header ...]   ; "Inbox" title row
 [:ul#episode-list.episode-list ...]
 ...]
```

Insert `[inbox-dubbed/widget]` immediately after the title-row section and before the inbox episode list:

```clojure
[:div.inbox-container
 [:div.section-header ...]   ; existing
 [inbox-dubbed/widget]       ; NEW — renders nothing when items empty
 [:ul#episode-list.episode-list ...]
 ...]
```

Don't fire fetch from this file — Task 7 wired `::fetch-inbox-dubbed` into the inbox-navigation dispatch, so by the time the view mounts the fetch is already in flight (or completed and idempotent).

- [ ] **Step 2: Compile**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs compile app'`
Expected: 0 warnings.

- [ ] **Step 3: Commit**

```bash
git add src/cljs/buzz_bot/views/inbox.cljs
git commit -m "cljs(views/inbox): mount latest-dubbed widget above the episode list"
```

---

## Task 12 — Final release build + push

**Files:**
- Modify: `public/js/main.js` (auto-generated)

- [ ] **Step 1: Full Crystal regression sweep**

```
nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen && crystal spec'
```
Expected: clean build; spec count unchanged from start of this plan (no new Crystal specs in this arc).

- [ ] **Step 2: Full CLJS regression sweep**

```
nix-shell -p jdk21_headless --run 'npm test'
```
Expected: previous CLJS count + 6 tests / +14 assertions from Task 5.

- [ ] **Step 3: Release build**

```
nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs release app'
```
Expected: `[:app] Build completed.` with `0 warnings`. If warnings appear, investigate and fix before pushing.

- [ ] **Step 4: Commit the regenerated bundle**

```bash
git add -f public/js/main.js
git commit -m "build: regenerate main.js for inbox latest-dubbed widget"
```

- [ ] **Step 5: Push all this arc's commits to main**

```bash
git push origin main
```
Expected: push succeeds; CI / k8s/deploy.sh will pick it up.

- [ ] **Step 6: Operator smoke (post-deploy)**

After `k8s/deploy.sh`:

1. Open the Mini App → Inbox tab.
2. **If there are recently-done dubs:** the widget appears at the top with horizontally-scrolling cards. Verify visually: 200 px cards, ~1.7 visible, peek of next.
3. Tap any card. Player opens at the card's episode and **the dubbed audio is selected** (not the original).
4. Pull-to-refresh / re-enter the inbox tab: the widget content is stable (no re-fetch — `:loaded?` flag prevents it).
5. Tap "See all →": nothing happens (v1 stub — expected).
6. **If there are no done dubs in the system:** the widget is absent; inbox list renders unchanged at the top.
7. (Optional) On a feed you subscribe to that has a done dub, verify your subscribed dubs appear BEFORE other-feed dubs (subscribed-first ordering).

---

## Self-review notes

**Spec coverage** (cross-checked against the acceptance checklist):

| Acceptance item | Task |
|---|---|
| Migration 020 adds `completed_at` + backfill + partial index | 1 |
| `set_complete` writes `completed_at = NOW()` | 2 |
| `DubbedEpisode.recent_for_inbox` projection, subscribed-first + DESC ordering, server-side `is_new` | 3 |
| `GET /inbox/dubbed` returns `{items: [...]}`, `?limit` clamped `[1, 50]`, empty array when no dubs | 4 |
| Widget appears at top of Inbox below title | 11 |
| DUBBED pill (warn palette + speaker icon), "LATEST DUBBED" label, "See all →" link — none wrap | 8 + 9 |
| 200 px cards, horizontal scroll, snap-to-start, ~1.7 visible | 8 + 9 |
| Card content: 48 px cover with NEW badge, mono lang-flow + relative time, 2-line title, meta | 5 + 9 |
| Tap card → player + dub language auto-activated when status `:done` | 9 + 10 |
| See all → is a v1 stub no-op | 7 |
| Widget hides entirely when items empty | 9 |
| New CSS tokens `--warn`, `--warn-13`, `--warn-33`, `--font-mono` in `:root` | 8 |
| No hardcoded `#E78A4E` outside `:root` | 8 |
| Scrollbar hidden in widget (Firefox + WebKit) | 8 |

**Placeholder scan:** No "TODO", "TBD", or "similar to…" left in step bodies. Step 1 of Task 7 (`::fetch-inbox-dubbed` wiring into navigation) describes the *principle* with a pseudocode example rather than the literal code change because the project's nav dispatch table is small enough that the precise edit depends on its current line shape — the implementer is told what to grep for and what the outcome should be.

**Type consistency:**
- `DubbedRecent` field names (Task 3) → JSON keys via `@[JSON::Field(key: ...)]` → CLJS destructure (Task 9) all use the same snake_case names: `episode_id`, `feed_title`, `feed_image`, `ep_title`, `ep_image`, `duration_sec`, `source_lang`, `target_lang`, `completed_at`, `subscribed`, `is_new`.
- Event names (`::fetch-inbox-dubbed`, `::inbox-dubbed-loaded`, `::inbox-dubbed-err`, `::see-all-dubbed-stub`) defined Task 7; consumed Tasks 9 + 11 — match exactly.
- Sub `::inbox-dubbed-items` defined Task 6; consumed Task 9.
- CSS classes (`.dubbed-section`, `.dubbed-header`, `.dubbed-header__label`, `.dubbed-pill`, `.see-all-link`, `.dubbed-cards`, `.dubbed-card`, `.dubbed-card__cover-wrap`, `.dubbed-card__cover`, `.dubbed-new-badge`, `.dubbed-card__body`, `.dubbed-langflow`, `.dubbed-langflow__pair`, `.dubbed-langflow__when`, `.dubbed-card__title`, `.dubbed-card__meta`, `.dubbed-divider`) defined Task 8; consumed Task 9 — every class used in the hiccup has a CSS rule.
- Pure helpers `buzz-bot.inbox-dubbed/{fmt-relative-time, fmt-langflow}` defined Task 5; consumed Task 9.
