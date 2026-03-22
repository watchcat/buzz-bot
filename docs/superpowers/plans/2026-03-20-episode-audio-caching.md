# Episode Audio Caching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cache audio blobs in IndexedDB while playing, with LRU eviction, a green download progress bar, bold inbox indicators, offline playback, and a Clear cache button.

**Architecture:** A new `cache.cljs` namespace owns all IndexedDB operations. Re-frame events manage cache state in `app-db`. The `::fx/start-cache-download` effect streams the audio via `fetch`+`ReadableStream` in parallel with the browser's normal audio streaming, dispatching progress events back into re-frame. On the next play, the cached blob URL is used instead of the network stream.

**Tech Stack:** ClojureScript, re-frame 1.4.3, Reagent 1.2.0, shadow-cljs 2.28.18, IndexedDB (browser API), localStorage, Fetch Streams API

---

## File Map

| File | What changes |
|------|-------------|
| `src/cljs/buzz_bot/cache.cljs` | **New.** IDB open, read, write, delete, clear. |
| `src/cljs/buzz_bot/db.cljs` | Add `:cache` key to `default-db`. |
| `src/cljs/buzz_bot/subs.cljs` | Add `::cached-ids`, `::episode-cached?`, `::cache-progress`. |
| `src/cljs/buzz_bot/fx.cljs` | Add `::open-cache-db`, `::start-cache-download`, `::get-cached-blob`, `::delete-cache-blob`, `::clear-cache-db`. |
| `src/cljs/buzz_bot/events.cljs` | Add `::cache-init`, `::cache-start`, `::cache-progress`, `::cache-complete`, `::cache-error`, `::cache-evict`, `::cache-clear-all`, `::cache-load-blob`, `::cached-blob-ready`, `::fetch-player-forced`. Modify `::fetch-player`, `::player-loaded`, `::audio-load`. |
| `src/cljs/buzz_bot/core.cljs` | Add `dispatch-sync [::events/cache-init]` in `mount!`. |
| `src/cljs/buzz_bot/views/player.cljs` | Add `cache-pct` arg to `seek-bar`; subscribe to `::subs/cache-progress` and `::subs/episode-cached?` in view. |
| `src/cljs/buzz_bot/views/inbox.cljs` | Add `.cached` class on items; add "Clear cache" button. |
| `public/css/app.css` | Green cache fill on seek bar; `.episode-item.cached .episode-title` bold. |

---

## Task 1: Add `:cache` to app-db initial state

**Files:**
- Modify: `src/cljs/buzz_bot/db.cljs`

- [ ] **Step 1: Open the file and add the `:cache` key**

The current `default-db` ends on line 18. Add `:cache` before the closing `}`:

```clojure
(ns buzz-bot.db)

(def default-db
  {:view        :inbox
   :view-params {}
   :init-data   ""
   :theme       {}
   :inbox       {:episodes [] :loading? false
                 :filters  {:hide-listened? false :compact? false :excluded-feeds #{}}}
   :feeds       {:list [] :loading? false}
   :episodes    {:feed-id nil :list [] :loading? false :order :desc :offset 0 :has-more? false}
   :player      {:data nil :loading? false :send-status nil}
   :bookmarks   {:list [] :loading? false :query ""}
   :search      {:query "" :results [] :loading? false :subscribed-urls #{}}
   :audio       {:episode-id nil :title "" :artist "" :artwork ""
                 :src "" :playing? false :current-time 0 :duration 0
                 :rate 1 :autoplay? false :pending? false}
   :saved-list  {:view nil :count 0}
   :cache       {:cached-ids  []   ;; most-recent first, max 5
                 :in-progress {}   ;; ep-id (string) → {:bytes-downloaded N :bytes-total N}
                 :blob-urls   {}}}) ;; ep-id (string) → blob URL string
```

- [ ] **Step 2: Commit**

```bash
cd /home/watchcat/work/crystal/buzz-bot/.worktrees/feature-clojurescript-spa
git add src/cljs/buzz_bot/db.cljs
git commit -m "feat(cache): add :cache key to app-db initial state"
```

---

## Task 2: Add cache subscriptions

**Files:**
- Modify: `src/cljs/buzz_bot/subs.cljs`

- [ ] **Step 1: Add three subscriptions at the bottom of `subs.cljs`**

```clojure
;; Cache
(rf/reg-sub ::cached-ids
  (fn [db _]
    (set (get-in db [:cache :cached-ids]))))

(rf/reg-sub ::episode-cached?
  :<- [::cached-ids]
  (fn [cached-ids [_ episode-id]]
    (contains? cached-ids episode-id)))

(rf/reg-sub ::cache-progress
  (fn [db [_ episode-id]]
    (get-in db [:cache :in-progress episode-id])))
```

`::episode-cached?` uses `::cached-ids` as a signal input (re-frame `:<-` syntax) so it does not redundantly rebuild the set on every call.

- [ ] **Step 2: Compile to check for syntax errors**

```bash
cd /home/watchcat/work/crystal/buzz-bot/.worktrees/feature-clojurescript-spa
npx shadow-cljs compile app 2>&1 | tail -20
```

Expected: no errors, ends with `Build completed`.

- [ ] **Step 3: Commit**

