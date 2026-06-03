(ns buzz-bot.views.player
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [clojure.string :as str]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.fx :as fx]
            [buzz-bot.views.dub :as dub-view]
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

(defn- fmt-time [sec]
  (if (or (js/isNaN sec) (neg? sec) (not (js/isFinite sec)))
    "--:--"
    (let [h (js/Math.floor (/ sec 3600))
          m (js/Math.floor (/ (mod sec 3600) 60))
          s (js/Math.floor (mod sec 60))]
      (if (pos? h)
        (str h ":" (.padStart (str m) 2 "0") ":" (.padStart (str s) 2 "0"))
        (str m ":" (.padStart (str s) 2 "0"))))))

(defn- seek-bar [_current _duration _pending? _dl-pct]
  (let [dragging? (r/atom false)
        drag-pct  (r/atom 0)]
    (fn [current duration pending? dl-pct]
      (let [pct   (if (pos? duration) (* 100 (/ current duration)) 0)
            style (cond-> {"--pct" (str (.toFixed (if @dragging? @drag-pct pct) 2) "%")}
                    dl-pct (assoc "--dl-pct" (str dl-pct "%")))]
        (when-not @dragging?
          (reset! drag-pct pct))
        [:input#player-seek.player-seek-bar
         {:type          "range" :min 0 :max 100 :step 0.1
          :value         (str @drag-pct)
          :disabled      pending?
          :style         style
          :on-change     #(when (pos? duration)
                            (reset! dragging? true)
                            (reset! drag-pct (js/parseFloat (.. % -target -value))))
          :on-pointer-up #(when (pos? duration)
                            (reset! dragging? false)
                            (rf/dispatch [::events/audio-seek
                                          (* (/ (js/parseFloat (.. % -target -value)) 100) duration)]))}]))))

(defn- share-url [episode-id message]
  (let [bot-username (.. js/window -BOT_USERNAME)
        deep-link    (str "https://t.me/" bot-username "?start=ep_" episode-id)]
    (str "https://t.me/share/url?url=" (js/encodeURIComponent deep-link)
         "&text=" (js/encodeURIComponent (.trim message)))))

(defn- cue-text [cue lang]
  (if (= lang :original)
    (:text cue)
    (or (:translation cue) (:text cue))))

