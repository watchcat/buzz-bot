(ns buzz-bot.views.bookmarks
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- cached-episode-item [ep playing-id]
  [:li.episode-item.cached-item
   {:class           (when (= (str (:id ep)) (str playing-id)) "is-playing")
    :data-episode-id (str (:id ep))
    :on-click        #(rf/dispatch [::events/navigate :player
                                    {:episode-id (:id ep) :from "bookmarks"}])}
   (when-let [img (:image_url ep)]
     [:img.episode-thumb {:src img :alt ""}])
   [:div.episode-info
    [:span.episode-feed-name (:feed_title ep)]
    [:span.episode-title     (:title ep)]]
   [:button.btn-cache-delete
    {:title    "Remove from cache"
     :on-click (fn [e]
                 (.stopPropagation e)
                 (rf/dispatch [::events/cache-evict
                               {:episode-id (:id ep)
                                :blob-url   (:blob-url ep)}]))}
    "×"]])

(defn- cached-section [cached-eps playing-id open?-atom]
  (let [open? @open?-atom]
    [:div.cached-section
     [:button.cached-section-toggle
      {:on-click #(swap! open?-atom not)}
      [:span.cached-section-icon (if open? "▾" "▸")]
      [:span.cached-section-label (str "Cached (" (count cached-eps) ")")]
      [:span.cached-section-hint "available offline"]]
     (when open?
       [:ul.episode-list.cached-list
        (for [ep cached-eps]
          ^{:key (:id ep)} [cached-episode-item ep playing-id])])]))

(defn- episode-item [ep playing-id]
  [:li.episode-item
   {:class           (when (= (str (:id ep)) (str playing-id)) "is-playing")
    :data-episode-id (str (:id ep))
    :on-click        #(rf/dispatch [::events/navigate :player
                                    {:episode-id (:id ep) :from "bookmarks"}])}
   [:div.episode-info
    [:span.episode-feed-name (:feed_title ep)]
    [:span.episode-title     (:title ep)]]
   [:span.episode-play-icon "▶"]])

(defn view []
  (let [query-atom   (r/atom "")
        debounce     (atom nil)
        cache-open?  (r/atom true)]
    (fn []
      (let [episodes    @(rf/subscribe [::subs/bookmarks-list])
            loading?    @(rf/subscribe [::subs/bookmarks-loading?])
            playing-id  @(rf/subscribe [::subs/audio-episode-id])
            cached-eps  @(rf/subscribe [::subs/cached-episodes])]
        [:div.episodes-container
         [:div.section-header
          [:div.section-header-row [:h2 "Bookmarks"]]]
         (when (seq cached-eps)
           [cached-section cached-eps playing-id cache-open?])
         [:div.search-section
          [:input.search-input
           {:type        "search"
            :placeholder "Search all episodes..."
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
              ^{:key (:id ep)} [episode-item ep playing-id])])]))))
