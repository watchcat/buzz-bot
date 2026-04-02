# Offline Audio Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add transparent offline audio caching to the Buzz-Bot Telegram Mini App podcast player — auto-download when episode opens, LRU max-5 eviction, mid-playback source switch when download completes, clear-cache button in Inbox, and full offline browsing via Service Worker API response caching.

**Architecture:** Audio files are downloaded through the existing Crystal auth proxy (`/episodes/:id/audio_proxy`) and stored in the Cache API under the same-origin URL `/episodes/:id/audio`. A replaced Service Worker intercepts that URL with CacheFirst, intercepts versioned static assets with CacheFirst, and intercepts all other same-origin GETs with NetworkFirst-with-stale-fallback. LRU state lives in `db` under `:offline` and is persisted to `localStorage` as `buzz-cached-audio-ids`. No IndexedDB, no blob URLs.

**Tech Stack:** ClojureScript/Re-frame/Reagent (frontend), Cache API, Service Worker, Crystal/Kemal (backend — no changes needed).

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `public/sw.js` | Rewrite | NetworkFirst for API/HTML, CacheFirst for assets + audio |
| `src/views/layout.ecr` | Modify | Register service worker via inline script |
| `src/cljs/buzz_bot/db.cljs` | Modify | Add `:offline` slice to `default-db` |
| `src/cljs/buzz_bot/subs.cljs` | Modify | Add `::network-online?`, `::cached-ids`, `::episode-cached?`, `::cache-progress` |
| `src/cljs/buzz_bot/fx.cljs` | Modify | Add `::start-audio-download`, `::delete-cached-audio`, `::clear-audio-cache`, `::persist-cached-ids` |
| `src/cljs/buzz_bot/events.cljs` | Modify | Add offline/download events; modify `::player-loaded` and `::audio-load` |
| `src/cljs/buzz_bot/audio.cljs` | Modify | Add `:switch-src` execute-cmd; update `recover-from-stall!` to prefer cached URL |
| `src/cljs/buzz_bot/core.cljs` | Modify | Register SW, wire `online`/`offline` events, dispatch `::offline-init` |
| `src/cljs/buzz_bot/views/player.cljs` | Modify | Download progress bar below seek bar |
| `src/cljs/buzz_bot/views/inbox.cljs` | Modify | Clear cache button; `cached` class on episode items |
| `src/cljs/buzz_bot/views/episodes.cljs` | Modify | `cached` class on episode items |
| `public/css/app.css` | Modify | Styles for progress bar, cached indicator, clear-cache button |

---

## Task 1: Service Worker

**Files:**
- Rewrite: `public/sw.js`
- Modify: `src/views/layout.ecr`

- [ ] **Step 1: Replace `public/sw.js` with full implementation**

```javascript
const SHELL_CACHE = 'buzz-shell-v1';
const API_CACHE   = 'buzz-api-v1';
const AUDIO_CACHE = 'buzz-audio-v1';
const KEEP_CACHES = new Set([SHELL_CACHE, API_CACHE, AUDIO_CACHE]);

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(SHELL_CACHE)
      .then(c => c.addAll(['/app', '/js/telegram-web-app.js']))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => !KEEP_CACHES.has(k)).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const req = event.request;
  const url = new URL(req.url);

  if (url.origin !== self.location.origin || req.method !== 'GET') return;

  // Audio cache endpoint — cache-first (pre-populated by download effect)
  if (/^\/episodes\/\d+\/audio$/.test(url.pathname)) {
    event.respondWith(cacheFirst(AUDIO_CACHE, req));
    return;
  }

  // Versioned static assets — cache-first
  if (url.pathname.startsWith('/js/') || url.pathname.startsWith('/css/')) {
    event.respondWith(cacheFirst(SHELL_CACHE, req));
    return;
  }

  // HTML + API — network-first, stale fallback
  event.respondWith(networkFirst(req));
});

async function cacheFirst(cacheName, request) {
  const cache  = await caches.open(cacheName);
  const cached = await cache.match(request);
  if (cached) return cached;
  try {
    const resp = await fetch(request);
    if (resp.ok) cache.put(request, resp.clone());
    return resp;
  } catch (_) {
    return new Response('Offline', { status: 503 });
  }
}

async function networkFirst(request) {
  const cache = await caches.open(API_CACHE);
  try {
    const resp = await fetch(request);
    if (resp.ok) {
      // Key by URL only — X-Init-Data header must not affect cache matching
      cache.put(new Request(request.url), resp.clone());
    }
    return resp;
  } catch (_) {
    const cached = await cache.match(new Request(request.url));
    return cached || new Response(
      JSON.stringify({ error: 'offline' }),
      { status: 503, headers: { 'Content-Type': 'application/json' } }
    );
  }
}
```

