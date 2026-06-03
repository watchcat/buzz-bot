# Dubbed Page + Language Filter — Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax. Executed inline
> with checkpoints (user-approved), not via subagents.

**Goal:** Add a dedicated Dubbed page reached from the inbox "See all" link, with a
persistent server-side language filter that also constrains the inbox dubbed bar.

**Architecture:** Crystal routes/model gain a `langs` param; cljs gains a `:dubbed`
view + persisted `[:dubbed-filter :langs]` set; toggling re-fetches both surfaces.

**Tech Stack:** Crystal/Kemal + crystal-pg, ClojureScript/re-frame (shadow-cljs).

---

### Task 1: Model — `langs` filter + full-list + distinct languages

**Files:** Modify `src/models/dubbed_episode.cr`

- [ ] `recent_for_inbox(user_id, limit, langs : Array(String)? = nil)`: add
  `AND ($3::text[] IS NULL OR de.language = ANY($3))` to the WHERE, pass `langs`.
- [ ] `all_for_user(user_id, limit, langs : Array(String)? = nil) : Array(DubbedRecent)`:
  same SELECT/JOINs as `recent_for_inbox`, `WHERE de.status='done' AND completed_at
  IS NOT NULL AND ($3::text[] IS NULL OR de.language = ANY($3))`, `ORDER BY
  de.completed_at DESC NULLS LAST LIMIT $2`.
- [ ] `distinct_languages_for_user(user_id) : Array(String)`:
  `SELECT DISTINCT de.language FROM dubbed_episodes de WHERE de.status='done'
   AND de.completed_at IS NOT NULL ... ORDER BY de.language` (only languages for
  episodes the user can see — JOIN episodes/feeds as in the other queries; user
  scoping matches `recent_for_inbox`). Return `Array(String)`.

### Task 2: Routes — extend `/inbox/dubbed`, add `/dubbed`

**Files:** Modify `src/web/routes/inbox.cr` (or wherever dub routes live)

- [ ] Helper to parse `langs`: `parse_langs(env)` → `Array(String)?`
  (split `,`, strip, downcase, reject empty; `nil` if none).
- [ ] `/inbox/dubbed`: pass `parse_langs(env)` to `recent_for_inbox`.
- [ ] New `get "/dubbed"`: auth; `limit = (query["limit"]?... || 100).clamp(1,200)`;
  `items = DubbedEpisode.all_for_user(user.id, limit, parse_langs(env))`;
  `languages = DubbedEpisode.distinct_languages_for_user(user.id)`;
  respond `{items: items, languages: languages}.to_json`.

### Task 3: Persistence — load filter from localStorage

**Files:** Modify `src/cljs/buzz_bot/db.cljs`

- [ ] Add to `default-db`:
```clojure
:dubbed {:items [] :languages [] :loading? false :loaded? false}
:dubbed-filter {:langs (if (exists? js/localStorage)
                         (let [raw (or (.getItem js/localStorage "buzz-dubbed-langs") "")]
                           (into #{} (remove empty? (clojure.string/split raw #","))))
                         #{})}
```
  (add `[clojure.string :as str]`-style require if needed; db.cljs currently has no
  requires — use `(.split raw ",")` interop + filter to avoid adding a require.)

### Task 4: Query-string helper (TDD) + events

**Files:** Modify `src/cljs/buzz_bot/events.cljs`; Test `test/buzz_bot/dubbed_test.cljs`

- [ ] **Step 1 (failing test)** `test/buzz_bot/dubbed_test.cljs`:
```clojure
(ns buzz-bot.dubbed-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.events :as e]))

(deftest dubbed-langs-qs-test
  (testing "empty set → no query string"
    (is (= "" (e/dubbed-langs-qs #{} "?"))))
  (testing "sorted, comma-joined, with separator"
    (is (= "?langs=en,ru" (e/dubbed-langs-qs #{"ru" "en"} "?")))
    (is (= "&langs=de,en,ru" (e/dubbed-langs-qs #{"ru" "en" "de"} "&")))))
```
- [ ] **Step 2** run: `npm test` → FAIL (`dubbed-langs-qs` undefined).
- [ ] **Step 3** add to events.cljs (public defn so the test can reach it):
```clojure
(defn dubbed-langs-qs
  "Query-string fragment for the langs filter; \"\" when none selected."
  [langs sep]
  (if (seq langs)
    (str sep "langs=" (clojure.string/join "," (sort langs)))
    ""))
```
  (events.cljs already requires `clojure.string` — verify; else use interop join.)
- [ ] **Step 4** run `npm test` → PASS.
- [ ] **Step 5** `dubbed-fetch`: change `:url "/inbox/dubbed"` →
  `(str "/inbox/dubbed" (dubbed-langs-qs (get-in db [:dubbed-filter :langs]) "?"))`.
