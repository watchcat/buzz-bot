(ns buzz-bot.fx
  (:require [re-frame.core :as rf]
            [re-frame.db]
            [buzz-bot.audio :as audio]))

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
             (if-not (.-ok resp)
               (rf/dispatch [:buzz-bot.events/audio-download-error episode-id])
               (let [total (js/parseInt (.get (.-headers resp) "content-length") 10)]
                 (rf/dispatch [:buzz-bot.events/audio-download-progress
                               episode-id 0 (or total 0)])
                 (letfn [(store! [blob]
                           (let [r (js/Response. blob
                                     #js{:status  200
                                         :headers #js{"Content-Type"   "audio/mpeg"
                                                      "Accept-Ranges"  "bytes"
                                                      "Content-Length" (str (.-size blob))}})]
                             (-> (.open js/caches "buzz-audio-v1")
                                 (.then #(.put % cache-key r))
                                 (.then #(rf/dispatch [:buzz-bot.events/audio-download-complete
                                                       episode-id]))
                                 (.catch #(rf/dispatch [:buzz-bot.events/audio-download-error
                                                        episode-id])))))]
                   (if (and (.-body resp) (.-getReader (.-body resp)))
                     ;; Streaming path — accumulate chunks, report progress
                     (let [chunks #js[]
                           reader (.getReader (.-body resp))
                           loaded (atom 0)]
                       (letfn [(read-chunk []
                                 (-> (.read reader)
                                     (.then
                                       (fn [result]
                                         (if (.-done result)
                                           (store! (js/Blob. chunks #js{:type "audio/mpeg"}))
                                           (let [chunk (.-value result)]
                                             (.push chunks chunk)
                                             (swap! loaded + (.-byteLength chunk))
                                             (rf/dispatch
                                               [:buzz-bot.events/audio-download-progress
                                                episode-id @loaded (or total 0)])
                                             (read-chunk)))))
                                     (.catch #(rf/dispatch [:buzz-bot.events/audio-download-error
                                                            episode-id]))))]
                         (read-chunk)))
                     ;; Fallback — environments without ReadableStream
                     (-> (.blob resp)
                         (.then store!)
                         (.catch #(rf/dispatch [:buzz-bot.events/audio-download-error
                                                episode-id])))))))))
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
