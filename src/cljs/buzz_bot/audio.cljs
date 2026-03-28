(ns buzz-bot.audio
  (:require [re-frame.core :as rf]
            [re-frame.db]))

(defonce audio-el (js/Audio.))

(set! (.-preload audio-el) "metadata")
;; Keep the element in the DOM so the OS treats the page as a media source
(.appendChild js/document.body audio-el)

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
  ;; "playing" | "paused" | "none"
  ;; This is the signal that makes iOS/Android keep audio alive in background.
  (when (ms)
    (set! (.. js/navigator -mediaSession -playbackState) state)))

(defn- update-position-state! []
  (when (and (ms) (.-setPositionState (ms)))
    (let [dur (.-duration audio-el)
          pos (.-currentTime audio-el)
          rate (.-playbackRate audio-el)]
      (when (and (js/isFinite dur) (pos? dur))
        (try
          (.setPositionState (ms)
            (clj->js {:duration dur
                      :playbackRate rate
                      :position (min pos dur)}))
          (catch :default _))))))

;; ── rAF throttle for timeupdate ──────────────────────────────────────────────

(defonce raf-pending? (atom false))

(defn- on-timeupdate []
  (when-not @raf-pending?
    (reset! raf-pending? true)
    (js/requestAnimationFrame
     (fn []
       (reset! raf-pending? false)
       (update-position-state!)
       (rf/dispatch-sync [:buzz-bot.events/audio-tick (.-currentTime audio-el)])))))

;; ── Audio element event listeners ────────────────────────────────────────────

(defn- wire-listeners! []
  (.addEventListener audio-el "timeupdate" on-timeupdate)
  (.addEventListener audio-el "durationchange"
    (fn [] (rf/dispatch [:buzz-bot.events/audio-duration (.-duration audio-el)])))
  (.addEventListener audio-el "play"
    (fn []
      (set-playback-state! "playing")
      (update-position-state!)
      (rf/dispatch [:buzz-bot.events/audio-playing])))
  (.addEventListener audio-el "pause"
    (fn []
      (set-playback-state! "paused")
      (rf/dispatch [:buzz-bot.events/audio-paused])))
  (.addEventListener audio-el "ended"
    (fn []
      (set-playback-state! "none")
      (rf/dispatch [:buzz-bot.events/audio-ended]))))

;; ── Media Session action handlers ────────────────────────────────────────────

(defn- wire-media-session! []
  (when (ms)
    (doto (ms)
      (.setActionHandler "play"
        (fn []
          (-> (.play audio-el) (.catch (fn [])))))
      (.setActionHandler "pause"
        (fn []
          (.pause audio-el)))
      (.setActionHandler "seekbackward"
        (fn [^js details]
          (let [delta (or (.-seekOffset details) 15)]
            (set! (.-currentTime audio-el)
                  (max 0 (- (.-currentTime audio-el) delta))))))
      (.setActionHandler "seekforward"
        (fn [^js details]
          (let [delta (or (.-seekOffset details) 30)]
            (set! (.-currentTime audio-el)
                  (+ (.-currentTime audio-el) delta)))))
      (.setActionHandler "seekto"
        (fn [^js details]
          (when-let [t (.-seekTime details)]
            (set! (.-currentTime audio-el)
                  (max 0 (min (or (.-duration audio-el) 0) t))))))
      (.setActionHandler "stop"
        (fn []
          (.pause audio-el)
          (set! (.-currentTime audio-el) 0)
          (set-playback-state! "none"))))))

;; ── Progress save interval ────────────────────────────────────────────────────

(defn- start-progress-interval! []
  (js/setInterval
   (fn []
     (when-not (.-paused audio-el)
       (let [ep-id (get-in @re-frame.db/app-db [:audio :episode-id])]
         (when ep-id
           (rf/dispatch [:buzz-bot.events/save-progress ep-id
                         (js/Math.floor (.-currentTime audio-el))])))))
   5000))

;; ── Init ─────────────────────────────────────────────────────────────────────

(defn init! []
  (wire-listeners!)
  (wire-media-session!)
  (start-progress-interval!))

;; ── Command dispatch ──────────────────────────────────────────────────────────

(defmulti execute-cmd! :op)

(defmethod execute-cmd! :load [{:keys [src start autoplay? title artist artwork]}]
  (set! (.-src audio-el) src)
  (.load audio-el)
  (set-metadata! {:title title :artist artist :artwork artwork})
  (.addEventListener audio-el "loadedmetadata"
    (fn []
      (when (pos? start)
        (set! (.-currentTime audio-el) start))
      (set! (.-playbackRate audio-el) (or (.-playbackRate audio-el) 1))
      (update-position-state!)
      (when autoplay?
        (-> (.play audio-el) (.catch (fn [])))))
    #js{:once true}))

(defmethod execute-cmd! :play [_]
  (-> (.play audio-el) (.catch (fn []))))

(defmethod execute-cmd! :pause [_]
  (.pause audio-el))

(defmethod execute-cmd! :seek [{:keys [time]}]
  (set! (.-currentTime audio-el) (max 0 (min (or (.-duration audio-el) 0) time))))

(defmethod execute-cmd! :seek-relative [{:keys [delta]}]
  (set! (.-currentTime audio-el)
        (max 0 (min (or (.-duration audio-el) 0)
                    (+ (.-currentTime audio-el) delta)))))

(defmethod execute-cmd! :set-rate [{:keys [rate]}]
  (set! (.-playbackRate audio-el) rate)
  (update-position-state!))

;; Switch src without interrupting perceived playback — used when a cache
;; download completes while the episode is already playing from a network URL.
(defmethod execute-cmd! :switch-src [{:keys [src]}]
  (let [t            (.-currentTime audio-el)
        was-playing? (not (.-paused audio-el))]
    (set! (.-src audio-el) src)
    (.load audio-el)
    (.addEventListener audio-el "loadedmetadata"
      (fn []
        (set! (.-currentTime audio-el) t)
        (when was-playing?
          (-> (.play audio-el) (.catch (fn [])))))
      #js{:once true})))

(defmethod execute-cmd! :default [cmd]
  (js/console.warn "Unknown audio-cmd:" (clj->js cmd)))
