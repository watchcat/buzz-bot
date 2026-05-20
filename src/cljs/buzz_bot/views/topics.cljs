(ns buzz-bot.views.topics
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.tag-cloud :as tc]
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

(defn- episode-item [ep playing-id]
  [:li.episode-item
   {:class           (cond-> ""
                       (:listened ep)                       (str " listened")
                       (= (str (:id ep)) (str playing-id)) (str " is-playing"))
    :data-episode-id (str (:id ep))
    :on-click        #(rf/dispatch [::events/navigate :player
                                    {:episode-id (:id ep) :from "topics"}])}
   (when-let [img (:episode_image_url ep)]
     [:img.episode-thumb {:src (img-proxy img) :alt "" :loading "lazy"}])
   [:div.episode-info
    [:span.episode-feed-name (:feed_title ep)]
    [:strong.episode-title   (:title ep)]
    [episode-meta ep]]
   [:span.episode-play-icon "▶"]])

(defn- tag-cloud-item
  "Single tag span with size/opacity/weight from tag-style, click-to-filter,
   and pointer-event long-press-to-hide. Form-2 component so each instance
   keeps its own timer in an r/atom. Outer accepts (but discards) the initial
   args Reagent passes at mount; the inner fn re-binds them on every render."
  [_initial-tag _min-c _max-c]
  (let [timer  (r/atom nil)
        cancel #(when @timer
                  (js/clearTimeout @timer)
                  (reset! timer nil))]
    (fn [{:keys [tag count selected?]} min-c max-c]
      [:span.tag-cloud-item
       {:class             (when selected? "tag-cloud-item--active")
        :style             (when-not selected?
                             (let [s (tc/tag-style count min-c max-c)]
                               {:font-size   (str (:font-size s) "px")
                                :font-weight (:font-weight s)
                                :opacity     (:opacity s)}))
        :ref               (when selected?
                             (fn [el]
                               (when el
                                 (js/requestAnimationFrame
                                  #(.scrollIntoView el
                                    #js {:block  "center"
                                         :inline "nearest"})))))
        :on-click          (fn [e]
                             (.stopPropagation e)
                             (if selected?
                               (rf/dispatch [::events/clear-tag])
                               (rf/dispatch [::events/select-tag tag])))
        :on-pointer-down   (fn [_e]
                             (reset! timer
                                     (js/setTimeout
                                      (fn []
                                        (reset! timer nil)
                                        (.showConfirm
                                         js/Telegram.WebApp
                                         (str "Hide \"" tag "\" from your topics?")
                                         (fn [confirmed?]
                                           (when confirmed?
                                             (rf/dispatch
                                              [::events/hide-topic tag])))))
                                      500)))
        :on-pointer-up     cancel
        :on-pointer-leave  cancel
        :on-pointer-cancel cancel}
       tag])))

(defn- tag-cloud [tags selected-tag has-more-tags? hint-dismissed?]
  (let [min-c (apply min (map :count tags))
        max-c (apply max (map :count tags))]
    [:div.tag-cloud-section
     [:div.tag-cloud
      (for [{:keys [tag] :as t} tags]
        ^{:key tag}
        [tag-cloud-item
         (assoc t :selected? (= tag selected-tag))
         min-c
         max-c])]
     (when-not hint-dismissed?
       [:button.tag-cloud-hint
        {:on-click #(rf/dispatch [::events/dismiss-tag-cloud-hint])}
        "Tap to filter · long-press to hide · ×"])
     (when has-more-tags?
       [:button.tag-cloud-toggle
        {:on-click #(rf/dispatch [::events/load-more-tags])}
        "Show more"])]))

(defn view []
  (fn []
    (let [tags            @(rf/subscribe [::subs/topics-tags])
          episodes        @(rf/subscribe [::subs/topics-episodes])
          loading?        @(rf/subscribe [::subs/topics-loading?])
          selected-tag    @(rf/subscribe [::subs/topics-selected-tag])
          has-more-tags?  @(rf/subscribe [::subs/topics-has-more-tags?])
          hint-dismissed? @(rf/subscribe [::subs/topics-cloud-hint-dismissed?])
          playing-id      @(rf/subscribe [::subs/audio-episode-id])]
      [:div.episodes-container
       [:div.section-header
        [:div.section-header-row
         [:h2 "Topics"]
         [:button.btn-icon
          {:title    "Refresh"
           :class    (when loading? "btn-icon--spinning")
           :on-click #(rf/dispatch [::events/fetch-topics])}
          "↻"]]]
       (when (seq tags)
         [tag-cloud tags selected-tag has-more-tags? hint-dismissed?])
       (when selected-tag
         [:div.topics-filter-label
          (str "\"" selected-tag "\" · " (count episodes)
               (if (= 1 (count episodes)) " episode" " episodes"))])
       (cond
         loading?          [:div.loading "Loading..."]
         (empty? episodes) [:div.empty-msg
                            (if selected-tag
                              "No episodes with this topic."
                              "No topics yet. Episodes need embeddings first.")]
         :else
         [:ul#episode-list.episode-list
          (for [ep episodes]
            ^{:key (:id ep)} [episode-item ep playing-id])])])))
