# Tab Bar Pill + Dubbed-List Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the bottom-nav "Bookmarks" tab from wrapping (active-tab expanding pill, icon-only inactive) and make the Inbox "Latest dubbed" widget actually refresh — both on the ↻ button and proactively when a dub finishes.

**Architecture:** Two independent front-end changes in the ClojureScript / re-frame Mini App (`src/cljs/buzz_bot/…`, built with shadow-cljs to `public/js/main.js`). Feature 2's one piece of real logic (the fetch guard) is extracted to a pure fn and unit-tested under the existing node-test harness; the rest (CSS, hiccup markup, re-frame dispatch wiring) is verified by a production build + manual checklist, since it isn't meaningfully unit-testable.

**Tech Stack:** ClojureScript, reagent, re-frame, shadow-cljs (`:app` build → `public/js/main.js`, `:test` build → node), plain CSS (`public/css/app.css`).

---

## Baseline notes (read before starting)

- `public/js/main.js` is a **tracked build artifact** and already carries a pre-existing uncommitted rebuild (unrelated to this work). The build in Task 4 regenerates it from current source; that supersedes the stale diff. `public/js/main.js.map` is **not** tracked — do not add it.
- Untracked files in the tree (`.superpowers/`, `docs/expenses.md`, `docs/ideas.md`, `k8s/tg-api-ingress.yaml`) are unrelated — leave them alone.
- Build/test commands (shadow-cljs is a local devDependency):
  - Unit tests: `npm test` (= `node node_modules/.bin/shadow-cljs compile test && node out/node-tests.js`)
  - Production app build: `node node_modules/.bin/shadow-cljs release app` → regenerates `public/js/main.js`
- The `:test` build runs every ns whose name ends in `-test` (`:ns-regexp "-test$"`).

## File Structure

| File | Change |
|---|---|
| `src/cljs/buzz_bot/events.cljs` | Add pure `dubbed-fetch` helper; give `::fetch-inbox-dubbed` a `force?` arg (Task 1) |
| `test/buzz_bot/events_test.cljs` | **New** — unit tests for `dubbed-fetch` (Task 1) |
| `src/cljs/buzz_bot/views/inbox.cljs` | Inbox ↻ handler also force-refetches dubbed list (Task 2) |
| `src/cljs/buzz_bot/events/dub.cljs` | `::sse-event` `:done` → mark dubbed stale + `:dispatch-n` both events (Task 2) |
| `src/cljs/buzz_bot/views/layout.cljs` | `tab-btn` takes icon+label, renders two spans (Task 3) |
| `public/css/app.css` | `.tab-btn` pill rules + `.tab-label` animation (Task 3) |
| `public/js/main.js` | Rebuilt artifact (Task 4) |

---

## Task 1: Dubbed-fetch guard — pure helper + `force?` arg (TDD)

**Files:**
- Create: `test/buzz_bot/events_test.cljs`
- Modify: `src/cljs/buzz_bot/events.cljs` (currently lines ~105–115)

- [ ] **Step 1: Write the failing test**

Create `test/buzz_bot/events_test.cljs`:

```clojure
(ns buzz-bot.events-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.events :as events]))

(deftest dubbed-fetch-skips-when-loaded-and-not-forced
  ;; Preserves the lazy-cache behaviour: navigating to Inbox a second time
  ;; must NOT refetch.
  (is (= {} (events/dubbed-fetch {:inbox-dubbed {:loaded? true}} false))))

(deftest dubbed-fetch-issues-request-when-not-loaded
  (let [fx (events/dubbed-fetch {:inbox-dubbed {:loaded? false}} false)]
    (is (contains? fx :buzz-bot.fx/http-fetch))
    (is (= "/inbox/dubbed" (get-in fx [:buzz-bot.fx/http-fetch :url])))
    (is (true? (get-in fx [:db :inbox-dubbed :loading?])))))

(deftest dubbed-fetch-force-overrides-loaded-guard
  ;; The ↻ button and dub-complete path pass force? = true to bypass the guard.
  (let [fx (events/dubbed-fetch {:inbox-dubbed {:loaded? true}} true)]
    (is (contains? fx :buzz-bot.fx/http-fetch))
    (is (= [:buzz-bot.events/inbox-dubbed-loaded]
           (get-in fx [:buzz-bot.fx/http-fetch :on-ok])))))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test`
Expected: compile/run fails because `buzz-bot.events/dubbed-fetch` does not exist (a "Var ... does not exist" / undefined error referencing `dubbed-fetch`). The other suites (smoke, inbox-dubbed, playback, etc.) still run.

