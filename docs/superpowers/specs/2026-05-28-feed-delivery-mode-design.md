# Per-feed delivery mode — design

**Status:** approved (pending plan)
**Source:** `/Users/watchcat/Downloads/design_handoff_feed_delivery/` (spec text +
`feed-v3.jsx` + `feed-chrome.jsx` + screenshots)

## Goal

Let each subscriber configure how new episodes for each feed are delivered:

- **`off`** (default) — episode shows up in the in-app list, no Telegram traffic.
- **`notify`** — bot posts a card-style Telegram message with a *Listen* button
  that deep-links into the Mini App player.
- **`mp3`** — bot uploads the episode audio via Telegram's native `sendAudio`,
  so the user can scrub/save inside Telegram itself.

The setting lives on the **Feed detail screen** (per-feed episode list — today
served at `/episodes?feed_id=...`). The same screen also gets its header
simplified and a "NEW" badge for unseen episodes.

## Non-goals

- No per-episode delivery override.
- No "send-on-publish" for backfill (historic episodes of a freshly-subscribed
  feed) — see *Backfill protection* below.
- No bot-side commands to change the mode (Mini App UI only).
- No push-notification path outside Telegram.

## Alignment with existing features

Two existing features overlap with this work; both confirmed during spec
review (2026-05-28):

1. **Dub-finished notifications** (`src/web/routes/dub_result.cr#notify_user`)
   already construct a Mini-App-button reply markup with the label
   `"▶️ Open Episode"`. The new `Delivery::Notify` uses the same button text;
   both routes share a `MiniAppLink.episode_button(episode_id)` helper
   (introduced as part of this work) so the convention can't drift.

2. **Manual Send-to-Chat** (`POST /episodes/:id/send` → `AudioSender.send_to_user`)
   is **premium-gated** (`unless user.subscribed? → 402 premium_required`).
   The new `mp3` delivery mode inherits the same gate — see "Premium gating"
   below — otherwise auto-delivery would be a trivial bypass of the manual
   feature's gate.

## Premium gating

`mp3` mode requires `user.subscribed?` (matches the manual Send-to-Chat
gate). `off` and `notify` are free for all users.

- **Server**: `PATCH /feeds/:id/delivery_mode` returns
  `402 {"error":"premium_required"}` when `mode = "mp3"` and the caller is
  not premium. The DB row is not updated.
- **Client (tap-cycle)**: For non-premium users the cycle order shortens to
  `off ↔ notify` — tap on `notify` returns to `off` instead of advancing
  to `mp3`. Implemented in `buzz-bot.delivery/next-mode` via an optional
  `premium?` arg.
- **Client (long-press popup)**: All three buttons remain visible. The
  `mp3` button is labeled `"Send MP3 (Premium)"`. If a non-premium user
  picks it, the optimistic update reverts and the upsell banner appears.
- **Upsell banner**: Reuses the visual treatment from the player's
  Send-to-Chat upsell (`.send-result.upsell` rule already in `app.css`).
  Text: `"⭐ Premium feature. Auto-deliver MP3s to your Telegram chat with
  a Buzz-Bot subscription."` Dismisses on tap.

## Data model

### Schema migration `019_feed_delivery_mode.sql`

```sql
ALTER TABLE user_feeds
  ADD COLUMN delivery_mode  VARCHAR(8)  NOT NULL DEFAULT 'off',
  ADD COLUMN last_viewed_at TIMESTAMPTZ;

ALTER TABLE user_feeds
  ADD CONSTRAINT user_feeds_delivery_mode_chk
  CHECK (delivery_mode IN ('off', 'notify', 'mp3'));

CREATE INDEX user_feeds_by_feed_delivery
  ON user_feeds (feed_id, delivery_mode)
  WHERE delivery_mode <> 'off';
```

- `delivery_mode` joins the existing `episode_order` column already on
  `user_feeds`. Per-user, per-feed.
- `last_viewed_at` powers the **NEW badge**. `NULL` means "user has never opened
  this feed page"; treat all current episodes as already-seen on first open to
  avoid badging every episode on day-one (set to `NOW()` on first view).
