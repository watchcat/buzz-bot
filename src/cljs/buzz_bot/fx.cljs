(ns buzz-bot.fx
  (:require [re-frame.core :as rf]
            [re-frame.db]
            [buzz-bot.audio :as audio]))

;; ── ::http-fetch ────────────────────────────────────────────────────────────
;; Options map:
;;   :method  — :get | :post | :put | :delete
;;   :url     — string
;;   :body    — nil | js/URLSearchParams | clj map (will be JSON-encoded)
;;   :on-ok   — event vector appended with parsed JSON response
;;   :on-err  — event vector appended with error string

(defn- method-str [m]
  (case m :get "GET" :post "POST" :put "PUT" :delete "DELETE" "GET"))

(defn- build-init [method body init-data]
  (let [headers (js-obj "X-Init-Data" init-data)
        base    (js-obj "method" (method-str method)
                        "headers" headers)]
    (when body
      (cond
        (instance? js/URLSearchParams body)
        (aset base "body" body)

        (map? body)
        (do (aset headers "Content-Type" "application/json")
            (aset base "body" (.stringify js/JSON (clj->js body))))))
    base))

(rf/reg-fx
 ::http-fetch
 (fn [{:keys [method url body on-ok on-err]}]
   (let [init-data (get @re-frame.db/app-db :init-data "")
         init      (build-init method body init-data)]
     (-> (js/fetch url init)
         (.then (fn [resp]
                  (if (.-ok resp)
                    (let [len (.get (.-headers resp) "content-length")
                          ct  (.get (.-headers resp) "content-type")]
                      (if (or (= (.-status resp) 204)
                              (= len "0")
                              (not (and ct (.includes ct "json"))))
                        (rf/dispatch (conj on-ok nil))
                        (-> (.json resp)
                            (.then (fn [data]
                                     (rf/dispatch (conj on-ok (js->clj data :keywordize-keys true))))))))
                    (rf/dispatch (conj on-err (str "HTTP " (.-status resp)))))))
         (.catch (fn [err]
                   (rf/dispatch (conj on-err (str err)))))))))

;; ── ::audio-cmd ─────────────────────────────────────────────────────────────
;; Delegates to buzz-bot.audio/execute-cmd!

(rf/reg-fx
 ::audio-cmd
 (fn [cmd] (audio/execute-cmd! cmd)))

;; ── ::open-telegram-link ─────────────────────────────────────────────────────
;; Opens a URL via Telegram.WebApp.openTelegramLink (falls back to window.open).

(rf/reg-fx
 ::open-telegram-link
 (fn [url]
   (when url
     (let [tg (.. js/window -Telegram -WebApp)]
       (if (.-openTelegramLink tg)
         (.openTelegramLink tg url)
         (.open js/window url "_blank"))))))

;; ── ::scroll-to-episode ──────────────────────────────────────────────────────
;; Scrolls the episode card with the given id into view (center, smooth).

(rf/reg-fx
 ::scroll-to-episode
 (fn [episode-id]
   (when episode-id
     (js/requestAnimationFrame
       (fn []
         (when-let [el (.querySelector js/document
                         (str "[data-episode-id='" episode-id "']"))]
           (.scrollIntoView el #js{:block "center" :behavior "smooth"})))))))
