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

;; ── ::copy-to-clipboard ──────────────────────────────────────────────────────
;; Copies text to clipboard and shows the `.copy-toast` element briefly.

(defn- show-copy-toast! []
  (let [toast (or (.getElementById js/document "copy-toast")
                  (let [el (.createElement js/document "div")]
                    (set! (.-id el) "copy-toast")
                    (set! (.-className el) "copy-toast")
                    (.appendChild (.-body js/document) el)
                    el))]
    (set! (.-textContent toast) "RSS URL copied")
    (.add (.-classList toast) "copy-toast--visible")
    (js/clearTimeout (.-_hideTimer toast))
    (set! (.-_hideTimer toast)
          (js/setTimeout #(.remove (.-classList toast) "copy-toast--visible") 1500))))

(rf/reg-fx
 ::copy-to-clipboard
 (fn [text]
   (when text
     (if (.. js/navigator -clipboard -writeText)
       (-> (.writeText (.-clipboard js/navigator) text)
           (.then show-copy-toast!)
           (.catch show-copy-toast!))
       (do
         (let [ta (.createElement js/document "textarea")]
           (set! (.-value ta) text)
           (set! (.-cssText (.-style ta)) "position:fixed;opacity:0;top:0;left:0")
           (.appendChild (.-body js/document) ta)
           (.select ta)
           (.execCommand js/document "copy")
           (.removeChild (.-body js/document) ta))
         (show-copy-toast!))))))

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
     ;; Double-rAF: Reagent batches DOM commits in its own rAF. The first rAF here fires
     ;; in the same frame as Reagent's render but before React has committed. The second
     ;; fires after Reagent's commit phase, so the element is guaranteed to be in the DOM.
     (js/requestAnimationFrame
       (fn []
         (js/requestAnimationFrame
           (fn []
             (when-let [el (.querySelector js/document
                             (str "[data-episode-id='" episode-id "']"))]
               (.scrollIntoView el #js{:block "center" :behavior "smooth"})))))))))
