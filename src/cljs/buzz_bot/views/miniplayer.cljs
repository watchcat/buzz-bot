(ns buzz-bot.views.miniplayer
  (:require [re-frame.core :as rf]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn bar []
  (let [ep-id    @(rf/subscribe [::subs/audio-episode-id])
        title    @(rf/subscribe [::subs/audio-title])
        artist   @(rf/subscribe [::subs/audio-artist])
        artwork  @(rf/subscribe [::subs/audio-artwork])
        playing? @(rf/subscribe [::subs/audio-playing?])
        rate     @(rf/subscribe [::subs/audio-rate])]
    (when ep-id
      [:div.now-playing-bar
       [:div.now-playing-inner
        {:on-click #(rf/dispatch [::events/navigate :player {:episode-id ep-id}])}
        [:div.now-playing-artwork
         (when artwork {:style {:background-image (str "url('" artwork "')")}})
         (when-not artwork "🎙")]
        [:div.now-playing-text
         [:span.now-playing-title  title]
         [:span.now-playing-podcast artist]]]
       [:button.btn-speed
        {:class    (when (not= rate 1) "btn-speed--active")
         :on-click #(rf/dispatch [::events/cycle-speed])}
        (if (= rate 1) "1×" (str rate "×"))]
       [:button.now-playing-playpause
        {:on-click #(rf/dispatch [::events/toggle-play-pause])}
        (if playing? "⏸" "▶")]])))
