(ns buzz-bot.delivery
  "Pure helpers for the per-feed delivery feature — mode cycling, labels,
   icon-key mapping, NEW-badge predicate. No re-frame, no DOM, no Telegram
   SDK; safe to unit-test under shadow-cljs :node-test.")

(defn next-mode
  "Cycle off → notify → mp3 → off (premium) or off ↔ notify (non-premium).
   Unknown / nil input → :off. The premium-aware variant matches the
   Send-to-Chat premium gate so tap-cycle never advances to mp3 without
   entitlement; the long-press popup is the only path that surfaces the
   mp3 option (and shows an upsell when picked without premium)."
  [mode premium?]
  (case mode
    :off    :notify
    :notify (if premium? :mp3 :off)
    :mp3    :off
    :off))

(defn mode->label [mode]
  (case mode
    :off    "In-app only"
    :notify "Notify me"
    :mp3    "Send MP3"
    "In-app only"))

(defn mode->icon-key
  "Maps the mode to an icon-key the view layer resolves into the actual SVG.
   Keeping this as a keyword instead of inline hiccup keeps it testable
   without pulling DOM helpers into the helpers ns."
  [mode]
  (case mode
    :off    :bell-off
    :notify :bell
    :mp3    :mp3
    :bell-off))

(defn new?
  "True iff `id` (number or string-of-number) is in `id-set`. Returns false
   when id-set is nil or empty — callers always render unconditionally."
  [id-set id]
  (let [n (cond
            (number? id) id
            (string? id) (js/parseInt id 10)
            :else        nil)]
    (boolean (and id-set n (contains? id-set n)))))
