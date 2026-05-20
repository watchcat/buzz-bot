# Topic-cloud visual redesign — design

Date: 2026-05-20
Status: approved (pre-implementation)
Repo: buzz-bot (`src/cljs/buzz_bot/views/topics.cljs`, `public/css/app.css`)

## Problem

The `/topics` view renders a tag cloud that looks like a wall of varied-size
text:

- `tag-font-size` in `topics.cljs:45-48` maps count → `11px–22px` linear
  (1.85× ratio — barely visible hierarchy)
- All tags share `--text-color` at full opacity → flat, no second dimension
  of information
- Tags live inside a `--secondary-bg` rounded box with `max-height: 40vh` +
  internal scroll → caged, doesn't feel like a "cloud"
- The hide-× child uses `:hover` to appear → **broken on touch** (Telegram
  Mini App is mobile-first)
- Smallest tags are 11px text in tight line-height → touch targets well
  below the 32 px / 44 px guidelines

## Goal

A polished, mobile-friendly tag cloud where size, weight, and opacity all
encode topic frequency; with discoverable, touch-friendly interactions
(tap to filter, long-press to hide). Single component file + a CSS block
change. No backend, no state-shape change, no new subscriptions.

## Non-goals

- No backend changes — the existing `:tag` + `:count` payload from
  `/topics` API is the input.
- No new layout algorithm (D3-cloud / wordcloud2.js packing). Flowed
  flex-wrap with size/weight/opacity remains.
- No tag rotation or color-hue gradients.
- No animation in this revision — could be a follow-up.
- No "Manage" edit-mode button — long-press handles hide.
- No localized "first-run hint" copy beyond English at this revision.

## Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Dialect | Heatmap cloud — size + opacity + weight all encode count. |
| Size dynamic | Log-scaled, `13px → 32px`. Smallest tag + padding = ~31 px touch target. |
| Hide UX | Long-press (~500 ms) → `Telegram.WebApp.showConfirm` (themed). |
| Container | Drop the `--secondary-bg` box entirely; cloud breathes against page. |
| Color encoding | Opacity `0.45 → 1.0` + font-weight `400 / 600` two-tier (no hue). |
| Active state | Solid pill using `--button-color` / `--button-text-color`. |
| Show-more | Stays functional; restyled to match the new quieter aesthetic. |
| First-run hint | One-line caption below the cloud, dismissible, persisted to localStorage. |

## Architecture

Single `topics.cljs` component rewrite + a focused CSS block rewrite. Data
flow unchanged: `::subs/topics-tags` produces `[{:tag :count} ...]`; the
component renders them with computed style; click dispatches
`::events/select-tag` (existing) or `::events/hide-topic` (existing) for
the long-press confirm. One new event + LS key for the dismissible hint.

### Files

| Action | File | Responsibility |
|---|---|---|
| Modify | `src/cljs/buzz_bot/views/topics.cljs` | `tag-font-size` becomes log-scaled; `tag-cloud` rewritten with long-press timer + opacity/weight computation + hint caption. |
| Modify | `public/css/app.css:1809-1880` | Rewrite the `.tag-cloud-*` block per the new design — drop container chrome, add `.tag-cloud-item--active` pill, restyle `.tag-cloud-hint`. |
| Modify | `src/cljs/buzz_bot/events.cljs` | Add `::events/dismiss-tag-cloud-hint` (sets db key, writes localStorage). |
| Modify | `src/cljs/buzz_bot/db.cljs` (or wherever default app-db lives) | Add `:topics/cloud-hint-dismissed?` boolean key; initialise from localStorage at boot. |
| Modify | `src/cljs/buzz_bot/subs.cljs` | Add `::subs/topics-cloud-hint-dismissed?` to read the boolean. |

## Component design — `topics.cljs`

### 1. Log-scaled `tag-font-size`

```clj
(defn- tag-font-size [count min-count max-count]
  (let [min-px 13
        max-px 32
        ratio  (if (= min-count max-count)
                 0.5
                 (/ (Math/log (inc (- count min-count)))
                    (Math/log (inc (- max-count min-count)))))]
    (+ min-px (* ratio (- max-px min-px)))))
```

`Math/log (inc x)` handles `x = 0` gracefully (returns 0). Ratio always in
`[0, 1]`; output always in `[13, 32]`. Returns Number, not String — formatted
to `"<n>px"` at render site.

