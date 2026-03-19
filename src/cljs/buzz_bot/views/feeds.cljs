(ns buzz-bot.views.feeds
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- feed-card [feed playing-feed-id]
  [:li.feed-item
   {:class (when (= (str (:id feed)) (str playing-feed-id)) "is-playing")}
   [:div.feed-info
    {:style    {:cursor "pointer"}
     :on-click #(rf/dispatch [::events/navigate :episodes {:feed-id (:id feed) :feed-url (:url feed)}])}
    (if (:image_url feed)
      [:div.feed-image {:style {:background-image    (str "url('" (:image_url feed) "')")
                                :background-size     "cover"
                                :background-position "center"}}]
      [:div.feed-image-placeholder "🎙"])
    [:div.feed-meta
     [:strong.feed-title (:title feed)]]]
   [:button.btn-icon
    {:title    "Unsubscribe"
     :on-click #(rf/dispatch [::events/unsubscribe-feed (:id feed)])}
    "✕"]])

(defn- search-result-item [result subscribed-urls]
  (let [feed-url    (:feed_url result)
        subscribed? (contains? subscribed-urls feed-url)]
    [:li.search-result-item
     (when (:artwork_url result)
       [:img.search-result-image {:src (:artwork_url result) :alt (:name result)}])
     [:div.search-result-meta
      [:span.search-result-name (:name result)]
      [:span.search-result-author (:author result)]
      (when (or (:genre result) (:episode_count result))
        [:div.search-result-tags
         (when (:genre result)
           [:span.tag (:genre result)])
         (when (:episode_count result)
           [:span.tag (str (:episode_count result) " eps")])])]
     (if subscribed?
       [:button.btn-subscribed {:disabled true} "✓ Subscribed"]
       [:button.btn-subscribe
        {:on-click #(rf/dispatch [::events/search-subscribe feed-url])}
        "Subscribe"])]))

(defn view []
  (let [url-atom  (r/atom "")
        query-atom (r/atom "")
        debounce  (atom nil)
        feeds     (rf/subscribe [::subs/feeds-list])
        loading?  (rf/subscribe [::subs/feeds-loading?])]
    (fn []
      (let [playing-feed-id  @(rf/subscribe [::subs/audio-feed-id])
            search-results   @(rf/subscribe [::subs/search-results])
            search-loading?  @(rf/subscribe [::subs/search-loading?])
            subscribed-urls  @(rf/subscribe [::subs/search-subscribed-urls])
            searching?       (seq @query-atom)]
        [:<>
         [:div.section-header
          [:div.section-header-row
           [:h2 "Feeds"]
           [:button.btn-icon
            {:title    "Refresh"
             :class    (when @loading? "btn-icon--spinning")
             :on-click #(rf/dispatch [::events/fetch-feeds])}
            "↻"]]]

         [:div.search-section
          [:input.search-input
           {:type        "search"
            :placeholder "Search podcasts by name..."
            :value       @query-atom
            :on-change   (fn [e]
                           (let [v (.. e -target -value)]
                             (reset! query-atom v)
                             (when @debounce (js/clearTimeout @debounce))
                             (reset! debounce
                               (js/setTimeout
                                 #(rf/dispatch [::events/fetch-search v])
                                 350))))}]]

         (cond
           (and searching? search-loading?)
           [:div.loading "Searching..."]

           (and searching? (empty? search-results))
           [:div.search-empty "No podcasts found"]

           searching?
           [:ul#search-results.search-result-list
            (for [r search-results]
              ^{:key (:feed_url r)} [search-result-item r subscribed-urls])]

           :else
           [:<>
            [:div.add-feed-form
             [:div.input-group
              [:input.feed-input
               {:type        "url"
                :placeholder "Or paste RSS feed URL..."
                :value       @url-atom
                :on-change   #(reset! url-atom (-> % .-target .-value))}]
              [:button.btn-primary
               {:on-click #(when (seq @url-atom)
                              (rf/dispatch [::events/subscribe-feed @url-atom])
                              (reset! url-atom ""))}
               "Add"]]]
            (cond
              @loading?       [:div.loading "Loading..."]
              (empty? @feeds) [:div.empty-msg "No feeds yet. Subscribe to a podcast!"]
              :else
              [:ul.feed-list
               (for [feed @feeds]
                 ^{:key (:id feed)} [feed-card feed playing-feed-id])])])]))))
