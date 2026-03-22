# Episode Audio Caching — Design Spec

**Date:** 2026-03-20
**Status:** Approved

---

## Overview

While an episode is playing, download it in parallel and cache the audio blob in IndexedDB. Once the full download completes, subsequent plays of that episode use the local blob instead of streaming. Cache up to 5 episodes (LRU eviction). Cached episodes play fully offline.

The "early/partial-blob switch" (swap src mid-play at a byte threshold) is **deferred to a follow-up**: partial blobs produce an unreliable `duration` on the `<audio>` element (often `Infinity`), which breaks completion-percentage logic and progress saves. The initial implementation caches in the background and uses the blob on the *next* play.

---

## Goals

1. **Parallel caching** — start downloading when playback begins; stream plays immediately with no delay
2. **Full-blob switch** — on the next play of a cached episode, use the IDB blob URL instead of streaming
3. **LRU cap** — maximum 5 cached episodes; when a 6th completes, evict the oldest
4. **Offline playback** — if `navigator.onLine` is false and the episode is cached, skip the server fetch and play from IDB blob directly
5. **Progress visibility** — player seek bar shows download progress in green behind the playback cursor
6. **Inbox indicators** — cached episodes appear bold in the Inbox list
7. **Manual eviction** — "Clear cache" button on Inbox page deletes all cached blobs

---

## Non-Goals

- No byte-size cap (count-only LRU)
- No background caching of episodes the user hasn't played
- No Service Worker changes for audio caching (Cache API evictability makes it unsuitable for blobs)
- No server changes (existing `/episodes/:id/audio_proxy` endpoint is used as-is)
- No mid-play partial-blob source swap (deferred)

---

## Architecture

All caching logic lives in ClojureScript. A new `cache.cljs` namespace owns IndexedDB operations and the streaming download pipeline. Re-frame events coordinate state transitions.

```
User taps Play
  │
  └─▶ ::fetch-player (existing)
        │
        ├─ If offline AND episode cached → ::cache-load-blob → play from IDB, skip server fetch
        │     └─ IDB blob missing?      → ::fetch-player-forced (bypasses offline check, fails to ::fetch-error if still offline)
        ├─ If offline, not cached        → fetch proceeds, fails → ::fetch-error (existing error UI)
        └─ If online                     → fetch /episodes/:id/player as normal
                                              → ::player-loaded → persist episode metadata to localStorage
                                                               → ::audio-load
                                                                     └─▶ ::cache-start (parallel)
                                                                              │
                                                                              ├─ Already cached? → no-op (blob used next play)
                                                                              ├─ In progress?    → no-op (download continues)
                                                                              └─ Not cached      → ::fx/start-cache-download
                                                                                                       │
                                                                                                       ├─ chunks → ::cache-progress
                                                                                                       └─ done   → ::cache-complete → IDB write → LRU evict if >5
```

---

## State Model

Added to `app-db` initial state:

```clojure
{:cache {:cached-ids  []   ;; LRU-ordered vector of episode IDs (strings), most-recent first, max 5
         :in-progress {}   ;; episode-id (string) → {:bytes-downloaded N :bytes-total N}
         :blob-urls   {}}} ;; episode-id (string) → blob URL string (for revocation on eviction)
```

**Episode IDs are strings throughout** — consistent with the rest of the app (`events.cljs` coerces IDs via `(str ...)`). All cache lookups, LRU comparisons, and IDB keys use the string form.

`cached-ids` is also persisted in `localStorage` (key `buzz-cached-ids`) and loaded at app init.

Actual audio blobs are stored in IndexedDB:
- **DB name:** `buzz-audio`
- **Store name:** `blobs`
- **Key:** episode ID as string
- **Value:** `{blob: <Blob>, episodeId: "<id>"}`

Episode metadata (title, artist, artwork, duration) needed for offline playback is persisted in `localStorage` under `buzz-episode-meta-<id>` as JSON when `::player-loaded` fires. This is a small object (~200 bytes) per episode. The `::cache-init` event does not need to load this — it is read on demand by `::cache-load-blob`.

`navigator.storage.persist()` is called after first write to prevent browser-initiated eviction.

---

