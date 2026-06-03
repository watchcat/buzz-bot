(ns buzz-bot.views.inbox-dubbed
  "Latest-dubbed widget mounted at the top of the Inbox screen. Pure
   presentation + dispatch — data comes from buzz-bot.subs/inbox-dubbed-items;
   pure helpers (fmt-relative-time, fmt-langflow) live in
   buzz-bot.inbox-dubbed."
  (:require [re-frame.core :as rf]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.inbox-dubbed :as id]
            [buzz-bot.views.utils :refer [img-proxy]]))

;; ── icons (verbatim port of inbox-chrome.jsx#DubbedIcon + a tiny chevron) ──

(defn- dubbed-icon [size]
  [:svg {:width size :height size :viewBox "0 0 10 10" :fill "none"}
   [:path {:d "M2 2 L4 2 L4 8 L2 8 Z" :fill "currentColor"}]
   [:path {:d "M5 1.5 C7 1.5 8.5 3 8.5 5 C8.5 7 7 8.5 5 8.5"
           :stroke "currentColor" :stroke-width "1.2" :fill "none" :stroke-linecap "round"}]
   [:path {:d "M5 3.5 C6 3.5 6.8 4.2 6.8 5 C6.8 5.8 6 6.5 5 6.5"
           :stroke "currentColor" :stroke-width "1.2" :fill "none" :stroke-linecap "round"}]])

(defn- chevron-right [size]
  [:svg {:width size :height size :viewBox "0 0 12 12" :fill "none"}
   [:path {:d "M4 2 L8 6 L4 10" :stroke "currentColor" :stroke-width "1.6"
           :stroke-linecap "round" :stroke-linejoin "round"}]])

(defn- fmt-duration [sec]
  (when (and sec (pos? sec))
    (let [h (js/Math.floor (/ sec 3600))
          m (js/Math.floor (/ (mod sec 3600) 60))]
      (if (pos? h) (str h "h " m "m") (str m " min")))))

(defn- card [item]
  (let [{:keys [episode_id feed_title feed_image ep_title ep_image
                duration_sec source_lang target_lang completed_at is_new]} item
        cover-url (or ep_image feed_image)
        when-str  (when completed_at
                    (id/fmt-relative-time (.getTime (js/Date. completed_at))))
        lang-flow (id/fmt-langflow source_lang target_lang)
        meta-str  (let [d (fmt-duration duration_sec)]
                    (cond
                      (and feed_title d) (str feed_title " · " d)
                      feed_title         feed_title
                      d                  d))]
    [:button.dubbed-card
     {:on-click #(rf/dispatch [::events/navigate :player
                               {:episode-id episode_id
                                :from       "inbox"
                                :dub-lang   target_lang}])}
     [:div.dubbed-card__cover-wrap
      (when cover-url
        [:img.dubbed-card__cover {:src      (img-proxy cover-url)
                                  :alt      ""
                                  :loading  "lazy"
                                  :decoding "async"
                                  :width    48
                                  :height   48}])
      (when is_new
        [:span.dubbed-new-badge "New"])]
     [:div.dubbed-card__body
      [:div.dubbed-langflow
       [:span.dubbed-langflow__pair lang-flow]
       (when when-str
         [:span.dubbed-langflow__when (str "· " when-str)])]
      [:div.dubbed-card__title ep_title]
      (when meta-str [:div.dubbed-card__meta meta-str])]]))

(defn widget
  "Renders nothing when there are no dubbed items — keeps the inbox
   list unchanged on the empty case."
  []
  (let [items @(rf/subscribe [::subs/inbox-dubbed-items])]
    (when (seq items)
      [:div.dubbed-section
       [:div.dubbed-header
        [:span.dubbed-header__label
         (dubbed-icon 11)
         "Latest dubbed"]
        [:span {:style {:flex 1}}]
        [:button.see-all-link
         {:on-click #(rf/dispatch [::events/navigate :dubbed])}
         "See all" (chevron-right 9)]]
       [:div.dubbed-cards
        (for [item items]
          ^{:key (:episode_id item)} [card item])]
       [:div.dubbed-divider]])))