> If `node out/node-tests.js` instead throws at *load time* referencing a browser global (`window`/`document`/`EventSource`) from a ns transitively required by `buzz-bot.events`, that is a pre-existing load-time issue — STOP and report it rather than restructuring. (Expected: it loads fine — `events`, `fx`, `dub`, `delivery`, `playback` are registration-only namespaces.)

- [ ] **Step 3: Implement the helper and rewire the event**

In `src/cljs/buzz_bot/events.cljs`, replace the existing block (lines ~105–115):

```clojure
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
```

with:

```clojure
(defn dubbed-fetch
  "Effect map for (re)fetching the inbox 'Latest dubbed' widget.
   When force? is false and the list is already loaded, returns {} (no-op,
   preserving lazy caching on Inbox navigation). force? = true (the ↻ button
   and the dub-complete path) bypasses the loaded? guard and always refetches."
  [db force?]
  (if (and (not force?) (get-in db [:inbox-dubbed :loaded?]))
    {}
    {:db (assoc-in db [:inbox-dubbed :loading?] true)
     ::buzz-bot.fx/http-fetch
     {:method :get
      :url    "/inbox/dubbed"
      :on-ok  [::inbox-dubbed-loaded]
      :on-err [::inbox-dubbed-err]}}))

(rf/reg-event-fx
 ::fetch-inbox-dubbed
 (fn [{:keys [db]} [_ force?]]
   (dubbed-fetch db force?)))
```