```bash
git add src/cljs/buzz_bot/subs.cljs
git commit -m "feat(cache): add cache subscriptions"
```

---

## Task 3: Create `cache.cljs` — IndexedDB module

**Files:**
- Create: `src/cljs/buzz_bot/cache.cljs`

This namespace owns all IDB operations. It is called only from effects in `fx.cljs` — never directly from event handlers or views.

- [ ] **Step 1: Create the file**

```clojure
(ns buzz-bot.cache)

;; Single IDB connection, opened once at app init.
(defonce db-conn (atom nil))

;; ── Open ─────────────────────────────────────────────────────────────────────

(defn open-db! []
  (js/Promise.
    (fn [resolve reject]
      (let [req (.open js/indexedDB "buzz-audio" 1)]
        (set! (.-onupgradeneeded req)
              (fn [e]
                (let [db (.. e -target -result)]
                  (when-not (.contains (.-objectStoreNames db) "blobs")
                    (.createObjectStore db "blobs")))))
        (set! (.-onsuccess req)
              (fn [e]
                (reset! db-conn (.. e -target -result))
                (resolve (.. e -target -result))))
        (set! (.-onerror req)
              (fn [e] (reject (.. e -target -error))))))))

;; ── Helpers ───────────────────────────────────────────────────────────────────

(defn- store [mode]
  (-> @db-conn (.transaction "blobs" mode) (.objectStore "blobs")))

;; ── Read ─────────────────────────────────────────────────────────────────────

(defn get-blob! [episode-id]
  ;; Resolves with the IDB record object {blob: Blob, episodeId: string}
  ;; or nil if not found / IDB unavailable.
  (js/Promise.
    (fn [resolve _reject]
      (if-not @db-conn
        (resolve nil)
        (let [req (.get (store "readonly") episode-id)]
          (set! (.-onsuccess req) (fn [e] (resolve (.. e -target -result))))
          (set! (.-onerror req)   (fn [_] (resolve nil))))))))

;; ── Write ─────────────────────────────────────────────────────────────────────

(defn put-blob! [episode-id blob]
  (js/Promise.
    (fn [resolve reject]
      (if-not @db-conn
        (reject (js/Error. "IDB not open"))
        (let [req (.put (store "readwrite")
                        #js{:blob blob :episodeId episode-id}
                        episode-id)]
          (set! (.-onsuccess req) (fn [_] (resolve true)))
          (set! (.-onerror req)   (fn [e] (reject (.. e -target -error)))))))))

;; ── Delete ────────────────────────────────────────────────────────────────────

(defn delete-blob! [episode-id]
  (when @db-conn
    (.delete (store "readwrite") episode-id)))

;; ── Clear all ────────────────────────────────────────────────────────────────

(defn clear-all-blobs! []
  (when @db-conn
    (.clear (store "readwrite"))))
```

- [ ] **Step 2: Compile to check for syntax errors**

```bash
npx shadow-cljs compile app 2>&1 | tail -20
```

Expected: `Build completed` with no errors.

- [ ] **Step 3: Commit**

```bash
git add src/cljs/buzz_bot/cache.cljs
git commit -m "feat(cache): add IndexedDB module (cache.cljs)"
```

---

## Task 4: Add cache effects to `fx.cljs`

**Files:**
- Modify: `src/cljs/buzz_bot/fx.cljs`

- [ ] **Step 1: Add `[buzz-bot.cache :as cache]` to the `ns` require**

The current ns declaration ends at line 4. Change it to:

```clojure
(ns buzz-bot.fx
  (:require [re-frame.core :as rf]
            [re-frame.db]
            [buzz-bot.audio :as audio]
            [buzz-bot.cache :as cache]))
```

- [ ] **Step 2: Append the five new effects at the bottom of `fx.cljs`**