- The partial index targets the delivery fanout query —
  *"who wants Telegram delivery for this feed?"* — without scanning subscribers
  in `off` mode (the majority).

### `Episode.upsert` returns insertion flag

Today's signature returns `Episode?` and the refresh loop counts every returned
row as "new". Add a boolean so the delivery fanout can distinguish a true insert
from an idempotent update:

```crystal
record UpsertResult, episode : Episode, was_inserted : Bool
def self.upsert(...) : UpsertResult?
```

SQL gains `(xmax = 0) AS was_inserted` (the standard Postgres trick — `xmax` is
0 on INSERT, the row's previous-version xid on UPDATE).

**Existing callers** (confirmed by grep): `src/feed_refresher.cr:132` is the
only site that uses the return value — change `result.was_inserted` logic
there. The other three sites (`src/web/routes/feeds.cr:30`, `feeds.cr:65`,
`src/web/routes/search.cr:60`) discard the return value already; the
signature change is transparent to them.

## API surface

### `GET /episodes?feed_id=…` — extend response

Already returns `{episodes, has_more, episode_order}`. Add:

```jsonc
{
  "episodes":      [...],
  "has_more":      bool,
  "episode_order": "desc" | "asc",
  "delivery_mode":   "off" | "notify" | "mp3",   // NEW
  "new_episode_ids": [123, 456],                 // NEW — ids with published_at > last_viewed_at
  "is_premium":      bool                        // NEW — drives the chip's mp3 gating UI
}
```

`new_episode_ids` is computed server-side once per request. The client uses it
to render the badge; no client-side date math.

### `PATCH /feeds/:id/delivery_mode` — new

```jsonc
// Request
{ "mode": "notify" }
// 204 No Content
```

Validates mode is one of `off|notify|mp3`. Auth: standard `X-Init-Data`
(matches all other Mini App routes). Idempotent.

### `POST /feeds/:id/viewed` — new

Bumps `user_feeds.last_viewed_at = NOW()` for `(user_id, feed_id)`. The Mini
App calls this once per feed-detail open (after the episodes load — so the
badge has rendered first).

Returns `204 No Content`. Idempotent.

## RSS refresh hook — delivery fanout

`src/feed_refresher.cr#refresh` already loops over parsed episodes and calls
`Episode.upsert`. We add a per-feed fanout *after* the upsert loop:

```crystal
inserted_eps = parsed.episodes.compact_map do |ep|
  res = Episode.upsert(...)
  res.episode if res && res.was_inserted
end

DeliveryDispatch.fanout(feed, inserted_eps) unless inserted_eps.empty?
```

`DeliveryDispatch.fanout(feed, eps)` (new module, `src/delivery/dispatch.cr`):

1. For each `ep` in `eps`, for each user with `delivery_mode IN ('notify','mp3')`
   subscribed to this `feed`, *and* `user_feeds.created_at < ep.published_at`
   (backfill protection):
2. `spawn` one fiber per (user, episode, mode) — same fire-and-forget pattern
   used elsewhere (`AudioSender.send_to_user` is already spawn-wrapped at the
   call site). The fiber is short — single Telegram API call or a queued
   `AudioSender.send_to_user`.
3. Skip if `episode.audio_url` is empty (defensive).
4. Per-call log line — `Delivery[user_id=… ep=… mode=notify] sent` —
   matching the `AudioSender:` / `Dub:` log style.

### Backfill protection (critical)

Without this, two failure modes:

- **First-ever sync of a feed (the user just subscribed):** without protection,
  the refresh inserts the feed's entire history, fanout fires for all of them
  → user gets dozens of Telegram messages or MP3 uploads.
- **User flips mode → mp3 for a feed that already has unsent episodes:** we'd
  retroactively send the backlog.

Both are prevented by `created_at < ep.published_at` (the user_feeds row is
older than the episode). Mode changes don't replay history because the existing
episodes have `published_at <= mode_change_time` and the user_feeds row's
`created_at` predates the user's interest in receiving them.

Edge case: if a feed publishes an episode dated in the past (republish of an old
ep), the filter correctly skips it. If `published_at IS NULL`, treat it as "no
fanout" — we have no way to determine if it's new-to-the-user.

## Telegram message formats

### `notify` mode

```
[feed cover thumb]  *NRC Vandaag* · new episode
In Ter Apel voelt iedereen zich in de…
May 28, 2026 · 18 min

[▶ Listen]   ← inline button → Mini App with episode pre-selected
```

Implementation:

```crystal
text = "*#{feed.title}* · new episode\n" \
       "#{ep.title}\n" \
       "#{fmt_date(ep.published_at)}#{ep.duration_sec ? " · #{fmt_dur(ep.duration_sec)}" : ""}"

# Standard Mini-App button shared with dub-finished notifications.
markup = Tourmaline::InlineKeyboardMarkup.new([[MiniAppLink.episode_button(ep.id)]])

if (img = feed.image_url)
  begin
    BotClient.client.send_photo(
      chat_id:      user.telegram_id,
      photo:        img,                          # Telegram fetches it server-side; no /img-proxy hop
      caption:      text,
      parse_mode:   Tourmaline::ParseMode::Markdown,
      reply_markup: markup,
    )
  rescue
    # send_photo can fail if Telegram can't fetch the cover (bad URL,
    # upstream 404, etc.) — degrade to a plain text card with the same
    # title/date/duration and the Open Episode button.
    BotClient.client.send_message(
      user.telegram_id, text,
      parse_mode: Tourmaline::ParseMode::Markdown, reply_markup: markup,
    )
  end
else
  BotClient.client.send_message(
    user.telegram_id, text,
    parse_mode: Tourmaline::ParseMode::Markdown, reply_markup: markup,
  )
end
```

Use the photo URL directly — no `/img-proxy` indirection. The proxy exists
only to satisfy the Mini App's strict img-src CSP; Telegram's server
fetches the photo on its own.

`MiniAppLink.episode_button(episode_id)` is a new shared helper (see
*Shared Mini-App button helper* below) used by both this notification
and the refactored `dub_result.cr#notify_user`.

### `mp3` mode

Direct call to `AudioSender.send_to_user(user.telegram_id, ep, feed, caption: caption)`
where `caption = "#{feed.title} · #{fmt_date(ep.published_at)}"` — same code
path used today by the *Send to Chat* button in the player. The fast (URL)
and slow (download+upload) paths both already exist; the only
infrastructure change is **adding an optional `caption: String?` parameter**
to `AudioSender.send_to_user` (defaults to nil so the existing
`/episodes/:id/send` caller's behavior is unchanged).

When `caption` is non-nil it's threaded into both the fast-path JSON payload
and the slow-path multipart form as the `caption` field on Telegram's
`sendAudio` — that renders as a text line below the audio bubble.

If the audio is over the upload limit (~50 MB without local Bot API server,
2 GB with one), `AudioSender` already messages the user with a size error —
that's acceptable behavior; we don't silently drop.

## Shared Mini-App button helper

Both `Delivery::Notify` (new) and `dub_result.cr#notify_user` (existing)
build an inline keyboard with a Mini-App-launching button to a specific
episode. Today the dub side constructs it inline; the new feature would
duplicate that. Instead, extract a single helper that both call:

```crystal
# src/bot/mini_app_link.cr (new)
require "tourmaline"
require "../config"

module MiniAppLink
  # Standard "open this episode in the Mini App" inline button. Used by
  # all bot-side notifications so the label and URL convention can't drift
  # between callers.
  def self.episode_button(episode_id : Int64) : Tourmaline::InlineKeyboardButton
    Tourmaline::InlineKeyboardButton.new(
      text:    "▶️ Open Episode",
      web_app: Tourmaline::WebAppInfo.new(url: "#{Config.base_url}/app?episode=#{episode_id}"),
    )
  end
end
```

`dub_result.cr#notify_user` is refactored as part of this work to use
the helper — same button, single source of truth.

## UI — Mini App Feed detail screen

**File:** `src/cljs/buzz_bot/views/episodes.cljs` (the per-feed episode list,
*not* the feeds subscription list at `feeds.cljs`).

### Before → after layout

```
TODAY                                       AFTER
─────────────────────────────────────────  ─────────────────────────────────────
[← Feeds]              [NRC Vandaag]       [← Feeds]  [NRC Vandaag]      [⋯]
[📡] [↻]  [☑] Oldest first                  [🔔 Notify me ▾]  [↕ Newest]
[episode list…]                             [NEW] [episode list…]
```

The current second toolbar row is **removed**. Refresh and RSS-copy move into
the `⋯` overflow menu.

### Chip A — delivery mode (the feature)

**Theme tokens** — the design handoff uses a fixed `#3DA5F0` accent, but this
app is theme-driven via `--tg-theme-*` (see `public/css/app.css:1-25`). Map
handoff tokens → existing app tokens so the chip inherits whatever Telegram
palette the user has:

| Handoff token | App token                                                                       |
|---------------|---------------------------------------------------------------------------------|
| `accent`      | `var(--button-color)`                                                           |
| `text` / `text2` | `var(--text-color)` / `var(--hint-color)`                                    |
| `surface`     | `var(--secondary-bg)`                                                           |
| `line`        | `var(--border)`                                                                 |
| `accent-13`   | `color-mix(in srgb, var(--button-color) 13%, transparent)` *(new variable: `--accent-13`)* |
| `accent-33`   | `color-mix(in srgb, var(--button-color) 33%, transparent)` *(new variable: `--accent-33`)* |

The existing `--accent-tint` (12 % alpha) is close to `accent-13` but for
fidelity to the spec we add the two new aliases at the top of `app.css`. No
hardcoded hex inside the chip rules.

Visual states (fixed `width: 140px` to prevent label-length jitter):

| Mode      | Icon          | Label         | bg               | fg                  | border          |
|-----------|---------------|---------------|------------------|---------------------|-----------------|
| `off`     | bell-w/-slash | "In-app only" | `var(--secondary-bg)` | `var(--hint-color)` | `var(--border)` |
| `notify`  | bell (filled) | "Notify me"   | `var(--accent-13)` | `var(--button-color)` | `var(--accent-33)` |
| `mp3`     | mp3-document  | "Send MP3"    | `var(--accent-13)` | `var(--button-color)` | `var(--accent-33)` |

Geometry (from `feed-v3.jsx`):

```css
.delivery-chip {
  width: 140px;                /* fixed — no jitter on label change */
  height: 28px;
  padding: 5px 12px 5px 10px;
  border-radius: 999px;
  font: 600 12.5px/1 inherit;  /* inherits the app's Inter stack */
  display: inline-flex; align-items: center; gap: 6px;
  white-space: nowrap;
  cursor: pointer;
}
```

Icon SVGs: copy verbatim from `feed-chrome.jsx` (`BellIcon` filled/outlined,
`BellOffIcon`, `MP3Icon`) into the CLJS component as hiccup `:svg` literals.
Each renders at 13 px (matches the chip's font baseline).

After the label, a 9 px downward chevron at 60 % opacity hints "tap to change".

### Interactions

| Gesture     | Effect                                                                                |
|-------------|---------------------------------------------------------------------------------------|
| Tap         | Cycle `off → notify → mp3 → off`. Optimistic UI; PATCH server in background.          |
| Long-press  | Open the mode picker — see below.                                                     |
| Right-click | Same as long-press (desktop / dev affordance).                                        |

**Mode picker — use `Telegram.WebApp.showPopup`.** Telegram's native
multi-button popup renders three buttons with the mode labels and a one-line
`message:` payload listing the descriptions. Zero CSS, on-brand. Schema:

```js
Telegram.WebApp.showPopup({
  title:   "Delivery for this feed",
  message: "Pick how new episodes reach you:\n" +
           "• In-app only — New episodes appear here. We won't ping you.\n" +
           "• Notify me — Telegram message when a new episode drops. Tap to play.\n" +
           "• Send MP3 — The audio file lands in your Telegram chat. Listen anywhere.",
  buttons: [
    {id: "off",    type: "default", text: "In-app only"},
    {id: "notify", type: "default", text: "Notify me"},
    {id: "mp3",    type: "default", text: "Send MP3"},
  ],
}, callback)
```

The callback receives the selected button id; dispatch `::set-delivery-mode`
with it. Fallback when `Telegram.WebApp.showPopup` is unavailable (older
clients, browser preview): plain `window.confirm`-style flow with one prompt
per mode — acceptable degradation; not the common path.

Long-press detection follows the pattern already established in
`views/topics.cljs` for tag-hide (form-2 component, `r/atom` timer, 500 ms
threshold, cancel on pointer-up/leave/cancel).

### Chip B — sort direction

```css
.sort-chip {
  height: 28px;
  padding: 5px 10px;
  border-radius: 999px;
  background: transparent;
  border: 1px solid var(--line);
  color: var(--text2);
  font: 500 12.5px/1 Inter;
  display: inline-flex; align-items: center; gap: 5px;
}
```

Tap toggles between Newest-first and Oldest-first sort. The icon is an arrow
that flips direction. **Persistence stays server-side** via the existing
`UPDATE user_feeds SET episode_order = ...` path — no schema change, no
behavior regression vs. today.

### `⋯` overflow menu

Anchored to the right edge of the header. Two items today:

- **Copy RSS link** — copies `feed.url`. Existing `events/copy-rss-url` event.
- **Refresh now** — dispatches `events/fetch-episodes feed-id`. Existing event.

Styling: custom CSS popover positioned `absolute; top: 100%; right: 0;`
relative to the `⋯` button; opens on click, closes on outside click
(document-level click listener attached on open, removed on close) and on item
selection. Item padding `10px 14px`, font 14px, `var(--text-color)`,
separator `1px solid var(--border)` between items, background
`var(--secondary-bg)`, `border-radius: var(--radius)`, drop-shadow
`0 4px 12px rgba(0,0,0,0.18)`. Width ≈ 180 px, no explicit cap.

(Pull-to-refresh is not in this spec — it's a possible future addition.)

### NEW badge

Renders inline before the title text in `.episode-title`:

```css
.episode-new-badge {
  display: inline-block;
  background: var(--button-color);
  color: var(--button-text-color);
  font: 700 9px/1 inherit;
  letter-spacing: 0.4px;
  padding: 1px 5px;
  border-radius: 4px;
  margin-right: 6px;
  text-transform: uppercase;
  flex: 0 0 auto;
}
```

Driven by `new_episode_ids` returned in the GET `/episodes` response (above).
On feed-page mount: render badges → load episodes → fire
`POST /feeds/:id/viewed`. Subsequent navigations show no NEW badges (until the
next RSS refresh produces new episodes).

## CLJS state

`src/cljs/buzz_bot/db.cljs` — extend the `:episodes` slice:

```clojure
:episodes {:feed-id          nil
           :list             []
           :offset           0
           :has-more?        false
           :order            :desc
           :delivery-mode    :off    ; NEW
           :new-episode-ids  #{}     ; NEW
           :delivery-pending nil     ; NEW — last optimistic mode while PATCH in flight
           :delivery-upsell? false   ; NEW — non-premium tried mp3; show banner
           :loading?         false}
```

New events (`events.cljs`):

- `::cycle-delivery-mode feed-id` — reads `:user/premium?` and calls
  `buzz-bot.delivery/next-mode` with the appropriate premium flag so the
  cycle skips `mp3` for non-premium users.
- `::set-delivery-mode feed-id mode` — used by the long-press menu. Performs
  the premium check client-side too: if `mode = :mp3` and not premium, set
  `:delivery-upsell? true` and skip the PATCH.
- `::delivery-patch-ok` / `::delivery-patch-err` — clear `:delivery-pending`;
  on err, revert to the prior mode. If err carries a `premium_required`
  signal (HTTP 402), also set `:delivery-upsell? true`.
- `::dismiss-delivery-upsell` — clears `:delivery-upsell?`.
- `::mark-feed-viewed feed-id` — fires the `POST /feeds/:id/viewed` and clears
  `:new-episode-ids` locally so a re-render doesn't keep the badges.

`::fetch-episodes` already exists; the response handler is extended to seed
`:delivery-mode` and `:new-episode-ids`.

The `:user/premium?` sub already exists in the player flow (`is_premium`
returned from `/episodes/:id/player`). For the per-feed-list view it must
also be available — exposed via the player endpoint response *or* via a
small extension to `/episodes` that includes the user's premium status in
the response root. Implementation favors the latter (one keyword field
alongside `delivery_mode`) to avoid coupling list rendering to the player
fetch.

## Acceptance checklist

- [ ] Migration `019_feed_delivery_mode.sql` adds `delivery_mode` +
      `last_viewed_at` to `user_feeds`; check-constraint enforces enum;
      partial index on `(feed_id, delivery_mode) WHERE delivery_mode <> 'off'`.
- [ ] `Episode.upsert` returns `UpsertResult?` with `was_inserted` from
      `(xmax = 0)`.
- [ ] `GET /episodes?feed_id=…` response includes `delivery_mode` and
      `new_episode_ids`.
- [ ] `PATCH /feeds/:id/delivery_mode {mode}` validates enum, persists,
      returns `204`.
- [ ] `POST /feeds/:id/viewed` updates `last_viewed_at = NOW()`, returns `204`.
- [ ] `DeliveryDispatch.fanout(feed, inserted_eps)` is called from
      `FeedRefresher#refresh` after the upsert loop.
- [ ] Fanout filter: `delivery_mode IN ('notify','mp3') AND
      user_feeds.created_at < ep.published_at`.
- [ ] `notify` mode posts a photo (or text-only fallback) with the standard
      `MiniAppLink.episode_button` (label `▶️ Open Episode`).
- [ ] `dub_result.cr#notify_user` refactored to use
      `MiniAppLink.episode_button` — single source of truth for the button.
- [ ] `AudioSender.send_to_user` gains an optional `caption: String?` arg
      (default nil); the existing `/episodes/:id/send` caller passes nil
      so its behavior is unchanged.
- [ ] `mp3` mode calls `AudioSender.send_to_user(..., caption: "...")` with
      `"feed_title · pub_date"`. Failures (size-cap etc.) surface via the
      existing failure-notification path.
- [ ] `PATCH /feeds/:id/delivery_mode` returns 402 `premium_required` if
      `mode = "mp3"` and `!user.subscribed?`.
- [ ] CLJS `next-mode` shortens the cycle to `off ↔ notify` for non-premium
      users so tap-cycle never lands on mp3 without entitlement.
- [ ] Long-press popup labels the mp3 button `"Send MP3 (Premium)"` for
      non-premium users; tapping it surfaces the upsell banner.
- [ ] Upsell banner reuses the `.send-result.upsell` visual treatment from
      the player's Send-to-Chat flow.
- [ ] Header collapses to a single row: back-link · title · `⋯`.
- [ ] `⋯` menu contains *Copy RSS link* and *Refresh now*.
- [ ] Delivery chip: 140 px fixed width, icon + label + chevron, three visual
      states match the table above.
- [ ] Tap cycles `off → notify → mp3 → off`. Optimistic UI; rollback on PATCH
      error.
- [ ] Long-press / right-click opens a mode-picker menu with descriptions.
- [ ] Sort chip toggles Newest ↔ Oldest with a direction icon, persists
      server-side via existing `episode_order`.
- [ ] `NEW` badge renders only on episodes in `new_episode_ids`; bumping
      `last_viewed_at` on page-open is fire-and-forget.
- [ ] Telegram message formatting matches the spec for both modes.
- [ ] No hardcoded hex inside chip / badge rules; `--accent-13` and
      `--accent-33` are added as new top-level vars synthesized via
      `color-mix(in srgb, var(--button-color) N%, transparent)`.
- [ ] Mode picker (long-press) uses `Telegram.WebApp.showPopup` when
      available; falls back gracefully when the SDK doesn't expose it.

## Out of scope (deferred)

- Notification throttling / digest mode ("send max N per day per feed").
- Per-feed delivery for episodes published *before* the user's subscription
  date (backfill is intentionally never delivered).
- Bot-side `/delivery` slash command — Mini App UI only for v1.
- Pull-to-refresh on the feed page.
- Migration of existing per-feed UI state (toolbar removal is destructive in a
  pleasant way; users will see the new chrome on next deploy).