## Files Changed

| File | Change |
|------|--------|
| `src/cljs/buzz_bot/cache.cljs` | **New.** IDB open/read/write/delete; streaming download; LRU helpers |
| `src/cljs/buzz_bot/db.cljs` | Add `:cache {:cached-ids [] :in-progress {} :blob-urls {}}` to `default-db` |
| `src/cljs/buzz_bot/events.cljs` | Add cache events; offline check in `::fetch-player`; persist episode metadata in `::player-loaded` |
| `src/cljs/buzz_bot/fx.cljs` | Add `::start-cache-download` effect |
| `src/cljs/buzz_bot/subs.cljs` | Add `::cache-progress`, `::episode-cached?`, `::cached-ids` subscriptions |
| `src/cljs/buzz_bot/views/player.cljs` | Pass `--cache-pct` CSS var to seek bar |
| `src/cljs/buzz_bot/views/inbox.cljs` | Apply `.cached` class to cached episode rows; add "Clear cache" button in header |
| `public/css/app.css` | Green cache fill on seek bar; `.episode-item.cached` bold |

`miniplayer.cljs` uses a separate progress display and does **not** render the seek bar — no changes needed there.

---

## Detailed Flow

### Offline detection — in `::fetch-player`

The offline check belongs in `::fetch-player` (not `::audio-load`) because the network error from a failed server fetch happens before `::audio-load` is ever reached. Add this guard at the top of the `::fetch-player` handler:

```clojure
(rf/reg-event-fx
 ::fetch-player
 (fn [{:keys [db]} [_ episode-id params]]
   (let [cached-ids (get-in db [:cache :cached-ids])
         ep-id      (str episode-id)
         cached?    (contains? (set cached-ids) ep-id)
         offline?   (not (.-onLine js/navigator))]
     (if (and offline? cached?)
       ;; Skip server fetch — load from IDB blob directly
       {:db       (assoc-in db [:player :loading?] true)
        :dispatch [::cache-load-blob ep-id params]}
       ;; Normal online path
       {:db           (assoc-in db [:player :loading?] true)
        ::fx/http-fetch {:method :get
                         :url    (str "/episodes/" episode-id "/player")
                         :on-ok  [::player-loaded params]
                         :on-err [::fetch-error]}}))))
```

If offline and not cached, the normal fetch proceeds and fails naturally — `::fetch-error` handles it, showing the existing error UI.

### Episode metadata persistence (in `::player-loaded`)

When `::player-loaded` fires after a successful server fetch, persist a small metadata snapshot to localStorage so the player can be reconstructed offline:

```clojure
;; Inside ::player-loaded, after updating app-db:
(let [ep      (get-in data [:episode])
      ep-id   (str (:id ep))
      meta    {:id       ep-id
               :title    (:title ep)
               :artist   (get-in data [:feed :title])
               :artwork  (:artwork_url ep)       ;; or whichever key the server uses
               :duration (:duration ep)
               :audio_url (:audio_url ep)}]
  (.setItem js/localStorage
            (str "buzz-episode-meta-" ep-id)
            (.stringify js/JSON (clj->js meta))))
```

This is a side effect inside the event handler (same pattern as the existing `restore-audio-state!` localStorage reads). It is small and synchronous.

### `::cache-load-blob`

Reads the blob from IDB and the metadata from localStorage, then populates the player without a server round-trip:

```clojure
(rf/reg-event-fx
 ::cache-load-blob
 (fn [{:keys [db]} [_ ep-id params]]
   {::fx/get-cached-blob {:episode-id ep-id
                          :on-ready   [::cached-blob-ready ep-id params]
                          :on-missing [::fetch-player-forced ep-id params]}}))
```

`::fx/get-cached-blob` calls `cache/get-blob-url` (IDB read) and dispatches `:on-ready` with the blob URL, or `:on-missing` if the IDB record is gone (stale index).

### `::cached-blob-ready`

Reads saved episode metadata from localStorage and populates the player state, then issues the audio-load command with the blob URL:

