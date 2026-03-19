(ns buzz-bot.views.inbox
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- episode-visible? [ep filters]
  (let [{:keys [hide-listened? excluded-feeds]} filters]
    (and (not (and hide-listened? (:listened ep)))
         (not (contains? excluded-feeds (str (:feed_id ep)))))))

(defn- episode-item [ep playing-id]
  [:li.episode-item
   {:class           (cond-> ""
                       (:listened ep)                         (str " listened")
                       (= (str (:id ep)) (str playing-id))   (str " is-playing"))
    :data-episode-id (str (:id ep))
    :data-feed-id    (str (:feed_id ep))
    :on-click        #(rf/dispatch [::events/navigate :player
                                    {:episode-id (:id ep) :from "inbox"}])}
   [:div.episode-info
    [:span.episode-feed-name (:feed_title ep)]
    [:strong.episode-title   (:title ep)]]
   [:span.episode-play-icon "▶"]])

(defn- compact-group [eps playing-id expanded-feeds-atom]
  (let [feed-id  (:feed_id (first eps))
        expanded @expanded-feeds-atom]
    (if (or (= 1 (count eps)) (contains? expanded feed-id))
      (for [ep eps]
        ^{:key (:id ep)} [episode-item ep playing-id])
      (list
        ^{:key (:id (first eps))}
        [:li.episode-item.compact-first
         {:class           (cond-> ""
                             (:listened (first eps))                        (str " listened")
                             (= (str (:id (first eps))) (str playing-id))   (str " is-playing"))
          :data-episode-id (str (:id (first eps)))
          :data-feed-id    (str feed-id)
          :on-click        #(rf/dispatch [::events/navigate :player
                                          {:episode-id (:id (first eps)) :from "inbox"}])}
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
      (let [episodes   @(rf/subscribe [::subs/inbox-episodes])
            loading?   @(rf/subscribe [::subs/inbox-loading?])
            filters    @(rf/subscribe [::subs/inbox-filters])
            playing-id @(rf/subscribe [::subs/audio-episode-id])
            {:keys [hide-listened? compact?]} filters
            visible    (filter #(episode-visible? % filters) episodes)]
        [:div.episodes-container
         [:div.section-header
          [:div.section-header-row
           [:h2 "Inbox"]
           [:div.section-controls
            [:label.filter-label
             {:on-click (fn [e]
                          (.preventDefault e)
                          (rf/dispatch [::events/toggle-hide-listened]))}
             [:input.filter-checkbox
              {:type      "checkbox"
               :checked   hide-listened?
               :read-only true}]
             [:span.filter-switch]
             [:span.filter-text "Hide\u00a0✓"]]
            [:label.filter-label
             {:on-click (fn [e]
                          (.preventDefault e)
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
              (let [groups (partition-by :feed_id visible)]
                (for [grp groups]
                  (compact-group grp playing-id expanded-feeds)))
              (for [ep visible]
                ^{:key (:id ep)} [episode-item ep playing-id]))])]))))
