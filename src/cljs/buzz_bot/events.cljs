(ns buzz-bot.events
  (:require [re-frame.core :as rf]
            [clojure.string :as str]
            [buzz-bot.db :as db]
            [buzz-bot.delivery]
            [buzz-bot.fx]
            [buzz-bot.playback :as pb]
            [buzz-bot.events.dub :as dub-events]))

(rf/reg-event-db ::initialize-db (fn [_ _] db/default-db))
(rf/reg-event-db ::noop (fn [db _] db))

;; ── Feature flags ────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-flags
 (fn [_ _]
   {::buzz-bot.fx/http-fetch {:method :get :url "/flags"
                              :on-ok  [::flags-loaded] :on-err [::noop]}}))

(rf/reg-event-db
 ::flags-loaded
 (fn [db [_ resp]]
   (assoc db :flags (or resp {}))))

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
                       :topics    [::fetch-topics]
                       :episodes  [::fetch-episodes (:feed-id params)]
                       nil)]
     (let [restore-id (when (and (= view :episodes) (= cur-view :player))
                        (str (get-in db [:player :data :episode :id])))]
       (cond-> {:db (-> db
                        (assoc :view view)
                        (assoc :view-params (or params {}))
                        (assoc :saved-list saved-list)
                        (cond-> restore-id
                          (assoc-in [:episodes :restore-to-id] restore-id)))}
         fetch-event (assoc :dispatch-n (cond-> [fetch-event]
                                           (= view :player)
                                           (conj [::dub-events/reset])
                                           (= view :inbox)
                                           (conj [::fetch-inbox-dubbed])))
         (= cur-view :player)
         (update :dispatch-n (fnil conj []) [::clear-subtitles]))))))

;; ── Inbox ────────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-inbox
 (fn [{:keys [db]} _]
   (let [saved (:saved-list db)
         limit (when (and (= (:view saved) :inbox) (pos? (:count saved)))
                 (:count saved))
         url   (if limit (str "/inbox?limit=" limit) "/inbox")]
     {:db         (-> db
                      (assoc-in [:inbox :loading?] true)
                      (assoc-in [:inbox :search-query] ""))
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

(rf/reg-event-fx
 ::search-inbox
 (fn [{:keys [db]} [_ query]]
   {:db (-> db
            (assoc-in [:inbox :loading?] true)
            (assoc-in [:inbox :search-query] query))
    ::buzz-bot.fx/http-fetch {:method :get
                              :url    (str "/inbox/search?q=" (js/encodeURIComponent query))
                              :on-ok  [::inbox-loaded] :on-err [::fetch-error]}}))

;; Latest-dubbed widget — fetched on first inbox entry; replaces items
;; on success; silent failure (widget just stays hidden).
(defn dubbed-fetch
  "Effect map for (re)fetching the inbox 'Latest dubbed' widget.
   When force? is false and the list is already loaded, returns {} (no-op,
   preserving lazy caching on Inbox navigation). force? = true (the ↻ button
   and the dub-complete path) bypasses the loaded? guard and always refetches."
  [db force?]
  (if (and (not force?) (get-in db [:inbox-dubbed :loaded?]))
    {}
    {:db (assoc-in db [:inbox-dubbed :loading?] true)
     ::buzz-bot.fx/http-fetch
     {:method :get
      :url    "/inbox/dubbed"
      :on-ok  [::inbox-dubbed-loaded]
      :on-err [::inbox-dubbed-err]}}))

(rf/reg-event-fx
 ::fetch-inbox-dubbed
 (fn [{:keys [db]} [_ force?]]
   (dubbed-fetch db force?)))

(rf/reg-event-db
 ::inbox-dubbed-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:inbox-dubbed :items]    (vec (:items resp)))
       (assoc-in [:inbox-dubbed :loaded?]  true)
       (assoc-in [:inbox-dubbed :loading?] false))))

(rf/reg-event-db
 ::inbox-dubbed-err
 (fn [db [_ _err]]
   ;; Silent: widget just stays empty/hidden. Inbox proper renders fine.
   ;; Marking :loaded? true stops the lazy navigation path from retrying; a
   ;; manual ↻ (force? true) or a dub-complete refetch still bypasses it.
   (-> db
       (assoc-in [:inbox-dubbed :loading?] false)
       (assoc-in [:inbox-dubbed :loaded?]  true))))

