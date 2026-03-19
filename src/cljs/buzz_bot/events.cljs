(ns buzz-bot.events
  (:require [re-frame.core :as rf]
            [clojure.string :as str]
            [buzz-bot.db :as db]
            [buzz-bot.fx]))

(rf/reg-event-db ::initialize-db (fn [_ _] db/default-db))

;; ── Navigation ───────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::navigate
 (fn [{:keys [db]} [_ view params]]
   (let [fetch-event (case view
                       :inbox     [::fetch-inbox]
                       :feeds     [::fetch-feeds]
                       :player    [::fetch-player (:episode-id params)]
                       :bookmarks [::fetch-bookmarks]
                       :episodes  [::fetch-episodes (:feed-id params)]
                       nil)]
     (cond-> {:db (assoc db :view view :view-params (or params {}))}
       fetch-event (assoc :dispatch fetch-event)))))

;; ── Inbox ────────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-inbox
 (fn [{:keys [db]} _]
   {:db         (assoc-in db [:inbox :loading?] true)
    ::buzz-bot.fx/http-fetch {:method :get :url "/inbox"
                              :on-ok  [::inbox-loaded] :on-err [::fetch-error]}}))

(rf/reg-event-db
 ::inbox-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:inbox :episodes] (:episodes resp))
       (assoc-in [:inbox :loading?] false))))

;; ── Feeds ────────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-feeds
 (fn [{:keys [db]} _]
   {:db         (assoc-in db [:feeds :loading?] true)
    ::buzz-bot.fx/http-fetch {:method :get :url "/feeds"
                              :on-ok  [::feeds-loaded] :on-err [::fetch-error]}}))

(rf/reg-event-db
 ::feeds-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:feeds :list] (:feeds resp))
       (assoc-in [:feeds :loading?] false))))

(rf/reg-event-fx
 ::subscribe-feed
 (fn [_ [_ url]]
   {::buzz-bot.fx/http-fetch {:method :post :url "/feeds"
                              :body   (js/URLSearchParams. #js{"url" url})
                              :on-ok  [::subscribe-feed-ok] :on-err [::fetch-error]}}))

(rf/reg-event-fx
 ::subscribe-feed-ok
 (fn [_ _] {:dispatch [::fetch-feeds]}))

(rf/reg-event-fx
 ::unsubscribe-feed
 (fn [_ [_ feed-id]]
   {::buzz-bot.fx/http-fetch {:method :delete :url (str "/feeds/" feed-id)
                              :on-ok  [::unsubscribe-feed-ok] :on-err [::fetch-error]}}))

(rf/reg-event-fx
 ::unsubscribe-feed-ok
 (fn [_ _] {:dispatch [::fetch-feeds]}))

;; ── Episode list ─────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-episodes
 (fn [{:keys [db]} [_ feed-id]]
   (let [order (get-in db [:episodes :order] :desc)]
     {:db         (-> db
                      (assoc-in [:episodes :feed-id]  feed-id)
                      (assoc-in [:episodes :list]     [])
                      (assoc-in [:episodes :offset]   0)
                      (assoc-in [:episodes :loading?] true))
      ::buzz-bot.fx/http-fetch {:method :get
                                :url    (str "/episodes?feed_id=" feed-id
                                             "&order=" (name order))
                                :on-ok  [::episodes-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-db
 ::episodes-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:episodes :list]      (:episodes resp))
       (assoc-in [:episodes :has-more?] (:has_more resp))
       (assoc-in [:episodes :loading?]  false))))

(rf/reg-event-fx
 ::load-more-episodes
 (fn [{:keys [db]} _]
   (let [{:keys [feed-id order offset list]} (:episodes db)
         new-offset (+ offset (count list))]
     {:db         (assoc-in db [:episodes :loading?] true)
      ::buzz-bot.fx/http-fetch {:method :get
                                :url    (str "/episodes?feed_id=" feed-id
                                             "&order=" (name order)
                                             "&offset=" new-offset)
                                :on-ok  [::more-episodes-loaded new-offset]
                                :on-err [::fetch-error]}})))

(rf/reg-event-db
 ::more-episodes-loaded
 (fn [db [_ _offset resp]]
   (-> db
       (update-in [:episodes :list]     into (:episodes resp))
       (assoc-in  [:episodes :has-more?] (:has_more resp))
       (assoc-in  [:episodes :loading?]  false))))

(rf/reg-event-fx
 ::set-order
 (fn [{:keys [db]} [_ order]]
   (let [feed-id (get-in db [:episodes :feed-id])]
     {:db       (assoc-in db [:episodes :order] order)
      :dispatch [::fetch-episodes feed-id]})))

;; ── Player ───────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-player
 (fn [{:keys [db]} [_ episode-id]]
   {:db         (assoc-in db [:player :loading?] true)
    ::buzz-bot.fx/http-fetch {:method :get
                              :url    (str "/episodes/" episode-id "/player")
                              :on-ok  [::player-loaded] :on-err [::fetch-error]}}))

