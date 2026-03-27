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

       ;; In-flight — open SSE if not already open (re-tapping idempotent)
       (#{:pending :processing} status)
       {::fx/open-dub-sse {:episode-id episode-id :lang lang}}

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
       (assoc ::fx/open-dub-sse {:episode-id episode-id :lang lang})))))

(rf/reg-event-db
 ::request-err
 (fn [db [_ lang err]]
   (-> db
       (assoc-in [:dub :statuses lang :status] :failed)
       (assoc-in [:dub :statuses lang :error]  (str "Request failed: " err)))))

;; Receives SSE events from the server.
(rf/reg-event-fx
 ::sse-event
 (fn [{:keys [db]} [_ episode-id lang data]]
   ;; Ignore if we've navigated away from this episode.
   (when (= (str episode-id) (str (get-in db [:player :data :episode :id])))
     (let [status (keyword (:status data))]
       (cond-> {:db (-> db
                        (assoc-in [:dub :statuses lang :status] status)
                        (assoc-in [:dub :statuses lang :step]   (:step data))
                        (cond-> (= status :done)
                          (-> (assoc-in [:dub :statuses lang :r2-url]      (:r2_url data))
                              (assoc-in [:dub :statuses lang :translation] (:translation data))))
                        (cond-> (= status :failed)
                          (assoc-in [:dub :statuses lang :error] (:error data))))}
         ;; SSE stream closes itself when done/failed; nothing to do on our end.
         )))))

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

(rf/reg-event-fx
 ::reset
 (fn [db _]
   {:db          (assoc (:db db) :dub {:statuses {} :active-lang nil :picker-open? false})
    ::fx/close-dub-sse nil}))

(rf/reg-event-db ::noop (fn [db _] db))