```clojure
;; ── ::open-cache-db ──────────────────────────────────────────────────────────
;; Opens the IndexedDB connection once at app startup.

(rf/reg-fx
 ::open-cache-db
 (fn [_]
   (-> (cache/open-db!)
       (.catch (fn [e] (js/console.warn "IDB open failed:" e))))))

;; ── ::start-cache-download ───────────────────────────────────────────────────
;; Streams audio from audio_proxy and stores the full blob in IDB.
;; Options: :episode-id, :url, :init-data
;; Dispatches:
;;   [:buzz-bot.events/cache-progress {:episode-id id :bytes-downloaded N :bytes-total N}]
;;   [:buzz-bot.events/cache-complete {:episode-id id :blob-url url}]
;;   [:buzz-bot.events/cache-error    {:episode-id id :error msg}]

(rf/reg-fx
 ::start-cache-download
 (fn [{:keys [episode-id url init-data]}]
   (let [chunks  #js []
         headers (js-obj "X-Init-Data" (or init-data ""))]
     (-> (js/fetch url #js{:headers headers})
         (.then
           (fn [resp]
             (let [total  (js/parseInt (.get (.-headers resp) "content-length") 10)
                   reader (.getReader (.-body resp))]
               (rf/dispatch [:buzz-bot.events/cache-progress
                             {:episode-id episode-id :bytes-downloaded 0 :bytes-total (or total 0)}])
               (letfn [(read-chunk []
                         (-> (.read reader)
                             (.then
                               (fn [result]
                                 (if (.-done result)
                                   ;; All chunks received — write to IDB
                                   (let [full-blob (js/Blob. chunks #js{:type "audio/mpeg"})]
                                     (-> (cache/put-blob! episode-id full-blob)
                                         (.then
                                           (fn [_]
                                             (when (.. js/navigator -storage -persist)
                                               (.. js/navigator -storage (persist)))
                                             (let [blob-url (js/URL.createObjectURL full-blob)]
                                               (rf/dispatch [:buzz-bot.events/cache-complete
                                                             {:episode-id episode-id
                                                              :blob-url   blob-url}]))))
                                         (.catch
                                           (fn [e]
                                             (rf/dispatch [:buzz-bot.events/cache-error
                                                           {:episode-id episode-id
                                                            :error      (str e)}])))))
                                   ;; More data — accumulate and report progress
                                   (do (.push chunks (.-value result))
                                       (let [downloaded (reduce + 0 (map #(.-byteLength %) chunks))]
                                         (rf/dispatch [:buzz-bot.events/cache-progress
                                                       {:episode-id      episode-id
                                                        :bytes-downloaded downloaded
                                                        :bytes-total     (or total 0)}]))
                                       (read-chunk)))))
                             (.catch
                               (fn [e]
                                 (rf/dispatch [:buzz-bot.events/cache-error
                                               {:episode-id episode-id
                                                :error      (str e)}])))))]
                 (read-chunk)))))
         (.catch
           (fn [e]
             (rf/dispatch [:buzz-bot.events/cache-error
                           {:episode-id episode-id :error (str e)}])))))))

;; ── ::get-cached-blob ────────────────────────────────────────────────────────
;; Reads a blob from IDB and dispatches :on-ready with the blob URL,
;; or :on-missing if the record is not found.
;; Options: :episode-id, :on-ready (event vec), :on-missing (event vec)

(rf/reg-fx
 ::get-cached-blob
 (fn [{:keys [episode-id on-ready on-missing]}]
   (-> (cache/get-blob! episode-id)
       (.then
         (fn [record]
           (if record
             (rf/dispatch (conj on-ready (js/URL.createObjectURL (.-blob record))))
             (rf/dispatch on-missing))))
       (.catch
         (fn [_] (rf/dispatch on-missing))))))

;; ── ::delete-cache-blob ──────────────────────────────────────────────────────
;; Revokes a blob URL and deletes the IDB record.
;; Options: :episode-id, :blob-url

(rf/reg-fx
 ::delete-cache-blob
 (fn [{:keys [episode-id blob-url]}]
   (when blob-url (js/URL.revokeObjectURL blob-url))
   (cache/delete-blob! episode-id)))

;; ── ::clear-cache-db ─────────────────────────────────────────────────────────
;; Revokes all blob URLs and clears the entire IDB store.
;; Value: sequence of blob URL strings to revoke.

(rf/reg-fx
 ::clear-cache-db
 (fn [blob-urls]
   (doseq [url blob-urls]
     (when url (js/URL.revokeObjectURL url)))
   (cache/clear-all-blobs!)))
```

- [ ] **Step 3: Compile**

```bash
npx shadow-cljs compile app 2>&1 | tail -20
```

Expected: `Build completed`.

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/fx.cljs
git commit -m "feat(cache): add cache effects to fx.cljs"
```

---

## Task 5: Add `::cache-init` event and wire into `core.cljs`

**Files:**
- Modify: `src/cljs/buzz_bot/events.cljs` (add one event at the bottom)
- Modify: `src/cljs/buzz_bot/core.cljs` (one line in `mount!`)

- [ ] **Step 1: Add `::cache-init` to the end of `events.cljs`**

Append after the last event in `events.cljs`:

```clojure
;; ── Cache init ───────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::cache-init
 (fn [{:keys [db]} _]
   (let [raw (js/localStorage.getItem "buzz-cached-ids")
         ids (if raw
               (try (mapv str (js->clj (.parse js/JSON raw)))
                    (catch :default _ []))
               [])]
     {:db (assoc-in db [:cache :cached-ids] ids)
      ::buzz-bot.fx/open-cache-db nil})))
```

`mapv str` coerces every ID to a string, consistent with the rest of the app.

- [ ] **Step 2: Wire `dispatch-sync` in `core.cljs`**

In `core.cljs`, the current `mount!` is:

```clojure
(defn- mount! []
  (.ready (tg))
  (.expand (tg))
  (apply-theme!)
  (rf/dispatch-sync [::events/initialize-db])
  (rf/dispatch-sync [::events/set-init-data (.. (tg) -initData)])
  (restore-audio-state!)
  (audio/init!)
  (check-deep-link)
  (rdom/render [error-boundary [layout/root]] (js/document.getElementById "app")))
```

Insert the `cache-init` dispatch between `restore-audio-state!` and `audio/init!`:

```clojure
(defn- mount! []
  (.ready (tg))
  (.expand (tg))
  (apply-theme!)
  (rf/dispatch-sync [::events/initialize-db])
  (rf/dispatch-sync [::events/set-init-data (.. (tg) -initData)])
  (restore-audio-state!)
  (rf/dispatch-sync [::events/cache-init])
  (audio/init!)
  (check-deep-link)
  (rdom/render [error-boundary [layout/root]] (js/document.getElementById "app")))
