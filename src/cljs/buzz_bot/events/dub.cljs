(ns buzz-bot.events.dub
  (:require [re-frame.core :as rf]
            [buzz-bot.fx :as fx]))

(def dub-languages
  [{:code "en" :name "English"}
   {:code "es" :name "Spanish"}
   {:code "fr" :name "French"}
   {:code "de" :name "German"}
   {:code "it" :name "Italian"}
   {:code "pt" :name "Portuguese"}
   {:code "pl" :name "Polish"}
   {:code "tr" :name "Turkish"}
   {:code "ru" :name "Russian"}
   {:code "nl" :name "Dutch"}
   {:code "cs" :name "Czech"}
   {:code "zh" :name "Chinese"}
   {:code "ja" :name "Japanese"}
   {:code "hu" :name "Hungarian"}
   {:code "ko" :name "Korean"}])

;; Load existing dub statuses from the player endpoint response.
(rf/reg-event-db
 ::init-statuses
 (fn [db [_ statuses-map]]
   ;; statuses-map: {"es" {:status "done" :r2_url "..." :translation "..."}, ...}
   (assoc-in db [:dub :statuses]
             (reduce-kv
               (fn [m lang v]
                 (assoc m (name lang) {:status      (keyword (:status v))
                                       :r2-url      (:r2_url v)
                                       :translation (:translation v)}))
               {}
               statuses-map))))

;; Main entry point: tap a language chip.
(rf/reg-event-fx
 ::language-tapped
 (fn [{:keys [db]} [_ episode-id lang]]
   (let [lang-state   (get-in db [:dub :statuses lang])
         status       (:status lang-state)
         active       (get-in db [:dub :active-lang])
         episode      (get-in db [:player :data :episode])
         start        (max 0 (- (get-in db [:audio :current-time] 0) 5))]
     (cond
       ;; Tapping the active dubbed language → switch back to original
       (and (= status :done) (= active lang))
       {:db (assoc-in db [:dub :active-lang] nil)
        ::fx/audio-cmd {:op        :load
                        :src       (:audio_url episode)
                        :start     start
                        :autoplay? true
                        :title     (:title episode)
                        :artist    (:feed_title episode)
                        :artwork   (:feed_image_url episode)}}

       ;; Done and not active → switch to dubbed audio
       (= status :done)
       {:db (assoc-in db [:dub :active-lang] lang)
        ::fx/audio-cmd {:op        :load
                        :src       (:r2-url lang-state)
                        :start     start
                        :autoplay? true
                        :title     (str (:title episode) " [" (clojure.string/upper-case lang) "]")
                        :artist    (:feed_title episode)
                        :artwork   (:feed_image_url episode)}}

       ;; Already in flight → ensure polling continues
       (#{:pending :processing} status)
       {::fx/poll-after {:ms 5000 :dispatch [::status-tick episode-id lang]}}

       ;; Nothing yet, failed, or expired → start a new dub job
       :else
       {:dispatch [::request episode-id lang]}))))

(rf/reg-event-fx
 ::request
 (fn [{:keys [db]} [_ episode-id lang]]
   {:db (-> db
            (assoc-in [:dub :statuses lang :status] :pending)
            (assoc-in [:dub :statuses lang :error]  nil))
    ::fx/http-fetch {:method :post
                     :url    (str "/episodes/" episode-id "/dub")
                     :body   {:language lang}
                     :on-ok  [::request-ok episode-id lang]
                     :on-err [::request-err lang]}}))

(rf/reg-event-fx
 ::request-ok
 (fn [{:keys [db]} [_ episode-id lang resp]]
   (let [status (keyword (:status resp))]
     (cond-> {:db (-> db
                      (assoc-in [:dub :statuses lang :status] status)
                      (assoc-in [:dub :statuses lang :step]   (:step resp))
                      (cond-> (= status :done)
                        (-> (assoc-in [:dub :statuses lang :r2-url]      (:r2_url resp))
                            (assoc-in [:dub :statuses lang :translation] (:translation resp)))))}
       (#{:pending :processing} status)
       (assoc ::fx/poll-after {:ms 5000 :dispatch [::status-tick episode-id lang]})))))

(rf/reg-event-db
 ::request-err
 (fn [db [_ lang err]]
   (-> db
       (assoc-in [:dub :statuses lang :status] :failed)
       (assoc-in [:dub :statuses lang :error]  (str "Request failed: " err)))))

(rf/reg-event-fx
 ::status-tick
 (fn [{:keys [db]} [_ episode-id lang]]
   ;; Cancel the poll loop if we've navigated away from this episode.
   (when (= (str episode-id) (str (get-in db [:player :data :episode :id])))
     {::fx/http-fetch {:method :get
                       :url    (str "/episodes/" episode-id "/dub/" lang)
                       :on-ok  [::status-loaded episode-id lang]
                       :on-err [::noop]}})))

(rf/reg-event-fx
 ::status-loaded
 (fn [{:keys [db]} [_ episode-id lang resp]]
   (let [status (keyword (:status resp))]
     (cond-> {:db (-> db
                      (assoc-in [:dub :statuses lang :status] status)
                      (assoc-in [:dub :statuses lang :step]   (:step resp))
                      (cond-> (= status :done)
                        (-> (assoc-in [:dub :statuses lang :r2-url]      (:r2_url resp))
                            (assoc-in [:dub :statuses lang :translation] (:translation resp))))
                      (cond-> (= status :failed)
                        (assoc-in [:dub :statuses lang :error] (:error resp))))}
       (#{:pending :processing} status)
       (assoc ::fx/poll-after {:ms 5000 :dispatch [::status-tick episode-id lang]})))))

(rf/reg-event-fx
 ::send-telegram
 (fn [{:keys [db]} [_ episode-id]]
   (let [lang (get-in db [:dub :active-lang])]
     {::fx/http-fetch {:method :post
                       :url    (str "/episodes/" episode-id "/send")
                       :body   {:dubbed true :language lang}
                       :on-ok  [::noop]
                       :on-err [::send-err]}})))

(rf/reg-event-db
 ::send-err
 (fn [db [_ err]]
   (assoc-in db [:dub :send-error] (str "Send failed: " err))))

(rf/reg-event-db
 ::toggle-picker
 (fn [db _]
   (update-in db [:dub :picker-open?] not)))

(rf/reg-event-db
 ::reset
 (fn [db _]
   (assoc db :dub {:statuses {} :active-lang nil :picker-open? false})))

(rf/reg-event-db ::noop (fn [db _] db))