- [ ] Add events:
```clojure
(rf/reg-event-fx ::fetch-dubbed
 (fn [{:keys [db]} [_ force?]]
   (if (and (not force?) (get-in db [:dubbed :loaded?]))
     {}
     {:db (assoc-in db [:dubbed :loading?] true)
      ::buzz-bot.fx/http-fetch
      {:method :get
       :url (str "/dubbed?limit=100"
                 (dubbed-langs-qs (get-in db [:dubbed-filter :langs]) "&"))
       :on-ok [::dubbed-loaded] :on-err [::dubbed-err]}})))

(rf/reg-event-db ::dubbed-loaded
 (fn [db [_ resp]]
   (-> db (assoc-in [:dubbed :items] (vec (:items resp)))
          (assoc-in [:dubbed :languages] (vec (:languages resp)))
          (assoc-in [:dubbed :loaded?] true)
          (assoc-in [:dubbed :loading?] false))))

(rf/reg-event-db ::dubbed-err
 (fn [db _] (-> db (assoc-in [:dubbed :loading?] false)
                   (assoc-in [:dubbed :loaded?] true))))

(defn- persist-dubbed-langs! [langs]
  (when (exists? js/localStorage)
    (.setItem js/localStorage "buzz-dubbed-langs"
              (clojure.string/join "," (sort langs)))))

(rf/reg-event-fx ::toggle-dubbed-lang
 (fn [{:keys [db]} [_ lang]]
   (let [cur  (get-in db [:dubbed-filter :langs] #{})
         next ((if (cur lang) disj conj) cur lang)]
     (persist-dubbed-langs! next)
     {:db (assoc-in db [:dubbed-filter :langs] next)
      :dispatch-n [[::fetch-dubbed true] [::fetch-inbox-dubbed true]]})))

(rf/reg-event-fx ::clear-dubbed-langs
 (fn [{:keys [db]} _]
   (persist-dubbed-langs! #{})
   {:db (assoc-in db [:dubbed-filter :langs] #{})
    :dispatch-n [[::fetch-dubbed true] [::fetch-inbox-dubbed true]]}))
```
- [ ] `::navigate` `fetch-event` case: add `:dubbed [::fetch-dubbed]`.
- [ ] Remove `::see-all-dubbed-stub` (replaced in Task 6).

### Task 5: Subscriptions

**Files:** Modify `src/cljs/buzz_bot/subs.cljs`

- [ ] Add:
```clojure
(rf/reg-sub ::dubbed-items          (fn [db _] (get-in db [:dubbed :items])))
(rf/reg-sub ::dubbed-languages      (fn [db _] (get-in db [:dubbed :languages])))
(rf/reg-sub ::dubbed-loading?       (fn [db _] (get-in db [:dubbed :loading?])))
(rf/reg-sub ::dubbed-selected-langs (fn [db _] (get-in db [:dubbed-filter :langs] #{})))
```
  (`::inbox-dubbed-items` unchanged — server already filtered.)

### Task 6: View — `dubbed.cljs`

**Files:** Create `src/cljs/buzz_bot/views/dubbed.cljs`; Modify `inbox_dubbed.cljs`,
`layout.cljs`

- [ ] New `dubbed.cljs`: header with `← Dubbed` back (`[::events/navigate :inbox]`);
  lang chip row from `::dubbed-languages` (each chip `role=button tab-index 0
  aria-pressed`, toggles `[::toggle-dubbed-lang lang]`, selected = accent fill;
  show an "All" reset chip → `[::clear-dubbed-langs]` when selection non-empty);
  vertical `episode-item` rows (cover, feed name, title, amber `EN→RU` via
  `inbox-dubbed/fmt-langflow` + duration + `fmt-relative-time`, ▶; row =
  role=button + keyboard, click → `[::events/navigate :player {:episode-id …
  :from "dubbed" :dub-lang target_lang}]`); empty/loading states reusing
  `.empty-state` / `.loading`.
- [ ] `inbox_dubbed.cljs`: "See all" `:on-click` → `[::events/navigate :dubbed]`.
- [ ] `layout.cljs`: add `:dubbed [dubbed/view]` to `case view`; require the ns.

### Task 7: Player back origin

**Files:** Modify `src/cljs/buzz_bot/views/player.cljs`

- [ ] Add `"dubbed"` to the `#{"inbox" "bookmarks" "topics"}` feed-link guard set so
  the optional "Feed →" link shows when arriving from the Dubbed page. (Back nav
  itself already works via `(keyword (get params :from))`.)

### Task 8: CSS — language filter chips

**Files:** Modify `public/css/app.css`

- [ ] `.lang-filter` (flex, wrap, gap, padding under the header) + `.lang-chip`
  (reuse the existing chip vocabulary: pill, 1px border, accent text; `:active`
  opacity) + `.lang-chip--active` (fill `--button-color`, `--button-text-color`).
  `:focus-visible` ring per the a11y standard.

### Task 9: Build, test, verify

- [ ] `JAVA_HOME=… npx shadow-cljs release app` → 0 warnings.
- [ ] `JAVA_HOME=… npm test` → all green (incl. new `dubbed-langs-qs` test).
- [ ] Crystal: `crystal build`/`shards build` (or the project's compile check) for
  the model + routes.
- [ ] Grep `main.js` for the new strings/events to confirm bundle.
- [ ] Commit (force-add `public/js/main.js`), push to `main`.

## Self-review notes
- Type consistency: `langs` is a set of lowercase codes everywhere; `dubbed-langs-qs`
  sorts; server `parse_langs` downcases — both ends agree on comparison form.
- DB-test caveat: the SQL methods aren't covered by the node suite; verify against
  Neon before relying on the route (per project convention).
