(ns buzz-bot.views.inbox
  (:require [re-frame.core :as rf]
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
    (when (:feed_image_url ep)
      [:div.episode-artwork {:style {:background-image (str "url('" (:feed_image_url ep) "')")}}])
    [:div.episode-text
     [:span.episode-feed  (:feed_title ep)]
     [:span.episode-title (:title ep)]]]
   [:span.episode-play "▶"]])

(defn view []
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
         [:input.filter-checkbox
          {:type      "checkbox"
           :checked   hide-listened?
           :on-change #(rf/dispatch [::events/toggle-hide-listened])}]
         [:span.filter-switch]
         [:span.filter-text "Hide\u00a0✓"]]
        [:label.filter-label
         [:input.filter-checkbox
          {:type      "checkbox"
           :checked   compact?
           :on-change #(rf/dispatch [::events/toggle-compact])}]
         [:span.filter-switch]
         [:span.filter-text "Compact"]]]]]
     (cond
       loading?         [:div.loading "Loading..."]
       (empty? visible) [:div.empty-msg "No episodes. Subscribe to some feeds!"]
       :else
       [:ul#episode-list.episode-list
        (for [ep visible]
          ^{:key (:id ep)} [episode-item ep])])]))