### 2. Heatmap channel computations

```clj
(defn- tag-style [count min-count max-count]
  (let [ratio   (if (= min-count max-count) 0.5
                  (/ (Math/log (inc (- count min-count)))
                     (Math/log (inc (- max-count min-count)))))
        size-px (+ 13 (* ratio (- 32 13)))
        opacity (+ 0.45 (* ratio 0.55))
        weight  (if (>= ratio 0.6) 600 400)]
    {:font-size   (str size-px "px")
     :font-weight weight
     :opacity     opacity}))
```

Single pass over each tag at render. Replaces the previous separate
`tag-font-size`. The thresholds (0.45, 0.6) are tunable constants — not
exposed via state, can be changed in code if the visual judgment shifts.

### 3. Long-press timer + tap

The tag span receives both onClick (tap = filter) and onPointerDown/onPointerUp
handlers (hold = hide confirm). Use Reagent atom for the timer reference:

```clj
(defn- tag-cloud-item [{:keys [tag count selected?]} min-c max-c]
  (let [timer  (r/atom nil)
        cancel #(when @timer
                  (js/clearTimeout @timer)
                  (reset! timer nil))]
    (fn [{:keys [tag count selected?]} _ _]
      [:span.tag-cloud-item
       {:class             (when selected? "tag-cloud-item--active")
        :style             (if selected? {} (tag-style count min-c max-c))
        :on-click          (fn [e]
                             (.stopPropagation e)
                             ;; A long-press also fires click; suppress here
                             ;; only if the timer already triggered the confirm.
                             ;; Easiest: clear the timer on click and let it run.
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
                                          (str "Hide \"" tag
                                               "\" from your topics?")
                                          (fn [confirmed?]
                                            (when confirmed?
                                              (rf/dispatch
                                                [::events/hide-topic tag])))))
                                      500)))
        :on-pointer-up     cancel
        :on-pointer-leave  cancel
        :on-pointer-cancel cancel}
       tag])))
```

Pointer events fire on both mouse and touch (unified API), so we use them in
preference to mouse-/touch- pairs. `Telegram.WebApp.showConfirm` is the
Telegram WebApp SDK's themed confirm — renders consistently across iOS,
Android, and the desktop client. It's callback-based (no return value);
the user's choice arrives via `confirmed?`. While the confirm sheet is
open, Telegram blocks underlying touches, so the short-press-after-confirm
conflict doesn't arise.

For local browser development (running the Mini App outside Telegram), the
existing app shell already loads `telegram-web-app.js`; if a developer
opens the page bare, `Telegram.WebApp.showConfirm` is still present (the
stub provided by the SDK falls back to `window.confirm`).

Selected tags drop their heatmap style (`(if selected? {} ...)`) so the pill
state cleanly overrides without inline `!important`.

### 4. First-run hint

The cloud-level component renders the hint when not dismissed:

```clj
(defn- tag-cloud [tags selected-tag has-more-tags? hint-dismissed?]
  (let [min-c (apply min (map :count tags))
        max-c (apply max (map :count tags))]
    [:div.tag-cloud-section
     [:div.tag-cloud
      (for [t tags]
        ^{:key (:tag t)}
        [tag-cloud-item
         (assoc t :selected? (= (:tag t) selected-tag))
         min-c max-c])]
     (when-not hint-dismissed?
       [:button.tag-cloud-hint
        {:on-click #(rf/dispatch [::events/dismiss-tag-cloud-hint])}
        "Tap to filter · long-press to hide · ×"])
     (when has-more-tags?
       [:button.tag-cloud-toggle
        {:on-click #(rf/dispatch [::events/load-more-tags])}
        "Show more"])]))
```

### 5. Event + db wiring

New event in `events.cljs`:

```clj
(rf/reg-event-fx
  ::dismiss-tag-cloud-hint
  (fn [{:keys [db]} _]
    {:db (assoc db :topics/cloud-hint-dismissed? true)
     :local-storage/set ["topics-cloud-hint-dismissed" "1"]}))
```

(The `:local-storage/set` effect already exists in the codebase per the
playback-resume work — re-use it. If it doesn't, add a tiny effect handler
that calls `js/localStorage.setItem`.)

Subscription in `subs.cljs`:

