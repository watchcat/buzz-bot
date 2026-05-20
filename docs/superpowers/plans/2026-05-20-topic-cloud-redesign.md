# Topic Cloud Visual Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the `/topics` tag-cloud as a heatmap-encoded log-scaled cloud (size + opacity + weight all reflect frequency), with long-press to hide via Telegram-themed `showConfirm`, replacing the broken hover-× pattern.

**Architecture:** Pure logic (`tag-style` formula) extracted to a focused new namespace `buzz-bot.tag-cloud` with cljs.test coverage (follows the playback-fix pattern from #114). The view component in `topics.cljs` is rewritten to consume it, add pointer-event long-press timers, and render a dismissible first-run hint. CSS rewrite drops the bounded container. One new boolean (`:cloud-hint-dismissed?`) in app-db, read from localStorage at boot.

**Tech Stack:** ClojureScript + Reagent + re-frame + shadow-cljs (`:node-test` target for unit tests, `:browser`/`:release` for the app) + plain CSS.

---

## File structure

| Action | File | Responsibility |
|---|---|---|
| Create | `src/cljs/buzz_bot/tag_cloud.cljs` | Pure `tag-style` function: maps `(count, min-count, max-count)` → `{:font-size, :font-weight, :opacity}` via log-scaled formula. No re-frame, no DOM. |
| Create | `test/buzz_bot/tag_cloud_test.cljs` | `cljs.test` unit tests for `tag-style`: boundaries (min/max count), degenerate case (all-equal), weight threshold around ratio 0.6, monotonic increase. |
| Modify | `src/cljs/buzz_bot/db.cljs:14` | Append `:cloud-hint-dismissed?` (initialised from `localStorage.getItem "topics-cloud-hint-dismissed"`) inside the existing `:topics` map. |
| Modify | `src/cljs/buzz_bot/events.cljs` | Add `::dismiss-tag-cloud-hint` event-db handler (write LS + assoc-in db). |
| Modify | `src/cljs/buzz_bot/subs.cljs` | Add `::topics-cloud-hint-dismissed?` sub. |
| Modify | `src/cljs/buzz_bot/views/topics.cljs:45-74` | Replace `tag-font-size` + `tag-cloud` with the new heatmap-styled, long-press-aware components. Require the new `buzz-bot.tag-cloud` ns. |
| Modify | `public/css/app.css:1809-1886` | Replace the entire `Tag Cloud` block: drop `--secondary-bg` box, drop `max-height`+overflow, add pill active state, restyle hint + show-more to quieter typography. |

Operator-run shadow-cljs release + deploy + visual smoke is the final task; no Crystal changes anywhere.

---

## Task 1: pure `tag-style` (TDD)

**Files:**
- Create: `src/cljs/buzz_bot/tag_cloud.cljs`
- Create: `test/buzz_bot/tag_cloud_test.cljs`

- [ ] **Step 1: Create the empty module file so the test require resolves**

Write `src/cljs/buzz_bot/tag_cloud.cljs` with this exact content:

```clojure
(ns buzz-bot.tag-cloud)
```

- [ ] **Step 2: Write the failing test for the min-count boundary**

Write `test/buzz_bot/tag_cloud_test.cljs` with this exact content:

```clojure
(ns buzz-bot.tag-cloud-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.tag-cloud :as tc]))

(deftest tag-style-min-count-test
  (testing "min count → smallest size, lowest opacity, lighter weight"
    (let [s (tc/tag-style 1 1 100)]
      (is (= 13.0 (:font-size s)))
      (is (= 400 (:font-weight s)))
      ;; opacity = 0.45 + 0 * 0.55 = 0.45
      (is (< 0.449 (:opacity s) 0.451)))))
```

- [ ] **Step 3: Run the test to verify it fails (function undefined)**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`

Expected: failing test with a CLJS compilation/runtime error referencing `tc/tag-style` (function does not exist).

- [ ] **Step 4: Implement `tag-style` to pass the first test**

Replace the contents of `src/cljs/buzz_bot/tag_cloud.cljs` with:

```clojure
(ns buzz-bot.tag-cloud
  "Pure visual-encoding helpers for the /topics tag cloud.

   `tag-style` maps a tag's count + the cloud's min/max counts to three
   visual channels (size, weight, opacity) via a log-scaled ratio in [0, 1].
   No re-frame, no DOM — testable in isolation.")

(def ^:private MIN-PX  13)
(def ^:private MAX-PX  32)
(def ^:private MIN-OP  0.45)
(def ^:private MAX-OP  1.0)
(def ^:private WEIGHT-THRESHOLD 0.6)

(defn- ratio
  "Logarithmic position of `count` in [min-count, max-count], in [0, 1].
   Degenerate case (all tags same count) → 0.5 (middle)."
  [count min-count max-count]
  (if (= min-count max-count)
    0.5
    (/ (Math/log (inc (- count min-count)))
       (Math/log (inc (- max-count min-count))))))

(defn tag-style
  "Returns a style map for a tag with `count` in the cloud, given the cloud's
   `min-count` and `max-count`. Three channels:
     :font-size   — Number (px). Caller formats with (str sz \"px\").
     :font-weight — 400 or 600 (two-tier).
     :opacity     — Number in [0.45, 1.0]."
  [count min-count max-count]
  (let [r (ratio count min-count max-count)]
    {:font-size   (+ MIN-PX (* r (- MAX-PX MIN-PX)))
     :font-weight (if (>= r WEIGHT-THRESHOLD) 600 400)
     :opacity     (+ MIN-OP (* r (- MAX-OP MIN-OP)))}))
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`
Expected: 1 test, 3 assertions, 0 failures.

- [ ] **Step 6: Add the failing test for max-count boundary**

Append to `test/buzz_bot/tag_cloud_test.cljs`:

```clojure
(deftest tag-style-max-count-test
  (testing "max count → largest size, full opacity, heavier weight"
    (let [s (tc/tag-style 100 1 100)]
      (is (= 32.0 (:font-size s)))
      (is (= 600 (:font-weight s)))
      ;; opacity = 0.45 + 1 * 0.55 = 1.0
      (is (< 0.999 (:opacity s) 1.001)))))
```

- [ ] **Step 7: Run the tests — should pass**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`
Expected: 2 tests, 6 assertions, 0 failures.

- [ ] **Step 8: Add the failing test for the degenerate "all equal" case**

Append to `test/buzz_bot/tag_cloud_test.cljs`:

```clojure
(deftest tag-style-all-equal-test
  (testing "all tags same count → ratio 0.5 → middle values"
    (let [s (tc/tag-style 5 5 5)]
      ;; 13 + 0.5 * 19 = 22.5
      (is (= 22.5 (:font-size s)))
      ;; ratio 0.5 is < 0.6 threshold, so 400
      (is (= 400 (:font-weight s)))
      ;; opacity = 0.45 + 0.5 * 0.55 = 0.725
      (is (< 0.724 (:opacity s) 0.726)))))
```

- [ ] **Step 9: Run the tests — should pass**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`
Expected: 3 tests, 9 assertions, 0 failures.

- [ ] **Step 10: Add the failing test for weight threshold (ratio 0.6 boundary)**

Append to `test/buzz_bot/tag_cloud_test.cljs`:

```clojure
(deftest tag-style-weight-threshold-test
  (testing "weight = 400 below ratio 0.6"
    ;; count=5 in [1, 100] → log(5)/log(100) ≈ 0.35 → < 0.6 → 400
    (is (= 400 (:font-weight (tc/tag-style 5 1 100)))))
  (testing "weight = 600 at or above ratio 0.6"
    ;; count=20 in [1, 100] → log(20)/log(100) ≈ 0.65 → ≥ 0.6 → 600
    (is (= 600 (:font-weight (tc/tag-style 20 1 100))))))
```

- [ ] **Step 11: Run the tests — should pass**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`
Expected: 4 tests, 11 assertions, 0 failures.

- [ ] **Step 12: Add the failing test for monotonic size**

Append to `test/buzz_bot/tag_cloud_test.cljs`:

```clojure
(deftest tag-style-monotonic-test
  (testing "size strictly increases with count over a typical range"
    (let [sizes (map #(:font-size (tc/tag-style % 1 100)) [1 5 10 25 50 100])]
      (is (apply < sizes))))
  (testing "opacity strictly increases with count over a typical range"
    (let [ops (map #(:opacity (tc/tag-style % 1 100)) [1 5 10 25 50 100])]
      (is (apply < ops)))))
```

- [ ] **Step 13: Run the tests — should pass**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`
Expected: 5 tests, 13 assertions, 0 failures.

- [ ] **Step 14: Commit**

```bash
git add src/cljs/buzz_bot/tag_cloud.cljs test/buzz_bot/tag_cloud_test.cljs
git commit -m "feat: pure tag-style helper for log-scaled heatmap cloud

New ns buzz-bot.tag-cloud with a single public fn tag-style that maps a
tag's count + the cloud's min/max counts to a style map (font-size,
font-weight, opacity). Log-scaled ratio handles power-law tag-frequency
distributions: rare tags stay readable, popular ones get presence.

5 unit tests cover both boundaries, the all-equal degenerate case, the
weight threshold at ratio 0.6, and monotonic increase. Pattern mirrors
buzz-bot.playback (pure fns extracted from views for testability).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

DO NOT push — controller pushes after all tasks complete.

---

## Task 2: dismiss-hint event + sub + db wiring

**Files:**
- Modify: `src/cljs/buzz_bot/db.cljs` (line 14 — the existing `:topics` map)
- Modify: `src/cljs/buzz_bot/events.cljs` (append new event)
- Modify: `src/cljs/buzz_bot/subs.cljs` (append new sub)

- [ ] **Step 1: Extend `:topics` in default-db with `:cloud-hint-dismissed?`**

Open `src/cljs/buzz_bot/db.cljs`. Find this exact line (line 14):

```clojure
   :topics    {:tags [] :episodes [] :loading? false :selected-tag nil :has-more-tags? false :tag-offset 0}
```

Replace it with:

```clojure
   :topics    {:tags [] :episodes [] :loading? false :selected-tag nil :has-more-tags? false :tag-offset 0
               :cloud-hint-dismissed? (= "1" (.getItem js/localStorage "topics-cloud-hint-dismissed"))}
```

Why: `default-db` is a `def` captured at app boot, so this reads localStorage once per app load. The event handler writes to localStorage, so the next boot picks up the new value.

- [ ] **Step 2: Add the `::dismiss-tag-cloud-hint` event handler**

Open `src/cljs/buzz_bot/events.cljs`. Locate the existing `::hide-topic` handler (around line 172). Immediately AFTER that handler's closing `))`, insert:

```clojure
(rf/reg-event-db
  ::dismiss-tag-cloud-hint
  (fn [db _]
    (js/localStorage.setItem "topics-cloud-hint-dismissed" "1")
    (assoc-in db [:topics :cloud-hint-dismissed?] true)))
```

Why: write LS first (persists across sessions), then mutate db (re-renders the view). Inline LS call matches the pattern used elsewhere in this file (lines 534, 596, 618).

- [ ] **Step 3: Add the `::topics-cloud-hint-dismissed?` subscription**

Open `src/cljs/buzz_bot/subs.cljs`. Find the existing `::topics-has-more-tags?` sub (around lines 67-69). Immediately after its closing `))`, insert:

```clojure
(rf/reg-sub ::topics-cloud-hint-dismissed?
  :<- [::topics]
  (fn [t _] (:cloud-hint-dismissed? t)))
```

Why: chains off the existing `::topics` sub for consistency with the siblings; returns the boolean directly.

- [ ] **Step 4: Compile the test build to verify no syntax errors**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`
Expected: 5 tests, 13 assertions, 0 failures (still — the Task 1 tests don't exercise the new event/sub, but the compile would fail if we introduced a CLJS syntax error).

- [ ] **Step 5: Commit**

```bash
git add src/cljs/buzz_bot/db.cljs src/cljs/buzz_bot/events.cljs src/cljs/buzz_bot/subs.cljs
git commit -m "feat: dismiss-tag-cloud-hint event + sub + localStorage init

Adds :cloud-hint-dismissed? boolean under :topics in app-db, initialised
from localStorage at boot. New ::dismiss-tag-cloud-hint event-db handler
writes 'topics-cloud-hint-dismissed' = '1' to localStorage and flips the
flag. New ::topics-cloud-hint-dismissed? sub for view consumption.

Backs the dismissible first-run hint in the topic-cloud redesign.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: rewrite `tag-cloud` component in topics.cljs

**Files:**
- Modify: `src/cljs/buzz_bot/views/topics.cljs` (replace lines 45-74 + add require + add sub binding in `view`)

- [ ] **Step 1: Update the ns require to include the new tag-cloud namespace**

Open `src/cljs/buzz_bot/views/topics.cljs`. Find the existing `:require` block (lines 2-6):

```clojure
(ns buzz-bot.views.topics
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.views.utils :refer [img-proxy]]))
```

Replace it with:

```clojure
(ns buzz-bot.views.topics
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.tag-cloud :as tc]
            [buzz-bot.views.utils :refer [img-proxy]]))
```

- [ ] **Step 2: Delete the existing `tag-font-size` and `tag-cloud` functions**

In `src/cljs/buzz_bot/views/topics.cljs`, locate and DELETE the two functions at lines 45-74:

```clojure
(defn- tag-font-size [count min-count max-count]
  (if (= min-count max-count)
    16
    (+ 11 (* (/ (- count min-count) (- max-count min-count)) 11))))

(defn- tag-cloud [tags selected-tag has-more-tags?]
  (let [min-count (apply min (map :count tags))
        max-count (apply max (map :count tags))]
    [:div.tag-cloud-section
     [:div.tag-cloud
      (for [{:keys [tag count]} tags]
        ^{:key tag}
        [:span.tag-cloud-item
         {:class    (when (= tag selected-tag) "tag-cloud-item--active")
          :style    {:font-size (str (tag-font-size count min-count max-count) "px")}
          :on-click (fn [e]
                      (.stopPropagation e)
                      (if (= tag selected-tag)
                        (rf/dispatch [::events/clear-tag])
                        (rf/dispatch [::events/select-tag tag])))}
         tag
         [:span.tag-cloud-hide
          {:on-click (fn [e]
                       (.stopPropagation e)
                       (rf/dispatch [::events/hide-topic tag]))}
          "×"]])]
     (when has-more-tags?
       [:button.tag-cloud-toggle
        {:on-click #(rf/dispatch [::events/load-more-tags])}
        "Show more"])]))
```

- [ ] **Step 3: Insert the new `tag-cloud-item` + `tag-cloud` components in their place**

In the same location (where the deleted code was), insert these two new component definitions:

```clojure
(defn- tag-cloud-item
  "Single tag span with size/opacity/weight from tag-style, click-to-filter,
   and pointer-event long-press-to-hide. Form-2 component so each instance
   keeps its own timer in an r/atom. Outer accepts (but discards) the initial
   args Reagent passes at mount; the inner fn re-binds them on every render."
  [_initial-tag _min-c _max-c]
  (let [timer  (r/atom nil)
        cancel #(when @timer
                  (js/clearTimeout @timer)
                  (reset! timer nil))]
    (fn [{:keys [tag count selected?]} min-c max-c]
      [:span.tag-cloud-item
       {:class             (when selected? "tag-cloud-item--active")
        :style             (when-not selected?
                             (let [s (tc/tag-style count min-c max-c)]
                               {:font-size   (str (:font-size s) "px")
                                :font-weight (:font-weight s)
                                :opacity     (:opacity s)}))
        :on-click          (fn [e]
                             (.stopPropagation e)
                             (if selected?
                               (rf/dispatch [::events/clear-tag])
                               (rf/dispatch [::events/select-tag tag])))
        :on-pointer-down   (fn [_e]
                             (reset! timer
                                     (js/setTimeout
                                      (fn []
                                        (reset! timer nil)
                                        (.showConfirm
                                         js/Telegram.WebApp
                                         (str "Hide \"" tag "\" from your topics?")
                                         (fn [confirmed?]
                                           (when confirmed?
                                             (rf/dispatch
                                              [::events/hide-topic tag])))))
                                      500)))
        :on-pointer-up     cancel
        :on-pointer-leave  cancel
        :on-pointer-cancel cancel}
       tag])))

(defn- tag-cloud [tags selected-tag has-more-tags? hint-dismissed?]
  (let [min-c (apply min (map :count tags))
        max-c (apply max (map :count tags))]
    [:div.tag-cloud-section
     [:div.tag-cloud
      (for [{:keys [tag] :as t} tags]
        ^{:key tag}
        [tag-cloud-item
         (assoc t :selected? (= tag selected-tag))
         min-c
         max-c])]
     (when-not hint-dismissed?
       [:button.tag-cloud-hint
        {:on-click #(rf/dispatch [::events/dismiss-tag-cloud-hint])}
        "Tap to filter · long-press to hide · ×"])
     (when has-more-tags?
       [:button.tag-cloud-toggle
        {:on-click #(rf/dispatch [::events/load-more-tags])}
        "Show more"])]))
```

Why form-2 (`(let [...] (fn [...] ...))`): each `tag-cloud-item` instance needs its OWN long-press timer in an `r/atom` closure. The outer `let` runs once per mount; the inner `fn` runs on every re-render. Same pattern as `view` at the bottom of the file.

- [ ] **Step 4: Wire the hint-dismissed sub into the top-level `view` and pass it to `tag-cloud`**

In `src/cljs/buzz_bot/views/topics.cljs`, find the `view` function (currently at lines 76-108). Locate the `let` binding block that pulls subscriptions:

```clojure
    (let [tags            @(rf/subscribe [::subs/topics-tags])
          episodes        @(rf/subscribe [::subs/topics-episodes])
          loading?        @(rf/subscribe [::subs/topics-loading?])
          selected-tag    @(rf/subscribe [::subs/topics-selected-tag])
          has-more-tags?  @(rf/subscribe [::subs/topics-has-more-tags?])
          playing-id      @(rf/subscribe [::subs/audio-episode-id])]
```

Replace it with:

```clojure
    (let [tags            @(rf/subscribe [::subs/topics-tags])
          episodes        @(rf/subscribe [::subs/topics-episodes])
          loading?        @(rf/subscribe [::subs/topics-loading?])
          selected-tag    @(rf/subscribe [::subs/topics-selected-tag])
          has-more-tags?  @(rf/subscribe [::subs/topics-has-more-tags?])
          hint-dismissed? @(rf/subscribe [::subs/topics-cloud-hint-dismissed?])
          playing-id      @(rf/subscribe [::subs/audio-episode-id])]
```

Then find the line:

```clojure
       (when (seq tags)
         [tag-cloud tags selected-tag has-more-tags?])
```

Replace it with:

```clojure
       (when (seq tags)
         [tag-cloud tags selected-tag has-more-tags? hint-dismissed?])
```

- [ ] **Step 5: Compile to verify there are no CLJS errors**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`
Expected: 5 tests, 13 assertions, 0 failures.

The compile step catches any typo in the rewritten component (missing namespace, malformed map, etc.). The unit tests don't exercise the component directly — Task 5's operator smoke does that.

- [ ] **Step 6: Commit**

```bash
git add src/cljs/buzz_bot/views/topics.cljs
git commit -m "feat(topics): heatmap-cloud component with long-press hide

Rewrites tag-cloud + introduces a form-2 tag-cloud-item component:
- pulls visual encoding (size/weight/opacity) from buzz-bot.tag-cloud/tag-style
- pointer-event long-press (500ms) opens Telegram.WebApp.showConfirm
- selected tag drops heatmap style — pill state takes over via CSS
- first-run hint caption renders when not dismissed (Task 2 sub)

Replaces the broken hover-× hide pattern (no hover on touch) with a
discoverable native-confirm dismissal flow. Calls existing
::select-tag / ::clear-tag / ::hide-topic / ::load-more-tags / new
::dismiss-tag-cloud-hint events.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: rewrite the `.tag-cloud-*` CSS block

**Files:**
- Modify: `public/css/app.css:1809-1886` (replace the entire `Tag Cloud` section block)

- [ ] **Step 1: Replace lines 1809-1886 with the new CSS**

Open `public/css/app.css`. Locate the section starting with:

```css
/* ── Tag Cloud ────────────────────────────────────────────────────── */
```

(around line 1809) and ending at the last rule before the next section. Replace the entire block (through line 1886, inclusive of `.topics-filter-label`) with:

```css
/* ── Tag Cloud ────────────────────────────────────────────────────── */

.tag-cloud-section {
  padding: 0 var(--gap) var(--gap);
}

.tag-cloud {
  display: flex;
  flex-wrap: wrap;
  gap: 12px 14px;
  align-items: baseline;
  padding: 4px 0 12px;
}

.tag-cloud-item {
  cursor: pointer;
  color: var(--text-color);
  line-height: 1.3;
  padding: 4px 6px;
  transition: opacity 0.15s, color 0.15s;
  user-select: none;
  -webkit-user-select: none;
  -webkit-tap-highlight-color: transparent;
}

.tag-cloud-item:active {
  opacity: 0.6;
}

.tag-cloud-item--active {
  padding: 4px 10px;
  border-radius: 999px;
  background: var(--button-color);
  color: var(--button-text-color);
  opacity: 1;
  font-weight: 600;
  font-size: 15px;
}

.tag-cloud-hint {
  display: block;
  width: 100%;
  margin: 4px 0 0;
  padding: 6px 0;
  background: none;
  border: none;
  color: var(--hint-color);
  font-size: 11px;
  text-align: center;
  cursor: pointer;
}

.tag-cloud-hint:active {
  opacity: 0.6;
}

.tag-cloud-toggle {
  display: block;
  width: 100%;
  margin-top: 4px;
  padding: 6px 0;
  background: none;
  border: none;
  color: var(--hint-color);
  font-size: 11px;
  text-align: center;
  cursor: pointer;
}

.tag-cloud-toggle:active {
  opacity: 0.6;
}

.topics-filter-label {
  padding: 6px var(--gap);
  font-size: 13px;
  color: var(--hint-color);
}
```

Key changes from the previous block:
- `.tag-cloud` loses `background`, `border-radius`, `max-height: 40vh`, `overflow-y: auto`.
- New `.tag-cloud-item--active` rule: full pill background using Telegram button vars, fixed 15px size so rare-but-selected tags don't render as tiny pills.
- New `.tag-cloud-hint` rule (replaces `.tag-cloud-hide`, which is gone — the hover-× child no longer exists).
- `.tag-cloud-toggle` hover state removed (no hover on touch) and `:active` opacity dim added for tactile feedback on tap.
- `.tag-cloud-item` gets `user-select: none` + `-webkit-tap-highlight-color: transparent` so long-press doesn't trigger iOS text-selection and the gray tap-flash doesn't show on Android.

- [ ] **Step 2: Verify the build still compiles (only the test build — CSS is static)**

Run: `nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js"`
Expected: 5 tests, 13 assertions, 0 failures (CSS doesn't affect tests, this just confirms we didn't accidentally break a CLJS file).

- [ ] **Step 3: Commit**

```bash
git add public/css/app.css
git commit -m "style(topics): rewrite tag-cloud CSS — heatmap-friendly, no box

Drops the bounded --secondary-bg container (caging the cloud), drops
internal max-height/scroll (Show more handles overflow), removes the
.tag-cloud-hide hover-only × child (long-press replaces it). Adds
.tag-cloud-item--active pill state, .tag-cloud-hint caption styling,
:active opacity dim on tap targets, and touch-friendly resets
(user-select: none, transparent tap-highlight).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: shadow-cljs release + deploy + visual smoke (USER-RUN)

This task is **operator-run**. It compiles, deploys, and verifies the integrated cloud against the live Mini App. No automated browser checks — visual + interaction is operator-judged.

**Files:** none modified. Operator execution only.

- [ ] **Step 1: Push commits to main**

```bash
cd /Users/watchcat/work/crystal/buzz-bot
git push origin main
```

Expected: `main -> main` push success. Four commits go up: tag-cloud helper + tests, event/sub/db wiring, component rewrite, CSS rewrite.

- [ ] **Step 2: Deploy via the existing pipeline**

```bash
./k8s/deploy.sh
```

Expected (final lines):
```
==> Rolling out deployment
deployment.apps/buzz-bot restarted
deployment "buzz-bot" successfully rolled out
==> Done
```

The deploy script runs `shadow-cljs release app` internally, so any CLJS-release-only compile error (e.g., undefined symbol that escaped node-test) would surface here.

- [ ] **Step 3: Wait for the pod to come up healthy**

```bash
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get pods -l app=buzz-bot
```

Expected: STATUS=Running, RESTARTS=0, age < 5m.

- [ ] **Step 4: Open the Mini App and navigate to /topics**

Open https://app.buzz-bot.top in Telegram (or use the bot's `/start` button if convenient). Navigate to the Topics tab.

Visual checks (eyeball):
- Cloud sits against the page background — no rounded box.
- Tags clearly vary in size — biggest tags noticeably larger than the smallest. Rare tags visibly faded (not invisible).
- Hint caption reads "Tap to filter · long-press to hide · ×" below the cloud.

- [ ] **Step 5: Tap a tag — filter applies, tag becomes a pill**

Tap any non-selected tag. Expected: filter applies (episode list below updates), the tag transforms into a solid `--button-color` pill with white text. Tap it again — pill clears, filter removed.

- [ ] **Step 6: Long-press a tag — confirm sheet appears**

Hold any tag for ~1 second without lifting. Expected: a Telegram-styled confirm sheet appears: "Hide \"<tag>\" from your topics?". Tap "Cancel" — nothing happens, sheet closes. Long-press again, tap "OK" — the tag disappears from the cloud, the cloud reflows.

- [ ] **Step 7: Dismiss the hint caption**

Tap the hint caption ("Tap to filter · long-press to hide · ×"). Expected: caption disappears immediately. Reload the Mini App (close + reopen). Expected: caption stays dismissed (localStorage persistence).

- [ ] **Step 8: Light/dark theme switch**

In Telegram settings, toggle the WebApp theme between light and dark (Settings → Chat Settings → some theme toggles affect the WebApp). Re-open the Mini App. Expected: cloud remains readable in both modes — text colors automatically use the new theme vars; pill colors automatically use the new accent.

- [ ] **Step 9: Sanity-check the rest of the app didn't regress**

Open the Inbox and Player views briefly — verify the rewrite of `topics.cljs` didn't accidentally break anything outside the topics view. Episode list renders, an episode plays.

- [ ] **Step 10: Report results**

Paste a short summary of what you observed in each step (pass/fail, plus any unexpected behavior). If anything failed, capture the browser DevTools Network/Console output if possible.

---

## Out-of-scope follow-ups (documented for trace)

- Cloud animation (fade-in on first paint, cross-fade on filter change) — could add later if the static cloud feels too static.
- A second-tier "Manage topics" view that lists hidden topics with an un-hide action.
- Localised hint copy (currently English only).
- Tighter touch-target audit (some 13px tags + 4px padding = 21px height — under the 32px guideline; if real users hit this, bump min-px to 14 or increase min vertical padding).
- A "shuffle" or "explore" affordance on the cloud (random tag → set as filter) — fun but out of scope.