(`::inbox-dubbed-loaded` / `::inbox-dubbed-err` keep resolving to `:buzz-bot.events/…`; `::buzz-bot.fx/http-fetch` resolves to `:buzz-bot.fx/http-fetch`, matching the test.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test`
Expected: all suites pass, including the three new `events-test` deftests.

- [ ] **Step 5: Commit**

```bash
git add src/cljs/buzz_bot/events.cljs test/buzz_bot/events_test.cljs
git commit -m "feat(inbox-dubbed): force-refetch guard for dubbed list"
```

---

## Task 2: Wire manual + proactive dubbed refresh

No unit test — these are re-frame dispatch/wiring changes verified by the build + manual checklist in Task 4. Make the edits exactly.

**Files:**
- Modify: `src/cljs/buzz_bot/views/inbox.cljs` (Refresh ↻ handler, currently lines ~117–120)
- Modify: `src/cljs/buzz_bot/events/dub.cljs` (`::sse-event`, currently lines ~153–172)

- [ ] **Step 1: Inbox ↻ button also force-refetches the dubbed list**

In `src/cljs/buzz_bot/views/inbox.cljs`, change the Refresh button's `:on-click` from:

```clojure
            {:title    "Refresh"
             :class    (when loading? "btn-icon--spinning")
             :on-click (fn [_]
                         (when @debounce (js/clearTimeout @debounce))
                         (reset! query-atom "")
                         (rf/dispatch [::events/fetch-inbox]))}
```

to:

```clojure
            {:title    "Refresh"
             :class    (when loading? "btn-icon--spinning")
             :on-click (fn [_]
                         (when @debounce (js/clearTimeout @debounce))
                         (reset! query-atom "")
                         (rf/dispatch [::events/fetch-inbox])
                         (rf/dispatch [::events/fetch-inbox-dubbed true]))}
```

- [ ] **Step 2: Dub-complete marks the widget stale and refetches it**

In `src/cljs/buzz_bot/events/dub.cljs`, the `::sse-event` handler currently is:

```clojure
(rf/reg-event-fx
 ::sse-event
 (fn [{:keys [db]} [_ episode-id lang data]]
   ;; Ignore if we've navigated away from this episode.
   (when (= (str episode-id) (str (get-in db [:player :data :episode :id])))
     (let [status (keyword (:status data))]
       (cond-> {:db (-> db
                        (assoc-in [:dub :statuses lang :status]    status)
                        (assoc-in [:dub :statuses lang :step]      (:step data))
                        (assoc-in [:dub :statuses lang :synth-pct] (:pct data))
                        (cond-> (= status :done)
                          (-> (assoc-in [:dub :statuses lang :r2-url]      (:r2_url data))
                              (assoc-in [:dub :statuses lang :translation] (:translation data))))
                        (cond-> (= status :failed)
                          (assoc-in [:dub :statuses lang :error] (:error data))))}
         (= status :done)
         (assoc :dispatch [:buzz-bot.events/fetch-subtitles episode-id lang])
         ;; Terminal — stop any reconnect/poll machinery
         (#{:done :failed} status)
         (assoc ::fx/stop-dub-poll nil))))))
```

Change two things: (a) inside the `:done` `:db` branch, also mark the dubbed widget stale; (b) replace the single `:dispatch` on `:done` with `:dispatch-n` firing both the existing subtitle fetch and a forced dubbed refetch. Result:

```clojure
(rf/reg-event-fx
 ::sse-event
 (fn [{:keys [db]} [_ episode-id lang data]]
   ;; Ignore if we've navigated away from this episode.
   (when (= (str episode-id) (str (get-in db [:player :data :episode :id])))
     (let [status (keyword (:status data))]
       (cond-> {:db (-> db
                        (assoc-in [:dub :statuses lang :status]    status)
                        (assoc-in [:dub :statuses lang :step]      (:step data))
                        (assoc-in [:dub :statuses lang :synth-pct] (:pct data))
                        (cond-> (= status :done)
                          (-> (assoc-in [:dub :statuses lang :r2-url]      (:r2_url data))
                              (assoc-in [:dub :statuses lang :translation] (:translation data))
                              ;; Dub finished — the inbox "Latest dubbed" widget is now stale.
                              (assoc-in [:inbox-dubbed :loaded?] false)))
                        (cond-> (= status :failed)
                          (assoc-in [:dub :statuses lang :error] (:error data))))}
         (= status :done)
         (assoc :dispatch-n [[:buzz-bot.events/fetch-subtitles   episode-id lang]
                             [:buzz-bot.events/fetch-inbox-dubbed true]])
         ;; Terminal — stop any reconnect/poll machinery
         (#{:done :failed} status)
         (assoc ::fx/stop-dub-poll nil))))))
```

(The forced refetch updates `[:inbox-dubbed :items]` regardless of the current view, so the list is fresh live if Inbox is visible and on the next Inbox open otherwise; marking `:loaded? false` is the belt-and-suspenders path for the lazy navigation fetch.)

- [ ] **Step 3: Sanity-check the source compiles**

Run: `npm test`
Expected: all suites still pass (these wiring changes don't affect the unit tests, but this confirms the two files still compile cleanly under the `:test` build, which includes `src/cljs`).

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/views/inbox.cljs src/cljs/buzz_bot/events/dub.cljs
git commit -m "feat(inbox-dubbed): refresh on ↻ and proactively on dub completion"
```

---

## Task 3: Tab bar expanding pill (markup + CSS)

Presentational — verified by build + manual checklist in Task 4.

**Files:**
- Modify: `src/cljs/buzz_bot/views/layout.cljs` (lines ~13–27)
- Modify: `public/css/app.css` (lines ~72–89)

- [ ] **Step 1: Split tab markup into icon + label spans**

In `src/cljs/buzz_bot/views/layout.cljs`, replace the `tab-btn` defn and its four call sites:

```clojure
(defn- tab-btn [label view-kw current-view]
  [:button.tab-btn
   {:class    (when (= current-view view-kw) "active")
    :on-click #(rf/dispatch [::events/navigate view-kw])}
   label])

(defn root []
  (let [view @(rf/subscribe [::subs/view])]
    [:div.app-root
     [:div.app-container
      [:nav.tab-bar
       [tab-btn "📥 Inbox"     :inbox     view]
       [tab-btn "📻 Feeds"     :feeds     view]
       [tab-btn "🔖 Bookmarks" :bookmarks view]
       [tab-btn "🏷 Topics"    :topics    view]]
```

with:

```clojure
(defn- tab-btn [icon label view-kw current-view]
  [:button.tab-btn
   {:class    (when (= current-view view-kw) "active")
    :on-click #(rf/dispatch [::events/navigate view-kw])}
   [:span.tab-icon icon]
   [:span.tab-label label]])

(defn root []
  (let [view @(rf/subscribe [::subs/view])]
    [:div.app-root
     [:div.app-container
      [:nav.tab-bar
       [tab-btn "📥" "Inbox"     :inbox     view]
       [tab-btn "📻" "Feeds"     :feeds     view]
       [tab-btn "🔖" "Bookmarks" :bookmarks view]
       [tab-btn "🏷" "Topics"    :topics    view]]
```

(Leave the rest of `root` — `[:main#content ...]`, the `case`, `[miniplayer/bar]` — unchanged.)

- [ ] **Step 2: Replace the tab CSS with the pill rules**

In `public/css/app.css`, replace the existing `.tab-btn` and `.tab-btn.active` blocks (lines ~72–89):

```css
.tab-btn {
  flex: 1;
  padding: 11px 12px 10px;
  border: none;
  background: transparent;
  color: var(--hint-color);
  font-size: 13px;
  font-weight: 500;
  cursor: pointer;
  transition: color 0.18s;
  border-bottom: 2px solid transparent;
  letter-spacing: 0.01em;
}

.tab-btn.active {
  color: var(--button-color);
  border-bottom-color: var(--button-color);
}
```

with:

```css
.tab-btn {
  flex: 0 1 auto;            /* inactive tabs shrink to their icon */
  display: flex;
  align-items: center;
  justify-content: center;
  white-space: nowrap;       /* never wrap to a second line */
  padding: 11px 12px 10px;
  border: none;
  background: transparent;
  color: var(--hint-color);
  font-size: 13px;
  font-weight: 500;
  cursor: pointer;
  transition: color 0.18s;
  border-bottom: 2px solid transparent;
  letter-spacing: 0.01em;
}

.tab-btn.active {
  flex: 1 1 auto;            /* active tab grows to fit icon + label */
  color: var(--button-color);
  border-bottom-color: var(--button-color);
}

.tab-label {
  max-width: 0;
  opacity: 0;
  overflow: hidden;
  white-space: nowrap;
  transition: max-width 0.18s, opacity 0.18s, margin-left 0.18s;
}

.tab-btn.active .tab-label {
  max-width: 7rem;           /* comfortably fits the longest label ("Bookmarks") */
  opacity: 1;
  margin-left: 4px;          /* icon↔label gap only when the label is shown */
}
```

- [ ] **Step 3: Sanity-check the source compiles**

Run: `npm test`
Expected: all suites still pass (confirms `layout.cljs` compiles under the `:test` build; CSS is not compiled by shadow-cljs).

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/views/layout.cljs public/css/app.css
git commit -m "style(tab-bar): expanding-pill active tab, icon-only inactive"
```

---

## Task 4: Build the app bundle + verify

**Files:**
- Modify (regenerate): `public/js/main.js`

- [ ] **Step 1: Production build**

Run: `node node_modules/.bin/shadow-cljs release app`
Expected: build completes without errors/warnings; `public/js/main.js` is regenerated.

- [ ] **Step 2: Confirm the rebuild reflects only expected source**

Run: `git diff --stat public/js/main.js`
Expected: `public/js/main.js` is modified (minified bundle — the diff will be large/opaque, that's normal for a release artifact). This regenerated file supersedes the pre-existing uncommitted rebuild noted in the baseline.

- [ ] **Step 3: Run the full unit-test suite once more**

Run: `npm test`
Expected: all suites pass (smoke, inbox-dubbed, playback, delivery, tag-cloud, and the new events-test).

- [ ] **Step 4: Manual verification — tab bar**

Open the Mini App (e.g. via the Telegram client against `https://app.buzz-bot.top`, or a local dev serve of `public/`). Confirm:
- No tab wraps to two lines at any phone width.
- The active tab shows its icon **and** label on one line; "🔖 Bookmarks" fits when active.
- Inactive tabs show only their icon.
- Tapping a tab animates its label in (~0.18s) and collapses the previously-active label back to icon-only.

- [ ] **Step 5: Manual verification — dubbed refresh**

- On Inbox with at least one completed dub, press the ↻ Refresh button → a `GET /inbox/dubbed` fires (visible in network/devtools) and the "Latest dubbed" widget reflects current server state.
- Start a dub for an episode, open its player, let it finish: on the `done` SSE event, the Inbox "Latest dubbed" list reflects the new dub — live if Inbox is visible, otherwise on the next Inbox open.

- [ ] **Step 6: Commit the rebuilt bundle**

```bash
git add public/js/main.js
git commit -m "build: recompile app bundle for tab-bar + dubbed-refresh"
```

---

## Self-Review

- **Spec coverage:**
  - Feature 1 (expanding pill, icon-only inactive, animated label, no wrap) → Task 3 (markup + CSS) + Task 4 build/verify. ✓
  - Feature 2 force-refetch guard → Task 1 (TDD). ✓
  - Feature 2 manual ↻ refresh → Task 2 Step 1. ✓
  - Feature 2 proactive refresh on dub `done` (mark stale + force refetch via `:dispatch-n`) → Task 2 Step 2. ✓
  - Build to `public/js/main.js` → Task 4. ✓
  - Data-flow (player SSE reused, no new endpoint) → honored in Task 2 Step 2. ✓
- **Placeholder scan:** none — every code step shows full before/after code and exact commands.
- **Type/name consistency:** `dubbed-fetch` (Task 1) is the same fn referenced nowhere else by name; `::fetch-inbox-dubbed` arity `[_ force?]` is consistent across Task 1 (def), Task 2 Step 1 (`[… true]`), and Task 2 Step 2 (`[… true]`); effect key `:buzz-bot.fx/http-fetch` consistent between impl and test; `.tab-label` / `.tab-icon` / `.tab-btn.active` class names match between `layout.cljs` (Task 3 Step 1) and `app.css` (Task 3 Step 2).
- **Testing honesty:** only the fetch guard carries real branching logic and is unit-tested; CSS, hiccup markup, and re-frame dispatch wiring are verified by compile + production build + manual checklist rather than synthetic tests.
