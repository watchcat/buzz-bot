(ns buzz-bot.views.inbox
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- episode-visible? [ep filters]
  (let [{:keys [hide-listened? excluded-feeds]} filters]
    (and (not (and hide-listened? (:listened ep)))
         (not (contains? excluded-feeds (str (:feed_id ep)))))))

(defn- episode-item [ep]
  [:li.episode-item
   {:class           (when (:listened ep) "listened")
    :data-episode-id (str (:id ep))
    :data-feed-id    (str (:feed_id ep))
    :on-click        #(rf/dispatch [::events/navigate :player {:episode-id (:id ep)}])}
   [:div.episode-info
    [:span.episode-feed-name (:feed_title ep)]
    [:strong.episode-title   (:title ep)]]
   [:span.episode-play-icon "▶"]])

(defn- compact-group [eps expanded-feeds-atom]
  (let [feed-id  (:feed_id (first eps))
        expanded @expanded-feeds-atom]
    (if (or (= 1 (count eps)) (contains? expanded feed-id))
      ;; show all episodes in group
      (for [ep eps]
        ^{:key (:id ep)} [episode-item ep])
      ;; show only first + expand button
      (list
        ^{:key (:id (first eps))}
        [:li.episode-item.compact-first
         {:class           (when (:listened (first eps)) "listened")
          :data-episode-id (str (:id (first eps)))
          :data-feed-id    (str feed-id)
          :on-click        #(rf/dispatch [::events/navigate :player
                                          {:episode-id (:id (first eps))}])}
         [:div.episode-info
          [:span.episode-feed-name (:feed_title (first eps))]
          [:strong.episode-title   (:title (first eps))]]
         [:span.episode-play-icon "▶"]
         [:button.compact-expand-btn
          {:on-click (fn [e]
                       (.stopPropagation e)
                       (swap! expanded-feeds-atom conj feed-id))}
          (str "+" (dec (count eps)) " more")]]))))

(defn view []
  (let [expanded-feeds (r/atom #{})]
    (fn []
      (let [episodes  @(rf/subscribe [::subs/inbox-episodes])
            loading?  @(rf/subscribe [::subs/inbox-loading?])
            filters   @(rf/subscribe [::subs/inbox-filters])
            {:keys [hide-listened? compact?]} filters
            visible   (filter #(episode-visible? % filters) episodes)]
        [:div.episodes-container
         [:div.section-header
          [:div.section-header-row
           [:h2 "Inbox"]
           [:div.section-controls
            [:label.filter-label
             {:on-click #(rf/dispatch [::events/toggle-hide-listened])}
             [:input.filter-checkbox
              {:type      "checkbox"
               :checked   hide-listened?
               :read-only true}]
             [:span.filter-switch]
             [:span.filter-text "Hide\u00a0✓"]]
            [:label.filter-label
             {:on-click (fn []
                          (reset! expanded-feeds #{})
                          (rf/dispatch [::events/toggle-compact]))}
             [:input.filter-checkbox
              {:type      "checkbox"
               :checked   compact?
               :read-only true}]
             [:span.filter-switch]
             [:span.filter-text "Compact"]]]]]
         (cond
           loading?         [:div.loading "Loading..."]
           (empty? visible) [:div.empty-msg "No episodes. Subscribe to some feeds!"]
           :else
           [:ul#episode-list.episode-list
            (if compact?
              ;; group by feed, show first + collapse rest
              (let [groups (partition-by :feed_id visible)]
                (for [grp groups]
                  (compact-group grp expanded-feeds)))
              ;; normal list
              (for [ep visible]
                ^{:key (:id ep)} [episode-item ep]))])]))))