(rf/reg-event-fx
 ::player-loaded
 (fn [{:keys [db]} [_ resp]]
   (let [new-id    (str (get-in resp [:episode :id]))
         cur-id    (str (get-in db [:audio :episode-id]))
         playing?  (get-in db [:audio :playing?])
         episode   (get-in resp [:episode])
         db'       (-> db
                       (assoc-in [:player :data]     resp)
                       (assoc-in [:player :loading?] false)
                       (assoc-in [:audio :title]     (:title episode))
                       (assoc-in [:audio :artist]    (:feed_title episode))
                       (assoc-in [:audio :artwork]   (:feed_image_url episode)))]
     (if (and playing? (not= cur-id new-id))
       {:db db' :dispatch [::audio-queue-pending]}
       {:db db' :dispatch [::audio-load]}))))

;; ── Bookmarks ────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-bookmarks
 (fn [{:keys [db]} _]
   {:db         (assoc-in db [:bookmarks :loading?] true)
    ::buzz-bot.fx/http-fetch {:method :get :url "/bookmarks"
                              :on-ok  [::bookmarks-loaded] :on-err [::fetch-error]}}))

(rf/reg-event-db
 ::bookmarks-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:bookmarks :list]     (:episodes resp))
       (assoc-in [:bookmarks :loading?] false))))

(rf/reg-event-fx
 ::search-bookmarks
 (fn [_ [_ query]]
   {::buzz-bot.fx/http-fetch {:method :get
                              :url    (str "/bookmarks/search?q=" (js/encodeURIComponent query))
                              :on-ok  [::bookmarks-loaded] :on-err [::fetch-error]}}))

;; ── Audio state ──────────────────────────────────────────────────────────────

(rf/reg-event-db ::audio-playing  (fn [db _] (assoc-in db [:audio :playing?] true)))
(rf/reg-event-db ::audio-paused   (fn [db _] (assoc-in db [:audio :playing?] false)))
(rf/reg-event-db ::audio-tick     (fn [db [_ t]] (assoc-in db [:audio :current-time] t)))
(rf/reg-event-db ::audio-duration (fn [db [_ d]] (assoc-in db [:audio :duration] d)))

(rf/reg-event-fx
 ::audio-ended
 (fn [{:keys [db]} _]
   (let [autoplay? (get-in db [:audio :autoplay?])
         next-id   (get-in db [:player :data :next_id])]
     (when (and autoplay? next-id)
       {:dispatch [::navigate :player {:episode-id next-id}]}))))

;; ── Audio commands ───────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::audio-load
 (fn [{:keys [db]} [_ opts]]
   (let [src       (get-in db [:player :data :episode :audio_url])
         start     (get-in db [:player :data :user_episode :progress_seconds] 0)
         ep-id     (str (get-in db [:player :data :episode :id]))
         autoplay? (:autoplay? opts false)]
     (js/localStorage.setItem "buzz-last-episode-id" ep-id)
     (js/localStorage.setItem "buzz-last-episode-meta"
       (.stringify js/JSON
         (clj->js {:title   (get-in db [:player :data :episode :title])
                   :podcast (get-in db [:player :data :episode :feed_title])
                   :artwork (get-in db [:player :data :episode :feed_image_url])})))
     {:db         (-> db
                      (assoc-in [:audio :episode-id] ep-id)
                      (assoc-in [:audio :src]        src)
                      (assoc-in [:audio :pending?]   false))
      ::buzz-bot.fx/audio-cmd {:op :load :src src :start start :autoplay? autoplay?}})))

(rf/reg-event-db
 ::audio-queue-pending
 (fn [db _] (assoc-in db [:audio :pending?] true)))

