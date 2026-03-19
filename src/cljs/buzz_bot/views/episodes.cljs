(ns buzz-bot.views.episodes
  (:require [re-frame.core :as rf]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- episode-item [ep]
  [:li.episode-item
   {:class           (when (:listened ep) "listened")
    :data-episode-id (str (:id ep))
    :on-click        #(rf/dispatch [::events/navigate :player {:episode-id (:id ep)}])}
   [:div.episode-info
    [:span.episode-title (:title ep)]]
   [:span.episode-play "▶"]])

(defn view []
  (let [episodes  @(rf/subscribe [::subs/episodes-list])
        loading?  @(rf/subscribe [::subs/episodes-loading?])
        has-more? @(rf/subscribe [::subs/episodes-has-more?])
        order     @(rf/subscribe [::subs/episodes-order])
        {:keys [feed-id]} @(rf/subscribe [:buzz-bot.subs/view-params])]
    [:div.episodes-container
     [:div.section-header
      [:button.btn-back
       {:on-click #(rf/dispatch [::events/navigate :feeds])}
       "← Feeds"]
      [:label.filter-label
       [:input.filter-checkbox
        {:type      "checkbox"
         :checked   (= order :asc)
         :on-change #(rf/dispatch [::events/set-order (if (= order :asc) :desc :asc)])}]
       [:span.filter-switch]
       [:span "Oldest first"]]]
     (cond
       (and loading? (empty? episodes)) [:div.loading "Loading..."]
       (empty? episodes) [:div.empty-msg "No episodes in this feed."]
       :else
       [:<>
        [:ul#episode-list.episode-list
         {:data-feed-id (str feed-id)}
         (for [ep episodes]
           ^{:key (:id ep)} [episode-item ep])]
        (when has-more?
          [:button.btn-load-more
           {:on-click #(rf/dispatch [::events/load-more-episodes])
            :disabled loading?}
           (if loading? "Loading..." "Load more")])])]))
