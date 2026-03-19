# ClojureScript SPA Rewrite — Design Spec

**Date:** 2026-03-19
**Status:** Approved

---

## Overview

Rewrite the Buzz-Bot Telegram Mini App frontend from vanilla JS + HTMX to a ClojureScript SPA using Re-frame and Reagent. The backend shifts from server-rendered HTML fragments to a JSON API. Offline support (Service Worker, IndexedDB audio cache, write queue) is deferred to a later phase.

The work happens on a dedicated git branch. The existing `layout.ecr` shell is not modified until the SPA is feature-complete; the new layout shell is swapped in as the final cutover step.

---

## Goals

- Replace ~700 lines of hard-to-maintain vanilla JS across 4 files with idiomatic, structured ClojureScript
- Eliminate HTMX lifecycle complexity (`htmx:afterSwap`, `htmx:configRequest` re-initialization hooks)
- Centralise all UI state in a single Re-frame app-db
- Clean separation: backend owns data, frontend owns rendering and interaction
- Backend changes are minimal: same routes, same auth, same DB queries — JSON output replaces ECR templates

## Non-Goals (deferred to later phases)

- Service Worker / offline app-shell caching
- IndexedDB audio blob caching
- Offline write queue
- URL-based routing (Telegram Mini App is single-URL)
- OPML bulk import (`POST /feeds/opml`) — deferred, preserve existing handler unchanged
- Send to Chat (`POST /episodes/:id/send`) — deferred; button is hidden in the SPA player view at cutover
- Podcast search / subscribe from catalog (`GET /search`, `POST /search/subscribe`) — deferred; Feeds tab shows subscribed feeds only, no search-to-subscribe in this phase

---

## Backend Changes

### What changes

- All in-scope route handlers return `application/json` instead of rendering ECR templates
- Crystal models gain `JSON::Serializable` includes
- `layout.ecr` is replaced with a new HTML shell at cutover (see Migration Strategy)
- All ECR templates are deleted at cutover
- `rec` items are denormalized at the backend: each rec includes `feed_title` pulled from the feeds lookup, so the ClojureScript client receives a flat struct without additional fetches

### What stays unchanged

- Route paths and HTTP methods (no new endpoints, no renames)
- Auth (`X-Init-Data` HMAC-SHA256 validation, `Auth.current_user(env)`)
- DB queries (same models, same SQL)
- `GET /episodes/:id/audio_proxy` (binary audio stream, untouched)
- Webhook route (bot, untouched)
- Deferred routes (`/feeds/opml`, `/episodes/:id/send`, `/search`, `/search/subscribe`) — handlers unchanged

### Request body format

`POST /feeds` continues to accept `application/x-www-form-urlencoded` with field `url`. The Crystal handler already reads `env.params.body["url"]`; no change needed.

### JSON API Contract

| Route | Method | Request | Response |
|---|---|---|---|
| `/app` | GET | — | HTML shell (mounts SPA) |
| `/inbox` | GET | — | `{episodes: [...], has_more: bool}` |
| `/feeds` | GET | — | `{feeds: [...]}` |
| `/episodes` | GET | `?feed_id=&order=&limit=&offset=` | `{episodes: [...], has_more: bool}` |
| `/episodes/:id/player` | GET | — | `{episode, feed, user_episode, next_id, recs, is_subscribed, is_premium}` |
| `/episodes/:id/progress` | PUT | `{seconds: int, completed: bool}` | 204 |
| `/episodes/:id/signal` | PUT | — | `{liked: bool}` |
| `/feeds` | POST | form: `url=...` | `{feed}` or `{error: str}` |
| `/feeds/:id` | DELETE | — | 204 |
| `/feeds/:id/subscribe` | POST | — | `{feed}` |
| `/bookmarks` | GET | — | `{episodes: [...]}` |
| `/bookmarks/search` | GET | `?q=` | `{episodes: [...]}` |

### Response Shapes

**Episode object** (used in all episode lists — inbox, feed episode list, bookmarks):
```json
{
  "id": 42,
  "title": "...",
  "audio_url": "https://...",
  "description": "...",
  "published_at": "2024-01-01T00:00:00Z",
  "duration_seconds": 3600,
  "feed_id": 7,
  "feed_title": "...",
  "feed_image_url": "https://...",
  "listened": false,
  "progress_seconds": 120,
  "liked": false
}
```
`listened`, `progress_seconds`, `liked` are sourced from `user_episodes` (joined at query time). If no `user_episode` row exists, `listened` = false, `progress_seconds` = 0, `liked` = false.

