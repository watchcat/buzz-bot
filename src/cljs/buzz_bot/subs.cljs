(ns buzz-bot.subs
  (:require [re-frame.core :as rf]))

;; Top-level
(rf/reg-sub ::view         (fn [db _] (:view db)))
(rf/reg-sub ::view-params  (fn [db _] (:view-params db)))
(rf/reg-sub ::init-data    (fn [db _] (:init-data db)))

;; Feature flags — (rf/subscribe [::flag "offline_caching"]) → bool (default true)
(rf/reg-sub ::flag
  (fn [db [_ name]] (get-in db [:flags name] true)))

;; Inbox
(rf/reg-sub ::inbox        (fn [db _] (:inbox db)))
(rf/reg-sub ::inbox-episodes
  :<- [::inbox]
  (fn [inbox _] (:episodes inbox)))
(rf/reg-sub ::inbox-loading?
  :<- [::inbox]
  (fn [inbox _] (:loading? inbox)))
(rf/reg-sub ::inbox-filters
  :<- [::inbox]
  (fn [inbox _] (:filters inbox)))

;; Feeds
(rf/reg-sub ::feeds-list     (fn [db _] (get-in db [:feeds :list])))
(rf/reg-sub ::feeds-loading? (fn [db _] (get-in db [:feeds :loading?])))

;; Episodes
(rf/reg-sub ::episodes     (fn [db _] (:episodes db)))
(rf/reg-sub ::episodes-list
  :<- [::episodes]
  (fn [ep _] (:list ep)))
(rf/reg-sub ::episodes-loading?
  :<- [::episodes]
  (fn [ep _] (:loading? ep)))
(rf/reg-sub ::episodes-has-more?
  :<- [::episodes]
  (fn [ep _] (:has-more? ep)))
(rf/reg-sub ::episodes-order
  :<- [::episodes]
  (fn [ep _] (:order ep)))

;; Player
(rf/reg-sub ::player-data        (fn [db _] (get-in db [:player :data])))
(rf/reg-sub ::player-loading?    (fn [db _] (get-in db [:player :loading?])))
(rf/reg-sub ::player-send-status (fn [db _] (get-in db [:player :send-status])))

;; Bookmarks
(rf/reg-sub ::bookmarks-list     (fn [db _] (get-in db [:bookmarks :list])))
(rf/reg-sub ::bookmarks-loading? (fn [db _] (get-in db [:bookmarks :loading?])))

;; Topics
(rf/reg-sub ::topics        (fn [db _] (:topics db)))
(rf/reg-sub ::topics-tags
  :<- [::topics]
  (fn [t _] (:tags t)))
(rf/reg-sub ::topics-episodes
  :<- [::topics]
  (fn [t _] (:episodes t)))
(rf/reg-sub ::topics-loading?
  :<- [::topics]
  (fn [t _] (:loading? t)))
(rf/reg-sub ::topics-selected-tag
  :<- [::topics]
  (fn [t _] (:selected-tag t)))
(rf/reg-sub ::topics-has-more-tags?
  :<- [::topics]
  (fn [t _] (:has-more-tags? t)))

;; Search
(rf/reg-sub ::search-results        (fn [db _] (get-in db [:search :results])))
(rf/reg-sub ::search-loading?       (fn [db _] (get-in db [:search :loading?])))
(rf/reg-sub ::search-subscribed-urls (fn [db _] (get-in db [:search :subscribed-urls])))

;; Audio
(rf/reg-sub ::audio          (fn [db _] (:audio db)))
(rf/reg-sub ::audio-playing? :<- [::audio] (fn [a _] (:playing? a)))
(rf/reg-sub ::audio-pending? :<- [::audio] (fn [a _] (:pending? a)))
(rf/reg-sub ::audio-episode-id :<- [::audio] (fn [a _] (:episode-id a)))
(rf/reg-sub ::audio-feed-id   :<- [::audio] (fn [a _] (:feed-id a)))
(rf/reg-sub ::audio-current-time :<- [::audio] (fn [a _] (:current-time a)))
(rf/reg-sub ::audio-duration :<- [::audio] (fn [a _] (:duration a)))
(rf/reg-sub ::audio-rate     :<- [::audio] (fn [a _] (:rate a)))
(rf/reg-sub ::audio-title    :<- [::audio] (fn [a _] (:title a)))
(rf/reg-sub ::audio-artist   :<- [::audio] (fn [a _] (:artist a)))
(rf/reg-sub ::audio-artwork  :<- [::audio] (fn [a _] (:artwork a)))
(rf/reg-sub ::audio-src      :<- [::audio] (fn [a _] (:src a)))

;; ── Offline / audio cache ────────────────────────────────────────────────────