(defn- transcript-modal [episode-id]
  (r/with-let
    [_ (js/setTimeout
         (fn []
           (when-let [el (.querySelector js/document ".transcript-cue--current")]
             (.scrollIntoView el #js {:block "center"})))
         80)]
    (let [all-cues    @(rf/subscribe [::subs/subtitle-cues])
          current-idx @(rf/subscribe [::subs/subtitle-current-idx])
          lang        @(rf/subscribe [::subs/subtitle-lang])
          source-lang @(rf/subscribe [::subs/subtitle-source-lang])
          done-langs  @(rf/subscribe [::subs/dub-done-langs])
          closing?    @(rf/subscribe [::subs/subtitle-transcript-closing?])]
      [:div.transcript-modal
       {:class (when closing? "transcript-modal--closing")}
       [:div.transcript-modal__header
        [:div.transcript-modal__chips
         [:button.sub-lang-chip
          {:class    (when (= lang :original) "sub-lang-chip--active")
           :on-click #(rf/dispatch [::events/set-subtitle-lang episode-id :original])}
          (if (seq source-lang) (str/upper-case source-lang) "Orig")]
         (for [code done-langs]
           ^{:key code}
           [:button.sub-lang-chip
            {:class    (when (= lang code) "sub-lang-chip--active")
             :on-click #(rf/dispatch [::events/set-subtitle-lang episode-id code])}
            (str/upper-case code)])]
        [:button.transcript-modal__close
         {:on-click #(rf/dispatch [::events/toggle-transcript])}
         "✕"]]
       [:div.transcript-modal__body
        (map-indexed
         (fn [i cue]
           ^{:key (:idx cue)}
           [:p.transcript-cue
            {:class    (when (= i current-idx) "transcript-cue--current")
             :on-click #(rf/dispatch [::events/audio-seek (:start cue)])}
            (cue-text cue lang)])
         all-cues)]])))

(defn- subtitle-panel [episode-id]
  (let [window      @(rf/subscribe [::subs/subtitle-window])
        lang        @(rf/subscribe [::subs/subtitle-lang])
        source-lang @(rf/subscribe [::subs/subtitle-source-lang])
        done-langs  @(rf/subscribe [::subs/dub-done-langs])
        transcript? @(rf/subscribe [::subs/subtitle-transcript?])]
    [:<>
     [:div.subtitle-panel
      [:div.subtitle-panel__cues
       (if (seq window)
         (for [{:keys [cue role]} window]
           ^{:key (:idx cue)}
           [:div.subtitle-cue-line {:class (name role)} (cue-text cue lang)])
         [:div.subtitle-cue-line.no-cue "…"])]
      [:div.subtitle-lang-chips
       [:button.sub-lang-chip
        {:class    (when (= lang :original) "sub-lang-chip--active")
         :on-click #(rf/dispatch [::events/set-subtitle-lang episode-id :original])}
        (if (seq source-lang) (str/upper-case source-lang) "Orig")]
       (for [code done-langs]
         ^{:key code}
         [:button.sub-lang-chip
          {:class    (when (= lang code) "sub-lang-chip--active")
           :on-click #(rf/dispatch [::events/set-subtitle-lang episode-id code])}
          (str/upper-case code)])
       [:button.sub-transcript-btn
        {:on-click #(rf/dispatch [::events/toggle-transcript])}
        "Transcript ↓"]]]
     (when transcript? [transcript-modal episode-id])]))

(defn- recs-section [recs]
  (let [show-scores? (r/atom false)]
    (fn [recs]
      [:div.recs-section
       [:div.recs-header
        {:style {:display "flex" :justify-content "space-between" :align-items "center"}}
        [:h3.recs-title "Similar and recommended"]
        [:span.recs-scores-toggle
         {:on-click #(swap! show-scores? not)
          :style {:cursor "pointer" :font-size "0.75rem" :opacity 0.5}}
         (if @show-scores? "Hide scores" "Show scores")]]
       [:ul.recs-list
        (for [[i rec] (map-indexed vector recs)]
          ^{:key (:id rec)}
          [:li.rec-item
           {:style    {"--rec-i" i}
            :on-click #(rf/dispatch [::events/navigate :player {:episode-id (:id rec) :from "inbox"}])}
           [:div.rec-info
            [:span.rec-feed  (:feed_title rec)]
            [:span.rec-title (:title rec)]
            (when @show-scores?
              (let [topics (seq (:matching_topics rec))
                    total  (or (:total_matching rec) 0)]
                [:span.rec-scores
                 {:style {:font-size "0.65rem" :opacity 0.5 :font-family "monospace"}}
                 (if topics
                   (str (str/join ", " (:matching_topics rec))
                        (when (> total 3) (str " +" (- total 3) " more"))
                        " | collab: " (.toFixed (or (:collab_score rec) 0) 2)
                        " | combined: " (.toFixed (or (:score rec) 0) 2))
                   (str "vector: " (.toFixed (or (:vector_score rec) 0) 2)
                        " | collab: " (.toFixed (or (:collab_score rec) 0) 2)
                        " | combined: " (.toFixed (or (:score rec) 0) 2)))]))]
           [:span.rec-play "▶"]])]])))

(defn view []
  (let [share-open?    (r/atom false)
        share-msg      (r/atom "")
        desc-expanded? (r/atom false)]
    (fn []
      (let [data           @(rf/subscribe [::subs/player-data])
            loading?       @(rf/subscribe [::subs/player-loading?])
            playing?       @(rf/subscribe [::subs/audio-playing?])
            pending?       @(rf/subscribe [::subs/audio-pending?])
            audio-ep-id    @(rf/subscribe [::subs/audio-episode-id])
            audio-time     @(rf/subscribe [::subs/audio-current-time])
            audio-duration @(rf/subscribe [::subs/audio-duration])
            rate           @(rf/subscribe [::subs/audio-rate])
            send-status    @(rf/subscribe [::subs/player-send-status])
            subtitle-lang   @(rf/subscribe [::subs/subtitle-lang])
            subtitle-avail? @(rf/subscribe [::subs/subtitles-available?])
            params         @(rf/subscribe [:buzz-bot.subs/view-params])
            ep-id          (str (get-in data [:episode :id] ""))
            cache-progress @(rf/subscribe [::subs/cache-progress ep-id])
            this-ep?       (= ep-id (str audio-ep-id))
            cur-time       (if this-ep? audio-time
                               (get-in data [:user_episode :progress_seconds] 0))
            duration       (if this-ep? audio-duration
                               (or (get-in data [:episode :duration]) 0))]
        (cond
          loading?    [:div.loading "Loading episode..."]
          (nil? data) [:div.error-msg "Episode not found."]
          :else
          (let [{:keys [episode feed user_episode next_id next_title recs is_subscribed is_premium]} data
                liked?    (= true (:liked user_episode))
                autoplay? (:autoplay? @(rf/subscribe [::subs/audio]))]
            ;; Initialize share message when episode changes
            (when (empty? @share-msg)
              (reset! share-msg
                (str "🎧 Check out this episode:\n\n"
                     (:title episode) "\n"
                     (or (:title feed) ""))))
            [:div#player-root.player-container
             [:div.section-header
              [:div.section-header-row
               [:button.btn-back
                {:on-click #(rf/dispatch [::events/navigate
                                          (keyword (get params :from "inbox"))
                                          (when (= "episodes" (get params :from))
                                            {:feed-id (:feed_id episode)})])}
                "← Back"]
               (when (contains? #{"inbox" "bookmarks" "topics" "dubbed"} (get params :from))
                 [:button.btn-feed-link
                  {:on-click #(rf/dispatch [::events/navigate :episodes
                                            {:feed-id   (:feed_id episode)
                                             :feed-url  (:url feed)
                                             :feed-title (:title feed)}])}
                  (str (or (:title feed) "Feed") " →")])]]
             [:div.player-card
              [:div.player-title-row
               [:h2.player-title (:title episode)]
               (when-let [rss-url (:url feed)]
                 [:button.btn-rss-copy
                  {:title    "Copy RSS URL"
                   :on-click #(rf/dispatch [::events/copy-rss-url rss-url])}
                  [:svg {:xmlns "http://www.w3.org/2000/svg" :width "18" :height "18"
                         :viewBox "0 0 24 24" :fill "none" :stroke "currentColor"
                         :stroke-width "2" :stroke-linecap "round" :stroke-linejoin "round"}
                   [:path {:d "M4 11a9 9 0 0 1 9 9"}]
                   [:path {:d "M4 4a16 16 0 0 1 16 16"}]
                   [:circle {:cx "5" :cy "19" :r "1.5" :fill "currentColor" :stroke "none"}]]])
               [:button.btn-share-icon
                {:title    "Share episode"
                 :on-click #(swap! share-open? not)}
                [:svg {:xmlns "http://www.w3.org/2000/svg" :width "20" :height "20"
                       :viewBox "0 0 24 24" :fill "none" :stroke "currentColor"
                       :stroke-width "2" :stroke-linecap "round" :stroke-linejoin "round"}
                 [:path {:d "M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"}]
                 [:polyline {:points "16 6 12 2 8 6"}]
                 [:line {:x1 "12" :y1 "2" :x2 "12" :y2 "15"}]]]]

              ;; Meta row: date/duration
              (let [date-str (fmt-pub-date (get-in data [:episode :published_at]))
                    dur-str  (fmt-duration (get-in data [:episode :duration_seconds]))
                    meta-str (cond (and date-str dur-str) (str date-str " · " dur-str)
                                   date-str date-str
                                   dur-str  dur-str)]
                (when meta-str [:div.player-meta-row [:span.player-episode-meta meta-str]]))

              ;; Dub section: chips + add-chips + active controls — premium users only
              (when is_premium [dub-view/dub-section ep-id])

              ;; Subtitle panel replaces cover + description when CC is active
              (if (not= subtitle-lang :off)
                [subtitle-panel ep-id]
                [:<>
                 ;; Cover image floats left at 30%; description fills alongside + 2 lines below
                 (when-let [img (get-in data [:episode :episode_image_url])]
                   [:img.player-cover {:src (img-proxy img) :alt ""}])

                 (when-let [desc (and episode (not (str/blank? (:description episode)))
                                      (:description episode))]
                   [:<>
                    [:div.player-description
                     {:class                   (when-not @desc-expanded? "player-description--collapsed")
                      :dangerouslySetInnerHTML {:__html desc}}]
                    [:button.player-desc-toggle
                     {:on-click #(swap! desc-expanded? not)}
                     (if @desc-expanded? "Show less" "Read more")]])

                 [:div.player-cover-clearfix]])

              (when @share-open?
                [:div.share-panel
                 [:textarea.share-message-input
                  {:rows      3
                   :value     @share-msg
                   :on-change #(reset! share-msg (.. % -target -value))}]
                 [:button.btn-share-confirm
                  {:on-click #(rf/dispatch [::events/open-telegram-link
                                            (share-url (:id episode) @share-msg)])}
                  "📤 Share"]])

              [:div.player-controls
               [:div.player-progress-row
                [:span#player-current-time.player-time (fmt-time cur-time)]
                [seek-bar cur-time duration pending?
                 (when-let [prog cache-progress]
                   (when (pos? (:bytes-total prog 0))
                     (int (* 100 (/ (:bytes-downloaded prog 0)
                                    (:bytes-total prog 0))))))]
                [:span#player-duration.player-time (fmt-time duration)]]
               [:div.player-buttons-row
                [:button.btn-seek {:on-click #(rf/dispatch [::events/audio-seek-relative -15])}
                 [:span.btn-seek-icon "↺"] [:span.btn-seek-label "15s"]]
                [:button#player-play-pause.btn-play-pause-large
                 {:on-click #(rf/dispatch [::events/toggle-play-pause])}
                 (cond pending? "▶" playing? "⏸" :else "▶")]
                [:button.btn-seek {:on-click #(rf/dispatch [::events/audio-seek-relative 30])}
                 [:span.btn-seek-icon "↻"] [:span.btn-seek-label "30s"]]]
               [:div.player-speed-row
                [:button#player-speed-btn.btn-speed
                 {:class    (when (not= rate 1) "btn-speed--active")
                  :on-click #(rf/dispatch [::events/cycle-speed])}
                 (if (= rate 1) "1×" (str rate "×"))]
                [:button.btn-cc
                 {:class    (when (not= subtitle-lang :off) "btn-cc--active")
                  :disabled (not subtitle-avail?)
                  :title    (case subtitle-lang
                              :off        "Turn on subtitles"
                              :original   "Showing original text"
                              :translated "Showing translation"
                              "Subtitles")
                  :on-click #(rf/dispatch [::events/cycle-subtitle-lang ep-id])}
                 "CC"]
                [:button.btn-bookmark
                 {:class    (when liked? "active")
                  :title    (if liked? "Remove bookmark" "Bookmark")
                  :on-click #(rf/dispatch [::events/toggle-bookmark (:id episode)])}
                 [:svg {:viewBox "0 0 24 24" :xmlns "http://www.w3.org/2000/svg"}
                  (if liked?
                    [:path {:d "M17 3H7c-1.1 0-2 .9-2 2v16l7-3 7 3V5c0-1.1-.9-2-2-2z"}]
                    [:path {:d "M17 3H7c-1.1 0-2 .9-2 2v16l7-3 7 3V5c0-1.1-.9-2-2-2zm0 15-5-2.18L7 18V5h10v13z"}])]]]]

[:div.autoplay-row
               [:label.autoplay-label {:class (when-not next_id "autoplay-label--disabled")}
                [:input#autoplay-checkbox.autoplay-checkbox
                 {:type      "checkbox"
                  :disabled  (not next_id)
                  :checked   autoplay?
                  :on-change #(rf/dispatch [::events/toggle-autoplay])}]
                [:span.autoplay-switch]
                [:span.autoplay-text
                 (if next_id (str "Play next: " next_title) "Last episode in feed")]]]

              (when-not is_subscribed
                [:div.subscribe-row
                 [:button.btn-subscribe
                  {:on-click #(rf/dispatch [::events/subscribe-from-player (:feed_id episode)])}
                  (str "➕ Subscribe to " (or (:title feed) "this podcast"))]])

              [:div.send-row
               (case send-status
                 nil
                 [:button.btn-send
                  {:on-click #(if is_premium
                                (rf/dispatch [::events/send-episode (:id episode)])
                                (rf/dispatch [::events/send-episode-error "HTTP 402"]))}
                  "📤 Send to Chat"]
                 :loading
                 [:button.btn-send {:disabled true} "Sending…"]
                 :sent
                 [:div.send-result.info "📤 Sending to your chat… it will arrive in a moment."]
                 :upsell
                 [:div.send-result.upsell
                  "⭐ " [:strong "Premium feature."]
                  " Send episodes to your Telegram chat with a Buzz-Bot subscription."]
                 :error
                 [:div.send-result.error "Something went wrong. Please try again."])]

              (when (seq recs)
                [recs-section recs])]]))))))