**`GET /episodes/:id/player` response**:
```json
{
  "episode":      { ...episode object (as above)... },
  "feed":         { "id": 7, "title": "...", "url": "...", "image_url": "..." },
  "user_episode": { "episode_id": 42, "progress_seconds": 120, "listened": false, "liked": true },
  "next_id":      43,
  "recs":         [{ "id": 99, "title": "...", "feed_id": 12, "feed_title": "..." }],
  "is_subscribed": true,
  "is_premium":    false
}
```
`user_episode` is nullable (null if user has never interacted with this episode).

**Feed object**:
```json
{ "id": 7, "title": "...", "url": "...", "image_url": "..." }
```

---

## Frontend Architecture

### Build Tooling

- **shadow-cljs** replaces esbuild + Preact
- `:browser` build target → `public/js/main.js`
- Hot reload in development (`shadow-cljs watch app`)
- Production build: `shadow-cljs release app` (generates single `public/js/main.js`)
- `package.json` updated: remove `esbuild`, `preact`, `@preact/signals`; add `shadow-cljs`
- During the migration phase, `public/js/main.js` (new CLJS output) and the old JS files coexist; the old `layout.ecr` is not modified until cutover

### HTML Shell (new `layout.ecr` at cutover)

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Buzz-Bot</title>
  <script src="/js/telegram-web-app.js"></script>
  <link rel="stylesheet" href="/css/app.css?v=<%= Assets::VERSION %>">
</head>
<body>
  <div id="app"></div>
  <script>window.BOT_USERNAME = '<%= BotClient.username %>';</script>
  <script src="/js/main.js?v=<%= Assets::VERSION %>"></script>
</body>
</html>
```

`telegram-web-app.js` remains a separate vendored `<script>` (not bundled). The Reagent root mounts to `#app`. shadow-cljs `release` output is a single self-contained file; no `goog/base.js` tag is needed in production. In development, shadow-cljs handles module loading automatically.

### File Structure

```
src/cljs/buzz_bot/
├── core.cljs           ← app entry: single-instance check, Telegram SDK init, mount
├── db.cljs             ← initial app-db value
├── events.cljs         ← all Re-frame event handlers
├── subs.cljs           ← all Re-frame subscriptions
├── fx.cljs             ← custom effects: ::http-fetch, ::audio-cmd
├── audio.cljs          ← JS interop: <audio> element, MediaSession, progress interval
└── views/
    ├── layout.cljs     ← root component: tab bar + active view + miniplayer
    ├── miniplayer.cljs ← persistent bottom bar (always rendered)
    ├── inbox.cljs      ← inbox view + filters
    ├── feeds.cljs      ← feeds list + subscribe form
    ├── episodes.cljs   ← feed episode list + pagination
    ├── player.cljs     ← full player page
    └── bookmarks.cljs  ← bookmarked episodes + search
```

### App-DB Shape

```clojure
{;; Navigation
 :view         :inbox              ;; :inbox | :feeds | :episodes | :player | :bookmarks
 :view-params  {}                  ;; e.g. {:feed-id 42} or {:episode-id 99}

 ;; Telegram
 :init-data    ""                  ;; raw initData string sent as X-Init-Data header
 :theme        {}                  ;; Telegram themeParams mapped to CSS var names

 ;; Inbox
 :inbox {:episodes    []
         :loading?    false
         :filters     {:hide-listened?  false
                       :compact?        false
                       :excluded-feeds  #{}}}

 ;; Feeds
 :feeds {:list     []
         :loading? false}

 ;; Feed episode list
 :episodes {:feed-id   nil
            :list      []
            :loading?  false
            :order     :desc
            :offset    0
            :has-more? false}

 ;; Player
 :player {:data     nil    ;; map with keys: episode, feed, user_episode, next_id, recs, is_subscribed, is_premium
          :loading? false}

 ;; Bookmarks
 :bookmarks {:list     []
             :loading? false
             :query    ""}

 ;; Audio engine state
 :audio {:episode-id   nil    ;; ID of episode currently loaded into <audio>
         :title        ""     ;; displayed in miniplayer (restored from localStorage on init)
         :artist       ""
         :artwork      ""
         :src          ""
         :playing?     false
         :current-time 0
         :duration     0
         :rate         1
         :autoplay?    false  ;; persisted to localStorage "buzz-autoplay"
         :pending?     false} ;; true = player data loaded for a different episode than currently playing
}
```