```

`dispatch-sync` ensures cache state is in app-db before the first render.

- [ ] **Step 3: Compile**

```bash
npx shadow-cljs compile app 2>&1 | tail -20
```

Expected: `Build completed`.

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/events.cljs src/cljs/buzz_bot/core.cljs
git commit -m "feat(cache): add ::cache-init event and wire into mount!"
```

---

## Task 6: Add cache lifecycle events

**Files:**
- Modify: `src/cljs/buzz_bot/events.cljs`

Add all six lifecycle events after `::cache-init` at the bottom of `events.cljs`.

- [ ] **Step 1: Add `::cache-start`**

Dispatched from `::audio-load` when an episode begins playing. No-ops if already cached or in progress.

```clojure
(rf/reg-event-fx
 ::cache-start
 (fn [{:keys [db]} [_ {:keys [episode-id]}]]
   (let [cached-ids  (get-in db [:cache :cached-ids])
         in-progress (get-in db [:cache :in-progress])
         init-data   (:init-data db)]
     (cond
       (contains? (set cached-ids) episode-id)  nil
       (contains? in-progress episode-id)        nil
       :else
       {:db (assoc-in db [:cache :in-progress episode-id]
                      {:bytes-downloaded 0 :bytes-total 0})
        ::buzz-bot.fx/start-cache-download
        {:episode-id episode-id
         :url        (str "/episodes/" episode-id "/audio_proxy")
         :init-data  init-data}}))))
```

- [ ] **Step 2: Add `::cache-progress`**

```clojure
(rf/reg-event-db
 ::cache-progress
 (fn [db [_ {:keys [episode-id bytes-downloaded bytes-total]}]]
   (assoc-in db [:cache :in-progress episode-id]
             {:bytes-downloaded bytes-downloaded
              :bytes-total      bytes-total})))
```

- [ ] **Step 3: Add `::cache-complete`**

Updates `cached-ids` (most-recent first), stores the blob URL, triggers eviction if > 5 episodes.

```clojure
(rf/reg-event-fx
 ::cache-complete
 (fn [{:keys [db]} [_ {:keys [episode-id blob-url]}]]
   (let [cached-ids (get-in db [:cache :cached-ids])
         ;; Deduplicate and put newest first
         new-ids    (into [episode-id] (remove #{episode-id} cached-ids))
         to-evict   (when (> (count new-ids) 5) (last new-ids))
         final-ids  (vec (take 5 new-ids))]
     (js/localStorage.setItem "buzz-cached-ids"
                              (.stringify js/JSON (clj->js final-ids)))
     (cond-> {:db (-> db
                      (assoc-in [:cache :cached-ids] final-ids)
                      (assoc-in [:cache :blob-urls episode-id] blob-url)
                      (update-in [:cache :in-progress] dissoc episode-id))}
       to-evict (assoc :dispatch [::cache-evict to-evict])))))
```

- [ ] **Step 4: Add `::cache-error`**

```clojure
(rf/reg-event-db
 ::cache-error
 (fn [db [_ {:keys [episode-id error]}]]
   (js/console.warn "Cache download failed for episode" episode-id ":" error)
   (update-in db [:cache :in-progress] dissoc episode-id)))
```

- [ ] **Step 5: Add `::cache-evict`**

```clojure
(rf/reg-event-fx
 ::cache-evict
 (fn [{:keys [db]} [_ episode-id]]
   (let [blob-url (get-in db [:cache :blob-urls episode-id])]
     {:db (-> db
              (update-in [:cache :cached-ids] #(vec (remove #{episode-id} %)))
              (update-in [:cache :blob-urls]  dissoc episode-id))
      ::buzz-bot.fx/delete-cache-blob {:episode-id episode-id
                                       :blob-url   blob-url}})))
```

- [ ] **Step 6: Add `::cache-clear-all`**

```clojure
(rf/reg-event-fx
 ::cache-clear-all
 (fn [{:keys [db]} _]
   (let [blob-urls (vals (get-in db [:cache :blob-urls]))]
     (js/localStorage.removeItem "buzz-cached-ids")
     {:db (-> db
              (assoc-in [:cache :cached-ids] [])
              (assoc-in [:cache :blob-urls]  {})
              (assoc-in [:cache :in-progress] {}))
      ::buzz-bot.fx/clear-cache-db blob-urls})))
```

- [ ] **Step 7: Compile**

```bash
npx shadow-cljs compile app 2>&1 | tail -20
```

Expected: `Build completed`.

- [ ] **Step 8: Commit**

```bash
git add src/cljs/buzz_bot/events.cljs
git commit -m "feat(cache): add cache lifecycle events (start/progress/complete/error/evict/clear)"
```

---

## Task 7: Modify `::fetch-player` and add offline playback events

**Files:**
- Modify: `src/cljs/buzz_bot/events.cljs`

- [ ] **Step 1: Replace the `::fetch-player` handler (lines 162–169)**

The new version adds an offline+cached guard at the top:

