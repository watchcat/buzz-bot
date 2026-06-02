# Tab Bar Pill + Dubbed-List Refresh — Design

**Date:** 2026-06-02
**Status:** Approved (design)
**Repo:** buzz-bot
**Scope:** Two small, independent front-end fixes in the ClojureScript/re-frame Mini App.

## Context

The buzz-bot Mini App front-end is a **ClojureScript / re-frame SPA** (`src/cljs/buzz_bot/…`), built with shadow-cljs (`:app` build → `public/js/main.js`), **not** the ECR+HTMX stack. Two unrelated issues:

1. **Tab bar wrapping.** The bottom nav has four equal-width tabs — 📥 Inbox, 📻 Feeds, 🔖 Bookmarks, 🏷 Topics (a 5th is planned). Each is `flex: 1`, `13px`, emoji+label inline, with **no `white-space: nowrap`**, so the longest label ("Bookmarks") wraps to a second line inside its ¼-width slot. A 5th tab makes every slot narrower and worsens it.
2. **Dubbed list never refreshes.** The Inbox "Latest dubbed" widget fetches `/inbox/dubbed` once and caches forever. The Inbox ↻ Refresh button doesn't touch it, and a dub completing doesn't update it.

## Goals

- Tabs: no wrapping, ever (including with a 5th tab); show the label only on the active tab, icon-only on the rest, with a smooth width animation.
- Dubbed list: the Inbox ↻ button refreshes it; it also refreshes proactively when a dub finishes.

## Non-Goals

- No new server endpoints or SSE streams. Reuse the player's existing per-episode dub SSE.
- No redesign of the dubbed widget, the "See all" stub, or tab navigation logic.
- No change to which tabs exist (the 5th tab is a separate future change; this just stops it from making wrapping worse).

## Feature 1 — Expanding-pill tab bar

**Decision:** Active tab expands to fit `icon + label` on one line; inactive tabs shrink to icon-only. Width change is animated (~0.18s, matching the existing color transition).

**Files:**
- `src/cljs/buzz_bot/views/layout.cljs` — tab markup
- `public/css/app.css` — `.tab-bar` / `.tab-btn` rules (currently lines ~61–89)

**Markup change** (`layout.cljs`): split each tab's combined string into an always-shown icon span and a label span. `tab-btn` currently takes a single `label` like `"📥 Inbox"`; change it to take an `icon` and a `label` and render:

```clojure
(defn- tab-btn [icon label view-kw current-view]
  [:button.tab-btn
   {:class    (when (= current-view view-kw) "active")
    :on-click #(rf/dispatch [::events/navigate view-kw])}
   [:span.tab-icon icon]
   [:span.tab-label label]])
```

with call sites:

```clojure
[tab-btn "📥" "Inbox"     :inbox     view]
[tab-btn "📻" "Feeds"     :feeds     view]
[tab-btn "🔖" "Bookmarks" :bookmarks view]
[tab-btn "🏷" "Topics"    :topics    view]
```

