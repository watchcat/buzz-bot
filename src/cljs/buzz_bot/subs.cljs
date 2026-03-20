(ns buzz-bot.subs
  (:require [re-frame.core :as rf]))

;; Top-level
(rf/reg-sub ::view         (fn [db _] (:view db)))
(rf/reg-sub ::view-params  (fn [db _] (:view-params db)))
(rf/reg-sub ::init-data    (fn [db _] (:init-data db)))

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

;; Cache
(rf/reg-sub ::cached-ids
  (fn [db _]
    (set (get-in db [:cache :cached-ids]))))

(rf/reg-sub ::episode-cached?
  :<- [::cached-ids]
  (fn [cached-ids [_ episode-id]]
    (contains? cached-ids episode-id)))

(rf/reg-sub ::cache-progress
  (fn [db [_ episode-id]]
    (get-in db [:cache :in-progress episode-id])))
