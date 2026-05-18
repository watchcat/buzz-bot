(ns buzz-bot.playback)

;; HTMLMediaElement.readyState below this -> currentTime is not trustworthy.
(def ^:private trustworthy-ready-state 2) ;; HAVE_CURRENT_DATA

(defn resume-start
  "Position (seconds) to resume an episode at. Completed episodes restart
  from 0 (decision 1); otherwise the saved progress, defaulting to 0."
  [completed progress-seconds]
  (if completed 0 (or progress-seconds 0)))