**CSS change** (`app.css`): animate the label open/closed (rather than `display` toggling, which can't transition), and let the active tab grow:

```css
.tab-btn {
  flex: 0 1 auto;          /* was: flex: 1 */
  white-space: nowrap;     /* never wrap */
  display: flex;
  align-items: center;
  justify-content: center;
  /* keep existing padding / color / border-bottom / transition */
}

.tab-btn.active { flex: 1 1 auto; }   /* active grows to fit its label */

.tab-label {
  max-width: 0;
  opacity: 0;
  overflow: hidden;
  white-space: nowrap;
  transition: max-width 0.18s, opacity 0.18s, margin-left 0.18s;
}

.tab-btn.active .tab-label {
  max-width: 7rem;         /* comfortably fits "Bookmarks" */
  opacity: 1;
  margin-left: 4px;        /* gap between icon and label only when shown */
}
```

`7rem` comfortably fits the longest current label. The active-class logic (`= current-view view-kw`) is unchanged; a future 5th tab is just another `tab-btn` call.

## Feature 2 — Dubbed-list refresh (manual + proactive)

**Decision:** Reuse the player's existing dub SSE. On the SSE `:done` transition, force-refetch `/inbox/dubbed` and mark the widget stale; the Inbox ↻ button also force-refetches it.

**Files:**
- `src/cljs/buzz_bot/events.cljs` — `::fetch-inbox-dubbed` (currently ~106–115), gains a `force?` arg
- `src/cljs/buzz_bot/views/inbox.cljs` — Inbox ↻ handler (currently ~117–120)
- `src/cljs/buzz_bot/events/dub.cljs` — `::sse-event` handler (currently ~153–172)

**Root causes:**
- The Inbox ↻ button dispatches only `[::events/fetch-inbox]` — never the dubbed widget.
- `::fetch-inbox-dubbed` short-circuits when `(get-in db [:inbox-dubbed :loaded?])` is true, so it fetches exactly once per session.
- Dub completion publishes to `DubHub` for the **player's** per-episode SSE only; nothing refetches `/inbox/dubbed`.

**Change 1 — force arg on `::fetch-inbox-dubbed`** (`events.cljs`). Add an optional `force?` that bypasses the `:loaded?` guard:

```clojure
(rf/reg-event-fx
 ::fetch-inbox-dubbed
 (fn [{:keys [db]} [_ force?]]
   (if (and (not force?) (get-in db [:inbox-dubbed :loaded?]))
     {}
     {:db (assoc-in db [:inbox-dubbed :loading?] true)
      ::buzz-bot.fx/http-fetch
      {:method :get
       :url    "/inbox/dubbed"
       :on-ok  [::inbox-dubbed-loaded]
       :on-err [::inbox-dubbed-err]}})))
```

The only change is the handler arg `[_ force?]` and the guard `(and (not force?) …)`; the `:db` / `::buzz-bot.fx/http-fetch` effect map is otherwise unchanged.

The existing lazy call from `::navigate :inbox` stays `[::fetch-inbox-dubbed]` (guarded, unchanged).

**Change 2 — manual refresh** (`inbox.cljs`). The ↻ handler dispatches the dubbed refetch alongside the inbox refetch:

```clojure
:on-click (fn [_]
            (when @debounce (js/clearTimeout @debounce))
            (reset! query-atom "")
            (rf/dispatch [::events/fetch-inbox])
            (rf/dispatch [::events/fetch-inbox-dubbed true]))
```

**Change 3 — proactive refresh on dub done** (`events/dub.cljs`). The `::sse-event` handler already uses `cond->` and, on `:done`, sets a single `:dispatch [:buzz-bot.events/fetch-subtitles …]`. Switch that to `:dispatch-n` so it fires both, and mark the widget stale in `:db`:

```clojure
;; in the :db cond-> branch for (= status :done), also:
(assoc-in [:inbox-dubbed :loaded?] false)   ; mark stale

;; replace the single :dispatch on :done with:
(= status :done)
(assoc :dispatch-n [[:buzz-bot.events/fetch-subtitles episode-id lang]
                    [:buzz-bot.events/fetch-inbox-dubbed true]])
```

Result: if the user is on Inbox when a dub completes, the list updates live; otherwise it's marked stale and the next Inbox view refetches (and the forced refetch already updated the cached items regardless of current view). No new server infrastructure.

## Data Flow (Feature 2)

```
dub finishes
  └─ POST /internal/dub_result (server) ── publishes to DubHub (unchanged)
       └─ player dub SSE "…::done"
            └─ events/dub.cljs ::sse-event  (status :done)
                 ├─ :db  → mark [:inbox-dubbed :loaded?] false
                 └─ :dispatch-n
                      ├─ [:…/fetch-subtitles episode-id lang]   (existing)
                      └─ [:…/fetch-inbox-dubbed true]           (force GET /inbox/dubbed)
                           └─ ::inbox-dubbed-loaded → updates [:inbox-dubbed :items]

Inbox ↻ button → [::fetch-inbox] + [::fetch-inbox-dubbed true]
Navigate :inbox → [::fetch-inbox-dubbed]  (lazy, guarded — unchanged)
```

## Build & Verification

- **Build:** ClojureScript changes require recompiling the `:app` build to `public/js/main.js`:
  `npx shadow-cljs release app` (production) or `npx shadow-cljs watch app` during development.
- **Tab bar (manual):** open the Mini App; confirm no tab wraps to two lines; tapping a tab shows its label (animated) and collapses the previously-active label to its icon; "Bookmarks" fits on one line when active.
- **Dubbed refresh (manual):**
  - Press Inbox ↻ → the dubbed widget refetches (network call to `/inbox/dubbed`, list reflects current server state).
  - Start a dub, open its player, let it finish → on `done`, the Inbox dubbed list reflects the new dub (live if Inbox visible, otherwise on next Inbox view).
- **Unit tests:** if the shadow-cljs `:test` (`:node-test`) build has re-frame event tests, add coverage for `::fetch-inbox-dubbed` honoring `force?` vs the `:loaded?` guard; otherwise rely on manual verification (no test harness change in scope).

## Risks / Notes

- `7rem` label cap is sized for current labels; a much longer future label would need a larger cap (still no wrap — it would clip, which is acceptable and visible during design of that tab).
- Forcing a refetch on every `:done` is cheap (one small JSON GET) and only fires on real completion events.
- `MEMORY.md` currently describes the front-end as ECR+HTMX; it is actually this re-frame SPA. Update memory after shipping (out of scope for this change).