### Initialisation sequence (`core.cljs`)

```
1. Single-instance check (Web Locks API) — if another tab holds lock, show overlay and stop
2. tg.ready() + tg.expand()
3. Apply Telegram theme params as CSS vars on :root
4. Store tg.initData in app-db :init-data
5. Restore last-played episode from localStorage:
     "buzz-last-episode-id"   → :audio/episode-id
     "buzz-last-episode-meta" → :audio/title, :audio/artist, :audio/artwork
   (no network call; miniplayer renders immediately with stale metadata)
6. Restore :audio/rate from localStorage "buzz-playback-speed"
7. Restore :audio/autoplay? from localStorage "buzz-autoplay"
8. Check deep link (see below)
9. Mount Reagent root onto #app
10. Start progress-save interval in audio.cljs
```

### Single-Instance Enforcement (`core.cljs`)

Before mounting:
```clojure
(if-let [locks (.. js/navigator -locks)]
  (.request locks "buzz-bot-instance"
    #js{:ifAvailable true}
    (fn [lock]
      (if lock
        (do (init!) (js/Promise. (fn [_ _])))  ; hold lock forever
        (show-already-open-overlay!))))
  (init!))  ; Web Locks not supported — mount unconditionally
```

### Deep-Link Handling (`core.cljs` init)

```clojure
(let [start     (.. js/window -Telegram -WebApp -initDataUnsafe -start_param)
      url-ep    (-> js/window .-location .-search js/URLSearchParams. (.get "episode"))
      episode-id (or url-ep
                     (when (clojure.string/starts-with? (str start) "ep_")
                       (subs start 3)))]
  (if episode-id
    (rf/dispatch [::events/navigate :player {:episode-id episode-id}])
    (rf/dispatch [::events/navigate :inbox])))
```

### Key Events