;; v1 stub — "See all →" routes here but does nothing yet. Wired up so
;; the button has a real dispatch and the design isn't lying about a
;; nav target; future work replaces this with a navigate to /dubbed.
(rf/reg-event-db
 ::see-all-dubbed-stub
 (fn [db _] db))

;; ── Topics ──────────────────────────────────────────────────────────────────

(defn- topics-url [tag tag-offset]
  (cond-> "/topics?"
    tag        (str "tag=" (js/encodeURIComponent tag) "&")
    true       (str "tag_limit=100&tag_offset=" tag-offset)))

(rf/reg-event-fx
 ::fetch-topics
 (fn [{:keys [db]} _]
   (let [tag (get-in db [:topics :selected-tag])]
     {:db (-> db
              (assoc-in [:topics :loading?] true)
              (assoc-in [:topics :tag-offset] 0))
      ::buzz-bot.fx/http-fetch {:method :get :url (topics-url tag 0)
                                :on-ok  [::topics-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-db
 ::topics-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:topics :tags]           (:tags resp))
       (assoc-in [:topics :episodes]       (:episodes resp))
       (assoc-in [:topics :has-more-tags?] (:has_more_tags resp))
       (assoc-in [:topics :tag-offset]     (count (:tags resp)))
       (assoc-in [:topics :loading?]       false))))

(rf/reg-event-fx
 ::load-more-tags
 (fn [{:keys [db]} _]
   (let [tag    (get-in db [:topics :selected-tag])
         offset (get-in db [:topics :tag-offset] 0)]
     {::buzz-bot.fx/http-fetch {:method :get :url (topics-url tag offset)
                                :on-ok  [::more-tags-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-db
 ::more-tags-loaded
 (fn [db [_ resp]]
   (-> db
       (update-in [:topics :tags] into (:tags resp))
       (update-in [:topics :tag-offset] + (count (:tags resp)))
       (assoc-in  [:topics :has-more-tags?] (:has_more_tags resp)))))

(rf/reg-event-fx
 ::select-tag
 (fn [{:keys [db]} [_ tag]]
   (let [offset (get-in db [:topics :tag-offset] 0)]
     {:db       (-> db
                    (assoc-in [:topics :selected-tag] tag)
                    (assoc-in [:topics :loading?] true))
      ::buzz-bot.fx/http-fetch {:method :get
                                :url    (topics-url tag offset)
                                :on-ok  [::tag-episodes-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-db
 ::tag-episodes-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:topics :episodes] (:episodes resp))
       (assoc-in [:topics :loading?] false))))

(rf/reg-event-fx
 ::clear-tag
 (fn [{:keys [db]} _]
   (let [offset (get-in db [:topics :tag-offset] 0)]
     {:db       (-> db
                    (assoc-in [:topics :selected-tag] nil)
                    (assoc-in [:topics :loading?] true))
      ::buzz-bot.fx/http-fetch {:method :get :url (topics-url nil offset)
                                :on-ok  [::tag-episodes-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-fx
 ::hide-topic
 (fn [{:keys [db]} [_ tag]]
   (let [selected (get-in db [:topics :selected-tag])]
     {:db (-> db
              (update-in [:topics :tags] (fn [tags] (vec (remove #(= (:tag %) tag) tags))))
              (cond-> (= selected tag)
                (-> (assoc-in [:topics :selected-tag] nil))))
      ::buzz-bot.fx/http-fetch {:method  :post
                                :url     "/topics/hide"
                                :body    {:tag tag}
                                :on-ok   [::topic-hidden] :on-err [::fetch-error]}})))

(rf/reg-event-db
  ::dismiss-tag-cloud-hint
  (fn [db _]
    (js/localStorage.setItem "topics-cloud-hint-dismissed" "1")
    (assoc-in db [:topics :cloud-hint-dismissed?] true)))

(rf/reg-event-fx
 ::topic-hidden
 (fn [_ _]
   {:dispatch [::fetch-topics]}))

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
 (fn [{:keys [db]} [_ feed-id order]]
   (let [;; When revisiting the same feed, send the in-memory order so the
         ;; server returns episodes in the right order even if the DB default
         ;; hasn't been saved yet (e.g. user set oldest-first this session).
         ;; When opening a different feed for the first time, omit order so the
         ;; server applies its saved preference and we learn it from the response.
         same-feed?      (= (str (get-in db [:episodes :feed-id])) (str feed-id))
         effective-order (or order (when same-feed? (get-in db [:episodes :order] :desc)))
         ;; seek-to-id tells the server to extend the limit to include this episode,
         ;; so it's always in the response regardless of its position in the feed.
         seek-to-id      (get-in db [:episodes :restore-to-id])
         saved (:saved-list db)
         limit (when (and (= (:view saved) :episodes) (pos? (:count saved)))
                 (:count saved))
         url   (cond-> (str "/episodes?feed_id=" feed-id)
                 effective-order (str "&order=" (name effective-order))
                 limit           (str "&limit=" limit)
                 seek-to-id      (str "&seek_to_id=" seek-to-id))]
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
   (let [restore-id (get-in db [:episodes :restore-to-id])
         server-order (some-> (:episode_order resp) keyword)
         delivery     (some-> (:delivery_mode resp) keyword)
         new-ids      (set (:new_episode_ids resp))
         premium?     (boolean (:is_premium resp))
         db'        (-> db
                        (assoc-in [:episodes :list]            (:episodes resp))
                        (assoc-in [:episodes :has-more?]       (:has_more resp))
                        (assoc-in [:episodes :loading?]        false)
                        (assoc-in [:episodes :restore-to-id]   nil)
                        (assoc-in [:episodes :new-episode-ids] new-ids)
                        (assoc-in [:episodes :is-premium?]     premium?)
                        (cond-> server-order
                          (assoc-in [:episodes :order] server-order))
                        (cond-> delivery
                          (assoc-in [:episodes :delivery-mode] delivery)))
         playing-id (get-in db [:audio :episode-id])
         eps        (:episodes resp)
         scroll-id  (or (when (and restore-id
                                   (some #(= (str (:id %)) restore-id) eps))
                          restore-id)
                        (when (and playing-id
                                   (some #(= (str (:id %)) (str playing-id)) eps))
                          playing-id))]
     (cond-> {:db db'}
       scroll-id (assoc ::buzz-bot.fx/scroll-to-episode scroll-id)))))

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
      :dispatch [::fetch-episodes feed-id order]})))

;; ── Per-feed delivery mode ───────────────────────────────────────────────────

;; Cycle delivery mode for the current feed. Optimistic UI: write the new
;; mode immediately to db, fire PATCH; on err revert. The premium flag
;; shortens the cycle to off↔notify for non-premium users so tap-cycle
;; never lands on mp3 without entitlement (matches Send-to-Chat gate).
(rf/reg-event-fx
 ::cycle-delivery-mode
 (fn [{:keys [db]} [_ feed-id]]
   (let [current   (or (get-in db [:episodes :delivery-mode]) :off)
         premium?  (boolean (get-in db [:episodes :is-premium?]))
         next-m    (buzz-bot.delivery/next-mode current premium?)]
     {:dispatch [::set-delivery-mode feed-id next-m]})))

(rf/reg-event-fx
 ::set-delivery-mode
 (fn [{:keys [db]} [_ feed-id mode]]
   (let [prior     (or (get-in db [:episodes :delivery-mode]) :off)
         premium?  (boolean (get-in db [:episodes :is-premium?]))]
     (cond
       (= prior mode)
       {}

       ;; Non-premium user picked mp3 from the long-press popup → no
       ;; optimistic write, no PATCH; just surface the upsell banner.
       (and (= mode :mp3) (not premium?))
       {:db (assoc-in db [:episodes :delivery-upsell?] true)}

       :else
       {:db (-> db
                (assoc-in [:episodes :delivery-mode]    mode)
                (assoc-in [:episodes :delivery-pending] prior)
                (assoc-in [:episodes :delivery-upsell?] false))
        ::buzz-bot.fx/http-fetch
        {:method :patch
         :url    (str "/feeds/" feed-id "/delivery_mode")
         :body   {:mode (name mode)}
         :on-ok  [::delivery-patch-ok]
         :on-err [::delivery-patch-err]}}))))

(rf/reg-event-db
 ::delivery-patch-ok
 (fn [db _]
   (assoc-in db [:episodes :delivery-pending] nil)))

(rf/reg-event-db
 ::delivery-patch-err
 (fn [db [_ err]]
   ;; Revert to the prior mode and clear pending. If err is HTTP 402
   ;; (premium_required — e.g. premium expired between fetch and PATCH),
   ;; also flip the upsell banner on.
   (let [prior    (get-in db [:episodes :delivery-pending])
         http402? (and (string? err) (str/includes? err "402"))]
     (-> db
         (assoc-in [:episodes :delivery-mode]    (or prior :off))
         (assoc-in [:episodes :delivery-pending] nil)
         (cond-> http402?
           (assoc-in [:episodes :delivery-upsell?] true))))))

(rf/reg-event-db
 ::dismiss-delivery-upsell
 (fn [db _]
   (assoc-in db [:episodes :delivery-upsell?] false)))

;; Bump last_viewed_at server-side and clear local NEW marks. Fire-and-forget;
;; failure is silent — the badge will just reappear on next fetch.
(rf/reg-event-fx
 ::mark-feed-viewed
 (fn [{:keys [db]} [_ feed-id]]
   {:db (assoc-in db [:episodes :new-episode-ids] #{})
    ::buzz-bot.fx/http-fetch
    {:method :post
     :url    (str "/feeds/" feed-id "/viewed")
     :on-ok  [::noop]
     :on-err [::noop]}}))

;; ── Player ───────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-player
 (fn [{:keys [db]} [_ episode-id]]
   (let [order        (name (get-in db [:episodes :order] :desc))
         was-playing? (get-in db [:audio :playing?])]
     {:db           (-> db
                        (assoc-in [:player :loading?]     true)
                        (assoc-in [:player :was-playing?] was-playing?))
      ::buzz-bot.fx/http-fetch {:method :get
                                :url    (str "/episodes/" episode-id "/player?order=" order)
                                :on-ok  [::player-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-fx
 ::player-loaded
 (fn [{:keys [db]} [_ resp]]
   (let [new-id       (str (get-in resp [:episode :id]))
         cur-id       (str (get-in db [:audio :episode-id]))
         ;; Use snapshot from navigation time, not live playing? which may have
         ;; flipped false during the HTTP round-trip due to a buffering pause.
         was-playing? (get-in db [:player :was-playing?])
         episode      (get-in resp [:episode])
         loading-new? (not (and was-playing? (not= cur-id new-id)))
         db'       (cond-> (-> db
                               (assoc-in [:player :data]        resp)
                               (assoc-in [:player :loading?]    false)
                               (assoc-in [:player :send-status] nil))
                     loading-new?
                     (-> (assoc-in [:audio :title]   (:title episode))
                         (assoc-in [:audio :artist]  (:feed_title episode))
                         (assoc-in [:audio :artwork] (:feed_image_url episode))))]
     (let [autoplay?    (get-in db [:view-params :autoplay?])
           dub-statuses (:dub_statuses resp)
           init-dub     (when dub-statuses [[::dub-events/init-statuses new-id dub-statuses]])
           ;; Recs split out of /player — fire the fetch now so audio can
           ;; start while the (expensive) HNSW kNN runs in parallel.
           fetch-recs   [[::fetch-recs new-id]]]
       (cond
         (pb/should-skip-reload? {:same-episode? (= cur-id new-id)
                                  :was-playing?  was-playing?})
         {:db         (assoc-in db' [:audio :pending?] false)
          :dispatch-n (into (vec init-dub) (into fetch-recs [[::audio-download-start new-id]]))}

         (and was-playing? (not= cur-id new-id))
         {:db         db'
          :dispatch-n (into [[::audio-queue-pending]
                             [::audio-download-start new-id]] (into init-dub fetch-recs))}

         :else
         {:db         db'
          :dispatch-n (into [[::audio-load {:autoplay? (boolean autoplay?)}]
                             [::audio-download-start new-id]] (into init-dub fetch-recs))})))))

(rf/reg-event-fx
 ::fetch-recs
 (fn [_ [_ episode-id]]
   {::buzz-bot.fx/http-fetch {:method :get
                              :url    (str "/episodes/" episode-id "/recs")
                              :on-ok  [::recs-loaded episode-id]
                              :on-err [::recs-err]}}))

(rf/reg-event-db
 ::recs-loaded
 (fn [db [_ episode-id resp]]
   ;; Defensive: if the user navigated to a different episode mid-flight,
   ;; drop the stale response rather than writing it into the new player.
   (if (= (str episode-id) (str (get-in db [:player :data :episode :id])))
     (assoc-in db [:player :data :recs] (:recs resp))
     db)))

(rf/reg-event-db
 ::recs-err
 ;; Silent — recs are non-critical; the "Listeners also liked" section just
 ;; stays hidden if the fetch fails.
 (fn [db _] db))

;; ── Bookmarks ────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-bookmarks
 (fn [{:keys [db]} _]
   (let [saved (:saved-list db)
         limit (when (and (= (:view saved) :bookmarks) (pos? (:count saved)))
                 (:count saved))
         url   (if limit (str "/bookmarks?limit=" limit) "/bookmarks")]
     {:db         (assoc-in db [:bookmarks :loading?] true)
      :dispatch   [::fetch-cached-metas]
      ::buzz-bot.fx/http-fetch {:method :get :url url
                                :on-ok  [::bookmarks-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-fx
 ::fetch-cached-metas
 (fn [{:keys [db]} _]
   (let [ids (get-in db [:offline :cached-ids])]
     (if (empty? ids)
       {}
       {::buzz-bot.fx/http-fetch
        {:method :get
         :url    (str "/episodes/meta?ids=" (str/join "," ids))
         :on-ok  [::cached-metas-loaded]
         :on-err [::noop]}}))))

(rf/reg-event-db
 ::cached-metas-loaded
 (fn [db [_ resp]]
   (if resp
     (assoc-in db [:offline :episode-metas]
               (into {} (map #(vector (str (:id %)) %) resp)))
     db)))

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

;; ── Subtitles ─────────────────────────────────────────────────────────────
;;
;; Timing and text are independent concerns:
;;   audio-lang  — which language's synth timestamps to use (nil = original audio)
;;                 always derived from [:dub :active-lang] at fetch time
;;   text-lang   — which language's translation to display (nil = original text)
;;                 set by the user's subtitle chip selection
;;
;; This is why both are separate params on the backend endpoint.

(defn- subtitle-url [ep-id text-lang audio-lang]
  (let [params (cond-> []
                 text-lang  (conj (str "language=" text-lang))
                 audio-lang (conj (str "audio_lang=" audio-lang)))]
    (str "/episodes/" ep-id "/subtitles"
         (when (seq params) (str "?" (str/join "&" params))))))

(rf/reg-event-fx
 ::fetch-subtitles
 ;; text-lang: the translation language to show (nil = original text).
 ;; audio-lang is read from db at dispatch time so it always matches the
 ;; audio currently playing, regardless of when the event was enqueued.
 (fn [{:keys [db]} [_ ep-id text-lang]]
   (let [audio-lang (get-in db [:dub :active-lang])
         url        (subtitle-url ep-id text-lang audio-lang)]
     {::buzz-bot.fx/http-fetch {:method :get :url url
                                :on-ok  [::subtitles-loaded ep-id text-lang audio-lang]
                                :on-err [::noop]}})))

(rf/reg-event-db
 ::subtitles-loaded
 (fn [db [_ ep-id text-lang audio-lang resp]]
   (let [cues (mapv (fn [c]
                      {:idx         (:idx c)
                       :start       (:start c)
                       :end         (:end c)
                       :text        (:text c)
                       :translation (:translation c)})
                    (:cues resp []))]
     (-> db
         (assoc-in [:subtitles :ep-id]              ep-id)
         (assoc-in [:subtitles :cues]                cues)
         (assoc-in [:subtitles :source-lang]         (:source_lang resp))
         (assoc-in [:subtitles :loaded-text-lang]    text-lang)
         (assoc-in [:subtitles :loaded-audio-lang]   audio-lang)))))

(rf/reg-event-fx
 ::cycle-subtitle-lang
 ;; Turning ON: refetch if timing is stale (audio changed since last fetch).
 ;; Turning OFF: just hide the panel.
 (fn [{:keys [db]} [_ episode-id]]
   (let [currently-off? (= :off (get-in db [:subtitles :lang]))
         new-lang       (if currently-off? :original :off)
         audio-lang     (get-in db [:dub :active-lang])
         loaded-audio   (get-in db [:subtitles :loaded-audio-lang])
         timing-stale?  (not= audio-lang loaded-audio)]
     (cond-> {:db (assoc-in db [:subtitles :lang] new-lang)}
       (and currently-off? timing-stale?)
       (assoc :dispatch [::fetch-subtitles episode-id nil])))))

(rf/reg-event-fx
 ::set-subtitle-lang
 ;; Refetch when: the requested translation language wasn't loaded yet,
 ;; OR the audio language changed since the last fetch (timing is stale).
 ;; Switching to :original never needs a text refetch (orig text is always
 ;; present in cues), but DOES need a timing refetch if audio changed.
 (fn [{:keys [db]} [_ episode-id lang]]
   (let [text-lang     (when (not= lang :original) lang)
         audio-lang    (get-in db [:dub :active-lang])
         loaded-text   (get-in db [:subtitles :loaded-text-lang])
         loaded-audio  (get-in db [:subtitles :loaded-audio-lang])
         timing-stale? (not= audio-lang loaded-audio)
         text-stale?   (and (some? text-lang) (not= text-lang loaded-text))]
     (cond-> {:db (assoc-in db [:subtitles :lang] lang)}
       (or timing-stale? text-stale?)
       (assoc :dispatch [::fetch-subtitles episode-id text-lang])))))

(rf/reg-event-fx
 ::toggle-transcript
 (fn [{:keys [db]} _]
   (if (get-in db [:subtitles :transcript?])
     ;; Closing: flag it so the modal plays its exit animation, then unmount
     ;; once the animation has finished.
     {:db (assoc-in db [:subtitles :transcript-closing?] true)
      :dispatch-later [{:ms 240 :dispatch [::end-transcript]}]}
     ;; Opening
     {:db (-> db
              (assoc-in [:subtitles :transcript?] true)
              (assoc-in [:subtitles :transcript-closing?] false))})))

(rf/reg-event-db
 ::end-transcript
 (fn [db _]
   ;; Guard against a reopen during the exit window: only unmount if we're
   ;; still closing (a fresh open clears the flag and no-ops this stale timer).
   (if (get-in db [:subtitles :transcript-closing?])
     (-> db
         (assoc-in [:subtitles :transcript?] false)
         (assoc-in [:subtitles :transcript-closing?] false))
     db)))

(rf/reg-event-db
 ::clear-subtitles
 (fn [db _]
   (assoc db :subtitles {:ep-id nil :cues [] :lang :off
                         :loaded-text-lang nil :loaded-audio-lang nil
                         :source-lang nil :transcript? false
                         :transcript-closing? false})))

;; ── Audio state ──────────────────────────────────────────────────────────────

(rf/reg-event-db ::audio-playing  (fn [db _] (assoc-in db [:audio :playing?] true)))
(rf/reg-event-db ::audio-paused   (fn [db _] (assoc-in db [:audio :playing?] false)))
(rf/reg-event-db ::audio-tick     (fn [db [_ t]] (assoc-in db [:audio :current-time] t)))
(rf/reg-event-db ::audio-duration (fn [db [_ d]] (assoc-in db [:audio :duration] d)))

(rf/reg-event-fx
 ::audio-ended
 (fn [{:keys [db]} _]
   (let [autoplay? (get-in db [:audio :autoplay?])
         next-id   (get-in db [:player :data :next_id])
         db'       (-> db
                       (assoc-in [:audio :episode-id] nil)
                       (assoc-in [:audio :playing?]   false))]
     (if (and autoplay? next-id)
       {:db db' :dispatch [::navigate :player {:episode-id next-id :autoplay? true}]}
       {:db db'}))))

;; ── Audio commands ───────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::audio-load
 (fn [{:keys [db]} [_ opts]]
   (let [ep-id     (str (get-in db [:player :data :episode :id]))
         caching?  (get-in db [:flags "offline_caching"] true)
         cached?   (and caching? (some #{ep-id} (get-in db [:offline :cached-ids])))
         src       (if cached?
                     (str "/episodes/" ep-id "/audio")
                     (get-in db [:player :data :episode :audio_url]))
         start     (pb/resume-start
                     (get-in db [:player :data :user_episode :completed])
                     (get-in db [:player :data :user_episode :progress_seconds]))
         autoplay? (:autoplay? opts false)]
     (js/localStorage.setItem "buzz-last-episode-id" ep-id)
     (js/localStorage.setItem "buzz-last-episode-meta"
       (.stringify js/JSON
         (clj->js {:title   (get-in db [:player :data :episode :title])
                   :podcast (get-in db [:player :data :episode :feed_title])
                   :artwork (get-in db [:player :data :episode :feed_image_url])})))
     {:db         (-> db
                      (assoc-in [:audio :episode-id]   ep-id)
                      (assoc-in [:audio :feed-id]      (str (get-in db [:player :data :episode :feed_id])))
                      (assoc-in [:audio :src]          src)
                      (assoc-in [:audio :current-time] 0)
                      (assoc-in [:audio :pending?]     false)
                      (assoc-in [:audio :title]        (get-in db [:player :data :episode :title]))
                      (assoc-in [:audio :artist]       (get-in db [:player :data :episode :feed_title]))
                      (assoc-in [:audio :artwork]      (get-in db [:player :data :episode :feed_image_url])))
      ::buzz-bot.fx/audio-cmd {:op        :load
                               :src       src
                               :start     start
                               :autoplay? autoplay?
                               :title     (get-in db [:player :data :episode :title])
                               :artist    (get-in db [:player :data :episode :feed_title])
                               :artwork   (get-in db [:player :data :episode :feed_image_url])}})))

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

;; ── Offline / audio cache ────────────────────────────────────────────────────

(rf/reg-event-db
 ::network-status-changed
 (fn [db [_ online?]]
   (assoc-in db [:offline :network-online?] online?)))

(rf/reg-event-db
 ::offline-init
 (fn [db _]
   (let [raw (js/localStorage.getItem "buzz-cached-audio-ids")
         ids (when raw
               (try (js->clj (.parse js/JSON raw))
                    (catch :default _ [])))]
     (assoc-in db [:offline :cached-ids] (or ids [])))))

;; Idempotent — no-op if already cached, download already in progress, or flag disabled.
(rf/reg-event-fx
 ::audio-download-start
 (fn [{:keys [db]} [_ ep-id]]
   (let [cached-ids  (get-in db [:offline :cached-ids])
         in-progress (get-in db [:offline :in-progress])
         caching?    (get-in db [:flags "offline_caching"] true)]
     (if (or (not caching?) (some #{ep-id} cached-ids) (contains? in-progress ep-id))
       {}
       {:db (assoc-in db [:offline :in-progress ep-id]
                      {:bytes-downloaded 0 :bytes-total 0})
        ::buzz-bot.fx/start-audio-download {:episode-id ep-id
                                            :init-data  (:init-data db)}}))))

(rf/reg-event-db
 ::audio-download-progress
 (fn [db [_ ep-id bytes-downloaded bytes-total]]
   (assoc-in db [:offline :in-progress ep-id]
             {:bytes-downloaded bytes-downloaded :bytes-total bytes-total})))

;; LRU: prepend new id, take 5 distinct, evict the rest.
(rf/reg-event-fx
 ::audio-download-complete
 (fn [{:keys [db]} [_ ep-id]]
   (let [old-ids (get-in db [:offline :cached-ids])
         new-ids (vec (take 5 (distinct (cons ep-id old-ids))))
         evicted (remove (set new-ids) old-ids)
         new-db  (-> db
                     (assoc-in [:offline :cached-ids] new-ids)
                     (update-in [:offline :in-progress] dissoc ep-id))
         playing (get-in db [:audio :episode-id])
         switch? (= (str ep-id) (str playing))]
     (cond-> {:db                              new-db
              ::buzz-bot.fx/persist-cached-ids new-ids
              :dispatch-n                      (mapv #(vector ::audio-cache-evict %) evicted)}
       switch? (assoc ::buzz-bot.fx/audio-cmd {:op  :switch-src
                                               :src (str "/episodes/" ep-id "/audio")})))))

(rf/reg-event-db
 ::audio-download-error
 (fn [db [_ ep-id]]
   (update-in db [:offline :in-progress] dissoc ep-id)))

(rf/reg-event-fx
 ::audio-cache-evict
 (fn [{:keys [db]} [_ ep-id]]
   (let [new-ids (vec (remove #{ep-id} (get-in db [:offline :cached-ids])))]
     {:db                               (-> db
                                            (assoc-in [:offline :cached-ids] new-ids)
                                            (update-in [:offline :in-progress] dissoc ep-id))
      ::buzz-bot.fx/persist-cached-ids  new-ids
      ::buzz-bot.fx/delete-cached-audio ep-id})))

(rf/reg-event-fx
 ::audio-cache-clear-all
 (fn [{:keys [db]} _]
   {:db                              (update db :offline merge
                                             {:cached-ids [] :in-progress {}})
    ::buzz-bot.fx/persist-cached-ids []
    ::buzz-bot.fx/clear-audio-cache  nil}))
