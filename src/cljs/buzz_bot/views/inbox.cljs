(ns buzz-bot.views.inbox
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- fmt-pub-date [published-at]
  (when published-at
    (let [d      (js/Date. published-at)
          months #js ["Jan" "Feb" "Mar" "Apr" "May" "Jun"
                      "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"]]
      (str (aget months (.getMonth d)) " " (.getDate d) ", " (.getFullYear d)))))

(defn- fmt-duration [sec]
  (when (and sec (pos? sec))
    (let [h (js/Math.floor (/ sec 3600))
          m (js/Math.floor (/ (mod sec 3600) 60))]
      (if (pos? h) (str h "h " m "m") (str m " min")))))

(defn- episode-meta [ep]
  (let [date-str (fmt-pub-date (:published_at ep))
        dur-str  (fmt-duration (:duration_seconds ep))
        meta-str (cond (and date-str dur-str) (str date-str " · " dur-str)
                       date-str date-str
                       dur-str  dur-str)]
    (when meta-str [:span.episode-meta meta-str])))

(defn- episode-visible? [ep filters]
  (let [{:keys [hide-listened? excluded-feeds]} filters]
    (and (not (and hide-listened? (:listened ep)))
         (not (contains? excluded-feeds (str (:feed_id ep)))))))

(defn- episode-item [ep playing-id cached-ids]
  [:li.episode-item
   {:class           (cond-> ""
                       (:listened ep)                         (str " listened")
                       (= (str (:id ep)) (str playing-id))   (str " is-playing")
                       (contains? cached-ids (str (:id ep))) (str " cached"))
    :data-episode-id (str (:id ep))
    :data-feed-id    (str (:feed_id ep))
    :on-click        #(rf/dispatch [::events/navigate :player
                                    {:episode-id (:id ep) :from "inbox"}])}
   (when-let [img (:episode_image_url ep)]
     [:img.episode-thumb {:src img :alt ""}])
   [:div.episode-info
    [:span.episode-feed-name (:feed_title ep)]
    [:strong.episode-title   (:title ep)]
    [episode-meta ep]]
   [:span.episode-play-icon "▶"]])

(defn- compact-group [eps playing-id cached-ids expanded-feeds-atom]
  (let [feed-id  (:feed_id (first eps))
        expanded @expanded-feeds-atom]
    (if (or (= 1 (count eps)) (contains? expanded feed-id))
      (for [ep eps]
        ^{:key (:id ep)} [episode-item ep playing-id cached-ids])
      (list
        ^{:key (:id (first eps))}
        [:li.episode-item.compact-first
         {:class           (cond-> ""
                             (:listened (first eps))                        (str " listened")
                             (= (str (:id (first eps))) (str playing-id))   (str " is-playing")
                             (contains? cached-ids (str (:id (first eps)))) (str " cached"))
          :data-episode-id (str (:id (first eps)))
          :data-feed-id    (str feed-id)
          :on-click        #(rf/dispatch [::events/navigate :player
                                          {:episode-id (:id (first eps)) :from "inbox"}])}
         (when-let [img (:feed_image_url (first eps))]
           [:img.episode-thumb {:src img :alt ""}])
         [:div.episode-info
          [:span.episode-feed-name (:feed_title (first eps))]
          [:strong.episode-title   (:title (first eps))]
          [episode-meta (first eps)]]
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
            cached-ids @(rf/subscribe [::subs/cached-ids])
            {:keys [hide-listened? compact?]} filters
            visible    (filter #(episode-visible? % filters) episodes)]
        [:div.episodes-container
         [:div.section-header
          [:div.section-header-row
           [:h2 "Inbox"]
           (when (seq cached-ids)
             [:button.btn-clear-cache
              {:title    "Clear cached audio"
               :on-click #(rf/dispatch [::events/cache-clear-all])}
              "🗑"])
           [:button.btn-icon
            {:title    "Refresh"
             :class    (when loading? "btn-icon--spinning")
             :on-click #(rf/dispatch [::events/fetch-inbox])}
            "↻"]
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
                  (compact-group grp playing-id cached-ids expanded-feeds)))
              (for [ep visible]
                ^{:key (:id ep)} [episode-item ep playing-id cached-ids]))])]))))
