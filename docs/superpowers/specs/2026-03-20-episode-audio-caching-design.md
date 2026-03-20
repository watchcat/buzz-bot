# Episode Audio Caching — Design Spec

**Date:** 2026-03-20
**Status:** Approved

---

## Overview

While an episode is playing, download it in parallel and cache the audio blob in IndexedDB. Once 5+ minutes of audio is buffered, switch the audio element's source from the live stream to the locally cached blob. Cache up to 5 episodes (LRU eviction). Cached episodes play fully offline.

---

## Goals

1. **Parallel caching** — start downloading when playback begins, stream plays immediately with no delay
2. **Early switch** — swap `audio.src` to cached blob once ≥5 min of audio is available locally
3. **LRU cap** — maximum 5 cached episodes; when a 6th completes, evict the oldest
4. **Offline playback** — if `navigator.onLine` is false and the episode is cached, play from IDB blob directly
5. **Progress visibility** — player seek bar shows cache progress in green behind the playback cursor
6. **Inbox indicators** — cached episodes appear bold in the Inbox list
7. **Manual eviction** — "Clear cache" button on Inbox page deletes all cached blobs

---

## Non-Goals

- No byte-size cap (count-only LRU)
- No background caching (only caches the currently playing episode)
- No Service Worker changes for audio caching (Cache API evictability makes it unsuitable for blobs)
- No server changes (existing `/episodes/:id/audio_proxy` endpoint is used as-is)

---

## Architecture

All caching logic lives in ClojureScript. A new `cache.cljs` namespace owns IndexedDB operations (open, read, write, delete) and the streaming download pipeline. Re-frame events coordinate state transitions. The audio element switch is handled by a new `:switch-src` command in `audio.cljs`.

```
User taps Play
  │
  ├─▶ ::audio-load  →  stream begins immediately
  │
  └─▶ ::cache-start
        │
        ├─ Already cached?  →  ::audio-load uses blob URL (no stream)
        ├─ In progress?     →  no-op
        └─ Not cached       →  ::fx/start-cache-download
                                  │
                                  ├─ chunks arriving → ::cache-progress (updates app-db)
                                  ├─ threshold hit   → ::cache-ready  → :switch-src (mid-play swap)
                                  └─ download done   → ::cache-complete → IDB write → LRU evict if >5
```

---

## State Model

Added to `app-db` initial state:

```clojure
{:cache {:cached-ids  []   ;; LRU-ordered vector of episode IDs, oldest first, max 5
         :in-progress {}}} ;; episode-id → {:bytes-downloaded N :bytes-total N}
```

`cached-ids` is also persisted in `localStorage` (key `buzz-cached-ids`) and loaded at app init so the cache survives page reloads.

Actual audio blobs are stored in IndexedDB:
- **DB name:** `buzz-audio`
- **Store name:** `blobs`
- **Key:** episode ID (integer)
- **Value:** `{:blob <Blob> :episode-id N}`

`navigator.storage.persist()` is called after first write to prevent browser-initiated eviction.

---

## Files Changed

| File | Change |
|------|--------|
| `src/cljs/buzz_bot/cache.cljs` | **New.** IDB open/read/write/delete; streaming download with early-switch callback; LRU helpers |
| `src/cljs/buzz_bot/db.cljs` | Add `:cache {:cached-ids [] :in-progress {}}` to `default-db` |
| `src/cljs/buzz_bot/events.cljs` | Add cache events (see below) |
| `src/cljs/buzz_bot/fx.cljs` | Add `::start-cache-download` effect |
| `src/cljs/buzz_bot/subs.cljs` | Add `::cache-progress`, `::episode-cached?`, `::cached-ids` subscriptions |
| `src/cljs/buzz_bot/audio.cljs` | Add `:switch-src` command — swaps `audio.src` to blob URL while preserving `currentTime` |
| `src/cljs/buzz_bot/views/player.cljs` | Pass `--cache-pct` CSS var to seek bar; show cached indicator |
| `src/cljs/buzz_bot/views/inbox.cljs` | Apply `.cached` class to cached episode rows; add "Clear cache" button in header |
| `public/css/app.css` | Green cache fill on seek bar; `.episode-item.cached` bold |

---

## Detailed Flow

### Play + cache start

In the `::audio-load` event handler, after the existing audio-cmd dispatch:

```clojure
(rf/dispatch [::cache-start {:episode-id id :url audio-url}])
```

`::cache-start` handler logic:
- If `id` is in `cached-ids` → load from IDB blob URL directly (set `audio.src` to blob URL before play)
- If `id` is in `in-progress` → no-op (download already running)
- Else → return `{::fx/start-cache-download {:episode-id id :url audio-url}}`

### Streaming download (`cache.cljs`)

```
fetch(audio-proxy-url)
  → response.body.getReader()
  → accumulate Uint8Array chunks
  → on each chunk:
      dispatch ::cache-progress {:episode-id id :bytes-downloaded N :bytes-total total}
      if bytes-downloaded >= threshold AND not yet switched:
          partial-blob = new Blob(chunks-so-far, {type: "audio/mpeg"})
          partial-url  = URL.createObjectURL(partial-blob)
          dispatch ::cache-ready {:episode-id id :blob-url partial-url}
  → on complete:
      full-blob = new Blob(all-chunks, {type: "audio/mpeg"})
      store in IDB
      dispatch ::cache-complete {:episode-id id :blob-url (URL.createObjectURL full-blob)}
```

