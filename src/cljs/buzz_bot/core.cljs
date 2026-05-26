(ns buzz-bot.core
  (:require [reagent.dom :as rdom]
            [reagent.core :as r]
            [re-frame.core :as rf]
            [clojure.string :as str]
            [buzz-bot.events :as events]
            [buzz-bot.subs]
            [buzz-bot.subs.dub]
            [buzz-bot.events.dub]
            [buzz-bot.fx]
            [buzz-bot.audio :as audio]
            [buzz-bot.views.layout :as layout]))

(defn- tg [] (.. js/window -Telegram -WebApp))

(defn- apply-theme! []
  (when-let [params (.. (tg) -themeParams)]
    (let [root (.-style js/document.documentElement)
          p    (js->clj params)]
      (doseq [[k v] {"--bg-color"          (get p "bg_color")
                     "--text-color"        (get p "text_color")
                     "--hint-color"        (get p "hint_color")
                     "--link-color"        (get p "link_color")
                     "--button-color"      (get p "button_color")
                     "--button-text-color" (get p "button_text_color")
                     "--secondary-bg"      (get p "secondary_bg_color")}]
        (when v (.setProperty root k v))))))

(defn- extract-episode-id []
  (let [unsafe (some-> (tg) (.-initDataUnsafe))
        start  (when unsafe (.-start_param unsafe))
        url-ep (-> js/window .-location .-search js/URLSearchParams. (.get "episode"))]
    (or url-ep
        (when (and start (str/starts-with? start "ep_"))
          (subs start 3)))))

(defn- check-deep-link []
  (if-let [ep-id (extract-episode-id)]
    (rf/dispatch [::events/navigate :player {:episode-id ep-id}])
    (rf/dispatch [::events/navigate :inbox])))

(defn- restore-audio-state! []
  (let [ep-id (js/localStorage.getItem "buzz-last-episode-id")
        meta  (try (-> (js/localStorage.getItem "buzz-last-episode-meta")
                       js/JSON.parse
                       (js->clj :keywordize-keys true))
                   (catch :default _ {}))
        rate  (let [r (js/parseFloat (js/localStorage.getItem "buzz-playback-speed"))]
                (if (js/isNaN r) 1 r))
        auto? (= "true" (js/localStorage.getItem "buzz-autoplay"))]
    (when ep-id
      (rf/dispatch-sync [::events/init-audio-meta ep-id meta rate auto?]))))

(defn- forward-deep-link!
  "Send deep link to the running instance via BroadcastChannel, then close."
  []
  (when-let [ep-id (extract-episode-id)]
    (let [ch (js/BroadcastChannel. "buzz-bot")]
      (.postMessage ch #js{:type "navigate" :episodeId ep-id})
      (.close ch)))
  (.close (tg)))

(defn- listen-deep-links!
  "Listen for navigation requests from new instances that couldn't acquire the lock."
  []
  (let [ch (js/BroadcastChannel. "buzz-bot")]
    (set! (.-onmessage ch)
      (fn [e]
        (let [data (js->clj (.-data e) :keywordize-keys true)]
          (when (and (= (:type data) "navigate") (:episodeId data))
            (rf/dispatch [::events/navigate :player {:episode-id (:episodeId data)}])))))))

(defn- error-boundary []
  (let [err (r/atom nil)]
    (r/create-class
      {:display-name      "ErrorBoundary"
       :component-did-catch (fn [_this e info]
                              (reset! err {:msg      (.-message e)
                                           :js-stack (.-stack e)
                                           :stack    (.-componentStack info)}))
       :render (fn [this]
                 (if-let [{:keys [msg js-stack stack]} @err]
                   [:div {:style {:padding "16px" :color "red"
                                  :font-size "11px" :white-space "pre-wrap"
                                  :overflow "auto"}}
                    "RENDER ERROR:\n" msg "\n\nJS stack:\n" js-stack
                    "\n\nComponent stack:\n" stack]
                   (first (r/children this))))})))

(defn- cleanup-legacy-caches! []
  ;; Remove any old cache buckets not used by the current SW strategy.
  ;; Do NOT call .unregister — we need the SW running.
  (when (.-caches js/window)
    (let [keep #{"buzz-shell-v1" "buzz-api-v1" "buzz-audio-v1" "buzz-img-v1"}]
      (-> (.keys js/caches)
          (.then (fn [ks]
                   (js/Promise.all
                     (.map (.filter ks #(not (contains? keep %)))
                           #(.delete js/caches %)))))))))

(defn- register-sw! []
  (when (.-serviceWorker js/navigator)
    (-> (.register (.-serviceWorker js/navigator) "/sw.js" #js{:scope "/"})
        (.catch (fn [e] (js/console.warn "SW registration failed:" e))))))

(defn- wire-network! []
  (.addEventListener js/window "online"
    #(rf/dispatch [::events/network-status-changed true]))
  (.addEventListener js/window "offline"
    #(rf/dispatch [::events/network-status-changed false])))

(defn- mount! []
  (.ready (tg))
  (.expand (tg))
  (apply-theme!)
  (rf/dispatch-sync [::events/initialize-db])
  (rf/dispatch-sync [::events/set-init-data (.. (tg) -initData)])
  (rf/dispatch-sync [::events/offline-init])
  (rf/dispatch [::events/fetch-flags])
  (wire-network!)
  (register-sw!)
  (restore-audio-state!)
  (audio/init!)
  (listen-deep-links!)
  (check-deep-link)
  (rdom/render [error-boundary [layout/root]] (js/document.getElementById "app")))

(defn ^:export init! []
  (cleanup-legacy-caches!)
  (if-let [locks (.. js/navigator -locks)]
    (.request locks "buzz-bot-instance"
      #js{:ifAvailable true}
      (fn [lock]
        (if lock
          (do (mount!) (js/Promise. (fn [_ _])))
          (forward-deep-link!))))
    (mount!)))