```clojure
(rf/reg-event-fx
 ::fetch-player
 (fn [{:keys [db]} [_ episode-id]]
   (let [order      (name (get-in db [:episodes :order] :desc))
         ep-id      (str episode-id)
         cached-ids (get-in db [:cache :cached-ids])
         cached?    (contains? (set cached-ids) ep-id)
         offline?   (not (.-onLine js/navigator))]
     (if (and offline? cached?)
       {:db       (assoc-in db [:player :loading?] true)
        :dispatch [::cache-load-blob ep-id]}
       {:db           (assoc-in db [:player :loading?] true)
        ::buzz-bot.fx/http-fetch {:method :get
                                  :url    (str "/episodes/" episode-id "/player?order=" order)
                                  :on-ok  [::player-loaded] :on-err [::fetch-error]}}))))
```

- [ ] **Step 2: Add `::cache-load-blob` after the `::fetch-player` handler**

```clojure
(rf/reg-event-fx
 ::cache-load-blob
 (fn [_ [_ ep-id]]
   {::buzz-bot.fx/get-cached-blob {:episode-id ep-id
                                    :on-ready   [::cached-blob-ready ep-id]
                                    :on-missing [::fetch-player-forced ep-id]}}))
```

- [ ] **Step 3: Add `::cached-blob-ready`**

Reads episode metadata from localStorage and reconstructs the player state without a server round-trip.

```clojure
(rf/reg-event-fx
 ::cached-blob-ready
 (fn [{:keys [db]} [_ ep-id blob-url]]
   (let [raw  (js/localStorage.getItem (str "buzz-episode-meta-" ep-id))
         meta (when raw
                (try (js->clj (.parse js/JSON raw) :keywordize-keys true)
                     (catch :default _ nil)))]
     (if (nil? meta)
       {:dispatch [::fetch-player-forced ep-id]}
       {:db           (-> db
                          (assoc-in [:player :loading?] false)
                          (assoc-in [:player :data]
                                    {:episode      meta
                                     :feed         {:title (:artist meta)}
                                     :user_episode {}
                                     :is_subscribed true
                                     :is_premium    true}))
        ::buzz-bot.fx/audio-cmd {:op       :load
                                  :src      blob-url
                                  :start    0
                                  :autoplay? true
                                  :title    (:title meta)
                                  :artist   (:artist meta)
                                  :artwork  (:artwork meta)}}))))
```

Note: `is_subscribed` and `is_premium` default to `true` for offline — the premium gate is irrelevant for cached content the user already owns.

- [ ] **Step 4: Add `::fetch-player-forced`**

Bypasses the offline check — used as a fallback when IDB record is missing despite appearing in `cached-ids`.

```clojure
(rf/reg-event-fx
 ::fetch-player-forced
 (fn [{:keys [db]} [_ ep-id]]
   (let [order (name (get-in db [:episodes :order] :desc))]
     {:db           (assoc-in db [:player :loading?] true)
      ::buzz-bot.fx/http-fetch {:method :get
                                 :url    (str "/episodes/" ep-id "/player?order=" order)
                                 :on-ok  [::player-loaded] :on-err [::fetch-error]}})))
```

- [ ] **Step 5: Compile**

```bash
npx shadow-cljs compile app 2>&1 | tail -20
```

Expected: `Build completed`.

- [ ] **Step 6: Commit**

```bash
git add src/cljs/buzz_bot/events.cljs
git commit -m "feat(cache): add offline playback path (cache-load-blob, cached-blob-ready, fetch-player-forced)"
```

---

## Task 8: Persist episode metadata and dispatch `::cache-start` on play

**Files:**
- Modify: `src/cljs/buzz_bot/events.cljs`

Two changes to existing handlers.

- [ ] **Step 1: Add metadata persistence to `::player-loaded`**

In the `::player-loaded` handler (lines 171–195), add localStorage persistence after the `db'` computation (before the `let [autoplay? ...]` block):

The new handler body — replace the entire `::player-loaded` registration:

```clojure
(rf/reg-event-fx
 ::player-loaded
 (fn [{:keys [db]} [_ resp]]
   (let [new-id    (str (get-in resp [:episode :id]))
         cur-id    (str (get-in db [:audio :episode-id]))
         playing?  (get-in db [:audio :playing?])
         episode   (get-in resp [:episode])
         loading-new? (not (and playing? (not= cur-id new-id)))
         db'       (cond-> (-> db
                               (assoc-in [:player :data]        resp)
                               (assoc-in [:player :loading?]    false)
                               (assoc-in [:player :send-status] nil))
                     loading-new?
                     (-> (assoc-in [:audio :title]   (:title episode))
                         (assoc-in [:audio :artist]  (:feed_title episode))
                         (assoc-in [:audio :artwork] (:feed_image_url episode))))]
     ;; Persist episode metadata for offline playback reconstruction
     (js/localStorage.setItem
       (str "buzz-episode-meta-" new-id)
       (.stringify js/JSON
         (clj->js {:id        new-id
                   :title     (:title episode)
                   :artist    (get-in resp [:feed :title])
                   :artwork   (:feed_image_url episode)
                   :audio_url (:audio_url episode)})))
     (let [autoplay? (get-in db [:view-params :autoplay?])]
       (cond
         (= cur-id new-id)                   {:db db'}
         (and playing? (not= cur-id new-id)) {:db db' :dispatch [::audio-queue-pending]}
         :else {:db db' :dispatch [::audio-load {:autoplay? (boolean autoplay?)}]})))))
```

