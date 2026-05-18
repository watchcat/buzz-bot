(ns buzz-bot.audio
  (:require [re-frame.core :as rf]
            [re-frame.db]
            [buzz-bot.playback :as pb]))

(defonce ^:private audio-atom
  (volatile! (doto (js/Audio.)
               (aset "preload" "metadata"))))

(defn- el [] @audio-atom)

;; ── Media Session helpers ─────────────────────────────────────────────────────

(defn- ms [] (.. js/navigator -mediaSession))

(defn- set-metadata! [{:keys [title artist artwork]}]
  (when (ms)
    (set! (.. js/navigator -mediaSession -metadata)
          (js/MediaMetadata.
            (clj->js {:title  (or title "")
                      :artist (or artist "")
                      :album  ""
                      :artwork (if artwork
                                 [{:src artwork :sizes "512x512" :type "image/jpeg"}]
                                 [])})))))

(defn- set-playback-state! [state]
  (when (ms)
    (set! (.. js/navigator -mediaSession -playbackState) state)))

(defn- update-position-state! []
  (when (and (ms) (.-setPositionState (ms)))
    (let [dur  (.-duration (el))
          pos  (.-currentTime (el))
          rate (.-playbackRate (el))]
      (when (and (js/isFinite dur) (pos? dur))
        (try
          (.setPositionState (ms)
            (clj->js {:duration dur :playbackRate rate :position (min pos dur)}))
          (catch :default _))))))

;; ── rAF throttle for timeupdate ──────────────────────────────────────────────

(defonce ^:private raf-pending? (atom false))

(defn- on-timeupdate []
  (when-not @raf-pending?
    (reset! raf-pending? true)
    (js/requestAnimationFrame
     (fn []
       (reset! raf-pending? false)
       (update-position-state!)
       (rf/dispatch-sync [:buzz-bot.events/audio-tick (.-currentTime (el))])))))

;; ── Stall / network-error recovery ──────────────────────────────────────────
;; On mobile WebViews, network loss typically causes `waiting` (buffer empty)
;; rather than `error`. We wait 5 s for the network to recover; if the element
;; is still stalled, we reload from the cached blob (if available), or retry
;; the stream URL when connectivity returns.

(defonce ^:private stall-timer (atom nil))
(defonce ^:private recovering? (atom false))

(defn- cancel-stall-timer! []
  (when-let [id @stall-timer]
    (js/clearTimeout id)
    (reset! stall-timer nil)))

