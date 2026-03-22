(ns buzz-bot.views.episodes
  (:require [re-frame.core :as rf]
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

(defn- episode-item [ep playing-id cached-ids]
  (let [date-str (fmt-pub-date (:published_at ep))
        dur-str  (fmt-duration (:duration_seconds ep))
        meta-str (cond (and date-str dur-str) (str date-str " · " dur-str)
                       date-str date-str
                       dur-str  dur-str)]
    [:li.episode-item
     {:class           (cond-> ""
                         (:listened ep)                              (str " listened")
                         (= (str (:id ep)) (str playing-id))        (str " is-playing")
                         (contains? cached-ids (str (:id ep)))      (str " cached"))
      :data-episode-id (str (:id ep))
      :on-click        #(rf/dispatch [::events/navigate :player
                                      {:episode-id (:id ep) :from "episodes"}])}
     [:div.episode-info
      [:span.episode-title (:title ep)]
      (when meta-str [:span.episode-meta meta-str])]
     [:span.episode-play-icon "▶"]]))

(defn view []
  (let [episodes   @(rf/subscribe [::subs/episodes-list])
        loading?   @(rf/subscribe [::subs/episodes-loading?])
        has-more?  @(rf/subscribe [::subs/episodes-has-more?])
        order      @(rf/subscribe [::subs/episodes-order])
        playing-id @(rf/subscribe [::subs/audio-episode-id])
        cached-ids @(rf/subscribe [::subs/cached-ids])
        {:keys [feed-id feed-url]} @(rf/subscribe [:buzz-bot.subs/view-params])]
    [:div.episodes-container
     [:div.section-header
      [:div.section-header-row
       [:button.btn-back
        {:on-click #(rf/dispatch [::events/navigate :feeds])}
        "← Feeds"]
       (when feed-url
         [:button.btn-rss-copy
          {:title    "Copy RSS URL"
           :on-click #(rf/dispatch [::events/copy-rss-url feed-url])}
          [:svg {:xmlns "http://www.w3.org/2000/svg" :width "18" :height "18"
                 :viewBox "0 0 24 24" :fill "none" :stroke "currentColor"
                 :stroke-width "2" :stroke-linecap "round" :stroke-linejoin "round"}
           [:path {:d "M4 11a9 9 0 0 1 9 9"}]
           [:path {:d "M4 4a16 16 0 0 1 16 16"}]
           [:circle {:cx "5" :cy "19" :r "1.5" :fill "currentColor" :stroke "none"}]]])
       [:button.btn-icon
        {:title    "Refresh"
         :class    (when loading? "btn-icon--spinning")
         :on-click #(rf/dispatch [::events/fetch-episodes feed-id])}
        "↻"]
       [:label.filter-label
        [:input.filter-checkbox
         {:type      "checkbox"
          :checked   (= order :asc)
          :on-change #(rf/dispatch [::events/set-order (if (= order :asc) :desc :asc)])}]
        [:span.filter-switch]
        [:span.filter-text "Oldest first"]]]]
     (cond
       (and loading? (empty? episodes)) [:div.loading "Loading..."]
       (empty? episodes)                [:div.empty-msg "No episodes in this feed."]
       :else
       [:<>
        [:ul#episode-list.episode-list
         {:data-feed-id (str feed-id)}
         (for [ep episodes]
           ^{:key (:id ep)} [episode-item ep playing-id cached-ids])]
        (when has-more?
          [:button.btn-load-more
           {:on-click #(rf/dispatch [::events/load-more-episodes])
            :disabled loading?}
           (if loading? "Loading..." "Load more")])])]))
