(ns buzz-bot.views.player
  (:require [re-frame.core :as rf]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- fmt-time [sec]
  (if (or (js/isNaN sec) (neg? sec) (not (js/isFinite sec)))
    "--:--"
    (let [h (js/Math.floor (/ sec 3600))
          m (js/Math.floor (/ (mod sec 3600) 60))
          s (js/Math.floor (mod sec 60))]
      (if (pos? h)
        (str h ":" (.padStart (str m) 2 "0") ":" (.padStart (str s) 2 "0"))
        (str m ":" (.padStart (str s) 2 "0"))))))

(defn- seek-bar [current duration pending?]
  (let [pct (if (pos? duration) (* 100 (/ current duration)) 0)]
    [:input#player-seek.player-seek-bar
     {:type      "range" :min 0 :max 100 :step 0.1
      :value     pct
      :disabled  pending?
      :style     {"--pct" (str (.toFixed pct 2) "%")}
      :on-change #(when (pos? duration)
                    (rf/dispatch [::events/audio-seek
                                  (* (/ (.. % -target -value) 100) duration)]))}]))

(defn view []
  (let [data      @(rf/subscribe [::subs/player-data])
        loading?  @(rf/subscribe [::subs/player-loading?])
        playing?  @(rf/subscribe [::subs/audio-playing?])
        pending?  @(rf/subscribe [::subs/audio-pending?])
        cur-time  @(rf/subscribe [::subs/audio-current-time])
        duration  @(rf/subscribe [::subs/audio-duration])
        rate      @(rf/subscribe [::subs/audio-rate])
        params    @(rf/subscribe [:buzz-bot.subs/view-params])]
    (cond
      loading?    [:div.loading "Loading episode..."]
      (nil? data) [:div.error-msg "Episode not found."]
      :else
      (let [{:keys [episode feed user_episode next_id recs is_subscribed]} data
            liked?    (= true (:liked user_episode))
            autoplay? (:autoplay? @(rf/subscribe [::subs/audio]))]
        [:div#player-root.player-container
         [:div.section-header
          [:div.section-header-row
           [:button.btn-back
            {:on-click #(rf/dispatch [::events/navigate
                                      (keyword (get params :from "inbox"))
                                      (when (= "episodes" (get params :from))
                                        {:feed-id (:feed_id episode)})])}
            "← Back"]]]
         [:div.player-card
          [:div.player-title-row
           [:h2.player-title (:title episode)]]

          [:div.player-controls
           [:div.player-progress-row
            [:span#player-current-time.player-time (fmt-time cur-time)]
            [seek-bar cur-time duration pending?]
            [:span#player-duration.player-time (fmt-time duration)]]
           [:div.player-buttons-row
            [:button.btn-seek {:on-click #(rf/dispatch [::events/audio-seek-relative -15])}
             [:span.btn-seek-icon "↺"] [:span.btn-seek-label "15s"]]
            [:button#player-play-pause.btn-play-pause-large
             {:on-click #(rf/dispatch [::events/toggle-play-pause])}
             (cond pending? "▶" playing? "⏸" :else "▶")]
            [:button.btn-seek {:on-click #(rf/dispatch [::events/audio-seek-relative 30])}
             [:span.btn-seek-icon "↻"] [:span.btn-seek-label "30s"]]]
           [:div.player-speed-row
            [:button#player-speed-btn.btn-speed
             {:class    (when (not= rate 1) "btn-speed--active")
              :on-click #(rf/dispatch [::events/cycle-speed])}
             (if (= rate 1) "1×" (str rate "×"))]
            [:button.btn-bookmark
             {:class    (when liked? "active")
              :title    (if liked? "Remove bookmark" "Bookmark")
              :on-click #(rf/dispatch [::events/toggle-bookmark (:id episode)])}
             [:svg {:viewBox "0 0 24 24" :xmlns "http://www.w3.org/2000/svg"}
              (if liked?
                [:path {:d "M17 3H7c-1.1 0-2 .9-2 2v16l7-3 7 3V5c0-1.1-.9-2-2-2z"}]
                [:path {:d "M17 3H7c-1.1 0-2 .9-2 2v16l7-3 7 3V5c0-1.1-.9-2-2-2zm0 15-5-2.18L7 18V5h10v13z"}])]]]]

          [:div.autoplay-row
           [:label.autoplay-label {:class (when-not next_id "autoplay-label--disabled")}
            [:input#autoplay-checkbox.autoplay-checkbox
             {:type      "checkbox"
              :disabled  (not next_id)
              :checked   autoplay?
              :on-change #(rf/dispatch [::events/toggle-autoplay])}]
            [:span.autoplay-switch]
            [:span.autoplay-text
             (if next_id "Play next episode after this one" "Last episode in feed")]]]

          (when-not is_subscribed
            [:div.subscribe-row
             [:button.btn-subscribe
              {:on-click #(rf/dispatch [::events/subscribe-from-player (:feed_id episode)])}
              (str "➕ Subscribe to " (or (:title feed) "this podcast"))]])

          (when (seq recs)
            [:div.recs-section
             [:h3.recs-title "Listeners also liked"]
             [:ul.recs-list
              (for [rec recs]
                ^{:key (:id rec)}
                [:li.rec-item
                 {:on-click #(rf/dispatch [::events/navigate :player {:episode-id (:id rec)}])}
                 [:div.rec-info
                  [:span.rec-feed  (:feed_title rec)]
                  [:span.rec-title (:title rec)]]
                 [:span.rec-play "▶"]])]])]]))))
