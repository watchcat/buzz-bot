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

(rf/reg-event-db
 ::open-picker
 (fn [db _]
   (assoc-in db [:dub :picker-open?] true)))

(rf/reg-event-db
 ::close-picker
 (fn [db _]
   (assoc-in db [:dub :picker-open?] false)))

(rf/reg-event-fx
 ::language-selected
 (fn [{:keys [db]} [_ episode-id lang]]
   {:db (-> db
            (assoc-in [:dub :picker-open?] false)
            (assoc-in [:dub :preferred-language] lang))
    ::fx/http-fetch {:method :put
                     :url    "/user/dub_language"
                     :body   {:language lang}
                     :on-ok  [::noop]
                     :on-err [::noop]}
    :dispatch [::request episode-id lang]}))

(rf/reg-event-fx
 ::request
 (fn [{:keys [db]} [_ episode-id lang]]
   {:db (-> db
            (assoc-in [:dub :status] :pending)
            (assoc-in [:dub :language] lang)
            (assoc-in [:dub :r2-url] nil)
            (assoc-in [:dub :error] nil))
    ::fx/http-fetch {:method :post
                     :url    (str "/episodes/" episode-id "/dub")
                     :body   {:language lang}
                     :on-ok  [::request-ok episode-id lang]
                     :on-err [::request-err]}}))

(rf/reg-event-fx
 ::request-ok
 (fn [{:keys [db]} [_ episode-id lang resp]]
   (let [status (keyword (:status resp))]
     (cond-> {:db (-> db
                      (assoc-in [:dub :status] status)
                      (assoc-in [:dub :dub-id] (:id resp))
                      (cond-> (= status :done)
                        (-> (assoc-in [:dub :r2-url] (:r2_url resp))
                            (assoc-in [:dub :translation] (:translation resp)))))}
       (#{:pending :processing} status)
       (assoc ::fx/poll-after {:ms 5000 :dispatch [::status-tick episode-id lang]})))))

(rf/reg-event-db
 ::request-err
 (fn [db [_ err]]
   (-> db
       (assoc-in [:dub :status] :failed)
       (assoc-in [:dub :error] (str "Request failed: " err)))))

(rf/reg-event-fx
 ::status-tick
 (fn [_ [_ episode-id lang]]
   {::fx/http-fetch {:method :get
                     :url    (str "/episodes/" episode-id "/dub/" lang)
                     :on-ok  [::status-loaded episode-id lang]
                     :on-err [::noop]}}))

(rf/reg-event-fx
 ::status-loaded
 (fn [{:keys [db]} [_ episode-id lang resp]]
   (let [status (keyword (:status resp))]
     (cond-> {:db (-> db
                      (assoc-in [:dub :status] status)
                      (cond-> (= status :done)
                        (-> (assoc-in [:dub :r2-url] (:r2_url resp))
                            (assoc-in [:dub :translation] (:translation resp))))
                      (cond-> (= status :failed)
                        (assoc-in [:dub :error] (:error resp))))}
       (#{:pending :processing} status)
       (assoc ::fx/poll-after {:ms 5000 :dispatch [::status-tick episode-id lang]})))))

(rf/reg-event-fx
 ::audio-play-url
 (fn [_ [_ url]]
   {::fx/audio-cmd {:op :load :src url :start 0 :autoplay? true}}))

(rf/reg-event-fx
 ::send-telegram
 (fn [{:keys [db]} [_ episode-id]]
   (let [lang (get-in db [:dub :language])]
     {::fx/http-fetch {:method :post
                       :url    (str "/episodes/" episode-id "/send")
                       :body   {:dubbed true :language lang}
                       :on-ok  [::noop]
                       :on-err [::send-err]}})))

(rf/reg-event-db
 ::send-err
 (fn [db [_ err]]
   (assoc-in db [:dub :error] (str "Send failed: " err))))

(rf/reg-event-db
 ::reset
 (fn [db _]
   (-> db
       (assoc-in [:dub :status] nil)
       (assoc-in [:dub :r2-url] nil)
       (assoc-in [:dub :translation] nil)
       (assoc-in [:dub :error] nil)
       (assoc-in [:dub :language] nil)
       (assoc-in [:dub :dub-id] nil))))

(rf/reg-event-db ::noop (fn [db _] db))
