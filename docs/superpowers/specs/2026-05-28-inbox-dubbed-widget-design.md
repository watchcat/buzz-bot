# Latest-dubbed widget on /inbox — design

**Status:** approved (pending plan)
**Source:** `/Users/watchcat/Downloads/design_handoff_inbox_dubbed/` (CLAUDE_CODE_PROMPT.md,
`inbox-v2.jsx` + `inbox-chrome.jsx` + `inbox-data.jsx`, screenshots).

## Goal

Surface recently-completed dubs at the top of the Inbox screen as a
horizontal-scrolling row of compact cards. Tapping a card opens the dubbed
episode in the player with the dub language already active.

Widget height budget: **≤ 25 %** of viewport (≈ 150–190 px on a 760 px mini-app).

## Non-goals

- No "See all" dedicated /dubbed page — the link stays in the design but is a
  no-op stub for v1.
- No long-press menu ("Hide from widget" / "Open original") — deferred.
- No widget on the Feeds / Bookmarks / Topics tabs — Inbox only.
- No push notification or Telegram message when a new dub completes — the
  existing dub-finished `notify_user` already covers that path.

## Alignment with existing features

- `DubbedEpisode` already powers per-episode dub statuses (`DubbedEpisode.statuses_for_episode`).
  This work *adds* a "recent across the system" query without disturbing
  per-episode reads.
- The card tap routes through the existing player view with the existing
  `dub-events/language-tapped` switch — no new audio-playback path.
- The dub-completion timestamp gap (only `created_at` and
  `expires_at = completed_at + 29d` exist today) is filled with a small
  schema addition rather than read-side offset math.

## Data model

### Schema migration `020_dubbed_episode_completed_at.sql`

```sql
ALTER TABLE dubbed_episodes
  ADD COLUMN completed_at TIMESTAMPTZ;

-- Backfill from the existing 29-day expiry contract. Rows in status='done'
-- with a non-NULL expires_at: completed_at = expires_at - 29 days. Other
-- rows (pending/processing/failed) remain NULL.
UPDATE dubbed_episodes
SET completed_at = expires_at - INTERVAL '29 days'
WHERE status = 'done' AND expires_at IS NOT NULL;

-- Index for the widget query: ORDER BY completed_at DESC LIMIT 12.
CREATE INDEX dubbed_episodes_recent_done
  ON dubbed_episodes (completed_at DESC NULLS LAST)
  WHERE status = 'done';
```

`DubbedEpisode.set_complete` (today writes `expires_at`) is updated to also set
`completed_at = NOW()`. Tested with a one-line spec assertion on the model.

### `DubbedEpisode.recent_for_inbox` — new query method

```crystal
record DubbedRecent,
  episode_id   : Int64,
  feed_id      : Int64,
  feed_title   : String,
  feed_image   : String?,
  ep_title     : String,
  ep_image     : String?,
  duration_sec : Int32?,
  source_lang  : String?,    # e.g. "ru" — from episodes.original_language
  target_lang  : String,     # the dub language
  completed_at : Time,
  subscribed?  : Bool        # whether the calling user subscribes to this feed

def self.recent_for_inbox(user_id : Int64, limit : Int32 = 12) : Array(DubbedRecent)
```

Query shape (single SQL):

```sql
SELECT
  e.id AS episode_id,
  e.feed_id, f.title AS feed_title, f.image_url AS feed_image,
  e.title AS ep_title, e.image_url AS ep_image, e.duration_sec,
  e.original_language AS source_lang,
  de.language         AS target_lang,
  de.completed_at,
  EXISTS (SELECT 1 FROM user_feeds uf WHERE uf.user_id = $1 AND uf.feed_id = e.feed_id) AS subscribed
FROM dubbed_episodes de
JOIN episodes e ON e.id = de.episode_id
JOIN feeds    f ON f.id = e.feed_id
WHERE de.status = 'done'
ORDER BY subscribed DESC, de.completed_at DESC NULLS LAST
LIMIT $2
```

Source language lives directly on `episodes.original_language` (migration 009,
written by `Episode.save_original_language` after a successful dub) — no
join needed. May be NULL if the dub pipeline didn't return a source-language
detection; the card falls back to showing just the target language.

The `subscribed DESC, completed_at DESC` ordering implements the
*subscribed-first, then recent globally* policy chosen during design review.
`NULLS LAST` on completed_at protects against backfill races (rows in
`status='done'` somehow lacking a backfill value would sort to the end).

## API surface

### `GET /inbox/dubbed` — new endpoint

```jsonc
{
  "items": [
    {
      "episode_id":   12345,
      "feed_title":   "NRC Vandaag",
      "feed_image":   "https://…",
      "ep_image":     "https://…",   // when episode has its own art; falls back to feed_image client-side
      "ep_title":     "In Ter Apel voelt iedereen zich in de…",
      "duration_sec": 1080,
      "source_lang":  "nl",
      "target_lang":  "en",
      "completed_at": "2026-05-28T11:30:00Z",
      "subscribed":   true,
      "is_new":       true            // server-computed: completed_at > NOW() - 24h
    },
    …
  ]
}
```