(rf/reg-sub ::network-online?
  (fn [db _] (get-in db [:offline :network-online?])))

(rf/reg-sub ::cached-ids-vec
  (fn [db _] (get-in db [:offline :cached-ids])))

(rf/reg-sub ::cached-ids
  :<- [::cached-ids-vec]
  (fn [ids _] (set ids)))

(rf/reg-sub ::episode-cached?
  (fn [[_ ep-id] _] (rf/subscribe [::cached-ids]))
  (fn [ids [_ ep-id]] (contains? ids ep-id)))

(rf/reg-sub ::cache-progress
  (fn [db [_ ep-id]] (get-in db [:offline :in-progress ep-id])))

(rf/reg-sub ::cached-episode-metas
  (fn [db _] (get-in db [:offline :episode-metas] {})))

;; Subtitles
(rf/reg-sub ::subtitles          (fn [db _] (:subtitles db)))
(rf/reg-sub ::subtitle-cues      :<- [::subtitles] (fn [s _] (:cues s)))
(rf/reg-sub ::subtitle-lang      :<- [::subtitles] (fn [s _] (:lang s)))
(rf/reg-sub ::subtitle-ep-id     :<- [::subtitles] (fn [s _] (:ep-id s)))
(rf/reg-sub ::subtitle-source-lang :<- [::subtitles] (fn [s _] (:source-lang s)))
(rf/reg-sub ::subtitle-transcript? :<- [::subtitles] (fn [s _] (:transcript? s)))
(rf/reg-sub ::subtitles-available?
  :<- [::subtitle-cues]
  (fn [cues _] (pos? (count cues))))
(rf/reg-sub ::translation-available?
  :<- [::subtitle-cues]
  (fn [cues _] (boolean (some :translation cues))))

;; Done dubbed languages for the current episode (for subtitle lang chips)
(rf/reg-sub ::dub-done-langs
  (fn [db _]
    (keep (fn [[code {:keys [status]}]]
            (when (= :done status) code))
          (get-in db [:dub :statuses]))))
(rf/reg-sub ::current-subtitle-cue
  :<- [::subtitles]
  :<- [::audio-current-time]
  :<- [::audio-episode-id]
  (fn [[subs t audio-ep-id] _]
    (let [lang   (:lang subs)
          cues   (:cues subs)
          sub-ep (:ep-id subs)]
      (when (and (not= lang :off)
                 (number? t)
                 (= (str sub-ep) (str audio-ep-id))
                 (pos? (count cues)))
        (some (fn [c]
                (when (and (<= (:start c) t) (< t (:end c)))
                  c))
              cues)))))

(defn- find-current-idx [cues t]
  ;; Returns the index of the active cue (start ≤ t < end), or the index of the
  ;; last cue whose end has already passed, or nil if t is before every cue.
  ;; nil = "nothing spoken yet" — callers must treat nil as "no current cue".
  (loop [i 0 last-past nil]
    (if (>= i (count cues))
      last-past
      (let [{:keys [start end]} (nth cues i)]
        (cond
          (and (<= start t) (< t end)) i          ; active
          (< end t)                    (recur (inc i) i)  ; past, keep going
          :else                        last-past)))))      ; future, stop

(rf/reg-sub
 ::subtitle-current-idx
 :<- [::subtitles]
 :<- [::audio-current-time]
 :<- [::audio-episode-id]
 (fn [[subs t audio-ep-id] _]
   (let [cues   (:cues subs)
         sub-ep (:ep-id subs)]
     (when (and (not= :off (:lang subs))
                (seq cues)
                (number? t)
                (= (str sub-ep) (str audio-ep-id)))
       (find-current-idx cues t)))))

(rf/reg-sub
 ::subtitle-window
 :<- [::subtitles]
 :<- [::audio-current-time]
 :<- [::audio-episode-id]
 (fn [[subs t audio-ep-id] _]
   (let [lang   (:lang subs)
         cues   (:cues subs)
         sub-ep (:ep-id subs)]
     (when (and (not= lang :off)
                (seq cues)
                (number? t)
                (= (str sub-ep) (str audio-ep-id)))
       ;; nil idx means audio hasn't reached the first cue yet — show the
       ;; first 3 upcoming cues as :next so the user knows what's coming.
       (let [n        (count cues)
             idx      (find-current-idx cues t)
             anchor   (or idx 0)
             from     (max 0 (- anchor 2))
             to       (min n (+ anchor 3))]
         (mapv (fn [i c]
                 {:cue  c
                  :role (cond (nil? idx)              :next     ; before first cue
                              (= (+ from i) idx)      :current
                              (< (+ from i) idx)      :prev
                              :else                   :next)})
               (range (- to from))
               (subvec cues from to)))))))