| Event | Trigger | What it does |
|---|---|---|
| `::navigate` | Tab / episode click / back | Set `:view` + `:view-params`; dispatch fetch event for that view |
| `::fetch-inbox` | Navigate to inbox | HTTP GET `/inbox`; set `:inbox/loading? true` |
| `::inbox-loaded` | Fetch success | Set `:inbox/episodes`, `:inbox/loading? false` |
| `::fetch-feeds` | Navigate to feeds, or after subscribe/unsubscribe | HTTP GET `/feeds`; set `:feeds/loading? true` |
| `::feeds-loaded` | Fetch success | Set `:feeds/list`, `:feeds/loading? false` |
| `::fetch-episodes` | Navigate to episode list | HTTP GET `/episodes?feed_id=&order=&limit=&offset=` |
| `::episodes-loaded` | Fetch success | Set `:episodes/list`, `:episodes/has-more?` |
| `::load-more-episodes` | Load more button | HTTP GET `/episodes` with next offset; on success: append to `:episodes/list`, update offset |
| `::set-order` | Reverse order toggle | Set `:episodes/order`; reset `:episodes/offset` to 0; dispatch `::fetch-episodes` |
| `::fetch-player` | Navigate to player | HTTP GET `/episodes/:id/player`; set `:player/loading? true` |
| `::player-loaded` | Fetch success | Set `:player/data`; also set `:audio/title`, `:audio/artist`, `:audio/artwork` from episode data; then: if `(:audio/playing? db)` AND `(:audio/episode-id db) ≠ new-episode-id` → dispatch `::audio-queue-pending`; else → dispatch `::audio-load` |
| `::audio-load` | Player loaded without conflict | Read `src` = `(get-in db [:player :data :episode :audio_url])` and `start` = `(get-in db [:player :data :user_episode :progress_seconds] 0)`; dispatch `{::audio-cmd {:op :load :src src :start start}}`; set `:audio/episode-id`, `:audio/pending? false`; persist episode-id + meta to localStorage |
| `::audio-queue-pending` | Player loaded while playing different episode | Set `:audio/pending? true`; do NOT issue `::audio-cmd`; playback continues uninterrupted |
| `::toggle-play-pause` | Play/pause button | If `:audio/pending?` → dispatch `::audio-commit-pending`; else if `:audio/playing?` → dispatch `::audio-pause`; else → dispatch `::audio-play` |
| `::audio-commit-pending` | Play pressed while pending | Set `:audio/pending? false`; dispatch `::audio-load` with `{:autoplay? true}` (load effect will call `audio.play()` inside `loadedmetadata` listener) |
| `::audio-play` | Play button (no pending state) | `{::audio-cmd {:op :play}}` |
| `::audio-pause` | Pause button | `{::audio-cmd {:op :pause}}` |
| `::audio-tick` | `timeupdate` listener (throttled 1×/rAF) | Set `:audio/current-time` |
| `::audio-duration` | `durationchange` listener | Set `:audio/duration` |
| `::audio-ended` | `ended` listener | If `:audio/autoplay?` and `(get-in db [:player :data :next_id])` → dispatch `[::navigate :player {:episode-id next-id}]` |
| `::audio-seek` | Seek bar `change` event | `{::audio-cmd {:op :seek :time t}}` |
| `::audio-seek-relative` | ±15s / ±30s buttons | `{::audio-cmd {:op :seek-relative :delta d}}` |
| `::cycle-speed` | Speed button | Cycle 1→1.5→2→1; `{::audio-cmd {:op :set-rate :rate r}}`; persist to localStorage `"buzz-playback-speed"` |
| `::toggle-bookmark` | Bookmark button | HTTP PUT `/episodes/:id/signal`; on success: `(assoc-in db [:player :data :user_episode :liked] (:liked response))` |
| `::toggle-autoplay` | Autoplay checkbox | Toggle `:audio/autoplay?`; persist to localStorage `"buzz-autoplay"` |
| `::toggle-hide-listened` | Filter checkbox | Set `:inbox/filters/hide-listened?` |
| `::toggle-feed-filter` | Feed filter checkbox | Toggle feed-id in `:inbox/filters/excluded-feeds` |
| `::toggle-compact` | Compact mode checkbox | Set `:inbox/filters/compact?` |
| `::search-bookmarks` | Search input (debounced 300ms) | HTTP GET `/bookmarks/search?q=`; set `:bookmarks/list` |
| `::subscribe-feed` | Subscribe form submit | HTTP POST `/feeds` (form body `url=...`); on success → dispatch `::fetch-feeds` (response body `{feed}` is ignored) |
| `::unsubscribe-feed` | Unsubscribe button | HTTP DELETE `/feeds/:id`; on success (204) → dispatch `::fetch-feeds` |
| `::subscribe-from-player` | Player subscribe button | HTTP POST `/feeds/:id/subscribe`; on success → `(assoc-in db [:player :data :is_subscribed] true)` |

### Custom Effects

**`::http-fetch`** — wraps `js/fetch`, always injects `X-Init-Data` header from `:init-data` in app-db, parses JSON response:
```clojure
;; GET
{:http-fetch {:method :get
              :url    "/inbox"
              :on-ok  [::inbox-loaded]
              :on-err [::fetch-error]}}

;; POST with form body
{:http-fetch {:method  :post
              :url     "/feeds"
              :body    (js/URLSearchParams. #js{"url" "https://..."})
              :on-ok   [::subscribe-feed-ok]
              :on-err  [::fetch-error]}}

;; PUT with JSON body
{:http-fetch {:method  :put
              :url     "/episodes/42/progress"
              :body    {:seconds 120 :completed false}
              :on-ok   [::progress-saved]
              :on-err  [::fetch-error]}}
```

**`::audio-cmd`** — sends commands to the audio interop layer in `audio.cljs`. Autoplay on load is handled by the `loadedmetadata` listener:
```clojure
{:audio-cmd {:op :load :src "https://..." :start 42 :autoplay? false}}
;; → sets audio.src, queues audio.load(); on loadedmetadata:
;;   audio.currentTime = start
;;   if autoplay? → audio.play()

{:audio-cmd {:op :play}}
{:audio-cmd {:op :pause}}
{:audio-cmd {:op :seek :time 120}}
{:audio-cmd {:op :seek-relative :delta -15}}
{:audio-cmd {:op :set-rate :rate 1.5}}
```