Auth: standard `X-Init-Data`. Default `?limit=12`, clamped to `[1, 50]`.
Empty array when there are no done dubs — client hides the widget entirely.

A separate endpoint (not extending `/inbox`) keeps the existing inbox-list
response stable. The widget fetches its own data on inbox mount.

## UI — the widget

**File:** `src/cljs/buzz_bot/views/inbox_dubbed.cljs` (new — keeps `inbox.cljs`
focused on the list).

### Layout

```
┌─────────────────────────────────────────────────────────────┐
│ [🔊 DUBBED]  LATEST DUBBED                       See all → │  ← header (6 px below)
│ ┌─────────┐ ┌─────────┐ ┌──────                            │
│ │[cover]  │ │[cover]  │ │[cov…                              │  ← horizontal scroll
│ │NL→EN·2h │ │RU→EN·5h │ │                                   │     ~1.7 cards visible
│ │Episode  │ │Episode  │ │                                   │
│ │Show·18m │ │Show·54m │ │                                   │
│ └─────────┘ └─────────┘ └──────                            │
├─────────────────────────────────────────────────────────────┤  ← 1 px divider, 6/12 px margins
│ TODAY                                                       │
│ • NRC Vandaag …                                             │     existing inbox list
└─────────────────────────────────────────────────────────────┘
```

### Header

A flex row with:

- **DUBBED pill** (left): `--warn-13` bg, `--warn-33` border, `--warn` text,
  uppercase 9 px / 700 / letter-spacing 0.6, padding 1 × 6 px, border-radius
  999. Small speaker-with-wave icon (port the SVG verbatim from
  `inbox-chrome.jsx#DubbedIcon`).
- **Section label** "LATEST DUBBED": 11 px / 700 / letter-spacing 0.6 /
  uppercase / `var(--hint-color)`.
- **`See all →`** button (right): 11 px / 600 / `var(--button-color)`, plain
  background, chevron after text. `on-click` is a stub no-op event for v1
  (see *Out of scope*).

`white-space: nowrap` on both the label group and the action so the row
never wraps even on narrow viewports.

### Card

```css
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
  scroll-snap-align: start;
  cursor: pointer;
}
```

Inside:

- **Cover** (48 × 48 px, `border-radius: 8px`): `ep_image` if present,
  else `feed_image`, served through `/img-proxy` (the existing helper).
  Position: `relative` so the NEW badge can overlay.
- **NEW badge** (when `is_new`): absolute top-right, `--warn` bg, white text,
  8 px / 800 / uppercase, padding 1 × 4 px, border-radius 999, **2 px solid
  `var(--bg-color)` border** so it looks lifted off the cover edge.
- **Right column** (`flex: 1; min-width: 0`):
  - **Lang-flow + when**: a flex row, `gap: 5 px`, `color: var(--warn)`.
    - The flow itself: `<from-lang> → <to-lang>` in **monospace**, 8 px / 700.
      Arrow at 60 % opacity. Falls back to just the target language if
      `source_lang` is nil (no original-language record yet).
    - `· <when>`: 9 px / `var(--text3)` (the `--hint-color` analogue used as
      `text3` in the design). Format helper: relative time (`2h ago`,
      `5h ago`, `1d ago`).
  - **Title** (2-line clamp, 12 px / 600 / `var(--text-color)`, line-height
    1.2, `min-height: 28px` so 1-line and 2-line cards stay aligned).
  - **Meta**: `<feed_title> · <duration>`, 9 px / `var(--text3)`,
    single-line ellipsis.

### Scroll row

```css
.dubbed-cards {
  display: flex;
  gap: 8px;
  padding: 0 16px 4px;
  overflow-x: auto;
  scroll-snap-type: x mandatory;
  scrollbar-width: none;          /* Firefox */
}
.dubbed-cards::-webkit-scrollbar { display: none; }  /* Chrome/Safari */
```

A 200 px card + 8 px gap means ~1.7 cards visible on a 390 px viewport
(390 − 32 padding = 358 → fits 1.79 cards) — preserving the "peek" of the
next card.

### Divider

```css
.dubbed-divider {
  height: 1px;
  background: var(--border);
  margin: 6px 16px 12px;
}
```

### Behavior

- **Tap card** → dispatch `[:buzz-bot.events/navigate :player
  {:episode-id <id> :from "inbox" :dub-lang <to>}]`. The player init logic
  reads `:dub-lang` from view-params and, if the language's `dub_statuses`
  entry is `:done`, dispatches `dub-events/language-tapped` once after
  load so the dubbed audio activates by default.
- **Empty** state — when `items` is `[]`, the entire widget (header + cards
  + divider) renders nothing. The inbox list renders unchanged.
