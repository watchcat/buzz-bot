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
   (let [cur-view (:view db)
         ;; Snapshot list length when entering the player (not for player→player autoplay)
         saved-list
         (if (and (= view :player) (not= cur-view :player))
           {:view  cur-view
            :count (case cur-view
                     :inbox     (count (get-in db [:inbox :episodes]))
                     :episodes  (count (get-in db [:episodes :list]))
                     :bookmarks (count (get-in db [:bookmarks :list]))
                     0)}
           (:saved-list db))
         fetch-event (case view
                       :inbox     [::fetch-inbox]
                       :feeds     [::fetch-feeds]
                       :player    [::fetch-player (:episode-id params)]
                       :bookmarks [::fetch-bookmarks]
                       :episodes  [::fetch-episodes (:feed-id params)]
                       nil)]
     (cond-> {:db (-> db
                      (assoc :view view)
                      (assoc :view-params (or params {}))
                      (assoc :saved-list saved-list))}
       fetch-event (assoc :dispatch fetch-event)))))

;; ── Inbox ────────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-inbox
 (fn [{:keys [db]} _]
   (let [saved (:saved-list db)
         limit (when (and (= (:view saved) :inbox) (pos? (:count saved)))
                 (:count saved))
         url   (if limit (str "/inbox?limit=" limit) "/inbox")]
     {:db         (assoc-in db [:inbox :loading?] true)
      ::buzz-bot.fx/http-fetch {:method :get :url url
                                :on-ok  [::inbox-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-fx
 ::inbox-loaded
 (fn [{:keys [db]} [_ resp]]
   (let [db'        (-> db
                        (assoc-in [:inbox :episodes] (:episodes resp))
                        (assoc-in [:inbox :loading?] false))
         playing-id (get-in db [:audio :episode-id])]
     (cond-> {:db db'}
       (and playing-id
            (some #(= (str (:id %)) (str playing-id)) (:episodes resp)))
       (assoc ::buzz-bot.fx/scroll-to-episode playing-id)))))

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
   (let [order (get-in db [:episodes :order] :desc)
         saved (:saved-list db)
         limit (when (and (= (:view saved) :episodes) (pos? (:count saved)))
                 (:count saved))
         url   (cond-> (str "/episodes?feed_id=" feed-id "&order=" (name order))
                 limit (str "&limit=" limit))]
     {:db         (-> db
                      (assoc-in [:episodes :feed-id]  feed-id)
                      (assoc-in [:episodes :list]     [])
                      (assoc-in [:episodes :offset]   0)
                      (assoc-in [:episodes :loading?] true))
      ::buzz-bot.fx/http-fetch {:method :get :url url
                                :on-ok  [::episodes-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-fx
 ::episodes-loaded
 (fn [{:keys [db]} [_ resp]]
   (let [db'        (-> db
                        (assoc-in [:episodes :list]      (:episodes resp))
                        (assoc-in [:episodes :has-more?] (:has_more resp))
                        (assoc-in [:episodes :loading?]  false))
         playing-id (get-in db [:audio :episode-id])]
     (cond-> {:db db'}
       (and playing-id
            (some #(= (str (:id %)) (str playing-id)) (:episodes resp)))
       (assoc ::buzz-bot.fx/scroll-to-episode playing-id)))))

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
   (let [order (name (get-in db [:episodes :order] :desc))]
     {:db         (assoc-in db [:player :loading?] true)
      ::buzz-bot.fx/http-fetch {:method :get
                                :url    (str "/episodes/" episode-id "/player?order=" order)
                                :on-ok  [::player-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-fx
 ::player-loaded
 (fn [{:keys [db]} [_ resp]]
   (let [new-id    (str (get-in resp [:episode :id]))
         cur-id    (str (get-in db [:audio :episode-id]))
         playing?  (get-in db [:audio :playing?])
         episode   (get-in resp [:episode])
         db'       (-> db
                       (assoc-in [:player :data]        resp)
                       (assoc-in [:player :loading?]    false)
                       (assoc-in [:player :send-status] nil)
                       (assoc-in [:audio :title]        (:title episode))
                       (assoc-in [:audio :artist]       (:feed_title episode))
                       (assoc-in [:audio :artwork]      (:feed_image_url episode)))]
     (let [autoplay? (get-in db [:view-params :autoplay?])]
       (cond
         (= cur-id new-id)                   {:db db'}
         (and playing? (not= cur-id new-id)) {:db db' :dispatch [::audio-queue-pending]}
         :else {:db db' :dispatch [::audio-load {:autoplay? (boolean autoplay?)}]})))))

;; ── Bookmarks ────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-bookmarks
 (fn [{:keys [db]} _]
   (let [saved (:saved-list db)
         limit (when (and (= (:view saved) :bookmarks) (pos? (:count saved)))
                 (:count saved))
         url   (if limit (str "/bookmarks?limit=" limit) "/bookmarks")]
     {:db         (assoc-in db [:bookmarks :loading?] true)
      ::buzz-bot.fx/http-fetch {:method :get :url url
                                :on-ok  [::bookmarks-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-fx
 ::bookmarks-loaded
 (fn [{:keys [db]} [_ resp]]
   (let [db'        (-> db
                        (assoc-in [:bookmarks :list]     (:episodes resp))
                        (assoc-in [:bookmarks :loading?] false))
         playing-id (get-in db [:audio :episode-id])]
     (cond-> {:db db'}
       (and playing-id
            (some #(= (str (:id %)) (str playing-id)) (:episodes resp)))
       (assoc ::buzz-bot.fx/scroll-to-episode playing-id)))))

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
       {:dispatch [::navigate :player {:episode-id next-id :autoplay? true}]}))))

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
                      (assoc-in [:audio :feed-id]    (str (get-in db [:player :data :episode :feed_id])))
                      (assoc-in [:audio :src]        src)
                      (assoc-in [:audio :pending?]   false))
      ::buzz-bot.fx/audio-cmd {:op      :load
                               :src     src
                               :start   start
                               :autoplay? autoplay?
                               :title   (get-in db [:player :data :episode :title])
                               :artist  (get-in db [:player :data :episode :feed_title])
                               :artwork (get-in db [:player :data :episode :feed_image_url])}})))

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
 ::open-telegram-link
 (fn [_ [_ url]]
   {::buzz-bot.fx/open-telegram-link url}))

(rf/reg-event-fx
 ::copy-rss-url
 (fn [_ [_ url]]
   {::buzz-bot.fx/copy-to-clipboard url}))

(rf/reg-event-fx
 ::send-episode
 (fn [{:keys [db]} [_ episode-id]]
   {:db (assoc-in db [:player :send-status] :loading)
    ::buzz-bot.fx/http-fetch {:method :post :url (str "/episodes/" episode-id "/send")
                              :on-ok  [::send-episode-done] :on-err [::send-episode-error]}}))

(rf/reg-event-db
 ::send-episode-done
 (fn [db _] (assoc-in db [:player :send-status] :sent)))

(rf/reg-event-db
 ::send-episode-error
 (fn [db [_ err]]
   (assoc-in db [:player :send-status]
             (if (= err "HTTP 402") :upsell :error))))

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

;; ── Podcast search ───────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-search
 (fn [{:keys [db]} [_ query]]
   (if (str/blank? query)
     {:db (-> db
              (assoc-in [:search :results] [])
              (assoc-in [:search :loading?] false))}
     {:db         (assoc-in db [:search :loading?] true)
      ::buzz-bot.fx/http-fetch {:method :get
                                :url    (str "/search?q=" (js/encodeURIComponent query))
                                :on-ok  [::search-loaded] :on-err [::search-load-error]}})))

(rf/reg-event-db
 ::search-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:search :results]  (:results resp))
       (assoc-in [:search :loading?] false))))

(rf/reg-event-db
 ::search-load-error
 (fn [db _]
   (assoc-in db [:search :loading?] false)))

(rf/reg-event-fx
 ::search-subscribe
 (fn [_ [_ feed-url]]
   {::buzz-bot.fx/http-fetch {:method :post
                              :url    "/search/subscribe"
                              :body   (js/URLSearchParams. #js{"url" feed-url})
                              :on-ok  [::search-subscribed feed-url]
                              :on-err [::fetch-error]}}))

(rf/reg-event-fx
 ::search-subscribed
 (fn [{:keys [db]} [_ feed-url _resp]]
   {:db       (update-in db [:search :subscribed-urls] conj feed-url)
    :dispatch [::fetch-feeds]}))

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

;; ── Init helpers ─────────────────────────────────────────────────────────────

(rf/reg-event-db
 ::set-init-data
 (fn [db [_ v]] (assoc db :init-data v)))

(rf/reg-event-db
 ::init-audio-meta
 (fn [db [_ ep-id meta rate auto?]]
   (-> db
       (assoc-in [:audio :episode-id] ep-id)
       (assoc-in [:audio :title]     (:title meta ""))
       (assoc-in [:audio :artist]    (:podcast meta ""))
       (assoc-in [:audio :artwork]   (:artwork meta ""))
       (assoc-in [:audio :rate]      rate)
       (assoc-in [:audio :autoplay?] auto?))))
