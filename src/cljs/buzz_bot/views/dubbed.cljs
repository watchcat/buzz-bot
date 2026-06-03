(ns buzz-bot.views.dubbed
  "Dedicated 'Dubbed' page reached from the inbox 'See all' link: the full
   dubbed-episode history with a persistent, server-side language filter that
   also constrains the inbox bar. Presentation + dispatch only; pure helpers
   (fmt-langflow, fmt-relative-time) live in buzz-bot.inbox-dubbed."
  (:require [clojure.string :as str]
            [re-frame.core :as rf]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.inbox-dubbed :as id]
            [buzz-bot.views.utils :refer [img-proxy]]))

(defn- fmt-duration [sec]
  (when (and sec (pos? sec))
    (let [h (js/Math.floor (/ sec 3600))
          m (js/Math.floor (/ (mod sec 3600) 60))]
      (if (pos? h) (str h "h " m "m") (str m " min")))))

(defn- on-activate-key [f]
  (fn [e]
    (when (and (contains? #{"Enter" " "} (.-key e))
               (= (.-target e) (.-currentTarget e)))
      (.preventDefault e)
      (f))))

(defn- lang-chip [lang selected?]
  [:span.lang-chip
   {:class        (when selected? "lang-chip--active")
    :role         "button"
    :tab-index    0
    :aria-pressed (if selected? "true" "false")
    :on-click     #(rf/dispatch [::events/toggle-dubbed-lang lang])
    :on-key-down  (on-activate-key #(rf/dispatch [::events/toggle-dubbed-lang lang]))}
   (str/upper-case lang)])

(defn- lang-filter [languages selected]
  [:div.lang-filter
   (for [lang languages]
     ^{:key lang} [lang-chip lang (contains? selected lang)])
   (when (seq selected)
     [:span.lang-chip.lang-chip--reset
      {:role        "button"
       :tab-index   0
       :aria-label  "Show all languages"
       :on-click    #(rf/dispatch [::events/clear-dubbed-langs])
       :on-key-down (on-activate-key #(rf/dispatch [::events/clear-dubbed-langs]))}
      "All"])])

(defn- nav-to-player [item]
  (rf/dispatch [::events/navigate :player
                {:episode-id (:episode_id item)
                 :from       "dubbed"
                 :dub-lang   (:target_lang item)}]))

(defn- dubbed-row [item]
  (let [{:keys [feed_title feed_image ep_title ep_image duration_sec
                source_lang target_lang completed_at]} item
        cover-url (or ep_image feed_image)
        when-str  (when completed_at
                    (id/fmt-relative-time (.getTime (js/Date. completed_at))))
        dur-str   (fmt-duration duration_sec)
        tail      (str/join " · " (remove nil? [dur-str when-str]))]
    [:li.episode-item
     {:role        "button"
      :tab-index   0
      :aria-label  (str "Play " ep_title " dubbed in " (str/upper-case target_lang))
      :on-click    #(nav-to-player item)
      :on-key-down (on-activate-key #(nav-to-player item))}
     (when cover-url
       [:img.episode-thumb {:src      (img-proxy cover-url)
                            :alt      ""
                            :loading  "lazy"
                            :decoding "async"
                            :width    48
                            :height   48}])
     [:div.episode-info
      [:span.episode-feed-name feed_title]
      [:strong.episode-title ep_title]
      [:div.episode-meta
       [:span.dubbed-langflow
        [:span.dubbed-langflow__pair (id/fmt-langflow source_lang target_lang)]]
       (when (seq tail) [:span tail])]]
     [:span.episode-play-icon "▶"]]))

(defn view []
  (fn []
    (let [items     @(rf/subscribe [::subs/dubbed-items])
          languages @(rf/subscribe [::subs/dubbed-languages])
          selected  @(rf/subscribe [::subs/dubbed-selected-langs])
          loading?  @(rf/subscribe [::subs/dubbed-loading?])]
      [:div.episodes-container
       [:div.section-header
        [:div.section-header-row
         [:button.btn-back
          {:on-click #(rf/dispatch [::events/navigate :inbox])}
          "← Dubbed"]]]
       (when (seq languages)
         [lang-filter languages selected])
       (cond
         loading?
         [:div.loading "Loading..."]

         (empty? languages)
         [:div.empty-state
          [:div.empty-state__title "No dubbed episodes yet"]
          [:div.empty-state__body
           "When you dub an episode, every dubbed episode collects here so you can find it later."]]

         (empty? items)
         [:div.empty-state
          [:div.empty-state__title "Nothing in those languages"]
          [:div.empty-state__body "No dubbed episodes match the selected languages."]
          [:button.btn-secondary
           {:on-click #(rf/dispatch [::events/clear-dubbed-langs])}
           "Show all languages"]]

         :else
         [:ul#dubbed-list.episode-list
          (for [item items]
            ^{:key (:episode_id item)} [dubbed-row item])])])))