- **Loading** state — first paint: no widget. Once data lands and `(seq
  items)`, the widget appears. Don't show a skeleton — the inbox list below
  is the primary content; the widget is supplementary.

## Design tokens

Two new top-level CSS custom properties:

```css
:root {
  /* … existing … */
  --warn:    #E78A4E;
  --warn-13: color-mix(in srgb, var(--warn) 13%, transparent);
  --warn-33: color-mix(in srgb, var(--warn) 33%, transparent);
}
```

The dubbed accent (`#E78A4E` orange) is intentionally **theme-independent**
— it always reads as the same color regardless of the user's Telegram
palette. This signals "dubbed content" as a distinct category, the same way
the accent blue signals "primary action".

A `--text3` token (the `#6B7C8E` tertiary text color from the design) maps
to the existing `var(--hint-color)` — they serve the same semantic role.
No new variable for that one.

Fonts: the lang-flow chip wants a **monospace** family. Add a single
`--font-mono` token at `:root`:

```css
  --font-mono: ui-monospace, "JetBrains Mono", "SF Mono", Menlo, monospace;
```

The system-monospace fallback chain renders well across iOS/Android/web
without bundling a webfont.

## CLJS state

`src/cljs/buzz_bot/db.cljs` — extend the `:inbox` slice (or add a new top-level
key) with:

```clojure
:inbox-dubbed {:items   []
               :loading? false
               :loaded?  false}
```

(Use a sibling key to avoid coupling with the existing `:inbox` slice
shape, which holds the episode list.)

New events (`events.cljs`):

- `::fetch-inbox-dubbed` — fires `GET /inbox/dubbed`; sets `:loading? true`.
- `::inbox-dubbed-loaded` — replaces `:items`, clears `:loading?`, sets
  `:loaded? true`.
- `::inbox-dubbed-err` — silent failure (widget hides, inbox unaffected).
- `::see-all-dubbed-stub` — pure no-op for v1; the chip exists so the
  button has a real dispatch handler.

`::navigate` to `:player` already accepts a params map; the new
`:dub-lang` key passes through unchanged. The player-mount logic
(buzz-bot.events.dub/init-statuses currently handles `:in-flight` reopen
of SSE) gets a tiny extension: after `init-statuses`, if view-params'
`:dub-lang` matches a status with `:status :done`, dispatch
`::dub-events/language-tapped episode-id (keyword dub-lang)` so the
dubbed audio loads instead of the original.

New subs:

```clojure
(rf/reg-sub ::inbox-dubbed-items
  (fn [db _] (get-in db [:inbox-dubbed :items])))
```

(No sub for `:loading?` — the widget renders only when items are present;
no skeleton.)

`::inbox`-navigation should dispatch `::fetch-inbox-dubbed` on entering
the inbox tab if `:loaded?` is false. Cheap follow-on call.

## Acceptance checklist

- [ ] Migration `020_dubbed_episode_completed_at.sql` adds the
      `completed_at` column, backfills from `expires_at - 29d`, indexes
      `(completed_at DESC NULLS LAST) WHERE status = 'done'`.
- [ ] `DubbedEpisode.set_complete` writes `completed_at = NOW()`.
- [ ] `DubbedEpisode.recent_for_inbox(user_id, limit=12)` returns the
      `DubbedRecent` projection with `subscribed-first, completed_at DESC`
      ordering. Includes `is_new := completed_at > NOW() - 24h` server-side.
- [ ] `GET /inbox/dubbed` returns `{items: [...]}` with the JSON shape
      above. `?limit=` clamped to `[1, 50]`. Empty array when no dubs.
- [ ] Widget appears at the top of `/inbox`, below the title row.
- [ ] Header has DUBBED pill (warn palette, speaker icon) + LATEST DUBBED
      label + See all → link. None of these wrap.
- [ ] Card is 200 px wide; flex/scroll-snap container shows ~1.7 cards.
- [ ] Card shows: 48 px cover (with NEW badge when `is_new`), monospace
      lang-flow + relative time, 2-line title (min-height 28 px), meta.
- [ ] Tap card → opens player with episode pre-selected AND dub language
      auto-activated when its status is `:done`.
- [ ] See all → is a stub no-op for v1.
- [ ] Widget hides entirely when items is empty — inbox list renders
      unchanged.
- [ ] CSS: `--warn`, `--warn-13`, `--warn-33`, `--font-mono` added to
      `:root`; no hardcoded `#E78A4E` outside that block.
- [ ] Scrollbar hidden in widget on Firefox + WebKit.

## Out of scope (deferred)

- Dedicated `/dubbed` full-library page with language filter + sort. The
  "See all" button is a visible stub for now.
- Long-press menu (hide from widget, open original).
- Surfacing dubs in progress (only `status='done'` rows enter the widget).
- Per-language widget filtering ("Latest dubbed to English").
- Pagination beyond the 12-item cap (See all would supply that).
