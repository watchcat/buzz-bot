(ns buzz-bot.audio
  (:require [re-frame.core :as rf]
            [re-frame.db]))

(defonce audio-el (js/Audio.))

(set! (.-preload audio-el) "metadata")
(.appendChild js/document.body audio-el)

;; rAF throttle for timeupdate
(defonce raf-pending? (atom false))

(defn- on-timeupdate []
  (when-not @raf-pending?
    (reset! raf-pending? true)
    (js/requestAnimationFrame
     (fn []
       (reset! raf-pending? false)
       (rf/dispatch-sync [:buzz-bot.events/audio-tick (.-currentTime audio-el)])))))

(defn- wire-listeners! []
  (.addEventListener audio-el "timeupdate"    on-timeupdate)
  (.addEventListener audio-el "durationchange"
    (fn [] (rf/dispatch [:buzz-bot.events/audio-duration (.-duration audio-el)])))
  (.addEventListener audio-el "play"
    (fn [] (rf/dispatch [:buzz-bot.events/audio-playing])))
  (.addEventListener audio-el "pause"
    (fn [] (rf/dispatch [:buzz-bot.events/audio-paused])))
  (.addEventListener audio-el "ended"
    (fn [] (rf/dispatch [:buzz-bot.events/audio-ended]))))

(defn- wire-media-session! []
  (when (.. js/navigator -mediaSession)
    (let [ms (.. js/navigator -mediaSession)]
      (.setActionHandler ms "play"         #(.play audio-el))
      (.setActionHandler ms "pause"        #(.pause audio-el))
      (.setActionHandler ms "seekbackward" #(set! (.-currentTime audio-el)
                                                  (max 0 (- (.-currentTime audio-el) 10))))
      (.setActionHandler ms "seekforward"  #(set! (.-currentTime audio-el)
                                                  (+ (.-currentTime audio-el) 30))))))

(defn- start-progress-interval! []
  (js/setInterval
   (fn []
     (when-not (.-paused audio-el)
       (let [ep-id (get-in @re-frame.db/app-db [:audio :episode-id])]
         (when ep-id
           (rf/dispatch [:buzz-bot.events/save-progress ep-id
                         (js/Math.floor (.-currentTime audio-el))])))))
   5000))

(defn init! []
  (wire-listeners!)
  (wire-media-session!)
  (start-progress-interval!))

;; ── Command dispatch ─────────────────────────────────────────────────────────

(defmulti execute-cmd! :op)

(defmethod execute-cmd! :load [{:keys [src start autoplay?]}]
  (set! (.-src audio-el) src)
  (.load audio-el)
  (.addEventListener audio-el "loadedmetadata"
    (fn []
      (when (pos? start)
        (set! (.-currentTime audio-el) start))
      (set! (.-playbackRate audio-el) (or (.-playbackRate audio-el) 1))
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
  (set! (.-playbackRate audio-el) rate))

(defmethod execute-cmd! :default [cmd]
  (js/console.warn "Unknown audio-cmd:" (clj->js cmd)))
