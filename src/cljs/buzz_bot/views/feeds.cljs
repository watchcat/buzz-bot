(ns buzz-bot.views.feeds
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- feed-card [feed]
  [:div.feed-card
   (when (:image_url feed)
     [:div.feed-artwork {:style {:background-image (str "url('" (:image_url feed) "')")}}])
   [:div.feed-info
    [:span.feed-title (:title feed)]
    [:span.feed-url   (:url feed)]]
   [:div.feed-actions
    [:button.btn-episodes
     {:on-click #(rf/dispatch [::events/navigate :episodes {:feed-id (:id feed)}])}
     "Episodes"]
    [:button.btn-unsubscribe
     {:on-click #(rf/dispatch [::events/unsubscribe-feed (:id feed)])}
     "Unsubscribe"]]])

(defn view []
  (let [url-atom (r/atom "")
        feeds    (rf/subscribe [::subs/feeds-list])
        loading? (rf/subscribe [::subs/feeds-loading?])]
    (fn []
      [:div.feeds-container
       [:div.section-header [:h2 "Feeds"]]
       [:div.subscribe-form
        [:input.feed-url-input
         {:type        "url"
          :placeholder "Paste RSS feed URL..."
          :value       @url-atom
          :on-change   #(reset! url-atom (-> % .-target .-value))}]
        [:button.btn-subscribe
         {:on-click #(when (seq @url-atom)
                       (rf/dispatch [::events/subscribe-feed @url-atom])
                       (reset! url-atom ""))}
         "Subscribe"]]
       (cond
         @loading?        [:div.loading "Loading..."]
         (empty? @feeds)  [:div.empty-msg "No feeds yet. Subscribe to a podcast!"]
         :else
         [:div.feeds-list
          (for [feed @feeds]
            ^{:key (:id feed)} [feed-card feed])])])))