**Threshold calculation:**

```clojure
(let [bytes-per-sec (/ bytes-total duration-sec)  ;; from Content-Length + audio duration
      threshold     (* bytes-per-sec 300)]          ;; 5 min = 300 s
  ;; fallback if duration unknown: 2.3 MB (128 kbps × 5 min)
  (max threshold 2359296))
```

### Mid-play source switch (`:switch-src` in `audio.cljs`)

```clojure
(defmethod execute-cmd! :switch-src [{:keys [src]}]
  (let [t (.-currentTime audio-el)]
    (set! (.-src audio-el) src)
    (.load audio-el)
    (.addEventListener audio-el "loadedmetadata"
      (fn []
        (set! (.-currentTime audio-el) t)
        (-> (.play audio-el) (.catch (fn []))))
      #js{:once true})))
```

This is only triggered when playback is active (from `::cache-ready`).

### LRU eviction (`::cache-complete` handler)

```clojure
(let [new-ids (into [id] (remove #{id} cached-ids))  ;; move to front (most recent)
      to-evict (when (> (count new-ids) 5)
                 (last new-ids))
      final-ids (vec (take 5 new-ids))]
  ;; evict oldest if needed
  (when to-evict
    (rf/dispatch [::cache-evict to-evict]))
  ;; persist LRU index
  (.setItem js/localStorage "buzz-cached-ids" (.stringify js/JSON (clj->js final-ids)))
  {:db (-> db
           (assoc-in [:cache :cached-ids] final-ids)
           (update-in [:cache :in-progress] dissoc id))})
```

`::cache-evict` deletes the IDB record for the given episode ID.

### Offline detection

In `::audio-load`:

```clojure
(let [cached? (contains? (set cached-ids) episode-id)
      offline? (not (.-onLine js/navigator))]
  (cond
    (and offline? cached?)     ;; play from IDB blob
    (and offline? (not cached?)) ;; show error: "No internet connection"
    :else                        ;; normal stream + cache-start
    ))
```

---

## UI Changes

### Player seek bar — dual fill

The seek bar already uses `--pct` (playback position). Add `--cache-pct`:

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

When `--cache-pct` equals `--pct` or 0, no green is visible.

In `player.cljs`, the seek-bar component receives a `cache-pct` prop:

```clojure
(let [cache-progress @(rf/subscribe [::subs/cache-progress episode-id])
      cache-pct      (if (and (:bytes-total cache-progress) (pos? (:bytes-total cache-progress)))
                       (* 100 (/ (:bytes-downloaded cache-progress) (:bytes-total cache-progress)))
                       (if cached? 100 0))]
  [seek-bar cur-time duration pending? cache-pct])
```

### Inbox — bold cached episodes + Clear cache button

In `inbox.cljs`:

```clojure
;; In the header row:
[:button.btn-clear-cache
 {:on-click #(rf/dispatch [::events/cache-clear-all])}
 "🗑 Clear cache"]

;; On each episode list item:
[:li.episode-item
 {:class (when (contains? cached-ids-set (:id ep)) "cached")}
 ...]
```

```css
.episode-item.cached .episode-title {
  font-weight: 700;
}
```

---

## Subscriptions

```clojure
;; Cache download progress for a specific episode
(rf/reg-sub ::cache-progress
  (fn [db [_ episode-id]]
    (get-in db [:cache :in-progress episode-id])))

;; Whether an episode is fully cached
(rf/reg-sub ::episode-cached?
  (fn [db [_ episode-id]]
    (boolean (some #{episode-id} (get-in db [:cache :cached-ids])))))

;; All cached episode IDs (for inbox rendering)
(rf/reg-sub ::cached-ids
  (fn [db _]
    (set (get-in db [:cache :cached-ids]))))
```

---

## Init

In `core.cljs` `init!`:

```clojure
;; Load persisted LRU index from localStorage
(rf/dispatch [::events/cache-init])
```

`::cache-init` reads `buzz-cached-ids` from localStorage and sets `[:cache :cached-ids]` in app-db. Also opens the IDB connection (stored in a `defonce` atom in `cache.cljs`).

---

## Error Handling

- Download fetch fails → dispatch `::cache-error` → remove from `:in-progress`, log to console. Audio continues streaming normally.
- IDB write fails → same as above. No user-visible error.
- IDB unavailable (private browsing, storage denied) → caching silently disabled; streaming always used.
- Partial blob switch while user is seeking → `:switch-src` restores `currentTime` after `loadedmetadata`, so seek position is preserved.

---

## Verification Checklist

1. Play an episode → Network tab shows audio proxy request AND a parallel download request
2. Green fill appears on seek bar and advances independently of playback cursor
3. At ~5 min mark, Network tab shows streaming request cancelled; playback continues from blob
4. Play 6 episodes → oldest disappears from `localStorage` `buzz-cached-ids`; IDB record deleted
5. Go offline, play a cached episode → plays without network requests
6. Go offline, try to play an uncached episode → error shown
7. Inbox page → cached episodes appear bold
8. "Clear cache" → all IDB records deleted, `cached-ids` emptied, bold styling removed
