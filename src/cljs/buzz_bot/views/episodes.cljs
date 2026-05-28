(ns buzz-bot.views.episodes
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.delivery :as d]
            [buzz-bot.views.delivery-chip :refer [delivery-chip]]
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

(defn- episode-item [ep playing-id cached-ids new-ids]
  (let [date-str (fmt-pub-date (:published_at ep))
        dur-str  (fmt-duration (:duration_seconds ep))
        meta-str (cond (and date-str dur-str) (str date-str " · " dur-str)
                       date-str date-str
                       dur-str  dur-str)
        is-new?  (d/new? new-ids (:id ep))]
    [:li.episode-item
     {:class           (cond-> ""
                         (:listened ep)                        (str " listened")
                         (= (str (:id ep)) (str playing-id))  (str " is-playing")
                         (contains? cached-ids (str (:id ep))) (str " cached"))
      :data-episode-id (str (:id ep))
      :on-click        #(rf/dispatch [::events/navigate :player
                                      {:episode-id (:id ep) :from "episodes"}])}
     (when-let [img (:episode_image_url ep)]
       [:img.episode-thumb {:src      (img-proxy img)
                            :alt      ""
                            :loading  "lazy"
                            :decoding "async"
                            :width    48
                            :height   48}])
     [:div.episode-info
      [:span.episode-title
       (when is-new? [:span.episode-new-badge "New"])
       (:title ep)]
      (when meta-str [:span.episode-meta meta-str])]
     [:span.episode-play-icon "▶"]]))

(defn- overflow-menu [feed-id feed-url menu-open?]
  (when @menu-open?
    [:div.overflow-menu
     (when feed-url
       [:button.overflow-menu__item
        {:on-click (fn [_]
                     (reset! menu-open? false)
                     (rf/dispatch [::events/copy-rss-url feed-url]))}
        "Copy RSS link"])
     [:button.overflow-menu__item
      {:on-click (fn [_]
                   (reset! menu-open? false)
                   (rf/dispatch [::events/fetch-episodes feed-id]))}
      "Refresh now"]]))

(defn view []
  (let [menu-open?  (r/atom false)
        ;; Document-level click listener installed lazily on first menu open.
        ;; Stored in an atom so we can remove it on unmount / next close.
        outside-fn  (atom nil)
        unmount!    (fn []
                      (when-let [f @outside-fn]
                        (.removeEventListener js/document "click" f true)
                        (reset! outside-fn nil)))
        toggle-menu! (fn []
                       (swap! menu-open? not)
                       (if @menu-open?
                         (let [f (fn [_] (reset! menu-open? false) (unmount!))]
                           (reset! outside-fn f)
                           (.addEventListener js/document "click" f true))
                         (unmount!)))]
    (r/create-class
     {:component-will-unmount unmount!
      :reagent-render
      (fn []
        (let [episodes        @(rf/subscribe [::subs/episodes-list])
              loading?        @(rf/subscribe [::subs/episodes-loading?])
              has-more?       @(rf/subscribe [::subs/episodes-has-more?])
              order           @(rf/subscribe [::subs/episodes-order])
              playing-id      @(rf/subscribe [::subs/audio-episode-id])
              cached-ids      @(rf/subscribe [::subs/cached-ids])
              delivery-mode   @(rf/subscribe [::subs/delivery-mode])
              premium?        @(rf/subscribe [::subs/is-premium?])
              upsell?         @(rf/subscribe [::subs/delivery-upsell?])
              new-ids         @(rf/subscribe [::subs/new-episode-ids])
              {:keys [feed-id feed-url feed-title]} @(rf/subscribe [:buzz-bot.subs/view-params])]

          ;; Fire-and-forget mark-viewed on first render with episodes loaded
          ;; (the marker happens after the badges have rendered).
          (r/with-let [_ (when (and feed-id (seq episodes))
                           (js/setTimeout
                            #(rf/dispatch [::events/mark-feed-viewed feed-id])
                            100))])

          [:div.episodes-container
           ;; ── Header — one row ──
           [:div.section-header
            [:div.section-header-row
             [:button.btn-back
              {:on-click #(rf/dispatch [::events/navigate :feeds])}
              "← Feeds"]
             (when feed-title
               [:span.section-feed-title feed-title])
             [:span {:style {:flex 1}}]
             [:span.overflow-anchor
              {:on-click #(.stopPropagation %)}  ; keep menu open until next outside click
              [:button.overflow-trigger {:on-click toggle-menu!} "⋯"]
              [overflow-menu feed-id feed-url menu-open?]]]]

           ;; ── Chips row ──
           (when feed-id
             [:div.feed-chips-row
              [delivery-chip feed-id delivery-mode premium?]
              [:button.sort-chip
               {:on-click #(rf/dispatch [::events/set-order (if (= order :asc) :desc :asc)])}
               [:span (if (= order :asc) "↑" "↕")]
               (if (= order :asc) "Oldest" "Newest")]])

           ;; ── Upsell banner — non-premium tried mp3 ──
           (when upsell?
             [:div.delivery-upsell
              {:on-click #(rf/dispatch [::events/dismiss-delivery-upsell])}
              "⭐ " [:strong "Premium feature."]
              " Auto-deliver MP3s to your Telegram chat with a Buzz-Bot subscription."])

           ;; ── Body ──
           (cond
             (and loading? (empty? episodes)) [:div.loading "Loading..."]
             (empty? episodes)                [:div.empty-msg "No episodes in this feed."]
             :else
             [:<>
              [:ul#episode-list.episode-list
               {:data-feed-id (str feed-id)}
               (for [ep episodes]
                 ^{:key (:id ep)} [episode-item ep playing-id cached-ids new-ids])]
              (when has-more?
                [:button.btn-load-more
                 {:on-click #(rf/dispatch [::events/load-more-episodes])
                  :disabled loading?}
                 (if loading? "Loading..." "Load more")])])]))})))
