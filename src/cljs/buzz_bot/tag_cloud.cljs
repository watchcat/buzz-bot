(ns buzz-bot.tag-cloud
  "Pure visual-encoding helpers for the /topics tag cloud.

   All tags render at a uniform font-size (set in CSS). Visual hierarchy is
   carried by two channels — font-weight and opacity — bucketed into four
   quartile tiers driven by each tag's episode count. No re-frame, no DOM —
   testable in isolation.")

(def ^:private tier-styles
  "Index 0 = bottom 25% of the distribution, index 3 = top 25%.
   Heavier weight + higher opacity reads as visually 'louder'."
  [{:font-weight 400 :opacity 0.5}
   {:font-weight 500 :opacity 0.7}
   {:font-weight 700 :opacity 0.9}
   {:font-weight 800 :opacity 1.0}])

(defn quartile-thresholds
  "Returns a 3-vector [q1 q2 q3] — the count values at the 25th, 50th, and
   75th percentile of `counts`. Used to bucket tags into four visual tiers.

   Uses the type-1 (nearest-rank, floor) definition: q_p = sorted[⌊p·n⌋].
   This keeps the implementation trivial and dependency-free, at the cost
   of some asymmetry on very small samples — adequate for tag clouds.

   Degenerate inputs:
     - empty collection → [0 0 0]
     - all counts equal → [v v v] (every tag lands in the top tier, which
       is correct: no hierarchy is meaningful when there is no variation)."
  [counts]
  (let [sorted (vec (sort counts))
        n      (count sorted)]
    (if (zero? n)
      [0 0 0]
      (mapv (fn [p]
              (let [idx (min (dec n) (max 0 (int (Math/floor (* p n)))))]
                (get sorted idx)))
            [0.25 0.50 0.75]))))

(defn- tier
  "Bucket `count` into 0 (bottom 25%) through 3 (top 25%) using the
   quartile thresholds `[q1 q2 q3]`. Tier boundaries are inclusive on
   the lower edge: count == q_k bumps to the higher tier."
  [count [q1 q2 q3]]
  (cond
    (>= count q3) 3
    (>= count q2) 2
    (>= count q1) 1
    :else         0))

(defn tag-style
  "Returns {:font-weight :opacity} for `count` given quartile `thresholds`
   (the 3-vector from `quartile-thresholds`). Font-size is uniform and
   lives in CSS, so it is intentionally not returned."
  [count thresholds]
  (get tier-styles (tier count thresholds)))