- [ ] **Step 2: Add SW registration script to `src/views/layout.ecr` just before `</body>`**

The final body section becomes:

```html
<body>
  <div id="app"></div>
  <script>window.BOT_USERNAME = '<%= BotClient.username %>';</script>
  <script src="/js/main.js?v=<%= Assets::VERSION %>"></script>
  <script>
    if ('serviceWorker' in navigator) {
      window.addEventListener('load', function() {
        navigator.serviceWorker.register('/sw.js', { scope: '/' })
          .catch(function(e) { console.warn('SW registration failed:', e); });
      });
    }
  </script>
</body>
```

- [ ] **Step 3: Verify build — no warnings**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
# Expected: [:app] Build completed. (... 0 warnings ...)
```

---

## Task 2: DB Default + Subscriptions

**Files:**
- Modify: `src/cljs/buzz_bot/db.cljs`
- Modify: `src/cljs/buzz_bot/subs.cljs`

- [ ] **Step 1: Add `:offline` slice to `default-db` in `db.cljs`**

Append after the `:dub` key:

```clojure
:offline {:cached-ids      []   ;; episode IDs, most-recent-first, max 5
          :in-progress     {}   ;; ep-id → {:bytes-downloaded N :bytes-total N}
          :network-online? true}
```

- [ ] **Step 2: Append four subscriptions to `subs.cljs` after `::audio-src`**

```clojure
;; ── Offline / audio cache ────────────────────────────────────────────────────

(rf/reg-sub ::network-online?
  (fn [db _] (get-in db [:offline :network-online?])))

(rf/reg-sub ::cached-ids
  (fn [db _] (set (get-in db [:offline :cached-ids]))))

(rf/reg-sub ::episode-cached?
  :<- [::cached-ids]
  (fn [ids [_ ep-id]] (contains? ids ep-id)))

(rf/reg-sub ::cache-progress
  (fn [db [_ ep-id]] (get-in db [:offline :in-progress ep-id])))
```

- [ ] **Step 3: Verify build**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
```

---

## Task 3: Download + Cache Effects

**Files:**
- Modify: `src/cljs/buzz_bot/fx.cljs`

- [ ] **Step 1: Append four effects to `fx.cljs` after `::close-dub-sse`**