```clojure
(rf/reg-event-fx
 ::cached-blob-ready
 (fn [{:keys [db]} [_ ep-id params blob-url]]
   (let [raw  (.getItem js/localStorage (str "buzz-episode-meta-" ep-id))
         meta (when raw (js->clj (.parse js/JSON raw) :keywordize-keys true))]
     (if (nil? meta)
       ;; Metadata missing — fall back to online fetch
       {:dispatch [::fetch-player-forced ep-id params]}
       ;; Reconstruct player state from cached metadata
       {:db           (-> db
                          (assoc-in [:player :loading?] false)
                          (assoc-in [:player :data]
                                    {:episode      meta
                                     :feed         {:title (:artist meta)}
                                     :user_episode {}
                                     :is_subscribed true
                                     :is_premium    true}))
        ::fx/audio-cmd {:op       :load
                        :src      blob-url
                        :start    (get-in db [:audio :saved-time] 0)
                        :autoplay? true
                        :title    (:title meta)
                        :artist   (:artist meta)
                        :artwork  (:artwork meta)}}))))
```

Note: `is_subscribed` and `is_premium` are set to `true` as safe defaults for offline — the user is already subscribed (they're using the app) and the premium gate is irrelevant when playing cached content. Any premium/subscription UI that depends on these values will show the most permissive state.

### `::fetch-player-forced`

Dispatches the HTTP fetch unconditionally, bypassing the offline check. This is the fallback when the IDB record claimed by `cached-ids` is actually missing (stale index):

```clojure
(rf/reg-event-fx
 ::fetch-player-forced
 (fn [{:keys [db]} [_ ep-id params]]
   {:db           (assoc-in db [:player :loading?] true)
    ::fx/http-fetch {:method :get
                     :url    (str "/episodes/" ep-id "/player")
                     :on-ok  [::player-loaded params]
                     :on-err [::fetch-error]}}))
```

This event is only reached when both conditions are true: (a) the episode was in `cached-ids` (triggered the offline path) and (b) the IDB blob is missing. It attempts a live fetch; if still offline, `::fetch-error` handles the failure normally.

### `::cache-start`

Dispatched from `::audio-load` after the audio stream begins:

```clojure
(rf/reg-event-fx
 ::cache-start
 (fn [{:keys [db]} [_ {:keys [episode-id]}]]
   (let [cached-ids  (get-in db [:cache :cached-ids])
         in-progress (get-in db [:cache :in-progress])
         init-data   (:init-data db)]        ;; read from app-db, same as fx.cljs line 34
     (cond
       (contains? (set cached-ids) episode-id)  nil  ;; already cached
       (contains? in-progress episode-id)        nil  ;; download running
       :else
       {:db (assoc-in db [:cache :in-progress episode-id] {:bytes-downloaded 0 :bytes-total 0})
        ::fx/start-cache-download {:episode-id episode-id
                                   :url        (str "/episodes/" episode-id "/audio_proxy")
                                   :init-data  init-data}}))))
```

`init-data` is passed explicitly to the effect — `cache.cljs` receives it as a parameter rather than reading from `window` or `app-db` directly. This mirrors the pattern in `fx.cljs` line 34.

### Streaming download (`::fx/start-cache-download` effect + `cache.cljs`)

```
fetch(url, {headers: {"X-Init-Data": init-data}})
  → response.body.getReader()
  → accumulate Uint8Array chunks
  → on each chunk:
      dispatch [:buzz-bot.events/cache-progress {:episode-id id :bytes-downloaded N :bytes-total total}]
  → on complete:
      full-blob = new Blob(all-chunks, {type: "audio/mpeg"})
      write to IDB (key = episode-id string)
      call navigator.storage.persist()
      blob-url = URL.createObjectURL(full-blob)
      dispatch [:buzz-bot.events/cache-complete {:episode-id id :blob-url blob-url}]
  → on error:
      dispatch [:buzz-bot.events/cache-error {:episode-id id :error msg}]
```

**Download continues in the background if the user switches episodes.** The next `::cache-start` for a new episode is a no-op only for that specific episode — the old download continues to completion and caches silently. This is intentional: the download is already in-flight, aborting it wastes the bytes already transferred. No `AbortController` is needed.

### LRU eviction (`::cache-complete` handler)

```clojure
(rf/reg-event-fx
 ::cache-complete
 (fn [{:keys [db]} [_ {:keys [episode-id blob-url]}]]
   (let [cached-ids (get-in db [:cache :cached-ids])
         new-ids    (into [episode-id] (remove #{episode-id} cached-ids))  ;; most-recent first
         to-evict   (when (> (count new-ids) 5) (last new-ids))
         final-ids  (vec (take 5 new-ids))]
     ;; blob-url was created by the ::fx/start-cache-download effect and passed in the dispatch payload
     (.setItem js/localStorage "buzz-cached-ids"
               (.stringify js/JSON (clj->js final-ids)))
     (cond-> {:db (-> db
                      (assoc-in [:cache :cached-ids] final-ids)
                      (assoc-in [:cache :blob-urls episode-id] blob-url)
                      (update-in [:cache :in-progress] dissoc episode-id))}
       to-evict (assoc :dispatch [::cache-evict to-evict])))))
```

`::cache-evict` is expressed as a `:dispatch` key in the effect map (not an inline `rf/dispatch`), preserving re-frame's event purity. The `::cache-evict` handler:
1. Calls `cache/delete-blob!` (IDB delete) for the episode ID
2. Revokes the stored blob URL via `URL.revokeObjectURL` (looked up from `[:cache :blob-urls ep-id]`)
3. Removes the ID from `[:cache :cached-ids]` and `[:cache :blob-urls]`

### `::cache-clear-all`

Uses a single IDB `objectStore.clear()` call rather than N individual deletes, then revokes all blob URLs and resets state:

```clojure
(rf/reg-event-fx
 ::cache-clear-all
 (fn [{:keys [db]} _]
   (let [blob-urls (vals (get-in db [:cache :blob-urls]))]
     ;; Revoke all blob URLs
     (doseq [url blob-urls] (js/URL.revokeObjectURL url))
     ;; Clear localStorage
     (.removeItem js/localStorage "buzz-cached-ids")
     {:db       (-> db
                    (assoc-in [:cache :cached-ids] [])
                    (assoc-in [:cache :blob-urls] {})
                    (assoc-in [:cache :in-progress] {}))
      ::fx/clear-cache-db nil})))  ;; effect calls cache/clear-all-blobs! → IDB objectStore.clear()
```

---

## UI Changes

### Player seek bar — dual fill

The seek bar already uses `--pct` (playback position). Add `--cache-pct` to the `:style` map:

```clojure
(defn- seek-bar [current duration pending? cache-pct]
  (let [pct (if (pos? duration) (* 100 (/ current duration)) 0)]
    [:input#player-seek.player-seek-bar
     {:type      "range" :min 0 :max 100 :step 0.1
      :value     pct
      :disabled  pending?
      :style     {"--pct"       (str (.toFixed pct 2) "%")
                  "--cache-pct" (str (.toFixed (or cache-pct 0) 2) "%")}
      :on-change #(when (pos? duration)
                    (rf/dispatch [::events/audio-seek
                                  (* (/ (.. % -target -value) 100) duration)]))}]))
```

`cache-pct` defaults to `0` when not supplied (e.g. any future caller that passes 3 args).

CSS — the existing `.player-seek-bar` background rule gains the green band:

```css
.player-seek-bar {
  background: linear-gradient(
    to right,
    var(--button-color)    0%,
    var(--button-color)    var(--pct),
    #4caf50                var(--pct),
    #4caf50                var(--cache-pct),
    rgba(0,0,0,0.15)       var(--cache-pct),
    rgba(0,0,0,0.15)       100%
  );
}
```

When `--cache-pct` ≤ `--pct`, the green section is zero width and invisible.

In `player.cljs`:

```clojure
(let [ep-id          (str (get-in data [:episode :id]))
      cache-progress @(rf/subscribe [::subs/cache-progress ep-id])
      cached?        @(rf/subscribe [::subs/episode-cached? ep-id])
      cache-pct      (cond
                       cached?                                100
                       (pos? (:bytes-total cache-progress 0)) (* 100 (/ (:bytes-downloaded cache-progress)
                                                                        (:bytes-total cache-progress)))
                       :else                                  0)]
  [seek-bar cur-time duration pending? cache-pct])
```

### Inbox — bold cached episodes + Clear cache button

```clojure
(let [cached-ids @(rf/subscribe [::subs/cached-ids])   ;; a set of strings
      ...]
  ;; In the header row:
  [:button.btn-clear-cache
   {:on-click #(rf/dispatch [::events/cache-clear-all])}
   "🗑 Clear cache"]

  ;; On each episode list item:
  [:li.episode-item
   {:class (when (contains? cached-ids (str (:id ep))) "cached")}
   ...])
```

```css
.episode-item.cached .episode-title {
  font-weight: 700;
}
```

---

## Subscriptions

```clojure
;; Base: all cached IDs as a set of strings
(rf/reg-sub ::cached-ids
  (fn [db _]
    (set (get-in db [:cache :cached-ids]))))

;; Whether a specific episode is fully cached — uses ::cached-ids as signal (no redundant set creation)
(rf/reg-sub ::episode-cached?
  :<- [::cached-ids]
  (fn [cached-ids [_ episode-id]]
    (contains? cached-ids episode-id)))

;; Download progress for a specific episode
(rf/reg-sub ::cache-progress
  (fn [db [_ episode-id]]
    (get-in db [:cache :in-progress episode-id])))
```

---

## Init

In `core.cljs`'s `mount!`, insert `::cache-init` **between** `restore-audio-state!` and `audio/init!`:

```clojure
(defn- mount! []
  (restore-audio-state!)
  (rf/dispatch-sync [::events/cache-init])  ;; ← insert here
  (audio/init!)
  (rdom/render [views/app] (.getElementById js/document "app"))
  (check-deep-link))
```

`dispatch-sync` ensures cache state is in app-db before the first render, so the seek bar shows the correct green fill immediately on reload. Placement before `audio/init!` ensures the cache state is available if `audio/init!` or `restore-audio-state!` eventually dispatches a play command.

`::cache-init`:
1. Reads `buzz-cached-ids` from localStorage, parses the JSON array, coerces all values to strings
2. Sets `[:cache :cached-ids]` in app-db
3. Returns `{::fx/open-cache-db nil}` — effect calls `cache/open-db!` to establish the IDB connection

---

## Error Handling

- Download fetch fails → `::cache-error` → remove from `:in-progress`, log to console; audio continues streaming normally
- IDB write fails → same as above; no user-visible error
- IDB unavailable (private browsing, quota exceeded) → caching silently disabled; streaming always used
- `navigator.storage.persist()` denied → log warning; caching still works but may be evicted by browser under storage pressure
- Stale `cached-ids` index (IDB record deleted externally) → `::cache-load-blob` dispatches `::fetch-player-online` fallback when blob is not found in IDB

---

## Blob URL Lifecycle

- Blob URLs are created in the `::fx/start-cache-download` effect when the download completes
- The URL is stored in `[:cache :blob-urls episode-id]` in app-db
- On `::cache-evict`: `URL.revokeObjectURL` is called before IDB delete
- On `::cache-clear-all`: all blob URLs are revoked before clearing IDB
- On page reload: IDB blobs are re-read on demand (via `::cache-load-blob`) and new blob URLs are created; stale in-memory URLs from a previous session are never created

---

## Verification Checklist

1. Play an episode → Network tab shows audio proxy request AND a separate parallel download request
2. Green fill appears on seek bar and advances independently of playback cursor
3. After download completes, stop and replay the episode → no new network request for audio (blob URL used, green bar at 100%)
4. Play 6 episodes to completion → oldest disappears from `localStorage` `buzz-cached-ids`; IDB record deleted; its blob URL revoked
5. Go offline, play a cached episode → no server fetch attempted; plays from blob URL
6. Go offline, try to play an uncached episode → server fetch fails → existing error UI shown
7. Inbox page → cached episodes appear bold
8. "Clear cache" → all IDB records cleared atomically, `cached-ids` emptied, all blob URLs revoked, bold styling removed
9. Page reload → `::cache-init` fires before first render; seek bar shows 100% green for cached episodes immediately
10. Switch episodes mid-download → old download continues silently to completion and caches; new episode streams normally
