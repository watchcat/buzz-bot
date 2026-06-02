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
;; Also opens SSE for any in-flight dubs so progress updates arrive on fresh sessions.
(rf/reg-event-fx
 ::init-statuses
 (fn [{:keys [db]} [_ episode-id statuses-map]]
   (let [statuses (reduce-kv
                    (fn [m lang v]
                      (assoc m (name lang) {:status      (keyword (:status v))
                                            :step        (:step v)
                                            :r2-url      (:r2_url v)
                                            :translation (:translation v)}))
                    {}
                    statuses-map)
         in-flight (first (keep (fn [[lang {:keys [status]}]]
                                  (when (#{:pending :processing} status) lang))
                                statuses))
         done-lang (first (keep (fn [[lang {:keys [status]}]]
                                  (when (= :done status) lang))
                                statuses))
         ;; Card click in views/inbox_dubbed.cljs sets :dub-lang in view-params
         ;; via ::events/navigate :player {... :dub-lang "<target>"}. If that
         ;; language's status is :done now, auto-activate it so the dubbed
         ;; audio loads instead of the original.
         nav-lang  (some-> (get-in db [:view-params :dub-lang]) name)
         auto-lang (when (and nav-lang
                              (= :done (get-in statuses [nav-lang :status])))
                     nav-lang)
         dispatches (cond-> []
                      ;; Preload translation text with original-audio timing (audio_lang=nil).
                      ;; User starts on original audio; timing will be refetched if they switch to dubbed.
                      done-lang (conj [:buzz-bot.events/fetch-subtitles episode-id done-lang])
                      ;; Arriving via inbox-dubbed widget: switch to the dubbed
                      ;; track silently so the player opens on the dubbed audio,
                      ;; but don't autoplay — the user clicked the card to land
                      ;; on the episode, not to start playback.
                      auto-lang (conj [::language-tapped episode-id auto-lang false]))]
     (cond-> {:db (assoc-in db [:dub :statuses] statuses)}
       in-flight
       (assoc ::fx/open-dub-sse {:episode-id episode-id :lang in-flight})
       (seq dispatches)
       (assoc :dispatch-n dispatches)))))

;; Main entry point: tap a language chip. The optional 4th arg `autoplay?`
;; defaults to true (manual chip taps in the player UI start playback).
;; The init-statuses auto-tap from the inbox-dubbed widget passes false so
;; landing on the player from the card click doesn't start playback.
(rf/reg-event-fx
 ::language-tapped
 (fn [{:keys [db]} [_ episode-id lang autoplay?]]
   (let [autoplay?    (if (nil? autoplay?) true autoplay?)
         lang-state   (get-in db [:dub :statuses lang])
         status       (:status lang-state)
         active       (get-in db [:dub :active-lang])
         episode      (get-in db [:player :data :episode])
         start        (max 0 (- (get-in db [:audio :current-time] 0) 5))
         sub-lang     (get-in db [:subtitles :lang])
         ;; text-lang for subtitle refresh: nil when showing original text
         sub-text-lang (when (not= sub-lang :original) sub-lang)
         subs-active? (not= sub-lang :off)]
     (cond
       ;; Tapping the active dubbed language → switch back to original audio.
       ;; [:dub :active-lang] becomes nil; if subs are visible, refetch with
       ;; audio_lang=nil (original timestamps).
       (and (= status :done) (= active lang))
       (cond-> {:db (assoc-in db [:dub :active-lang] nil)
                ::fx/audio-cmd {:op        :load
                                :src       (:audio_url episode)
                                :start     start
                                :autoplay? autoplay?
                                :title     (:title episode)
                                :artist    (:feed_title episode)
                                :artwork   (:feed_image_url episode)}}
         subs-active?
         (assoc :dispatch [:buzz-bot.events/fetch-subtitles episode-id sub-text-lang]))

       ;; Done and not active → switch to dubbed audio.
       ;; [:dub :active-lang] becomes lang; if subs are visible, refetch with
       ;; audio_lang=lang (synth timestamps for this dub).
       (= status :done)
       (cond-> {:db (assoc-in db [:dub :active-lang] lang)
                ::fx/audio-cmd {:op        :load
                                :src       (:r2-url lang-state)
                                :start     start
                                :autoplay? autoplay?
                                :title     (str (:title episode) " [" (clojure.string/upper-case lang) "]")
                                :artist    (:feed_title episode)
                                :artwork   (:feed_image_url episode)}}
         subs-active?
         (assoc :dispatch [:buzz-bot.events/fetch-subtitles episode-id sub-text-lang]))

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
                        (assoc-in [:dub :statuses lang :status]    status)
                        (assoc-in [:dub :statuses lang :step]      (:step data))
                        (assoc-in [:dub :statuses lang :synth-pct] (:pct data))
                        (cond-> (= status :done)
                          (-> (assoc-in [:dub :statuses lang :r2-url]      (:r2_url data))
                              (assoc-in [:dub :statuses lang :translation] (:translation data))
                              ;; Dub finished — the inbox "Latest dubbed" widget is now stale.
                              (assoc-in [:inbox-dubbed :loaded?] false)))
                        (cond-> (= status :failed)
                          (assoc-in [:dub :statuses lang :error] (:error data))))}
         (= status :done)
         (assoc :dispatch-n [[:buzz-bot.events/fetch-subtitles   episode-id lang]
                             [:buzz-bot.events/fetch-inbox-dubbed true]])
         ;; Terminal — stop any reconnect/poll machinery
         (#{:done :failed} status)
         (assoc ::fx/stop-dub-poll nil))))))

;; ── SSE reconnect + poll-fallback machinery ──────────────────────────────────
;; EventSource's built-in auto-reconnect handles transient blips (readyState
;; stays 0=CONNECTING). When it gives up (readyState 2=CLOSED) the fx layer
;; dispatches ::sse-error here. We retry the open up to MAX-SSE-ATTEMPTS times
;; with a short backoff; beyond that we fall back to polling the player JSON
;; until terminal.

