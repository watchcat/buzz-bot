(ns buzz-bot.views.player
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.fx :as fx]))

(defn- fmt-time [sec]
  (if (or (js/isNaN sec) (neg? sec) (not (js/isFinite sec)))
    "--:--"
    (let [h (js/Math.floor (/ sec 3600))
          m (js/Math.floor (/ (mod sec 3600) 60))
          s (js/Math.floor (mod sec 60))]
      (if (pos? h)
        (str h ":" (.padStart (str m) 2 "0") ":" (.padStart (str s) 2 "0"))
        (str m ":" (.padStart (str s) 2 "0"))))))

(defn- seek-bar [current duration pending? cache-pct]
  (let [pct       (if (pos? duration) (* 100 (/ current duration)) 0)
        cpct      (or cache-pct 0)]
    [:input#player-seek.player-seek-bar
     {:type      "range" :min 0 :max 100 :step 0.1
      :value     pct
      :disabled  pending?
      :style     {"--pct"       (str (.toFixed pct 2) "%")
                  "--cache-pct" (str (.toFixed cpct 2) "%")}
      :on-change #(when (pos? duration)
                    (rf/dispatch [::events/audio-seek
                                  (* (/ (.. % -target -value) 100) duration)]))}]))

(defn- share-url [episode-id message]
  (let [bot-username (.. js/window -BOT_USERNAME)
        deep-link    (str "https://t.me/" bot-username "?start=ep_" episode-id)]
    (str "https://t.me/share/url?url=" (js/encodeURIComponent deep-link)
         "&text=" (js/encodeURIComponent (.trim message)))))

(defn view []
  (let [share-open? (r/atom false)
        share-msg   (r/atom "")]
    (fn []
      (let [data           @(rf/subscribe [::subs/player-data])
            loading?       @(rf/subscribe [::subs/player-loading?])
            playing?       @(rf/subscribe [::subs/audio-playing?])
            pending?       @(rf/subscribe [::subs/audio-pending?])
            cur-time       @(rf/subscribe [::subs/audio-current-time])
            duration       @(rf/subscribe [::subs/audio-duration])
            rate           @(rf/subscribe [::subs/audio-rate])
            send-status    @(rf/subscribe [::subs/player-send-status])
            params         @(rf/subscribe [:buzz-bot.subs/view-params])
            ep-id          (str (get-in data [:episode :id] ""))
            cache-progress @(rf/subscribe [::subs/cache-progress ep-id])
            cached?        @(rf/subscribe [::subs/episode-cached? ep-id])
            cache-pct      (cond
                             cached?                                  100
                             (pos? (:bytes-total cache-progress 0))  (* 100.0
                                                                        (/ (:bytes-downloaded cache-progress)
                                                                           (:bytes-total cache-progress)))
                             :else                                    0)]
        (cond
          loading?    [:div.loading "Loading episode..."]
          (nil? data) [:div.error-msg "Episode not found."]
          :else
          (let [{:keys [episode feed user_episode next_id next_title recs is_subscribed is_premium]} data
                liked?    (= true (:liked user_episode))
                autoplay? (:autoplay? @(rf/subscribe [::subs/audio]))]
            ;; Initialize share message when episode changes
            (when (empty? @share-msg)
              (reset! share-msg
                (str "🎧 Check out this episode:\n\n"
                     (:title episode) "\n"
                     (or (:title feed) ""))))
            [:div#player-root.player-container
             [:div.section-header
              [:div.section-header-row
               [:button.btn-back
                {:on-click #(rf/dispatch [::events/navigate
                                          (keyword (get params :from "inbox"))
                                          (when (= "episodes" (get params :from))
                                            {:feed-id (:feed_id episode)})])}
                "← Back"]
               (when (contains? #{"inbox" "bookmarks"} (get params :from))
                 [:button.btn-feed-link
                  {:on-click #(rf/dispatch [::events/navigate :episodes
                                            {:feed-id (:feed_id episode)
                                             :feed-url (:url feed)}])}
                  (str (or (:title feed) "Feed") " →")])]]
             [:div.player-card
              [:div.player-title-row
               [:h2.player-title (:title episode)]
               (when-let [rss-url (:url feed)]
                 [:button.btn-rss-copy
                  {:title    "Copy RSS URL"
                   :on-click #(rf/dispatch [::events/copy-rss-url rss-url])}
                  [:svg {:xmlns "http://www.w3.org/2000/svg" :width "18" :height "18"
                         :viewBox "0 0 24 24" :fill "none" :stroke "currentColor"
                         :stroke-width "2" :stroke-linecap "round" :stroke-linejoin "round"}
                   [:path {:d "M4 11a9 9 0 0 1 9 9"}]
                   [:path {:d "M4 4a16 16 0 0 1 16 16"}]
                   [:circle {:cx "5" :cy "19" :r "1.5" :fill "currentColor" :stroke "none"}]]])
               [:button.btn-share-icon
                {:title    "Share episode"
                 :on-click #(swap! share-open? not)}
                [:svg {:xmlns "http://www.w3.org/2000/svg" :width "20" :height "20"
                       :viewBox "0 0 24 24" :fill "none" :stroke "currentColor"
                       :stroke-width "2" :stroke-linecap "round" :stroke-linejoin "round"}
                 [:path {:d "M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"}]
                 [:polyline {:points "16 6 12 2 8 6"}]
                 [:line {:x1 "12" :y1 "2" :x2 "12" :y2 "15"}]]]]

              (when @share-open?
                [:div.share-panel
                 [:textarea.share-message-input
                  {:rows      3
                   :value     @share-msg
                   :on-change #(reset! share-msg (.. % -target -value))}]
                 [:button.btn-share-confirm
                  {:on-click #(rf/dispatch [::events/open-telegram-link
                                            (share-url (:id episode) @share-msg)])}
                  "📤 Share"]])

              [:div.player-controls
               [:div.player-progress-row
                [:span#player-current-time.player-time (fmt-time cur-time)]
                [seek-bar cur-time duration pending? cache-pct]
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
                 (if next_id (str "Play next: " next_title) "Last episode in feed")]]]

              (when-not is_subscribed
                [:div.subscribe-row
                 [:button.btn-subscribe
                  {:on-click #(rf/dispatch [::events/subscribe-from-player (:feed_id episode)])}
                  (str "➕ Subscribe to " (or (:title feed) "this podcast"))]])

              [:div.send-row
               (case send-status
                 nil
                 [:button.btn-send
                  {:on-click #(if is_premium
                                (rf/dispatch [::events/send-episode (:id episode)])
                                (rf/dispatch [::events/send-episode-error "HTTP 402"]))}
                  "📤 Send to Chat"]
                 :loading
                 [:button.btn-send {:disabled true} "Sending…"]
                 :sent
                 [:div.send-result.info "📤 Sending to your chat… it will arrive in a moment."]
                 :upsell
                 [:div.send-result.upsell
                  "⭐ " [:strong "Premium feature."]
                  " Send episodes to your Telegram chat with a Buzz-Bot subscription."]
                 :error
                 [:div.send-result.error "Something went wrong. Please try again."])]

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
                     [:span.rec-play "▶"]])]])]]))))))
