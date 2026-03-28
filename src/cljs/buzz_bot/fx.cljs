(ns buzz-bot.fx
  (:require [re-frame.core :as rf]
            [re-frame.db]
            [buzz-bot.audio :as audio]
            [buzz-bot.cache :as cache]))

;; ── ::http-fetch ────────────────────────────────────────────────────────────
;; Options map:
;;   :method  — :get | :post | :put | :delete
;;   :url     — string
;;   :body    — nil | js/URLSearchParams | clj map (will be JSON-encoded)
;;   :on-ok   — event vector appended with parsed JSON response
;;   :on-err  — event vector appended with error string

(defn- method-str [m]
  (case m :get "GET" :post "POST" :put "PUT" :delete "DELETE" "GET"))

(defn- build-init [method body init-data]
  (let [headers (js-obj "X-Init-Data" init-data)
        base    (js-obj "method" (method-str method)
                        "headers" headers)]
    (when body
      (cond
        (instance? js/URLSearchParams body)
        (aset base "body" body)

        (map? body)
        (do (aset headers "Content-Type" "application/json")
            (aset base "body" (.stringify js/JSON (clj->js body))))))
    base))

(rf/reg-fx
 ::http-fetch
 (fn [{:keys [method url body on-ok on-err]}]
   (let [init-data (get @re-frame.db/app-db :init-data "")
         init      (build-init method body init-data)]
     (-> (js/fetch url init)
         (.then (fn [resp]
                  (if (.-ok resp)
                    (let [len (.get (.-headers resp) "content-length")
                          ct  (.get (.-headers resp) "content-type")]
                      (if (or (= (.-status resp) 204)
                              (= len "0")
                              (not (and ct (.includes ct "json"))))
                        (rf/dispatch (conj on-ok nil))
                        (-> (.json resp)
                            (.then (fn [data]
                                     (rf/dispatch (conj on-ok (js->clj data :keywordize-keys true))))))))
                    (rf/dispatch (conj on-err (str "HTTP " (.-status resp)))))))
         (.catch (fn [err]
                   (rf/dispatch (conj on-err (str err)))))))))

;; ── ::audio-cmd ─────────────────────────────────────────────────────────────
;; Delegates to buzz-bot.audio/execute-cmd!

(rf/reg-fx
 ::audio-cmd
 (fn [cmd] (audio/execute-cmd! cmd)))

;; ── ::copy-to-clipboard ──────────────────────────────────────────────────────
;; Copies text to clipboard and shows the `.copy-toast` element briefly.

