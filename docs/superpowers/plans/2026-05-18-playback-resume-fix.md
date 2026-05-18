# Playback Resume Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reopening a previously-played episode resumes at its true saved position, position is reliably persisted across pause/suspend, and spurious mid-reload writes never corrupt it.

**Architecture:** Approach A — server `progress_seconds` is the source of truth, re-applied idempotently on player-open. The three decisions are extracted into a new pure `buzz-bot.playback` namespace (unit-tested under a new shadow-cljs `:node-test` harness); `events.cljs` and `audio.cljs` consume them. No server/DB change.

**Tech Stack:** ClojureScript, re-frame 1.4.3, reagent 1.2.0, shadow-cljs 2.28.18, cljs.test (`:node-test`), Node + OpenJDK via `nix-shell`.

**Spec:** `docs/superpowers/specs/2026-05-18-playback-resume-fix-design.md`

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `shadow-cljs.edn` | Add `"test"` source path + `:test` `:node-test` build | 1 |
| `package.json` | Add `"test"` npm script | 1 |
| `.gitignore` | Ignore shadow-cljs test output `out/` | 1 |
| `test/buzz_bot/smoke_test.cljs` | Proves the harness runs (permanent regression guard) | 1 |
| `src/cljs/buzz_bot/playback.cljs` | Pure decisions: `resume-start`, `should-skip-reload?`, `should-save-progress?` | 2–4 |
| `test/buzz_bot/playback_test.cljs` | Exhaustive pure-fn tests (realizes the spec's decision/event tests) | 2–4 |
| `src/cljs/buzz_bot/events.cljs` | `::player-loaded` guard, `::audio-load` start, `::audio-ended` clear | 5 |
| `src/cljs/buzz_bot/audio.cljs` | `flush-progress!`, pause/visibilitychange/pagehide flush, interval trust-gate | 6 |

**Testing strategy note:** the codebase has no DOM/re-frame-runtime test harness and the spec scopes automated tests to the pure decision functions. The spec's "`::player-loaded` event tests (a)–(d)" are realized as exhaustive tests of the pure fns those branches delegate to (`should-skip-reload?`, `resume-start`) — deterministic, no fx/async machinery. Tasks 5–6 are DOM/re-frame-coupled wiring; their verification is `shadow-cljs compile app` (catches cljs errors) plus the already-tested pure logic and the Task 7 manual checks. This is intentional and matches the approved spec.

---

## Task 1: Stand up the shadow-cljs `:node-test` harness

**Files:**
- Modify: `shadow-cljs.edn`
- Modify: `package.json`
- Modify: `.gitignore`
- Create: `test/buzz_bot/smoke_test.cljs`

- [ ] **Step 1: Write the smoke test (the "failing" artifact — harness can't run yet)**

Create `test/buzz_bot/smoke_test.cljs`:

```clojure
(ns buzz-bot.smoke-test
  (:require [cljs.test :refer [deftest is]]))

(deftest harness-runs
  (is (= 2 (+ 1 1))))
```

- [ ] **Step 2: Run it to confirm the harness does NOT exist yet**

Run:
```bash
nix-shell -p nodejs -p openjdk --run "npm ci --prefer-offline && node node_modules/.bin/shadow-cljs compile test"
```
Expected: FAIL — `Unknown build "test"` (no `:test` build defined yet).

- [ ] **Step 3: Add the test build + source path**

Replace the entire contents of `shadow-cljs.edn` with:

```clojure
{:source-paths ["src/cljs" "test"]
 :dependencies [[reagent "1.2.0"]
                [re-frame "1.4.3"]]
 :builds
 {:app  {:target     :browser
         :output-dir "public/js"
         :asset-path "/js"
         :modules    {:main {:init-fn buzz-bot.core/init!}}
         :release    {:compiler-options {:source-map "public/js/main.js.map"}}
         :build-options {:cache-level :off}
         :devtools   {:repl-init-ns buzz-bot.core}}
  :test {:target    :node-test
         :output-to "out/node-tests.js"
         :ns-regexp "-test$"
         :autorun   false}}}
```

(Only additions: `"test"` in `:source-paths`, and the `:test` build. The
`:app` build is byte-identical to before.)

In `package.json`, add a `"scripts"` block (the file currently has none) so the
object becomes exactly:

```json
{
  "name": "buzz-bot",
  "version": "1.0.0",
  "scripts": {
    "test": "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"
  },
  "devDependencies": {
    "shadow-cljs": "2.28.18"
  },
  "dependencies": {
    "react": "18.3.1",
    "react-dom": "18.3.1"
  }
}
```

Append a line to `.gitignore` (after the existing `public/js/` JS-artifacts block):

```
# shadow-cljs node-test output
out/
```

- [ ] **Step 4: Run the harness — smoke test passes**

Run:
```bash
nix-shell -p nodejs -p openjdk --run "npm ci --prefer-offline && node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"
```
Expected: compiles, then node runs cljs.test; output ends with
`1 tests, 1 assertions, 0 failures.` and exit code 0.

- [ ] **Step 5: Commit**

```bash
git add shadow-cljs.edn package.json .gitignore test/buzz_bot/smoke_test.cljs
git commit -m "test: stand up shadow-cljs :node-test harness"
```

---

## Task 2: `resume-start` (pure, TDD)

**Files:**
- Create: `src/cljs/buzz_bot/playback.cljs`
- Create: `test/buzz_bot/playback_test.cljs`

- [ ] **Step 1: Write the failing test**

Create `test/buzz_bot/playback_test.cljs`:

```clojure
(ns buzz-bot.playback-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.playback :as pb]))

(deftest resume-start-test
  (testing "completed episode restarts from 0 (decision 1)"
    (is (= 0 (pb/resume-start true 1234))))
  (testing "in-progress episode resumes at saved position"
    (is (= 600 (pb/resume-start false 600))))
  (testing "opened but not advanced (progress=0, not completed) -> 0"
    (is (= 0 (pb/resume-start false 0))))
  (testing "missing/nil progress -> 0"
    (is (= 0 (pb/resume-start false nil)))
    (is (= 0 (pb/resume-start nil nil))))
  (testing "completed wins even if progress present"
    (is (= 0 (pb/resume-start true 999)))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test"`
Expected: FAIL — cannot require `buzz-bot.playback` (namespace does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `src/cljs/buzz_bot/playback.cljs`:

```clojure
(ns buzz-bot.playback)

;; HTMLMediaElement.readyState below this -> currentTime is not trustworthy.
(def ^:private trustworthy-ready-state 2) ;; HAVE_CURRENT_DATA

(defn resume-start
  "Position (seconds) to resume an episode at. Completed episodes restart
  from 0 (decision 1); otherwise the saved progress, defaulting to 0."
  [completed progress-seconds]
  (if completed 0 (or progress-seconds 0)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`
Expected: PASS — `resume-start-test` green (smoke test still green too).

- [ ] **Step 5: Commit**

```bash
git add src/cljs/buzz_bot/playback.cljs test/buzz_bot/playback_test.cljs
git commit -m "feat: playback/resume-start (completed -> 0)"
```

---

## Task 3: `should-skip-reload?` (pure, TDD)

**Files:**
- Modify: `src/cljs/buzz_bot/playback.cljs`
- Modify: `test/buzz_bot/playback_test.cljs`

- [ ] **Step 1: Write the failing test**

Append to `test/buzz_bot/playback_test.cljs`:

```clojure
(deftest should-skip-reload?-test
  (testing "skip ONLY when reopening the actively-playing episode"
    (is (true?  (pb/should-skip-reload? {:same-episode? true  :was-playing? true}))))
  (testing "same episode but paused -> reload (the bug-1 fix)"
    (is (false? (pb/should-skip-reload? {:same-episode? true  :was-playing? false}))))
  (testing "different episode -> never skip"
    (is (false? (pb/should-skip-reload? {:same-episode? false :was-playing? true})))
    (is (false? (pb/should-skip-reload? {:same-episode? false :was-playing? false}))))
  (testing "nil inputs are falsey, not exceptions"
    (is (false? (pb/should-skip-reload? {:same-episode? nil :was-playing? nil})))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test"`
Expected: FAIL — `pb/should-skip-reload?` is not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `src/cljs/buzz_bot/playback.cljs`:

```clojure
(defn should-skip-reload?
  "True only when reopening the episode that is actively playing right now —
  the single case where re-issuing a load would wrongly interrupt playback.
  `was-playing?` is the navigation-time snapshot (events.cljs :325-327)."
  [{:keys [same-episode? was-playing?]}]
  (boolean (and same-episode? was-playing?)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`
Expected: PASS — all tests green.

- [ ] **Step 5: Commit**

```bash
git add src/cljs/buzz_bot/playback.cljs test/buzz_bot/playback_test.cljs
git commit -m "feat: playback/should-skip-reload? (skip only if actively playing)"
```

---

## Task 4: `should-save-progress?` (pure, TDD)

**Files:**
- Modify: `src/cljs/buzz_bot/playback.cljs`
- Modify: `test/buzz_bot/playback_test.cljs`

- [ ] **Step 1: Write the failing test**

Append to `test/buzz_bot/playback_test.cljs`:

```clojure
(deftest should-save-progress?-test
  (testing "trustworthy when not recovering, not seeking, readyState >= 2"
    (is (true? (pb/should-save-progress?
                 {:recovering? false :ready-state 2 :seeking? false})))
    (is (true? (pb/should-save-progress?
                 {:recovering? false :ready-state 4 :seeking? false}))))
  (testing "suppressed during reload (recovering?)"
    (is (false? (pb/should-save-progress?
                  {:recovering? true :ready-state 4 :seeking? false}))))
  (testing "suppressed while seeking"
    (is (false? (pb/should-save-progress?
                  {:recovering? false :ready-state 4 :seeking? true}))))
  (testing "suppressed when readyState below HAVE_CURRENT_DATA (covers .load() reset)"
    (is (false? (pb/should-save-progress?
                  {:recovering? false :ready-state 1 :seeking? false})))
    (is (false? (pb/should-save-progress?
                  {:recovering? false :ready-state 0 :seeking? false}))))
  (testing "nil readyState treated as untrustworthy"
    (is (false? (pb/should-save-progress?
                  {:recovering? false :ready-state nil :seeking? false})))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test"`
Expected: FAIL — `pb/should-save-progress?` is not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `src/cljs/buzz_bot/playback.cljs`:

```clojure
(defn should-save-progress?
  "True when the element's currentTime is trustworthy enough to persist.
  False during reloads/seeks (covers stall-recovery, :switch-src, download
  swap, network reload — bug 3) regardless of source. nil readyState is
  treated as untrustworthy."
  [{:keys [recovering? ready-state seeking?]}]
  (not (or (boolean recovering?)
           (boolean seeking?)
           (< (or ready-state 0) trustworthy-ready-state))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`
Expected: PASS — all three pure-fn deftests + smoke green.

- [ ] **Step 5: Commit**

```bash
git add src/cljs/buzz_bot/playback.cljs test/buzz_bot/playback_test.cljs
git commit -m "feat: playback/should-save-progress? trust gate"
```

---

## Task 5: Wire Bug 1 into `events.cljs`

**Files:**
- Modify: `src/cljs/buzz_bot/events.cljs`

- [ ] **Step 1: Add the `playback` require**

In `src/cljs/buzz_bot/events.cljs`, in the `ns` `:require` vector, add:

```clojure
            [buzz-bot.playback :as pb]
```

(Place it alphabetically/with the other `buzz-bot.*` requires; it is the only
new require.)

- [ ] **Step 2: `::player-loaded` — skip only if actively playing**

In `::player-loaded` (the `cond` at lines ~341-354), the current first clause is:

```clojure
       (cond
         (= cur-id new-id)
         {:db         (assoc-in db' [:audio :pending?] false)
          :dispatch-n (conj (vec init-dub) [::audio-download-start new-id])}
```

Replace **only that clause's test** so it becomes:

```clojure
       (cond
         (pb/should-skip-reload? {:same-episode? (= cur-id new-id)
                                  :was-playing?  was-playing?})
         {:db         (assoc-in db' [:audio :pending?] false)
          :dispatch-n (conj (vec init-dub) [::audio-download-start new-id])}
```

Leave the other two clauses — `(and was-playing? (not= cur-id new-id))` and
`:else` — exactly as they are. (`was-playing?` is already bound in the `let`
at line ~327 from `[:player :was-playing?]`.)

- [ ] **Step 3: `::audio-load` — completed restarts from 0**

In `::audio-load` (line ~524), replace:

```clojure
         start     (get-in db [:player :data :user_episode :progress_seconds] 0)
```

with:

```clojure
         start     (pb/resume-start
                     (get-in db [:player :data :user_episode :completed])
                     (get-in db [:player :data :user_episode :progress_seconds]))
```

- [ ] **Step 4: `::audio-ended` — clear episode-id so a finished id can't linger**

The current `::audio-ended` (lines ~505-511) is:

```clojure
(rf/reg-event-fx
 ::audio-ended
 (fn [{:keys [db]} _]
   (let [autoplay? (get-in db [:audio :autoplay?])
         next-id   (get-in db [:player :data :next_id])]
     (when (and autoplay? next-id)
       {:dispatch [::navigate :player {:episode-id next-id :autoplay? true}]}))))
```

Replace it with (always clear audio identity; keep the autoplay-next behavior):

```clojure
(rf/reg-event-fx
 ::audio-ended
 (fn [{:keys [db]} _]
   (let [autoplay? (get-in db [:audio :autoplay?])
         next-id   (get-in db [:player :data :next_id])
         db'       (-> db
                       (assoc-in [:audio :episode-id] nil)
                       (assoc-in [:audio :playing?]   false))]
     (if (and autoplay? next-id)
       {:db db' :dispatch [::navigate :player {:episode-id next-id :autoplay? true}]}
       {:db db'}))))
```

- [ ] **Step 5: Compile-verify the app build (no DOM test harness for events)**

Run:
```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app && node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"
```
Expected: `app` compiles with no warnings/errors; `test` still green
(the decision logic these branches delegate to is covered by Tasks 2–4).

- [ ] **Step 6: Commit**

```bash
git add src/cljs/buzz_bot/events.cljs
git commit -m "fix: re-apply server position on player-open; clear audio id on ended (bug 1)"
```

---

## Task 6: Wire Bugs 2 & 3 into `audio.cljs`

**Files:**
- Modify: `src/cljs/buzz_bot/audio.cljs`

- [ ] **Step 1: Add the `playback` require**

In `src/cljs/buzz_bot/audio.cljs` change the `ns` form from:

```clojure
(ns buzz-bot.audio
  (:require [re-frame.core :as rf]
            [re-frame.db]))
```

to:

```clojure
(ns buzz-bot.audio
  (:require [re-frame.core :as rf]
            [re-frame.db]
            [buzz-bot.playback :as pb]))
```

- [ ] **Step 2: Add `flush-progress!` and replace the interval with a trust-gated save**

> **Controller correction (applied during execution):** `trustworthy-position?`
> and `flush-progress!` are defined **before `wire-listeners!`** (immediately
> after the stall-recovery helpers, before the `;; ── Listener wiring` comment),
> NOT at the `start-progress-interval!` location. Reason: the `pause` listener
> inside `wire-listeners!` (Step 3) calls `flush-progress!`; defining it later
> in the same namespace is a ClojureScript forward reference that emits an
> "undeclared Var" warning and would fail the "compiles clean" gate. The two
> helper defns' bodies are exactly as shown below; only their file position
> moved earlier. `start-progress-interval!` is then replaced in place with just
> the gated version (it references the now-earlier `trustworthy-position?`).

Replace the entire `start-progress-interval!` block (lines ~212-219):

```clojure
(defn- start-progress-interval! []
  (js/setInterval
   (fn []
     (when-not (.-paused (el))
       (when-let [ep-id (get-in @re-frame.db/app-db [:audio :episode-id])]
         (rf/dispatch [:buzz-bot.events/save-progress ep-id
                       (js/Math.floor (.-currentTime (el)))]))))
   5000))
```

with:

```clojure
(defn- trustworthy-position? []
  (pb/should-save-progress? {:recovering? @recovering?
                             :ready-state (.-readyState (el))
                             :seeking?    (.-seeking (el))}))

;; Persist the current position now (pause / app-hide / pagehide). Trust-gated
;; so a transient .load() reset (stall-recovery, :switch-src, download swap)
;; can never write a spurious 0 over good progress (bug 3).
(defn- flush-progress! []
  (when (trustworthy-position?)
    (when-let [ep-id (get-in @re-frame.db/app-db [:audio :episode-id])]
      (rf/dispatch [:buzz-bot.events/save-progress ep-id
                    (js/Math.floor (.-currentTime (el)))]))))

(defn- start-progress-interval! []
  (js/setInterval
   (fn []
     (when (and (not (.-paused (el))) (trustworthy-position?))
       (when-let [ep-id (get-in @re-frame.db/app-db [:audio :episode-id])]
         (rf/dispatch [:buzz-bot.events/save-progress ep-id
                       (js/Math.floor (.-currentTime (el)))]))))
   5000))
```

(`recovering?` is the private atom defined at audio.cljs ~line 61, in scope
here.)

- [ ] **Step 3: Flush on `pause`**

In `wire-listeners!`, the current `pause` handler (lines ~132-136) is:

```clojure
    (.addEventListener audio "pause"
      (fn []
        (cancel-stall-timer!)
        (set-playback-state! "paused")
        (rf/dispatch [:buzz-bot.events/audio-paused])))
```

Replace it with (flush AFTER the paused dispatch; `flush-progress!` reads the
element's `currentTime` directly so ordering is irrelevant to correctness):

```clojure
    (.addEventListener audio "pause"
      (fn []
        (cancel-stall-timer!)
        (set-playback-state! "paused")
        (rf/dispatch [:buzz-bot.events/audio-paused])
        (flush-progress!)))
```

- [ ] **Step 4: Flush on `visibilitychange`(hidden) and `pagehide`**

Replace the `init!` block (lines ~223-226):

```clojure
(defn init! []
  (wire-listeners!)
  (wire-media-session!)
  (start-progress-interval!))
```

with:

```clojure
(defn init! []
  (wire-listeners!)
  (wire-media-session!)
  (start-progress-interval!)
  ;; Telegram's WebView suspends/throttles the 5 s interval when the Mini App
  ;; is backgrounded/closed; flush the position before that happens (bug 2).
  (.addEventListener js/document "visibilitychange"
    (fn [] (when (.-hidden js/document) (flush-progress!))))
  (.addEventListener js/window "pagehide" (fn [] (flush-progress!))))
```

- [ ] **Step 5: Compile-verify both builds**

Run:
```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app && node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"
```
Expected: `app` compiles clean; `test` still green (smoke + 3 pure-fn deftests).

- [ ] **Step 6: Commit**

```bash
git add src/cljs/buzz_bot/audio.cljs
git commit -m "fix: flush progress on pause/hide; trust-gate all saves (bugs 2 & 3)"
```

---

## Task 7: Build, deploy & manual verification (OPERATOR-RUN)

**Files:** none (operational). **Do NOT auto-run** — this is the user's
deploy step (mirrors prior plans). Hand these to the user.

- [ ] **Step 1: Release build**

```bash
nix-shell -p nodejs -p openjdk --run "npm ci --prefer-offline && node node_modules/.bin/shadow-cljs release app"
```
Expected: produces `public/js/main.js`; no compile errors.

- [ ] **Step 2: Deploy**

Run `k8s/deploy.sh` (it runs the same release build, exports the image,
imports into k3s, rolls out).

- [ ] **Step 3: Verify against success criteria (manual, in the Mini App)**

1. Open an episode, listen ~1 min, **pause**, navigate away, reopen → resumes
   at the saved position (no "play another episode first").
2. Listen, **force-close/background** the Mini App mid-play, reopen → resumes
   within ≤5 s of where you were.
3. While playing, induce a stall/cache-switch (toggle network briefly), let it
   recover → the position never jumps to 0 afterwards (check via reopening, or
   `psql … SELECT progress_seconds FROM user_episodes WHERE …`).
4. Finish an episode (or open one with `completed=true`) → it starts at 0.
5. Seek backward deliberately, leave, reopen → resumes at the rewound point
   (exact position preserved; server unchanged).

- [ ] **Step 4: Final commit (only if operational tweaks were needed)**

```bash
git add -A -- src/cljs shadow-cljs.edn package.json && \
  git commit -m "chore: playback resume fix deployed" || echo "nothing to commit"
```

---

## Self-review notes (author)

- **Spec coverage:** §Bug1 → Task 5 (steps 2–4); §Bug2 → Task 6 (steps 3–4);
  §Bug3 → Task 6 step 2; §pure module → Tasks 2–4; §tests/harness → Task 1 +
  the `playback_test` deftests; §server-unchanged → no task touches Crystal/SQL
  (explicit); §success-criteria → Task 7 step 3. The spec's "`::player-loaded`
  event tests (a)–(d)" are realized by the exhaustive `should-skip-reload?` +
  `resume-start` deftests (documented in the Testing-strategy note).
- **Placeholders:** none — full code in every code step; exact `nix-shell`
  commands; before/after blocks quote the current source verbatim.
- **Type/name consistency:** `pb/resume-start` (2-arg completed,progress),
  `pb/should-skip-reload?` (`{:same-episode? :was-playing?}`),
  `pb/should-save-progress?` (`{:recovering? :ready-state :seeking?}`) — defined
  Tasks 2–4, consumed identically in Tasks 5–6. `trustworthy-ready-state` (2)
  defined once in playback.cljs. `flush-progress!`/`trustworthy-position?`
  defined Task 6 step 2, used in steps 3–4.
- **Ordering:** harness (1) → pure TDD (2–4) → consumers (5–6) → operator (7).
  Each consumer task only references already-defined pure fns.