```clj
(rf/reg-sub ::topics-cloud-hint-dismissed?
  (fn [db _] (:topics/cloud-hint-dismissed? db)))
```

App-db init reads the LS value at boot (in the existing default-db
construction):

```clj
:topics/cloud-hint-dismissed?
(= "1" (js/localStorage.getItem "topics-cloud-hint-dismissed"))
```

## CSS design — `app.css:1809-1880` block

Replace the entire block with:

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

Notes:
- Active pill uses fixed `font-size: 15px` (not the heatmap-sized version)
  so the selected tag always has a consistent visual presence regardless
  of its frequency. Otherwise rare selected tags would render as tiny pills.
- `user-select: none` + `-webkit-tap-highlight-color: transparent` are the
  standard touch-friendly resets — prevents the long-press from selecting
  text on iOS and removes the gray tap-flash.
- `.tag-cloud-item:active` opacity dim doubles as visual feedback for both
  tap and hold-in-progress (the long-press confirm doesn't show its own
  affordance, this 150ms opacity dip on press does).

## Verification

Operator smoke (no Crystal/CLJS specs added — this is visual + interaction):

1. `npx shadow-cljs release app` (or via the existing build pipeline).
2. Open `/topics` in the Mini App.
3. Visual check: cloud breathes against page background (no rounded
   secondary-bg box). Tags vary noticeably in size (13–32 px range) and in
   opacity (clearly faded vs. clearly present).
4. Tap a tag → filter applies, tag becomes a solid `--button-color` pill.
5. Long-press a tag for ~1 s → Telegram-styled confirm sheet appears
   ("Hide ..."). Confirm → tag disappears from cloud, episodes for that
   tag are no longer shown anywhere (existing `::events/hide-topic` already
   does the global work).
6. Dismiss the hint caption → caption disappears immediately, does not
   reappear on reload of the Mini App (localStorage persists).
7. Light/dark theme switch: cloud remains readable in both modes.

## Risks

| Risk | Mitigation |
|---|---|
| Long-press is an invisible affordance — users won't discover it. | One-line hint caption "Tap to filter · long-press to hide". Dismissible, persists. If a follow-up shows users still miss it, escalate to an edit-mode button. |
| `Telegram.WebApp.showConfirm` not available outside Telegram (bare browser). | The SDK ships a fallback that uses `window.confirm` in that case; developer-mode use stays functional. |
| Pointer events not fully supported on older WebViews. | Pointer events are supported in Chrome 55+ and Safari 13+ (2019). Telegram WebViews are well newer than these. If we hit a real issue, fall back to onTouchStart/onTouchEnd + onMouseDown/onMouseUp. |
| Opacity at 0.45 too faint to read in bright sunlight on phones. | 0.45 lower bound was chosen as a balance; tested visually against the Telegram light theme. If a user complains, the constant is tunable in one place (`tag-style`). |
| LocalStorage write fails (Safari private mode). | The hint just keeps appearing — annoying but not broken. Wrap the LS write in a `try/catch` if real reports come in. |

## Success criteria

- Visual: tags clearly vary in size, weight, and opacity. The "cloud" reads
  as a cloud, not a list.
- Touch: tap-to-filter works first time; long-press hide is discoverable
  via the hint caption.
- Theme: works in both Telegram light and dark themes without code changes.
- No regression: existing `::events/select-tag`, `::events/clear-tag`,
  `::events/hide-topic`, `::events/load-more-tags` continue to fire from
  the same trigger points.
- Bundle: shadow-cljs release succeeds; no new shadow-cljs warnings.

## Implementation order

1. Update `src/cljs/buzz_bot/db.cljs` default app-db with the new
   `:topics/cloud-hint-dismissed?` key + LS read at init.
2. Add `::events/dismiss-tag-cloud-hint` to `events.cljs`.
3. Add `::subs/topics-cloud-hint-dismissed?` to `subs.cljs`.
4. Rewrite the `.tag-cloud-*` CSS block.
5. Rewrite the `tag-cloud` + new `tag-cloud-item` components in
   `topics.cljs`; rewrite `tag-font-size` → `tag-style` (returns full
   style map).
6. Operator smoke: shadow-cljs release, redeploy via `k8s/deploy.sh`,
   visual + interaction checks in the Mini App.