(def ^:private MAX-SSE-ATTEMPTS 3)
(def ^:private SSE-BACKOFF-MS  2000)

(rf/reg-event-fx
 ::sse-open
 (fn [{:keys [db]} [_ lang]]
   ;; Healthy connection — reset the attempt counter for this lang.
   {:db (assoc-in db [:dub :sse-attempts lang] 0)}))

(rf/reg-event-fx
 ::sse-error
 (fn [{:keys [db]} [_ episode-id lang]]
   (let [current-ep (get-in db [:player :data :episode :id])
         status     (get-in db [:dub :statuses lang :status])
         attempts   (get-in db [:dub :sse-attempts lang] 0)]
     (cond
       ;; User navigated away — abandon the SSE for this episode.
       (not= (str episode-id) (str current-ep))
       nil

       ;; Already terminal locally — nothing to recover.
       (#{:done :failed} status)
       nil

       ;; Still budget left — schedule another open attempt.
       (< attempts MAX-SSE-ATTEMPTS)
       {:db             (assoc-in db [:dub :sse-attempts lang] (inc attempts))
        :dispatch-later {:ms       SSE-BACKOFF-MS
                         :dispatch [::reopen-sse episode-id lang]}}

       ;; Exhausted SSE attempts — switch to polling the player JSON.
       :else
       {:db                 (assoc-in db [:dub :sse-attempts lang] 0)
        ::fx/start-dub-poll {:episode-id episode-id :lang lang}}))))

(rf/reg-event-fx
 ::reopen-sse
 (fn [{:keys [db]} [_ episode-id lang]]
   ;; Re-check preconditions before actually re-opening — the user may have
   ;; navigated, or the dub may have completed via a separate signal in the
   ;; interim.
   (let [current-ep (get-in db [:player :data :episode :id])
         status     (get-in db [:dub :statuses lang :status])]
     (when (and (= (str episode-id) (str current-ep))
                (#{:pending :processing} status))
       {::fx/open-dub-sse {:episode-id episode-id :lang lang}}))))

(rf/reg-event-fx
 ::poll-tick
 (fn [{:keys [db]} [_ episode-id lang]]
   (let [current-ep (get-in db [:player :data :episode :id])
         status     (get-in db [:dub :statuses lang :status])]
     (cond
       (not= (str episode-id) (str current-ep))
       {::fx/stop-dub-poll nil}

       (#{:done :failed} status)
       {::fx/stop-dub-poll nil}

       :else
       {::fx/http-fetch {:method :get
                         :url    (str "/episodes/" episode-id "/player")
                         :on-ok  [::poll-loaded episode-id lang]
                         :on-err [::poll-err]}}))))

(rf/reg-event-fx
 ::poll-loaded
 (fn [{:keys [db]} [_ episode-id lang resp]]
   ;; Defensive: don't apply if the user navigated away mid-flight.
   (when (= (str episode-id) (str (get-in db [:player :data :episode :id])))
     (let [dub-status-raw (get-in resp [:dub_statuses (keyword lang)])
           status         (some-> dub-status-raw :status keyword)]
       (when dub-status-raw
         (let [db' (-> db
                       (assoc-in [:dub :statuses lang :status] status)
                       (assoc-in [:dub :statuses lang :step]   (:step dub-status-raw))
                       (cond-> (= status :done)
                         (-> (assoc-in [:dub :statuses lang :r2-url]      (:r2_url dub-status-raw))
                             (assoc-in [:dub :statuses lang :translation] (:translation dub-status-raw)))))]
           (cond-> {:db db'}
             (#{:done :failed} status)
             (assoc ::fx/stop-dub-poll nil)
             (= status :done)
             (assoc :dispatch [:buzz-bot.events/fetch-subtitles episode-id lang]))))))))

(rf/reg-event-db
 ::poll-err
 ;; Transient — just let the next interval tick try again. The interval keeps
 ;; running until either ::poll-loaded sees a terminal status or the user
 ;; navigates away (caught by the next tick's guard).
 (fn [db _] db))

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
