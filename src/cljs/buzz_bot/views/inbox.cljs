(ns buzz-bot.views.inbox
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.views.inbox-dubbed :as inbox-dubbed]
            [buzz-bot.views.utils :refer [img-proxy]]))

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

(defn- tray-glyph []
  ;; Calm outline tray — quiet visual interest, not a loud emoji.
  [:svg.empty-state__glyph
   {:width 44 :height 44 :viewBox "0 0 24 24" :fill "none"
    :stroke "currentColor" :stroke-width "1.4"
    :stroke-linecap "round" :stroke-linejoin "round" :aria-hidden "true"}
   [:path {:d "M5 13 V6 a2 2 0 0 1 2 -2 h10 a2 2 0 0 1 2 2 v7"}]
   [:path {:d "M3 13 h5 l2 3 h4 l2 -3 h5 v5 a2 2 0 0 1 -2 2 H5 a2 2 0 0 1 -2 -2 z"}]])

(defn- inbox-empty-state
  "The inbox empties for three different reasons; each gets its own message
   and a CTA that fixes *that* situation. Showing 'subscribe to feeds' when
   the user already has feeds (just filtered/searched them away) is the bug
   this replaces."
  [{:keys [searching? no-episodes? query clear-search]}]
  (cond
    searching?
    [:div.empty-state
     [tray-glyph]
     [:div.empty-state__title "No matches"]
     [:div.empty-state__body (str "Nothing in your inbox matches “" query "”.")]
     [:button.btn-secondary {:on-click clear-search} "Clear search"]]

    no-episodes?
    [:div.empty-state
     [tray-glyph]
     [:div.empty-state__title "Your inbox is empty"]
     [:div.empty-state__body
      "New episodes from podcasts you follow show up here automatically."]
     [:button.btn-primary
      {:on-click #(rf/dispatch [::events/navigate :feeds])}
      "Browse feeds"]]

    :else
    [:div.empty-state
     [tray-glyph]
     [:div.empty-state__title "Nothing to show"]
     [:div.empty-state__body "Your filters are hiding every episode."]
     [:button.btn-secondary
      {:on-click #(rf/dispatch [::events/clear-inbox-filters])}
      "Show all episodes"]]))

(defn- nav-to-player [ep]
  (rf/dispatch [::events/navigate :player {:episode-id (:id ep) :from "inbox"}]))

(defn- play-label [ep]
  (str "Play " (:title ep)
       (when (:feed_title ep) (str " from " (:feed_title ep)))))

(defn- on-activate-key
  "Returns an on-key-down handler that runs `f` on Enter/Space. Guards on
   target == currentTarget so key events bubbling up from a nested control
   (the compact row's expand button) don't also trigger the row's action."
  [f]
  (fn [e]
    (when (and (contains? #{"Enter" " "} (.-key e))
               (= (.-target e) (.-currentTarget e)))
      (.preventDefault e)
      (f))))

(defn- episode-item [ep playing-id cached-ids]
  [:li.episode-item
   {:class           (cond-> ""
                       (:listened ep)                         (str " listened")
                       (= (str (:id ep)) (str playing-id))   (str " is-playing")
                       (contains? cached-ids (str (:id ep))) (str " cached"))
    :data-episode-id (str (:id ep))
    :data-feed-id    (str (:feed_id ep))
    :role            "button"
    :tab-index       0
    :aria-label      (play-label ep)
    :on-click        #(nav-to-player ep)
    :on-key-down     (on-activate-key #(nav-to-player ep))}
   (when-let [img (:episode_image_url ep)]
     [:img.episode-thumb {:src      (img-proxy img)
                          :alt      ""
                          :loading  "lazy"
                          :decoding "async"
                          :width    48
                          :height   48}])
   [:div.episode-info
    [:span.episode-feed-name (:feed_title ep)]
    [:strong.episode-title   (:title ep)]
    [episode-meta ep]]
   [:span.episode-play-icon "▶"]])

(defn- compact-group [eps playing-id expanded-feeds-atom cached-ids]
  (let [feed-id  (:feed_id (first eps))
        expanded @expanded-feeds-atom]
    (if (or (= 1 (count eps)) (contains? expanded feed-id))
      (for [ep eps]
        ^{:key (:id ep)} [episode-item ep playing-id cached-ids])
      (list
        ^{:key (:id (first eps))}
        [:li.episode-item.compact-first
         {:class           (cond-> ""
                             (:listened (first eps))                         (str " listened")
                             (= (str (:id (first eps))) (str playing-id))    (str " is-playing")
                             (contains? cached-ids (str (:id (first eps))))  (str " cached"))
          :data-episode-id (str (:id (first eps)))
          :data-feed-id    (str feed-id)
          :role            "button"
          :tab-index       0
          :aria-label      (play-label (first eps))
          :on-click        #(nav-to-player (first eps))
          :on-key-down     (on-activate-key #(nav-to-player (first eps)))}
         (when-let [img (:feed_image_url (first eps))]
           [:img.episode-thumb {:src      (img-proxy img)
                                :alt      ""
                                :loading  "lazy"
                                :decoding "async"
                                :width    48
                                :height   48}])
         [:div.episode-info
          [:span.episode-feed-name (:feed_title (first eps))]
          [:strong.episode-title   (:title (first eps))]
          [episode-meta (first eps)]]
         [:span.episode-play-icon "▶"]
         [:button.compact-expand-btn
          {:aria-label (str "Show " (dec (count eps)) " more episodes from "
                            (:feed_title (first eps)))
           :on-click   (fn [e]
                         (.stopPropagation e)
                         (swap! expanded-feeds-atom conj feed-id))}
          (str "+" (dec (count eps)) " more")]]))))

(defn view []
  (let [expanded-feeds (r/atom #{})
        query-atom     (r/atom "")
        debounce       (r/atom nil)]
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
              {:title      "Clear cached audio"
               :aria-label "Clear cached audio"
               :on-click   #(rf/dispatch [::events/audio-cache-clear-all])}
              "🗑"])
           [:button.btn-icon
            {:title      "Refresh"
             :aria-label "Refresh inbox"
             :aria-busy  (when loading? "true")
             :class      (when loading? "btn-icon--spinning")
             :on-click (fn [_]
                         (when @debounce (js/clearTimeout @debounce))
                         (reset! query-atom "")
                         (rf/dispatch [::events/fetch-inbox])
                         (rf/dispatch [::events/fetch-inbox-dubbed true]))}
            "↻"]
           [:div.section-controls
            [:label.filter-label
             {:on-click (fn [e]
                          (.preventDefault e)
                          (rf/dispatch [::events/toggle-hide-listened]))}
             [:input.filter-checkbox
              {:type      "checkbox"
               :role      "switch"
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
               :role      "switch"
               :checked   compact?
               :read-only true}]
             [:span.filter-switch]
             [:span.filter-text "Compact"]]]]]
         [inbox-dubbed/widget]
         [:div.search-section
          [:input.search-input
           {:type        "search"
            :placeholder "Search episodes..."
            :value       @query-atom
            :on-change   (fn [e]
                           (let [v (.. e -target -value)]
                             (reset! query-atom v)
                             (when @debounce (js/clearTimeout @debounce))
                             (if (empty? v)
                               (rf/dispatch [::events/fetch-inbox])
                               (reset! debounce
                                 (js/setTimeout
                                   #(rf/dispatch [::events/search-inbox v])
                                   300)))))}]]
         (cond
           loading?         [:div.loading "Loading..."]
           (empty? visible) [inbox-empty-state
                             {:searching?   (seq @query-atom)
                              :no-episodes? (empty? episodes)
                              :query        @query-atom
                              :clear-search (fn []
                                              (when @debounce (js/clearTimeout @debounce))
                                              (reset! query-atom "")
                                              (rf/dispatch [::events/fetch-inbox]))}]
           :else
           [:ul#episode-list.episode-list
            (if compact?
              (let [groups (partition-by :feed_id visible)]
                (for [grp groups]
                  (compact-group grp playing-id expanded-feeds cached-ids)))
              (for [ep visible]
                ^{:key (:id ep)} [episode-item ep playing-id cached-ids]))])]))))