(defn- show-copy-toast! []
  (let [toast (or (.getElementById js/document "copy-toast")
                  (let [el (.createElement js/document "div")]
                    (set! (.-id el) "copy-toast")
                    (set! (.-className el) "copy-toast")
                    (.appendChild (.-body js/document) el)
                    el))]
    (set! (.-textContent toast) "RSS URL copied")
    (.add (.-classList toast) "copy-toast--visible")
    (js/clearTimeout (.-_hideTimer toast))
    (set! (.-_hideTimer toast)
          (js/setTimeout #(.remove (.-classList toast) "copy-toast--visible") 1500))))

(rf/reg-fx
 ::copy-to-clipboard
 (fn [text]
   (when text
     (if (.. js/navigator -clipboard -writeText)
       (-> (.writeText (.-clipboard js/navigator) text)
           (.then show-copy-toast!)
           (.catch show-copy-toast!))
       (do
         (let [ta (.createElement js/document "textarea")]
           (set! (.-value ta) text)
           (set! (.-cssText (.-style ta)) "position:fixed;opacity:0;top:0;left:0")
           (.appendChild (.-body js/document) ta)
           (.select ta)
           (.execCommand js/document "copy")
           (.removeChild (.-body js/document) ta))
         (show-copy-toast!))))))

;; ── ::open-telegram-link ─────────────────────────────────────────────────────
;; Opens a URL via Telegram.WebApp.openTelegramLink (falls back to window.open).

(rf/reg-fx
 ::open-telegram-link
 (fn [url]
   (when url
     (let [tg (.. js/window -Telegram -WebApp)]
       (if (.-openTelegramLink tg)
         (.openTelegramLink tg url)
         (.open js/window url "_blank"))))))

;; ── ::scroll-to-episode ──────────────────────────────────────────────────────
;; Scrolls the episode card with the given id into view (center, smooth).

(rf/reg-fx
 ::scroll-to-episode
 (fn [episode-id]
   (when episode-id
     ;; Double-rAF: Reagent batches DOM commits in its own rAF. The first rAF here fires
     ;; in the same frame as Reagent's render but before React has committed. The second
     ;; fires after Reagent's commit phase, so the element is guaranteed to be in the DOM.
     (js/requestAnimationFrame
       (fn []
         (js/requestAnimationFrame
           (fn []
             (when-let [el (.querySelector js/document
                             (str "[data-episode-id='" episode-id "']"))]
               (.scrollIntoView el #js{:block "center" :behavior "smooth"})))))))))

;; ── ::open-cache-db ──────────────────────────────────────────────────────────
;; Opens the IndexedDB connection once at app startup.

(rf/reg-fx
 ::open-cache-db
 (fn [_]
   (-> (cache/open-db!)
       (.then (fn [_] (rf/dispatch [:buzz-bot.events/cache-verify])))
       (.catch (fn [e] (js/console.warn "IDB open failed:" e))))))

;; ── ::persist-cached-ids ─────────────────────────────────────────────────────
;; Writes the given vector of episode IDs to localStorage under "buzz-cached-ids".

(rf/reg-fx
 ::persist-cached-ids
 (fn [ids]
   (js/localStorage.setItem "buzz-cached-ids" (.stringify js/JSON (clj->js ids)))))

;; ── ::verify-cache-ids ───────────────────────────────────────────────────────
;; Fetches all keys from IDB and dispatches :cache-prune-stale with the valid set.

(rf/reg-fx
 ::verify-cache-ids
 (fn [_]
   (-> (cache/get-all-keys!)
       (.then (fn [keys]
                (rf/dispatch [:buzz-bot.events/cache-prune-stale
                              (set (js->clj keys))]))))))

;; ── ::persist-cache-meta ──────────────────────────────────────────────────────
;; Writes episode metadata map to localStorage under "buzz-cache-meta".

(rf/reg-fx
 ::persist-cache-meta
 (fn [meta-map]
   (js/localStorage.setItem "buzz-cache-meta" (.stringify js/JSON (clj->js meta-map)))))

;; ── ::start-cache-download ───────────────────────────────────────────────────
;; Downloads audio from audio_proxy and stores the full blob in IDB.
;; Uses ReadableStream for progress reporting when available; falls back to
;; response.blob() on environments that don't support it (Android WebView).
;; Options: :episode-id, :url, :init-data
;; Dispatches:
;;   [:buzz-bot.events/cache-progress {:episode-id id :bytes-downloaded N :bytes-total N}]
;;   [:buzz-bot.events/cache-complete {:episode-id id :blob-url url}]
;;   [:buzz-bot.events/cache-error    {:episode-id id :error msg}]

(defn- finish-cache! [episode-id blob]
  (when (.. js/navigator -storage -persist)
    (.. js/navigator -storage (persist)))
  (-> (cache/put-blob! episode-id blob)
      (.then (fn [_]
               (rf/dispatch [:buzz-bot.events/cache-complete
                             {:episode-id episode-id
                              :blob-url   (js/URL.createObjectURL blob)}])))
      (.catch (fn [e]
                (rf/dispatch [:buzz-bot.events/cache-error
                              {:episode-id episode-id :error (str e)}])))))

(rf/reg-fx
 ::start-cache-download
 (fn [{:keys [episode-id url init-data]}]
   (let [headers (js-obj "X-Init-Data" (or init-data ""))]
     (-> (js/fetch url #js{:headers headers})
         (.then
           (fn [resp]
             (let [total (js/parseInt (.get (.-headers resp) "content-length") 10)]
               (rf/dispatch [:buzz-bot.events/cache-progress
                             {:episode-id episode-id :bytes-downloaded 0 :bytes-total (or total 0)}])
               (if (and (.-body resp) (.-getReader (.-body resp)))
                 ;; Streaming path — reports download progress as chunks arrive
                 (let [chunks #js []
                       reader (.getReader (.-body resp))]
                   (letfn [(read-chunk []
                             (-> (.read reader)
                                 (.then
                                   (fn [result]
                                     (if (.-done result)
                                       (finish-cache! episode-id (js/Blob. chunks #js{:type "audio/mpeg"}))
                                       (do (.push chunks (.-value result))
                                           (let [dl (reduce + 0 (map #(.-byteLength %) chunks))]
                                             (rf/dispatch [:buzz-bot.events/cache-progress
                                                           {:episode-id      episode-id
                                                            :bytes-downloaded dl
                                                            :bytes-total     (or total 0)}]))
                                           (read-chunk)))))
                                 (.catch (fn [e]
                                           (rf/dispatch [:buzz-bot.events/cache-error
                                                         {:episode-id episode-id :error (str e)}])))))]
                     (read-chunk)))
                 ;; Fallback path — no progress bar, works on Android WebView
                 (-> (.blob resp)
                     (.then #(finish-cache! episode-id %))
                     (.catch (fn [e]
                               (rf/dispatch [:buzz-bot.events/cache-error
                                             {:episode-id episode-id :error (str e)}]))))))))
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

;; ── ::preload-blob-urls ──────────────────────────────────────────────────────
;; Reads blobs for a list of episode IDs from IDB and dispatches
;; :blob-url-loaded for each, populating [:cache :blob-urls] at startup.
;; This ensures ::audio-load can use cached blobs even after a fresh page load.

(rf/reg-fx
 ::preload-blob-urls
 (fn [episode-ids]
   (doseq [ep-id episode-ids]
     (-> (cache/get-blob! ep-id)
         (.then (fn [record]
                  (when record
                    (rf/dispatch [:buzz-bot.events/blob-url-loaded
                                  ep-id (js/URL.createObjectURL (.-blob record))]))))
         (.catch (fn [_]))))))

;; ── ::open-dub-sse ───────────────────────────────────────────────────────────
;; Opens an SSE connection for dub progress updates.
;; Dispatches ::dub-events/sse-event with each parsed JSON message.
;; Stores the EventSource in a js-side atom so ::close-dub-sse can close it.
;; Options: {:episode-id id :lang lang :init-data str}

(def ^:private active-sse (atom nil))

(rf/reg-fx
 ::open-dub-sse
 (fn [{:keys [episode-id lang]}]
   ;; Close any existing SSE connection first
   (when-let [es @active-sse]
     (.close es)
     (reset! active-sse nil))
   (let [init-data (get @re-frame.db/app-db :init-data "")
         url       (str "/episodes/" episode-id "/dub/" lang "/events?initData=" (js/encodeURIComponent init-data))
         es        (js/EventSource. url)]
     (reset! active-sse es)
     (set! (.-onmessage es)
           (fn [e]
             (when-let [data (try (js->clj (.parse js/JSON (.-data e)) :keywordize-keys true)
                                  (catch :default _ nil))]
               (rf/dispatch [:buzz-bot.events.dub/sse-event episode-id lang data]))))
     (set! (.-onerror es)
           (fn [_]
             (.close es)
             (reset! active-sse nil))))))

;; ── ::close-dub-sse ──────────────────────────────────────────────────────────

(rf/reg-fx
 ::close-dub-sse
 (fn [_]
   (when-let [es @active-sse]
     (.close es)
     (reset! active-sse nil))))
