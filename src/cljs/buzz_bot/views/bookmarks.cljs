(ns buzz-bot.views.bookmarks
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- episode-item [ep]
  [:li.episode-item
   {:data-episode-id (str (:id ep))
    :on-click        #(rf/dispatch [::events/navigate :player
                                    {:episode-id (:id ep) :from "bookmarks"}])}
   [:div.episode-info
    [:span.episode-feed  (:feed_title ep)]
    [:span.episode-title (:title ep)]]
   [:span.episode-play "▶"]])

(defn view []
  (let [query-atom (r/atom "")
        debounce   (atom nil)]
    (fn []
      (let [episodes @(rf/subscribe [::subs/bookmarks-list])
            loading? @(rf/subscribe [::subs/bookmarks-loading?])]
        [:div.bookmarks-container
         [:div.section-header [:h2 "Bookmarks"]]
         [:div.search-row
          [:input.search-input
           {:type        "search"
            :placeholder "Search bookmarks..."
            :on-change   (fn [e]
                           (let [v (.. e -target -value)]
                             (reset! query-atom v)
                             (when @debounce (js/clearTimeout @debounce))
                             (reset! debounce
                               (js/setTimeout
                                 #(rf/dispatch [::events/search-bookmarks v])
                                 300))))}]]
         (cond
           loading?          [:div.loading "Loading..."]
           (empty? episodes) [:div.empty-msg "No bookmarks yet. Like an episode to save it."]
           :else
           [:ul.episode-list
            (for [ep episodes]
              ^{:key (:id ep)} [episode-item ep])])]))))
