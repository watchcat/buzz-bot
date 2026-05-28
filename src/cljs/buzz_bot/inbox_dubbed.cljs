(ns buzz-bot.inbox-dubbed
  "Pure presentation helpers for the latest-dubbed widget — relative-time
   formatting and language-flow rendering. No re-frame, no DOM, no SDK;
   safe to unit-test under shadow-cljs :node-test."
  (:require [clojure.string :as str]))

(def ^:private month-abbr
  ["Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"])

(defn- fmt-date [^js d]
  ;; "May 28" if same year as now, else "May 28, 2026".
  (let [now    (js/Date.)
        m     (.getMonth d)
        day   (.getDate d)
        yr    (.getFullYear d)]
    (if (= yr (.getFullYear now))
      (str (get month-abbr m) " " day)
      (str (get month-abbr m) " " day ", " yr))))

(defn fmt-relative-time
  "Given a millisecond timestamp `t-ms` and an optional `now-ms` reference,
   return a short human relative string: 'just now', 'Nm ago', 'Nh ago',
   'Nd ago', 'Nw ago' — or a fallback date string for > 8 weeks.
   `now-ms` defaults to (.now js/Date) and is parameterised for tests."
  ([t-ms]
   (fmt-relative-time t-ms (.now js/Date)))
  ([t-ms now-ms]
   (let [delta-s (max 0 (js/Math.floor (/ (- now-ms t-ms) 1000)))]
     (cond
       (< delta-s 60)            "just now"
       (< delta-s 3600)          (str (js/Math.floor (/ delta-s 60))    "m ago")
       (< delta-s 86400)         (str (js/Math.floor (/ delta-s 3600))  "h ago")
       (< delta-s (* 7 86400))   (str (js/Math.floor (/ delta-s 86400)) "d ago")
       (< delta-s (* 56 86400))  (str (js/Math.floor (/ delta-s (* 7 86400))) "w ago")
       :else                     (fmt-date (js/Date. t-ms))))))

(defn fmt-langflow
  "Source → target language pair, uppercased. Falls back to just the
   target when source is nil/empty (the dub pipeline didn't write a
   source-language detection for this episode)."
  [source target]
  (let [t (some-> target str/upper-case)]
    (if (and source (not= source ""))
      (str (str/upper-case source) " → " t)
      t)))
