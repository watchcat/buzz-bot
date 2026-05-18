# Playback resume fix — design

Date: 2026-05-18
Status: approved (pre-implementation)
Repo: buzz-bot (ClojureScript Mini App frontend)

## Problem

Reopening a previously-played episode does not resume at the saved position;
the user must play a different (never-listened) episode first and even then the
old episode starts from 0. Confirmed root causes (code-traced):

1. **Bug 1 — resume never re-applied.** `[:audio :episode-id]` is set in
   `events.cljs` `::audio-load` (:533) and `:742` and **never cleared**. In
   `::player-loaded` (events.cljs:341-354) the branch `(= cur-id new-id)`
   (`cur-id` = `[:audio :episode-id]`) skips `::audio-load` entirely, so the
   resume seek — the only place server `progress_seconds` is applied to the
   element (`::audio-load` :524 → `:load` cmd → `loadedmetadata` handler,
   audio.cljs:236-244) — never runs when reopening the still-"current"
   episode. The single shared `<audio>` element (audio.cljs:5, `defonce`)
   holds the live position only in volatile memory, which the Telegram Mini
   App WebView routinely zeroes/drops on backgrounding or after any `.load()`.
   Playing a different episode changes `cur-id`, forcing the `:else` →
   `::audio-load` path — exactly the user's workaround.

2. **Bug 2 — no persistence flush.** Progress is saved only by a 5 s
   `setInterval` gated on `(not (.-paused el))` (audio.cljs:212-219), with no
   save on `pause`, `visibilitychange`, or `pagehide`. The last ≤5 s before a
   pause is never persisted, and a mobile WebView throttles/kills the timer on
   suspend, losing more.

3. **Bug 3 — spurious 0 clobbers good progress.**
   `UserEpisode.upsert_progress` (user_episode.cr:31-43) sets
   `progress_seconds = EXCLUDED.progress_seconds` unconditionally. A mid-session
   `.load()` (stall-recovery, offline-cache `:switch-src`, download swap)
   momentarily resets `currentTime` to 0 while not paused; the interval then
   PUTs `seconds:0`, permanently overwriting the saved position server-side.

Ruled out: a "completed → 0" path. `/episodes/:id/player` (episodes.cr:85-128)
returns `user_episode` verbatim and `::audio-load` reads `progress_seconds`
without consulting `completed`; neither server nor client zeroes a completed
episode today.

## Goals

- Reopening any episode resumes at its true saved position (server is the
  source of truth, re-applied idempotently on every player-open).
- Position is reliably persisted across pause / app-suspend / close.
- Spurious mid-reload writes never corrupt the stored position.
- Core decisions are pure, unit-tested; a cljs test harness exists.

## Non-goals

- No server/DB/migration change (see Locked decision 2).
- No restructuring of the offline-cache `:switch-src`/download flow (a generic
  client guard covers all reset sources).
- No new "currently playing" UX; the only preserved behavior is "don't
  interrupt the episode that is actively playing right now."

## Locked decisions (from brainstorming)

1. **Completed episodes restart from 0** on reopen (replay). Resume applies
   only to in-progress episodes.
2. **Exact position incl. deliberate rewinds.** The fix is client-side
   suppression of *spurious* writes only; the server stays dumb
   (`progress_seconds = EXCLUDED.progress_seconds`, no monotonic/`GREATEST`).
3. **Generic guard + regression tests.** One trust-gate covers all reset
   sources; plus automated tests, which requires standing up a ClojureScript
   test harness (none exists today).
4. **Approach A** — server-state-as-truth, idempotent re-apply; no reconciler
   refactor (Approach C deferred).

## Architecture

Entirely client-side, in `src/cljs/buzz_bot/`. Decisions are extracted into a
new pure namespace so they are testable without a DOM; DOM-coupled code
(`audio.cljs`) and re-frame events consume them.

### Component: `src/cljs/buzz_bot/playback.cljs` (new, pure)

```clojure
(ns buzz-bot.playback)

;; HAVE_CURRENT_DATA — below this, currentTime is not trustworthy.
(def ^:private trustworthy-ready-state 2)

(defn resume-start
  "Position to resume at. Completed episodes restart from 0 (decision 1)."
  [completed progress-seconds]
  (if completed 0 (or progress-seconds 0)))

(defn should-skip-reload?
  "True only when reopening the episode that is actively playing right now —
  the one case where re-issuing a load would wrongly interrupt playback.
  `was-playing?` is the navigation-time snapshot (events.cljs:325-327)."
  [{:keys [same-episode? was-playing?]}]
  (boolean (and same-episode? was-playing?)))

(defn should-save-progress?
  "True when the element's currentTime is trustworthy enough to persist.
  False during reloads/seeks (covers stall-recovery, :switch-src, download
  swap, network reload — bug 3) regardless of source."
  [{:keys [recovering? ready-state seeking?]}]
  (not (or recovering?
           seeking?
           (< (or ready-state 0) trustworthy-ready-state))))
```

### Bug 1 — `events.cljs`