(rf/reg-event-fx
 ::toggle-play-pause
 (fn [{:keys [db]} _]
   (cond
     (get-in db [:audio :pending?])  {:dispatch [::audio-commit-pending]}
     (get-in db [:audio :playing?])  {::buzz-bot.fx/audio-cmd {:op :pause}}
     :else                           {::buzz-bot.fx/audio-cmd {:op :play}})))

(rf/reg-event-fx
 ::audio-commit-pending
 (fn [_ _] {:dispatch [::audio-load {:autoplay? true}]}))

(rf/reg-event-fx
 ::audio-play
 (fn [_ _] {::buzz-bot.fx/audio-cmd {:op :play}}))

(rf/reg-event-fx
 ::audio-pause
 (fn [_ _] {::buzz-bot.fx/audio-cmd {:op :pause}}))

(rf/reg-event-fx
 ::audio-seek
 (fn [_ [_ t]] {::buzz-bot.fx/audio-cmd {:op :seek :time t}}))

(rf/reg-event-fx
 ::audio-seek-relative
 (fn [_ [_ d]] {::buzz-bot.fx/audio-cmd {:op :seek-relative :delta d}}))

(rf/reg-event-fx
 ::cycle-speed
 (fn [{:keys [db]} _]
   (let [rates [1 1.5 2]
         cur   (get-in db [:audio :rate] 1)
         idx   (.indexOf (clj->js rates) cur)
         next  (get rates (mod (inc idx) (count rates)) 1)]
     (js/localStorage.setItem "buzz-playback-speed" (str next))
     {:db (assoc-in db [:audio :rate] next)
      ::buzz-bot.fx/audio-cmd {:op :set-rate :rate next}})))

;; ── Player actions ───────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::toggle-bookmark
 (fn [{:keys [db]} [_ episode-id]]
   {::buzz-bot.fx/http-fetch {:method :put
                              :url    (str "/episodes/" episode-id "/signal")
                              :on-ok  [::bookmark-toggled] :on-err [::fetch-error]}}))

(rf/reg-event-db
 ::bookmark-toggled
 (fn [db [_ resp]]
   (assoc-in db [:player :data :user_episode :liked] (:liked resp))))

(rf/reg-event-db
 ::toggle-autoplay
 (fn [db _]
   (let [new-val (not (get-in db [:audio :autoplay?]))]
     (js/localStorage.setItem "buzz-autoplay" (str new-val))
     (assoc-in db [:audio :autoplay?] new-val))))

(rf/reg-event-fx
 ::subscribe-from-player
 (fn [{:keys [db]} [_ feed-id]]
   {::buzz-bot.fx/http-fetch {:method :post :url (str "/feeds/" feed-id "/subscribe")
                              :on-ok  [::subscribe-from-player-ok] :on-err [::fetch-error]}}))

(rf/reg-event-db
 ::subscribe-from-player-ok
 (fn [db _] (assoc-in db [:player :data :is_subscribed] true)))

(rf/reg-event-fx
 ::save-progress
 (fn [{:keys [db]} [_ episode-id seconds]]
   (let [duration  (get-in db [:audio :duration] 0)
         completed (and (pos? duration) (> seconds (- duration 30)))]
     {::buzz-bot.fx/http-fetch {:method :put
                                :url    (str "/episodes/" episode-id "/progress")
                                :body   {:seconds seconds :completed completed}
                                :on-ok  [::progress-saved] :on-err [::fetch-error]}})))

(rf/reg-event-db ::progress-saved (fn [db _] db))

;; ── Filters ──────────────────────────────────────────────────────────────────

(rf/reg-event-db
 ::toggle-hide-listened
 (fn [db _]
   (update-in db [:inbox :filters :hide-listened?] not)))

(rf/reg-event-db
 ::toggle-feed-filter
 (fn [db [_ feed-id]]
   (let [excluded (get-in db [:inbox :filters :excluded-feeds] #{})]
     (assoc-in db [:inbox :filters :excluded-feeds]
               (if (contains? excluded feed-id)
                 (disj excluded feed-id)
                 (conj excluded feed-id))))))

(rf/reg-event-db
 ::toggle-compact
 (fn [db _]
   (update-in db [:inbox :filters :compact?] not)))

;; ── Error handling ───────────────────────────────────────────────────────────

(rf/reg-event-db
 ::fetch-error
 (fn [db [_ err]]
   (js/console.error "Fetch error:" err)
   db))
