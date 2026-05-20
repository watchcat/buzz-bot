(ns buzz-bot.tag-cloud
  "Pure visual-encoding helpers for the /topics tag cloud.

   `tag-style` maps a tag's count + the cloud's min/max counts to three
   visual channels (size, weight, opacity) via a log-scaled ratio in [0, 1].
   No re-frame, no DOM — testable in isolation.")

(def ^:private min-px  13)
(def ^:private max-px  22)
(def ^:private min-op  0.45)
(def ^:private max-op  1.0)
(def ^:private weight-threshold 0.6)

(defn- ratio
  "Logarithmic position of `count` in [min-count, max-count], in [0, 1].
   Degenerate case (all tags same count) → 0.5 (middle)."
  [count min-count max-count]
  (if (= min-count max-count)
    0.5
    (/ (Math/log (inc (- count min-count)))
       (Math/log (inc (- max-count min-count))))))

(defn tag-style
  "Returns a style map for a tag with `count` in the cloud, given the cloud's
   `min-count` and `max-count`. Three channels:
     :font-size   — Number (px). Caller formats with (str sz \"px\").
     :font-weight — 400 or 600 (two-tier).
     :opacity     — Number in [0.45, 1.0]."
  [count min-count max-count]
  (let [r (ratio count min-count max-count)]
    {:font-size   (+ min-px (* r (- max-px min-px)))
     :font-weight (if (>= r weight-threshold) 600 400)
     :opacity     (+ min-op (* r (- max-op min-op)))}))