- [ ] **Step 2: Add `::cache-start` dispatch to `::audio-load`**

In the `::audio-load` handler (lines 246–270), add `:dispatch [::cache-start {:episode-id ep-id}]` to the returned effect map.

Replace the entire `::audio-load` registration:

```clojure
(rf/reg-event-fx
 ::audio-load
 (fn [{:keys [db]} [_ opts]]
   (let [src       (get-in db [:player :data :episode :audio_url])
         start     (get-in db [:player :data :user_episode :progress_seconds] 0)
         ep-id     (str (get-in db [:player :data :episode :id]))
         autoplay? (:autoplay? opts false)]
     (js/localStorage.setItem "buzz-last-episode-id" ep-id)
     (js/localStorage.setItem "buzz-last-episode-meta"
       (.stringify js/JSON
         (clj->js {:title   (get-in db [:player :data :episode :title])
                   :podcast (get-in db [:player :data :episode :feed_title])
                   :artwork (get-in db [:player :data :episode :feed_image_url])})))
     {:db         (-> db
                      (assoc-in [:audio :episode-id] ep-id)
                      (assoc-in [:audio :feed-id]    (str (get-in db [:player :data :episode :feed_id])))
                      (assoc-in [:audio :src]        src)
                      (assoc-in [:audio :pending?]   false))
      ::buzz-bot.fx/audio-cmd {:op      :load
                               :src     src
                               :start   start
                               :autoplay? autoplay?
                               :title   (get-in db [:player :data :episode :title])
                               :artist  (get-in db [:player :data :episode :feed_title])
                               :artwork (get-in db [:player :data :episode :feed_image_url])}
      :dispatch [::cache-start {:episode-id ep-id}]})))
```

- [ ] **Step 3: Compile**

```bash
npx shadow-cljs compile app 2>&1 | tail -20
```

Expected: `Build completed`.

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/events.cljs
git commit -m "feat(cache): persist episode metadata in player-loaded; dispatch cache-start from audio-load"
```

---

## Task 9: Update the player seek bar to show cache progress

**Files:**
- Modify: `src/cljs/buzz_bot/views/player.cljs`

Two changes: (1) `seek-bar` gains a 4th `cache-pct` arg, (2) the `view` function subscribes to cache state and passes `cache-pct`.

- [ ] **Step 1: Replace the `seek-bar` function (lines 18–27)**

```clojure
(defn- seek-bar [current duration pending? cache-pct]
  (let [pct       (if (pos? duration) (* 100 (/ current duration)) 0)
        cpct      (or cache-pct 0)]
    [:input#player-seek.player-seek-bar
     {:type      "range" :min 0 :max 100 :step 0.1
      :value     pct
      :disabled  pending?
      :style     {"--pct"       (str (.toFixed pct 2) "%")
                  "--cache-pct" (str (.toFixed cpct 2) "%")}
      :on-change #(when (pos? duration)
                    (rf/dispatch [::events/audio-seek
                                  (* (/ (.. % -target -value) 100) duration)]))}]))
