(ns buzz-bot.playback)

;; HTMLMediaElement.readyState below this -> currentTime is not trustworthy.
(def ^:private trustworthy-ready-state 2) ;; HAVE_CURRENT_DATA

(defn resume-start
  "Position (seconds) to resume an episode at. Completed episodes restart
  from 0 (decision 1); otherwise the saved progress, defaulting to 0."
  [completed progress-seconds]
  (if completed 0 (or progress-seconds 0)))

(defn should-skip-reload?
  "True only when reopening the episode that is actively playing right now —
  the single case where re-issuing a load would wrongly interrupt playback.
  `was-playing?` is the navigation-time snapshot (events.cljs :325-327)."
  [{:keys [same-episode? was-playing?]}]
  (boolean (and same-episode? was-playing?)))

(defn should-save-progress?
  "True when the element's currentTime is trustworthy enough to persist.
  False during reloads/seeks (covers stall-recovery, :switch-src, download
  swap, network reload — bug 3) regardless of source. nil readyState is
  treated as untrustworthy."
  [{:keys [recovering? ready-state seeking?]}]
  (not (or (boolean recovering?)
           (boolean seeking?)
           (< (or ready-state 0) trustworthy-ready-state))))
