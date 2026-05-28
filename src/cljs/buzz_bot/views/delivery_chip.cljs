(ns buzz-bot.views.delivery-chip
  "Delivery chip + long-press mode picker. Pure presentation + dispatch —
   business logic lives in buzz-bot.delivery / buzz-bot.events."
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.delivery :as d]
            [buzz-bot.events :as events]))

;; SVG icons — ports of feed-chrome.jsx (BellIcon, BellOffIcon, MP3Icon).
;; Kept here (not in a shared icons ns) because they're only used by this chip.

(defn- bell-icon [size]
  [:svg {:width size :height size :viewBox "0 0 14 14" :fill "currentColor"}
   [:path {:d "M7 1 C5 1 4 2.5 4 4.5 C4 7 3 8 2 9 H12 C11 8 10 7 10 4.5 C10 2.5 9 1 7 1 Z"}]
   [:path {:d "M5.5 10.5 C5.5 11.5 6.2 12 7 12 C7.8 12 8.5 11.5 8.5 10.5 Z"}]])

(defn- bell-off-icon [size]
  [:svg {:width size :height size :viewBox "0 0 14 14" :fill "none"}
   [:path {:d "M7 1.5 C5.3 1.5 4.4 2.7 4.4 4.5 C4.4 7 3.5 8 2.7 8.8 H11.3 C10.5 8 9.6 7 9.6 4.5 C9.6 2.7 8.7 1.5 7 1.5 Z"
           :stroke "currentColor" :stroke-width "1.2" :stroke-linejoin "round"}]
   [:path {:d "M1.5 1.5 L12.5 12.5" :stroke "currentColor" :stroke-width "1.4" :stroke-linecap "round"}]])

(defn- mp3-icon [size]
  [:svg {:width size :height size :viewBox "0 0 14 14" :fill "none"}
   [:path {:d "M3 1.5 H8 L11 4.5 V12 C11 12.3 10.8 12.5 10.5 12.5 H3 C2.7 12.5 2.5 12.3 2.5 12 V2 C2.5 1.7 2.7 1.5 3 1.5 Z"
           :stroke "currentColor" :stroke-width "1.2" :stroke-linejoin "round"}]
   [:path {:d "M8 1.5 V4.5 H11" :stroke "currentColor" :stroke-width "1.2" :stroke-linejoin "round"}]
   [:text {:x "7" :y "10.3" :text-anchor "middle"
           :font-size "3.2" :font-weight "700"
           :fill "currentColor"} "MP3"]])

(defn- chevron-down [size]
  [:svg {:width size :height size :viewBox "0 0 12 12" :fill "none"}
   [:path {:d "M2 4 L6 8 L10 4" :stroke "currentColor" :stroke-width "1.6"
           :stroke-linecap "round" :stroke-linejoin "round"}]])

(defn- icon-for [mode]
  (case (d/mode->icon-key mode)
    :bell     [bell-icon 13]
    :bell-off [bell-off-icon 13]
    :mp3      [mp3-icon 13]))

;; Mode picker — prefer Telegram.WebApp.showPopup (native sheet); fall back
;; to window.confirm-style sequential prompt when SDK doesn't expose it.
;; The mp3 button is labeled "(Premium)" for non-premium users; the
;; ::set-delivery-mode handler enforces the gate (no PATCH; banner instead).
(defn- open-picker! [feed-id current-mode premium?]
  (let [tg     (some-> js/window .-Telegram .-WebApp)
        popup? (and tg (.-showPopup tg))
        mp3-label (if premium? "Send MP3" "Send MP3 (Premium)")]
    (if popup?
      (.showPopup tg
        #js{:title   "Delivery for this feed"
            :message (str "Pick how new episodes reach you:\n"
                          "• In-app only — New episodes appear here. We won't ping you.\n"
                          "• Notify me — Telegram message when a new episode drops. Tap to play.\n"
                          "• Send MP3 — The audio file lands in your Telegram chat. Listen anywhere.")
            :buttons #js[#js{:id "off"    :type "default" :text "In-app only"}
                         #js{:id "notify" :type "default" :text "Notify me"}
                         #js{:id "mp3"    :type "default" :text mp3-label}]}
        (fn [chosen-id]
          (when (and chosen-id (not= chosen-id (name current-mode)))
            (rf/dispatch [::events/set-delivery-mode feed-id (keyword chosen-id)]))))
      ;; Fallback — desktop / older WebViews
      (let [next-m (cond
                     (and premium? (js/confirm "Send MP3 to chat for new episodes?")) :mp3
                     (js/confirm "Notify in Telegram when a new episode drops?") :notify
                     :else :off)]
        (when (not= next-m current-mode)
          (rf/dispatch [::events/set-delivery-mode feed-id next-m]))))))

(defn delivery-chip
  "Reagent form-2 — outer accepts (and discards) the args Reagent passes at
   mount; inner re-binds them per render. Long-press = 500 ms; identical
   threshold to views/topics.cljs hide-topic gesture.

   Args (inner): feed-id, mode (keyword), premium? (bool). The premium flag
   gates the long-press popup's mp3 label and the cycle's next-mode (the
   cycle is computed in ::cycle-delivery-mode using db's :is-premium?)."
  [_initial-feed-id _initial-mode _initial-premium?]
  (let [timer        (r/atom nil)
        long-pressed (r/atom false)
        cancel!      (fn []
                       (when @timer (js/clearTimeout @timer) (reset! timer nil)))]
    (fn [feed-id mode premium?]
      (let [active? (not= mode :off)]
        [:button.delivery-chip
         {:class             (when active? "delivery-chip--active")
          :on-context-menu   (fn [e]
                               (.preventDefault e)
                               (reset! long-pressed true)
                               (open-picker! feed-id mode premium?))
          :on-pointer-down   (fn [_]
                               (reset! long-pressed false)
                               (reset! timer
                                       (js/setTimeout
                                        (fn []
                                          (reset! timer nil)
                                          (reset! long-pressed true)
                                          (open-picker! feed-id mode premium?))
                                        500)))
          :on-pointer-up     cancel!
          :on-pointer-leave  cancel!
          :on-pointer-cancel cancel!
          :on-click          (fn [e]
                               (.stopPropagation e)
                               (when-not @long-pressed
                                 (rf/dispatch [::events/cycle-delivery-mode feed-id])))}
         (icon-for mode)
         [:span (d/mode->label mode)]
         [:span.delivery-chip__chevron (chevron-down 9)]]))))