;; Load (or reload) the current audio src and resume from position t.
;; Keeps recovering?=true through the seek so waiting events during
;; buffering do not retrigger the stall timer prematurely.
(defn- load-and-resume! [t]
  (reset! recovering? true)
  (.load (el))
  (.addEventListener (el) "canplay"
    (fn []
      (if (pos? t)
        (do
          (set! (.-currentTime (el)) t)
          (.addEventListener (el) "seeked"
            (fn []
              (reset! recovering? false)
              (-> (.play (el)) (.catch (fn []))))
            #js{:once true}))
        (do
          (reset! recovering? false)
          (-> (.play (el)) (.catch (fn []))))))
    #js{:once true}))

(defn- recover-from-stall! []
  (let [ep-id      (get-in @re-frame.db/app-db [:audio :episode-id])
        cached-ids (get-in @re-frame.db/app-db [:offline :cached-ids])
        cached?    (some #{ep-id} cached-ids)
        stream-url (get-in @re-frame.db/app-db [:audio :src])
        t          (.-currentTime (el))
        cache-url  (when ep-id (str "/episodes/" ep-id "/audio"))
        ;; Are we already playing from the cached copy?
        on-cache?  (and cache-url
                        (= (.-src (el))
                           (.-href (js/URL. cache-url js/location.href))))
        ;; If cached but not yet on the cache URL → upgrade to the local copy.
        ;; If already on the cache URL → do NOT fall back to the stream: the SW
        ;; serves it from memory and a transient stall should resolve on its own.
        ;; Falling back would reload the CDN URL, which fails when offline.
        ;; If not cached at all → retry the stream URL.
        target     (cond
                     (and cached? (not on-cache?)) cache-url
                     (not cached?)                 stream-url
                     :else                         nil)]
    ;; Guard: resolve relative target to absolute before comparing so we never
    ;; reload the URL we're already on (prevents infinite error→recover loops).
    (when (and target (not= (.-src (el)) (.-href (js/URL. target js/location.href))))
      (set! (.-src (el)) target)
      (load-and-resume! t))))

;; ── Progress persistence helpers ─────────────────────────────────────────────
;; Defined before wire-listeners! / init! so the pause/hide listeners that call
;; flush-progress! are not forward references (no cljs "undeclared Var" warning).

(defn- trustworthy-position? []
  (pb/should-save-progress? {:recovering? @recovering?
                             :ready-state (.-readyState (el))
                             :seeking?    (.-seeking (el))}))

;; Persist the current position now (pause / app-hide / pagehide). Trust-gated
;; so a transient .load() reset (stall-recovery, :switch-src, download swap)
;; can never write a spurious 0 over good progress (bug 3).
(defn- flush-progress! []
  (when (trustworthy-position?)
    (when-let [ep-id (get-in @re-frame.db/app-db [:audio :episode-id])]
      (rf/dispatch [:buzz-bot.events/save-progress ep-id
                    (js/Math.floor (.-currentTime (el)))]))))

;; ── Listener wiring ──────────────────────────────────────────────────────────

(defn- wire-listeners! []
  (let [audio (el)]
    (.addEventListener audio "timeupdate" on-timeupdate)
    (.addEventListener audio "durationchange"
      (fn [] (rf/dispatch [:buzz-bot.events/audio-duration (.-duration (el))])))
    (.addEventListener audio "play"
      (fn []
        (cancel-stall-timer!)
        (set-playback-state! "playing")
        (update-position-state!)
        (rf/dispatch [:buzz-bot.events/audio-playing])))
    ;; `playing` fires when playback actually resumes after buffering —
    ;; cancel any stall timer so we don't reload a healthy stream.
    (.addEventListener audio "playing"
      (fn [] (cancel-stall-timer!)))
    (.addEventListener audio "pause"
      (fn []
        (cancel-stall-timer!)
        (set-playback-state! "paused")
        (rf/dispatch [:buzz-bot.events/audio-paused])
        (flush-progress!)))
    (.addEventListener audio "ended"
      (fn []
        (cancel-stall-timer!)
        (set-playback-state! "none")
        (rf/dispatch [:buzz-bot.events/audio-ended])))
    ;; `waiting` fires when the buffer runs dry. Start a 5-second countdown
    ;; only if one isn't already running (don't reset on repeated `waiting`).
    ;; Recovery reloads from cached blob if available, or retries the stream URL.
    (.addEventListener audio "waiting"
      (fn []
        (let [stall-recovery? (get-in @re-frame.db/app-db [:flags "stall_recovery"] true)]
          (when (and stall-recovery? (not (or @stall-timer @recovering?)))
            (reset! stall-timer
                    (js/setTimeout
                      (fn []
                        (reset! stall-timer nil)
                        (recover-from-stall!))
                      5000))))))
    ;; `error` handles hard failures (bad URL, decode error, etc.).
    (.addEventListener audio "error"
      (fn []
        (reset! recovering? false)
        (cancel-stall-timer!)
        (let [stall-recovery? (get-in @re-frame.db/app-db [:flags "stall_recovery"] true)]
          (when stall-recovery? (recover-from-stall!)))))
    ;; When connectivity is restored, reload if the audio element is stalled or
    ;; in an error state (readyState < HAVE_FUTURE_DATA = 3). This handles the
    ;; case where the download hadn't finished before the connection was cut:
    ;; the browser buffer ran dry while offline, and now that we're back we can
    ;; resume streaming or switch to the now-downloadable cached copy.
    (.addEventListener js/window "online"
      (fn []
        (let [t (.-currentTime (el))]
          (when (and (not @recovering?)
                     (pos? t)
                     (or (.-error (el))
                         (< (.-readyState (el)) 3)))
            ;; First see if we should upgrade to a cached copy (it may have
            ;; become available while offline via a parallel download that
            ;; completed just before the cut).
            (recover-from-stall!)
            ;; If recover-from-stall! decided there was nothing to switch to
            ;; (e.g. not cached, same URL) we force a reload of the current src
            ;; so the stream can resume now that the network is back.
            (when (not @recovering?)
              (load-and-resume! t))))))))

;; ── Media Session action handlers ────────────────────────────────────────────

(defn- wire-media-session! []
  (when (ms)
    (doto (ms)
      (.setActionHandler "play"    #(-> (.play (el)) (.catch (fn []))))
      (.setActionHandler "pause"   #(.pause (el)))
      (.setActionHandler "seekbackward"
        (fn [^js d]
          (set! (.-currentTime (el))
                (max 0 (- (.-currentTime (el)) (or (.-seekOffset d) 15))))))
      (.setActionHandler "seekforward"
        (fn [^js d]
          (set! (.-currentTime (el))
                (+ (.-currentTime (el)) (or (.-seekOffset d) 30)))))
      (.setActionHandler "seekto"
        (fn [^js d]
          (when-let [t (.-seekTime d)]
            (set! (.-currentTime (el))
                  (max 0 (min (or (.-duration (el)) 0) t))))))
      (.setActionHandler "stop"
        (fn []
          (.pause (el))
          (set! (.-currentTime (el)) 0)
          (set-playback-state! "none"))))))

;; ── Progress save interval ────────────────────────────────────────────────────

(defn- start-progress-interval! []
  (js/setInterval
   (fn []
     (when (and (not (.-paused (el))) (trustworthy-position?))
       (when-let [ep-id (get-in @re-frame.db/app-db [:audio :episode-id])]
         (rf/dispatch [:buzz-bot.events/save-progress ep-id
                       (js/Math.floor (.-currentTime (el)))]))))
   5000))

;; ── Init ─────────────────────────────────────────────────────────────────────

(defn init! []
  (wire-listeners!)
  (wire-media-session!)
  (start-progress-interval!)
  ;; Telegram's WebView suspends/throttles the 5 s interval when the Mini App
  ;; is backgrounded/closed; flush the position before that happens (bug 2).
  (.addEventListener js/document "visibilitychange"
    (fn [] (when (.-hidden js/document) (flush-progress!))))
  (.addEventListener js/window "pagehide" (fn [] (flush-progress!))))

;; ── Command dispatch ──────────────────────────────────────────────────────────

(defmulti execute-cmd! :op)

(defmethod execute-cmd! :load [{:keys [src start autoplay? title artist artwork]}]
  (set! (.-src (el)) src)
  (.load (el))
  (set-metadata! {:title title :artist artist :artwork artwork})
  (.addEventListener (el) "loadedmetadata"
    (fn []
      (when (pos? start)
        (set! (.-currentTime (el)) start))
      (set! (.-playbackRate (el)) (or (.-playbackRate (el)) 1))
      (update-position-state!)
      (when autoplay?
        (-> (.play (el)) (.catch (fn [])))))
    #js{:once true}))

(defmethod execute-cmd! :play [_]
  (-> (.play (el)) (.catch (fn []))))

(defmethod execute-cmd! :pause [_]
  (.pause (el)))

(defmethod execute-cmd! :seek [{:keys [time]}]
  (set! (.-currentTime (el)) (max 0 (min (or (.-duration (el)) 0) time))))

(defmethod execute-cmd! :seek-relative [{:keys [delta]}]
  (set! (.-currentTime (el))
        (max 0 (min (or (.-duration (el)) 0)
                    (+ (.-currentTime (el)) delta)))))

(defmethod execute-cmd! :set-rate [{:keys [rate]}]
  (set! (.-playbackRate (el)) rate)
  (update-position-state!))

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
          ;; Keep recovering? = true through the seek so waiting during
          ;; seeking does not start the stall timer prematurely.
          (set! (.-currentTime (el)) t)
          (.addEventListener (el) "seeked"
            (fn []
              (reset! recovering? false)
              (when was-playing?
                (-> (.play (el)) (.catch (fn [])))))
            #js{:once true}))
        #js{:once true}))))

(defmethod execute-cmd! :default [cmd]
  (js/console.warn "Unknown audio-cmd:" (clj->js cmd)))