- `::player-loaded` (341-354): change the first branch guard
  `(= cur-id new-id)` → `(and (= cur-id new-id) was-playing?)`. The
  queue-pending branch `(and was-playing? (not= cur-id new-id))` and `:else`
  are unchanged. Net: reopening a *paused/stopped/stale* same episode now
  reaches `:else` → `::audio-load`, re-applying server position; reopening the
  *actively playing* episode still skips (no interruption). Use
  `playback/should-skip-reload?` to express the first guard.
- `::audio-load` (524): replace
  `start (get-in db [:player :data :user_episode :progress_seconds] 0)` with
  `start (playback/resume-start
            (get-in db [:player :data :user_episode :completed])
            (get-in db [:player :data :user_episode :progress_seconds]))`.
- `::audio-ended` (505-511): also `assoc-in [:audio :episode-id] nil` and
  `[:audio :playing?] false` (hardening: a finished id can't linger as
  `cur-id`).

### Bug 2 — `audio.cljs`

- Add `flush-progress!`: reads `[:audio :episode-id]` from
  `re-frame.db/app-db` and dispatches `[:buzz-bot.events/save-progress ep-id
  (js/Math.floor (.-currentTime (el)))]`, **only when**
  `(playback/should-save-progress? {…})` holds.
- `pause` listener (132-136): after `::audio-paused`, call `flush-progress!`.
- In `init!`/`wire-listeners!`: add `document` listeners —
  `visibilitychange` (when `(.-hidden js/document)`) and `pagehide` — each
  calling `flush-progress!`.

### Bug 3 — `audio.cljs`

- `start-progress-interval!` (212-219): gate the existing dispatch with
  `(playback/should-save-progress? {:recovering? @recovering?
   :ready-state (.-readyState (el)) :seeking? (.-seeking (el))})` in addition
  to the existing `(not (.-paused (el)))`. The same gate is inside
  `flush-progress!` so all save paths share one trust rule.

### Server — unchanged

`UserEpisode.upsert_progress` and `/episodes/:id/progress` are not touched
(decision 2). No migration.

## Data flow (after fix)

`/episodes/:id/player` → `::player-loaded` decides via
`should-skip-reload?`: skip iff actively playing this episode; else
`::audio-load` with `start = resume-start(completed, progress_seconds)` →
`:load` cmd seeks on `loadedmetadata`. Saves: interval (5 s, not-paused) +
pause + visibilitychange-hidden + pagehide, each passing the
`should-save-progress?` trust gate; server overwrites with the exact value.

## Error handling / edge cases

- `was-playing?` stale-true if a WebView suspend ate the `pause` event → a
  rare wrongful skip; equals today's behavior for that path, now mitigated by
  the pagehide/visibilitychange flush + clear-on-`ended`. Accepted.
- Reopening a *paused* same episode now triggers reload+seek (was a no-op):
  one extra buffer cycle, but correct (re-applies true server position).
- pause-flush racing a near-simultaneous interval tick → duplicate idempotent
  PUT. Harmless.
- `flush-progress!` with no `[:audio :episode-id]` (nothing loaded) → no-op.

## Testing

Stand up a shadow-cljs `:node-test` build (Node, no browser) with a
`npx shadow-cljs compile test` runner (none exists today).

- `test/buzz_bot/playback_test.cljs` (must): exhaustive pure-fn tests —
  `resume-start` (completed→0; in-progress→progress; nil→0),
  `should-skip-reload?` (true only same+was-playing; all other combos false),
  `should-save-progress?` (false when recovering?/seeking?/ready-state<2;
  true otherwise; nil ready-state→false).
- re-frame event tests for `::player-loaded`: with test-overridden
  `::buzz-bot.fx/audio-cmd` and `::buzz-bot.fx/http-fetch` fx, assert:
  (a) same-id + was-playing → no `::audio-load`; (b) same-id + paused →
  `::audio-load` dispatched; (c) completed episode → resulting `:load` `start`
  is 0; (d) different id, not playing → `::audio-load`.

## Success criteria

- Open episode, listen, pause, navigate away, reopen → resumes at the saved
  position (no "play another episode first" needed).
- Force-close/background the Mini App mid-listen, reopen → within ≤5 s of the
  last heard position (pause/pagehide flush).
- Trigger a stall-recovery/cache switch mid-play → stored `progress_seconds`
  never drops to 0.
- Reopen a completed episode → starts at 0.
- `npx shadow-cljs compile test` green; pure-fn + `::player-loaded` tests pass.

## Implementation order

1. `playback.cljs` + `playback_test.cljs` + shadow-cljs test build (TDD; pure).
2. `events.cljs`: `::player-loaded` guard, `::audio-load` `start`,
   `::audio-ended` clear; event tests.
3. `audio.cljs`: `flush-progress!`, pause/visibilitychange/pagehide wiring,
   interval trust-gate.
4. Manual verification against the success criteria; build the SPA
   (`shadow-cljs` release) and deploy via the normal path (operator step).