```clojure
;; ── ::persist-cached-ids ─────────────────────────────────────────────────────

(rf/reg-fx
 ::persist-cached-ids
 (fn [ids]
   (js/localStorage.setItem "buzz-cached-audio-ids"
                             (.stringify js/JSON (clj->js ids)))))

;; ── ::start-audio-download ───────────────────────────────────────────────────
;; Streams /episodes/:id/audio_proxy (auth-gated Crystal proxy) into chunks,
;; then stores a synthetic Response in Cache API at /episodes/:id/audio.
;; Falls back to response.blob() on old WebViews without ReadableStream.

(rf/reg-fx
 ::start-audio-download
 (fn [{:keys [episode-id init-data]}]
   (let [proxy-url (str "/episodes/" episode-id "/audio_proxy")
         cache-key (str "/episodes/" episode-id "/audio")
         headers   (js-obj "X-Init-Data" (or init-data ""))]
     (-> (js/fetch proxy-url #js{:headers headers})
         (.then
           (fn [resp]
             (let [total (js/parseInt (.get (.-headers resp) "content-length") 10)]
               (rf/dispatch [:buzz-bot.events/audio-download-progress
                             episode-id 0 (or total 0)])
               (letfn [(store! [blob]
                         (let [r (js/Response. blob
                                   #js{:status  200
                                       :headers #js{"Content-Type" "audio/mpeg"}})]
                           (-> (.open js/caches "buzz-audio-v1")
                               (.then #(.put % cache-key r))
                               (.then #(rf/dispatch [:buzz-bot.events/audio-download-complete
                                                     episode-id]))
                               (.catch #(rf/dispatch [:buzz-bot.events/audio-download-error
                                                      episode-id])))))]
                 (if (and (.-body resp) (.-getReader (.-body resp)))
                   ;; Streaming path — accumulate chunks, report progress
                   (let [chunks #js[]
                         reader (.getReader (.-body resp))]
                     (letfn [(read-chunk []
                               (-> (.read reader)
                                   (.then
                                     (fn [result]
                                       (if (.-done result)
                                         (store! (js/Blob. chunks #js{:type "audio/mpeg"}))
                                         (do
                                           (.push chunks (.-value result))
                                           (rf/dispatch
                                             [:buzz-bot.events/audio-download-progress
                                              episode-id
                                              (reduce + 0 (map #(.-byteLength %) chunks))
                                              (or total 0)])
                                           (read-chunk)))))
                                   (.catch #(rf/dispatch [:buzz-bot.events/audio-download-error
                                                          episode-id]))))]
                       (read-chunk)))
                   ;; Fallback — environments without ReadableStream
                   (-> (.blob resp)
                       (.then store!)
                       (.catch #(rf/dispatch [:buzz-bot.events/audio-download-error
                                              episode-id]))))))))
         (.catch #(rf/dispatch [:buzz-bot.events/audio-download-error episode-id]))))))

;; ── ::delete-cached-audio ────────────────────────────────────────────────────

(rf/reg-fx
 ::delete-cached-audio
 (fn [ep-id]
   (-> (.open js/caches "buzz-audio-v1")
       (.then #(.delete % (str "/episodes/" ep-id "/audio"))))))

;; ── ::clear-audio-cache ──────────────────────────────────────────────────────

(rf/reg-fx
 ::clear-audio-cache
 (fn [_]
   (.delete js/caches "buzz-audio-v1")))
```

- [ ] **Step 2: Verify build**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
```

---

## Task 4: Download + Cache Events

**Files:**
- Modify: `src/cljs/buzz_bot/events.cljs`

- [ ] **Step 1: Append all offline/download events after `::init-audio-meta`**

```clojure
;; ── Offline / audio cache ────────────────────────────────────────────────────

(rf/reg-event-db
 ::network-status-changed
 (fn [db [_ online?]]
   (assoc-in db [:offline :network-online?] online?)))

(rf/reg-event-db
 ::offline-init
 (fn [db _]
   (let [raw (js/localStorage.getItem "buzz-cached-audio-ids")
         ids (when raw
               (try (js->clj (.parse js/JSON raw))
                    (catch :default _ [])))]
     (assoc-in db [:offline :cached-ids] (or ids [])))))