### Audio Interop (`audio.cljs`)

- Single `js/Audio.` element created at module load time, appended to `document.body`
- `execute-cmd!` multimethod dispatches on `:op`
- `{:op :load}` sets `audio.src`, calls `audio.load()`, registers a one-time `loadedmetadata` listener that sets `audio.currentTime = start` and calls `audio.play()` if `:autoplay? true`
- Listeners registered once at init:
  - `timeupdate` → `(rf/dispatch-sync [::audio-tick audio.currentTime])` inside rAF throttle
  - `durationchange` → `(rf/dispatch [::audio-duration audio.duration])`
  - `play` → `(rf/dispatch [::audio-playing])`
  - `pause` → `(rf/dispatch [::audio-paused])`
  - `ended` → `(rf/dispatch [::audio-ended])`
- MediaSession API wired once at init for lock-screen controls
- **Progress-save interval**: `js/setInterval` created once in `audio.cljs` `init!` function, fires every 5000ms, reads current episode-id and current-time from `audio` element directly (not from app-db), calls `(rf/dispatch [::save-progress episode-id current-time])` only if `(not audio.paused)`. Interval is never cancelled (lives for the app lifetime).

### Pending Episode Pattern

1. User navigates to episode B's player while episode A is playing
2. `::player-loaded` sees `:audio/playing? true` and `:audio/episode-id ≠ B` → dispatches `::audio-queue-pending`
3. `::audio-queue-pending`: sets `:audio/pending? true`; episode A continues playing; miniplayer still shows A
4. Player view: renders ▶ button when `(:audio/pending? db)` is true; seek bar disabled
5. User presses ▶ → `::toggle-play-pause` sees `:pending? true` → dispatches `::audio-commit-pending`
6. `::audio-commit-pending`: sets `:pending? false`, dispatches `::audio-load` with `{:autoplay? true}` — the `loadedmetadata` listener starts episode B

### Views

| Component | Key subscriptions | Key interactions |
|---|---|---|
| `layout.cljs` | `:view` | Tab clicks → `::navigate`; always renders `[miniplayer]` |
| `miniplayer.cljs` | `:audio` (episode-id, title, artist, artwork, playing?, rate) | Play/pause → `::toggle-play-pause`; speed → `::cycle-speed`; click bar → `::navigate :player {:episode-id current-id}` |
| `inbox.cljs` | `:inbox` | Episode click → `::navigate :player`; filter events; `listened` from episode objects drives CSS class and hide filter |
| `feeds.cljs` | `:feeds` | Subscribe form; `::unsubscribe-feed` per feed |
| `episodes.cljs` | `:episodes` | Load more; `::set-order`; back → `::navigate :feeds` |
| `player.cljs` | `:player`, `:audio` | All playback events; bookmark; autoplay toggle; subscribe; share builds `t.me/BOT?start=ep_ID`; "Send to Chat" button is not rendered in this phase |
| `bookmarks.cljs` | `:bookmarks` | Search (debounced 300ms); episode click → `::navigate :player` |

### CSS

`public/css/app.css` is kept as-is. Reagent components use the same class names as the existing ECR templates. No CSS framework is added.

---

## Migration Strategy

1. Create branch `feature/clojurescript-spa`
2. Add `shadow-cljs.edn`, update `package.json` — `shadow-cljs watch app` outputs to `public/js/main.js`; old JS files untouched
3. Convert Crystal backend routes to JSON one file at a time; existing `layout.ecr` and old JS files remain throughout
4. Build ClojureScript SPA in `src/cljs/buzz_bot/`; test by loading `/app-spa` (a temporary test route serving the new HTML shell) alongside the live app
5. When SPA is feature-complete and manually tested, perform cutover:
   a. Replace `src/views/layout.ecr` with the new HTML shell (as specified above)
   b. Remove the temporary `/app-spa` route
6. Delete dead files:
   - `public/js/app.js`, `miniplayer.js`, `cache.js`, `write-queue.js`, `htmx.min.js`
   - `public/sw.js`
   - `src/js/` directory (Preact source)
   - All `src/views/*.ecr` files