```

- [ ] **Step 2: Replace the entire inner `let` bindings block in the `fn []` form**

The current `let` block (starting at `(let [data @(rf/subscribe ...`) is the entire binding block inside the `(fn []` form of `view`. Replace it entirely with this version that adds `ep-id`, `cache-progress`, `cached?`, and `cache-pct`:

```clojure
(let [data           @(rf/subscribe [::subs/player-data])
      loading?       @(rf/subscribe [::subs/player-loading?])
      playing?       @(rf/subscribe [::subs/audio-playing?])
      pending?       @(rf/subscribe [::subs/audio-pending?])
      cur-time       @(rf/subscribe [::subs/audio-current-time])
      duration       @(rf/subscribe [::subs/audio-duration])
      rate           @(rf/subscribe [::subs/audio-rate])
      send-status    @(rf/subscribe [::subs/player-send-status])
      params         @(rf/subscribe [:buzz-bot.subs/view-params])
      ep-id          (str (get-in data [:episode :id] ""))
      cache-progress @(rf/subscribe [::subs/cache-progress ep-id])
      cached?        @(rf/subscribe [::subs/episode-cached? ep-id])
      cache-pct      (cond
                       cached?                                  100
                       (pos? (:bytes-total cache-progress 0))  (* 100.0
                                                                  (/ (:bytes-downloaded cache-progress)
                                                                     (:bytes-total cache-progress)))
                       :else                                    0)]
```

`ep-id` is derived from the already-bound `data` (not via a nested `rf/subscribe`), so there is no stale-subscription issue. Note that `cache-progress` and `cached?` subscriptions use `ep-id = ""` when `data` is nil (loading state), but the outer `cond` in the view body returns the loading div before any of those values are used.

Also update the `[seek-bar ...]` call site to pass `cache-pct`:

```clojure
[seek-bar cur-time duration pending? cache-pct]
```

- [ ] **Step 3: Compile**

```bash
npx shadow-cljs compile app 2>&1 | tail -20
```

Expected: `Build completed`.

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/views/player.cljs
git commit -m "feat(cache): add cache-pct to player seek bar"
```

---

## Task 10: Update Inbox — bold cached items + Clear cache button

**Files:**
- Modify: `src/cljs/buzz_bot/views/inbox.cljs`

- [ ] **Step 1: Add `::subs/cached-ids` subscription in the `view` fn**

In the inner `fn []`, add `cached-ids` to the `let`:

```clojure
cached-ids  @(rf/subscribe [::subs/cached-ids])
```

Full updated `let` in `view`:

```clojure
(let [episodes   @(rf/subscribe [::subs/inbox-episodes])
      loading?   @(rf/subscribe [::subs/inbox-loading?])
      filters    @(rf/subscribe [::subs/inbox-filters])
      playing-id @(rf/subscribe [::subs/audio-episode-id])
      cached-ids @(rf/subscribe [::subs/cached-ids])
      {:keys [hide-listened? compact?]} filters
      visible    (filter #(episode-visible? % filters) episodes)]
```

- [ ] **Step 2: Add `.cached` class in `episode-item`**

Change the `:class` computation in `episode-item` to accept `cached-ids` and add the `"cached"` class when the episode is in the set.

Replace:

```clojure
(defn- episode-item [ep playing-id]
  [:li.episode-item
   {:class           (cond-> ""
                       (:listened ep)                         (str " listened")
                       (= (str (:id ep)) (str playing-id))   (str " is-playing"))
```

With:

```clojure
(defn- episode-item [ep playing-id cached-ids]
  [:li.episode-item
   {:class           (cond-> ""
                       (:listened ep)                         (str " listened")
                       (= (str (:id ep)) (str playing-id))   (str " is-playing")
                       (contains? cached-ids (str (:id ep))) (str " cached"))
```

- [ ] **Step 3: Update `episode-item` call sites to pass `cached-ids`**

In `compact-group` and in `view`, every `[episode-item ep playing-id]` call becomes `[episode-item ep playing-id cached-ids]`.

`compact-group` signature changes to `[eps playing-id cached-ids ...]`, and its call in `view` changes too.

Full updated `compact-group`:

```clojure
(defn- compact-group [eps playing-id cached-ids expanded-feeds-atom]
  (let [feed-id  (:feed_id (first eps))
        expanded @expanded-feeds-atom]
    (if (or (= 1 (count eps)) (contains? expanded feed-id))
      (for [ep eps]
        ^{:key (:id ep)} [episode-item ep playing-id cached-ids])
      (list
        ^{:key (:id (first eps))}
        [:li.episode-item.compact-first
         {:class           (cond-> ""
                             (:listened (first eps))                        (str " listened")
                             (= (str (:id (first eps))) (str playing-id))   (str " is-playing")
                             (contains? cached-ids (str (:id (first eps)))) (str " cached"))
          :data-episode-id (str (:id (first eps)))
          :data-feed-id    (str feed-id)
          :on-click        #(rf/dispatch [::events/navigate :player
                                          {:episode-id (:id (first eps)) :from "inbox"}])}
         [:div.episode-info
          [:span.episode-feed-name (:feed_title (first eps))]
          [:strong.episode-title   (:title (first eps))]]
         [:span.episode-play-icon "▶"]
         [:button.compact-expand-btn
          {:on-click (fn [e]
                       (.stopPropagation e)
                       (swap! expanded-feeds-atom conj feed-id))}
          (str "+" (dec (count eps)) " more")]]))))
```

Updated call sites in `view`:

```clojure
(if compact?
  (let [groups (partition-by :feed_id visible)]
    (for [grp groups]
      (compact-group grp playing-id cached-ids expanded-feeds)))
  (for [ep visible]
    ^{:key (:id ep)} [episode-item ep playing-id cached-ids]))
```

- [ ] **Step 4: Replace the full `section-header-row` div in `view`**

Find the existing `[:div.section-header-row ...]` block in the `view` fn and replace it entirely:

```clojure
[:div.section-header-row
 [:h2 "Inbox"]
 (when (seq cached-ids)
   [:button.btn-clear-cache
    {:title    "Clear cached audio"
     :on-click #(rf/dispatch [::events/cache-clear-all])}
    "🗑"])
 [:button.btn-icon
  {:title    "Refresh"
   :class    (when loading? "btn-icon--spinning")
   :on-click #(rf/dispatch [::events/fetch-inbox])}
  "↻"]
 [:div.section-controls
  [:label.filter-label
   {:on-click (fn [e]
                (.preventDefault e)
                (rf/dispatch [::events/toggle-hide-listened]))}
   [:input.filter-checkbox
    {:type      "checkbox"
     :checked   hide-listened?
     :read-only true}]
   [:span.filter-switch]
   [:span.filter-text "Hide\u00a0✓"]]
  [:label.filter-label
   {:on-click (fn [e]
                (.preventDefault e)
                (reset! expanded-feeds #{})
                (rf/dispatch [::events/toggle-compact]))}
   [:input.filter-checkbox
    {:type      "checkbox"
     :checked   compact?
     :read-only true}]
   [:span.filter-switch]
   [:span.filter-text "Compact"]]]]
```

The 🗑 button only appears when there are cached episodes (`(when (seq cached-ids) ...)`).

- [ ] **Step 5: Add `::events/cache-clear-all` to the requires**

`events` is already required. No change needed — `::events/cache-clear-all` is already defined.

- [ ] **Step 6: Compile**

```bash
npx shadow-cljs compile app 2>&1 | tail -20
```

Expected: `Build completed`.

- [ ] **Step 7: Commit**

```bash
git add src/cljs/buzz_bot/views/inbox.cljs
git commit -m "feat(cache): bold cached episodes in inbox; add Clear cache button"
```

---

## Task 11: Add CSS

**Files:**
- Modify: `public/css/app.css`

- [ ] **Step 1: Update the `.player-seek-bar` background rule**

Find the existing `.player-seek-bar` rule and replace its `background` property with the dual-fill gradient. The existing rule likely looks something like:

```css
.player-seek-bar {
  ...
  background: linear-gradient(
    to right,
    var(--button-color) 0%,
    var(--button-color) var(--pct),
    rgba(0,0,0,0.15) var(--pct),
    rgba(0,0,0,0.15) 100%
  );
  ...
}
```

Replace the `background` value with:

```css
  background: linear-gradient(
    to right,
    var(--button-color)    0%,
    var(--button-color)    var(--pct),
    #4caf50                var(--pct),
    #4caf50                var(--cache-pct, 0%),
    rgba(0,0,0,0.15)       var(--cache-pct, 0%),
    rgba(0,0,0,0.15)       100%
  );
```

Using `var(--cache-pct, 0%)` as the fallback means no green shows before the variable is set.

- [ ] **Step 2: Add `.episode-item.cached` rule**

Add near the existing `.episode-item` rules:

```css
.episode-item.cached .episode-title {
  font-weight: 700;
}
```

- [ ] **Step 3: Add `.btn-clear-cache` rule**

Add near the other `.btn-icon`/button rules:

```css
.btn-clear-cache {
  background: none;
  border: none;
  cursor: pointer;
  font-size: 16px;
  padding: 4px 8px;
  opacity: 0.7;
  transition: opacity 0.15s;
}

.btn-clear-cache:hover {
  opacity: 1;
}
```

- [ ] **Step 4: Compile and verify CSS is picked up**

```bash
npx shadow-cljs release app 2>&1 | tail -20
```

Expected: `Build completed`.

- [ ] **Step 5: Commit**

```bash
git add public/css/app.css
git commit -m "feat(cache): green seek bar cache fill; bold cached episodes; clear cache button style"
```

---

## Task 12: Full release build and manual verification

- [ ] **Step 1: Release build**

```bash
cd /home/watchcat/work/crystal/buzz-bot/.worktrees/feature-clojurescript-spa
npx shadow-cljs release app 2>&1 | tail -30
```

Expected: `Build completed` with no warnings about undefined vars.

- [ ] **Step 2: Force-add compiled output and commit**

```bash
git add -f public/js/main.js
git commit -m "build: compile release JS for audio caching feature"
```

- [ ] **Step 3: Manual verification checklist**

Open the app in a browser with DevTools open (Network + Application tabs).

```
1. Play an episode
   ✓ Network: two simultaneous requests — one streaming audio (range request), one full download to /audio_proxy
   ✓ Seek bar: green fill begins appearing and advances left-to-right independently of the playhead

2. Wait for download to complete (watch Network tab until /audio_proxy finishes)
   ✓ Application → IndexedDB → buzz-audio → blobs: entry appears for the episode ID
   ✓ Application → Local Storage → buzz-cached-ids: contains the episode ID

3. Stop and replay the same episode
   ✓ Network: NO new /audio_proxy request (uses blob URL)
   ✓ Seek bar: immediately shows 100% green fill

4. Cache 6 distinct episodes to completion
   ✓ buzz-cached-ids: only 5 IDs; oldest IDB record deleted

5. Go to Inbox
   ✓ Played/cached episodes appear with bold title text
   ✓ 🗑 button visible in header

6. Click 🗑 Clear cache
   ✓ Application → IndexedDB: blobs store is empty
   ✓ buzz-cached-ids: removed from localStorage
   ✓ Bold styling gone from inbox
   ✓ 🗑 button hidden

7. Enable airplane mode, replay a cached episode
   ✓ Plays without any network requests

8. Enable airplane mode, try to open an uncached episode
   ✓ Error shown (existing fetch-error path)
```

- [ ] **Step 4: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix(cache): address issues found during manual verification"
```

---

## Reference: key field names from server response

The server's `/episodes/:id/player` JSON response has this shape (from `events.cljs` usage):

```
{:episode {:id          <int>
            :title       <string>
            :audio_url   <string>
            :feed_title  <string>       ← used as :artist in audio metadata
            :feed_image_url <string>    ← used as :artwork
            :feed_id     <int>
            :audio_url   <string>}
 :feed    {:title <string>}
 :user_episode {:progress_seconds <int> :liked <bool>}
 :next_id    <int|nil>
 :next_title <string|nil>
 :recs       [...]
 :is_subscribed <bool>
 :is_premium    <bool>}
```

The localStorage metadata key `buzz-episode-meta-<id>` stores:
```json
{"id":"42","title":"...","artist":"Feed Title","artwork":"https://...","audio_url":"https://..."}
```

Note: `:artist` in the stored metadata matches the `:feed_title` key on the episode object (used via `(get-in resp [:feed :title])`).