;; Idempotent — no-op if already cached or download already in progress.
(rf/reg-event-fx
 ::audio-download-start
 (fn [{:keys [db]} [_ ep-id]]
   (let [cached-ids  (get-in db [:offline :cached-ids])
         in-progress (get-in db [:offline :in-progress])]
     (when-not (or (some #{ep-id} cached-ids) (contains? in-progress ep-id))
       {:db (assoc-in db [:offline :in-progress ep-id]
                      {:bytes-downloaded 0 :bytes-total 0})
        ::buzz-bot.fx/start-audio-download {:episode-id ep-id
                                            :init-data  (:init-data db)}}))))

(rf/reg-event-db
 ::audio-download-progress
 (fn [db [_ ep-id bytes-downloaded bytes-total]]
   (assoc-in db [:offline :in-progress ep-id]
             {:bytes-downloaded bytes-downloaded :bytes-total bytes-total})))

;; LRU: prepend new id, take 5 distinct, evict the rest.
(rf/reg-event-fx
 ::audio-download-complete
 (fn [{:keys [db]} [_ ep-id]]
   (let [old-ids (get-in db [:offline :cached-ids])
         new-ids (vec (take 5 (distinct (cons ep-id old-ids))))
         evicted (remove (set new-ids) old-ids)
         new-db  (-> db
                     (assoc-in [:offline :cached-ids] new-ids)
                     (update-in [:offline :in-progress] dissoc ep-id))
         playing (get-in db [:audio :episode-id])
         switch? (= (str ep-id) (str playing))]
     (cond-> {:db                              new-db
              ::buzz-bot.fx/persist-cached-ids new-ids
              :dispatch-n                      (mapv #(vector ::audio-cache-evict %) evicted)}
       switch? (assoc ::buzz-bot.fx/audio-cmd {:op  :switch-src
                                               :src (str "/episodes/" ep-id "/audio")})))))

(rf/reg-event-db
 ::audio-download-error
 (fn [db [_ ep-id]]
   (update-in db [:offline :in-progress] dissoc ep-id)))

(rf/reg-event-fx
 ::audio-cache-evict
 (fn [{:keys [db]} [_ ep-id]]
   (let [new-ids (vec (remove #{ep-id} (get-in db [:offline :cached-ids])))]
     {:db                               (-> db
                                            (assoc-in [:offline :cached-ids] new-ids)
                                            (update-in [:offline :in-progress] dissoc ep-id))
      ::buzz-bot.fx/persist-cached-ids  new-ids
      ::buzz-bot.fx/delete-cached-audio ep-id})))

(rf/reg-event-fx
 ::audio-cache-clear-all
 (fn [{:keys [db]} _]
   {:db                              (update db :offline merge
                                             {:cached-ids [] :in-progress {}})
    ::buzz-bot.fx/persist-cached-ids []
    ::buzz-bot.fx/clear-audio-cache  nil}))
```

- [ ] **Step 2: Verify build**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
```

---

## Task 5: Wire Download into Existing Events

**Files:**
- Modify: `src/cljs/buzz_bot/events.cljs`

- [ ] **Step 1: Replace the three `cond` branches in `::player-loaded` to add `::audio-download-start`**

```clojure
(cond
  (= cur-id new-id)
  {:db         (assoc-in db' [:audio :pending?] false)
   :dispatch-n (conj (vec init-dub) [::audio-download-start new-id])}

  (and was-playing? (not= cur-id new-id))
  {:db         db'
   :dispatch-n (into [[::audio-queue-pending]
                      [::audio-download-start new-id]] init-dub)}

  :else
  {:db         db'
   :dispatch-n (into [[::audio-load {:autoplay? (boolean autoplay?)}]
                      [::audio-download-start new-id]] init-dub)})
```

- [ ] **Step 2: Replace the `src` binding in `::audio-load` to prefer cached URL**

Replace the `src` line only — everything else in `::audio-load` stays identical:

```clojure
(let [ep-id     (str (get-in db [:player :data :episode :id]))
      cached?   (some #{ep-id} (get-in db [:offline :cached-ids]))
      src       (if cached?
                  (str "/episodes/" ep-id "/audio")
                  (get-in db [:player :data :episode :audio_url]))
      start     (get-in db [:player :data :user_episode :progress_seconds] 0)
      autoplay? (:autoplay? opts false)]
```

- [ ] **Step 3: Verify build**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
```

---

## Task 6: Audio Source Switch + Stall Recovery

**Files:**
- Modify: `src/cljs/buzz_bot/audio.cljs`

- [ ] **Step 1: Add `:switch-src` dispatch method after `:set-rate`, before `:default`**

```clojure
(defmethod execute-cmd! :switch-src [{:keys [src]}]
  ;; Guard: only switch if playback has actually started (pos? t).
  ;; Switching from position 0 would be indistinguishable from a fresh load.
  (let [t            (.-currentTime (el))
        was-playing? (not (.-paused (el)))]
    (when (pos? t)
      (reset! recovering? true)
      (set! (.-src (el)) src)
      (.load (el))
      (.addEventListener (el) "canplay"
        (fn []
          (reset! recovering? false)
          (set! (.-currentTime (el)) t)
          (when was-playing?
            (-> (.play (el)) (.catch (fn [])))))
        #js{:once true}))))
```

- [ ] **Step 2: Replace `recover-from-stall!` to prefer cached URL**

```clojure
(defn- recover-from-stall! []
  (let [ep-id      (get-in @re-frame.db/app-db [:audio :episode-id])
        cached-ids (get-in @re-frame.db/app-db [:offline :cached-ids])
        cached?    (some #{ep-id} cached-ids)
        stream-url (get-in @re-frame.db/app-db [:player :data :episode :audio_url])
        t          (.-currentTime (el))
        target     (cond
                     cached?    (str "/episodes/" ep-id "/audio")
                     stream-url stream-url
                     :else      nil)]
    (when target
      (reset! recovering? true)
      (set! (.-src (el)) target)
      (.load (el))
      (.addEventListener (el) "canplay"
        (fn []
          (reset! recovering? false)
          (set! (.-currentTime (el)) t)
          (-> (.play (el)) (.catch (fn []))))
        #js{:once true}))))
```

- [ ] **Step 3: Verify build**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
```

---

## Task 7: Core Wiring

**Files:**
- Modify: `src/cljs/buzz_bot/core.cljs`

- [ ] **Step 1: Replace `cleanup-legacy!` with `cleanup-legacy-caches!` that does NOT unregister the SW**

```clojure
(defn- cleanup-legacy-caches! []
  ;; Remove any old cache buckets not used by the current SW strategy.
  ;; Do NOT call .unregister — we need the SW running.
  (when (.-caches js/window)
    (let [keep #{"buzz-shell-v1" "buzz-api-v1" "buzz-audio-v1"}]
      (-> (.keys js/caches)
          (.then (fn [ks]
                   (js/Promise.all
                     (.map ks (fn [k]
                                (when-not (contains? keep k)
                                  (.delete js/caches k)))))))))))
```

- [ ] **Step 2: Add `register-sw!` and `wire-network!`**

```clojure
(defn- register-sw! []
  (when (.-serviceWorker js/navigator)
    (-> (.register (.-serviceWorker js/navigator) "/sw.js" #js{:scope "/"})
        (.catch (fn [e] (js/console.warn "SW registration failed:" e))))))

(defn- wire-network! []
  (.addEventListener js/window "online"
    #(rf/dispatch [::events/network-status-changed true]))
  (.addEventListener js/window "offline"
    #(rf/dispatch [::events/network-status-changed false])))
```

- [ ] **Step 3: Update `mount!` — add `::offline-init`, `wire-network!`, `register-sw!`**

```clojure
(defn- mount! []
  (.ready (tg))
  (.expand (tg))
  (apply-theme!)
  (rf/dispatch-sync [::events/initialize-db])
  (rf/dispatch-sync [::events/set-init-data (.. (tg) -initData)])
  (rf/dispatch-sync [::events/offline-init])
  (wire-network!)
  (register-sw!)
  (restore-audio-state!)
  (audio/init!)
  (check-deep-link)
  (rdom/render [error-boundary [layout/root]] (js/document.getElementById "app")))
```

- [ ] **Step 4: Update `init!` to call `cleanup-legacy-caches!`**

```clojure
(defn ^:export init! []
  (cleanup-legacy-caches!)
  (if-let [locks (.. js/navigator -locks)]
    (.request locks "buzz-bot-instance"
      #js{:ifAvailable true}
      (fn [lock]
        (if lock
          (do (mount!) (js/Promise. (fn [_ _])))
          (show-already-open!))))
    (mount!)))
```

- [ ] **Step 5: Verify build**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
```

---

## Task 8: Player UI — Download Progress Bar

**Files:**
- Modify: `src/cljs/buzz_bot/views/player.cljs`

- [ ] **Step 1: Add `cache-progress` subscription in the inner `let` block**

Add after `send-status`:

```clojure
cache-progress @(rf/subscribe [::subs/cache-progress ep-id])
```

- [ ] **Step 2: Insert progress bar after `[:div.player-progress-row ...]`**

```clojure
[:div.player-controls
 [:div.player-progress-row
  [:span#player-current-time.player-time (fmt-time cur-time)]
  [seek-bar cur-time duration pending?]
  [:span#player-duration.player-time (fmt-time duration)]]
 (when-let [prog cache-progress]
   (let [pct (if (pos? (:bytes-total prog 0))
               (int (* 100 (/ (:bytes-downloaded prog)
                              (:bytes-total prog 0))))
               0)]
     [:div.player-download-bar
      {:style {"--dl-pct" (str pct "%")}}]))
 [:div.player-buttons-row
  ...]]
```

- [ ] **Step 3: Verify build**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
```

---

## Task 9: Inbox View

**Files:**
- Modify: `src/cljs/buzz_bot/views/inbox.cljs`

- [ ] **Step 1: Add `::subs/cached-ids` subscription after `playing-id`**

```clojure
cached-ids @(rf/subscribe [::subs/cached-ids])
```

- [ ] **Step 2: Update `episode-item` to accept `cached-ids` and apply `.cached` class**

```clojure
(defn- episode-item [ep playing-id cached-ids]
  [:li.episode-item
   {:class           (cond-> ""
                       (:listened ep)                         (str " listened")
                       (= (str (:id ep)) (str playing-id))   (str " is-playing")
                       (contains? cached-ids (str (:id ep))) (str " cached"))
    :data-episode-id (str (:id ep))
    :data-feed-id    (str (:feed_id ep))
    :on-click        #(rf/dispatch [::events/navigate :player
                                    {:episode-id (:id ep) :from "inbox"}])}
   (when-let [img (:episode_image_url ep)]
     [:img.episode-thumb {:src img :alt ""}])
   [:div.episode-info
    [:span.episode-feed-name (:feed_title ep)]
    [:strong.episode-title   (:title ep)]
    [episode-meta ep]]
   [:span.episode-play-icon "▶"]])
```

- [ ] **Step 3: Update `compact-group` to accept and forward `cached-ids`**

```clojure
(defn- compact-group [eps playing-id expanded-feeds-atom cached-ids]
  (let [feed-id  (:feed_id (first eps))
        expanded @expanded-feeds-atom]
    (if (or (= 1 (count eps)) (contains? expanded feed-id))
      (for [ep eps]
        ^{:key (:id ep)} [episode-item ep playing-id cached-ids])
      (list
        ^{:key (:id (first eps))}
        [:li.episode-item.compact-first
         {:class           (cond-> ""
                             (:listened (first eps))                         (str " listened")
                             (= (str (:id (first eps))) (str playing-id))    (str " is-playing")
                             (contains? cached-ids (str (:id (first eps))))  (str " cached"))
          :data-episode-id (str (:id (first eps)))
          :data-feed-id    (str feed-id)
          :on-click        #(rf/dispatch [::events/navigate :player
                                          {:episode-id (:id (first eps)) :from "inbox"}])}
         (when-let [img (:feed_image_url (first eps))]
           [:img.episode-thumb {:src img :alt ""}])
         [:div.episode-info
          [:span.episode-feed-name (:feed_title (first eps))]
          [:strong.episode-title   (:title (first eps))]
          [episode-meta (first eps)]]
         [:span.episode-play-icon "▶"]
         [:button.compact-expand-btn
          {:on-click (fn [e]
                       (.stopPropagation e)
                       (swap! expanded-feeds-atom conj feed-id))}
          (str "+" (dec (count eps)) " more")]]))))
```

- [ ] **Step 4: Add clear-cache button in section header, after `[:h2 "Inbox"]`**

```clojure
[:h2 "Inbox"]
(when (seq cached-ids)
  [:button.btn-clear-cache
   {:title    "Clear cached audio"
    :on-click #(rf/dispatch [::events/audio-cache-clear-all])}
   "🗑"])
```

- [ ] **Step 5: Pass `cached-ids` through in `view` rendering**

```clojure
;; compact mode
(compact-group grp playing-id expanded-feeds cached-ids)

;; normal mode
^{:key (:id ep)} [episode-item ep playing-id cached-ids]
```

- [ ] **Step 6: Verify build**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
```

---

## Task 10: Episodes View

**Files:**
- Modify: `src/cljs/buzz_bot/views/episodes.cljs`

- [ ] **Step 1: Add `::subs/cached-ids` subscription after `playing-id`**

```clojure
cached-ids @(rf/subscribe [::subs/cached-ids])
```

- [ ] **Step 2: Update `episode-item` to accept `cached-ids` and apply `.cached` class**

```clojure
(defn- episode-item [ep playing-id cached-ids]
  (let [date-str (fmt-pub-date (:published_at ep))
        dur-str  (fmt-duration (:duration_seconds ep))
        meta-str (cond (and date-str dur-str) (str date-str " · " dur-str)
                       date-str date-str
                       dur-str  dur-str)]
    [:li.episode-item
     {:class           (cond-> ""
                         (:listened ep)                        (str " listened")
                         (= (str (:id ep)) (str playing-id))  (str " is-playing")
                         (contains? cached-ids (str (:id ep))) (str " cached"))
      :data-episode-id (str (:id ep))
      :on-click        #(rf/dispatch [::events/navigate :player
                                      {:episode-id (:id ep) :from "episodes"}])}
     (when-let [img (:episode_image_url ep)]
       [:img.episode-thumb {:src img :alt ""}])
     [:div.episode-info
      [:span.episode-title (:title ep)]
      (when meta-str [:span.episode-meta meta-str])]
     [:span.episode-play-icon "▶"]]))
```

- [ ] **Step 3: Pass `cached-ids` in the render call**

```clojure
(for [ep episodes]
  ^{:key (:id ep)} [episode-item ep playing-id cached-ids])
```

- [ ] **Step 4: Verify build**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
```

---

## Task 11: CSS

**Files:**
- Modify: `public/css/app.css`

- [ ] **Step 1: Append new rules at the end of `app.css`**

```css
/* ── Clear cache button ──────────────────────────────────────────────────── */

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

/* ── Cached episode indicator ────────────────────────────────────────────── */

.episode-item.cached {
  border-bottom: 2px solid var(--button-color);
}

/* ── Player download progress bar ───────────────────────────────────────── */

.player-download-bar {
  height: 3px;
  border-radius: 2px;
  margin: 4px 0 0;
  background: linear-gradient(
    to right,
    var(--button-color) 0%,
    var(--button-color) var(--dl-pct, 0%),
    rgba(0, 0, 0, 0.10) var(--dl-pct, 0%)
  );
  opacity: 0.6;
}
```

- [ ] **Step 2: Verify build**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
```

---

## Final Verification

- [ ] **Full build — zero warnings**

```bash
nix-shell -p nodejs -p openjdk --run "node node_modules/.bin/shadow-cljs compile app 2>&1" | tail -5
# Expected: [:app] Build completed. (... 0 warnings ...)
```

- [ ] **Manual end-to-end checklist**

1. Open episode player → download progress bar appears below seek bar and fills to 100%
2. After download: `.cached` border appears on that episode in Inbox and Episodes views
3. Re-open the cached episode → Network tab shows `/episodes/:id/audio` served from Service Worker (no request to the external `audio_url`)
4. Open 6 different episodes → the 6th-oldest loses its `.cached` border; Cache API `buzz-audio-v1` contains exactly 5 entries
5. Trash icon appears in Inbox header only when `cached-ids` is non-empty; clicking clears all `.cached` borders and deletes the `buzz-audio-v1` cache bucket
6. DevTools → Network → Offline → navigate Inbox/Feeds/Episodes → pages load from SW stale cache; cached episode plays without a network request
7. Start streaming an episode that is mid-download → after download completes, audio continues from the cached URL without audible interruption or seek reset (guarded by `(when (pos? t))` in `:switch-src`)
