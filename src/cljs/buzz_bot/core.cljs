(ns buzz-bot.core
  (:require [reagent.dom :as rdom]
            [reagent.core :as r]
            [re-frame.core :as rf]
            [clojure.string :as str]
            [buzz-bot.events :as events]
            [buzz-bot.subs]
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

(defn- check-deep-link []
  (let [unsafe (some-> (tg) (.-initDataUnsafe))
        start  (when unsafe (.-start_param unsafe))
        url-ep (-> js/window .-location .-search js/URLSearchParams. (.get "episode"))
        ep-id  (or url-ep
                   (when (and start (str/starts-with? start "ep_"))
                     (subs start 3)))]
    (if ep-id
      (rf/dispatch [::events/navigate :player {:episode-id ep-id}])
      (rf/dispatch [::events/navigate :inbox]))))

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

(defn- show-already-open! []
  (let [div (js/document.createElement "div")]
    (set! (.-className div) "single-instance-overlay")
    (set! (.-innerHTML div)
      (str "<div class=\"single-instance-msg\">"
           "<div class=\"single-instance-icon\">📻</div>"
           "<strong>Already open</strong>"
           "<p>Buzz-Bot is already running in another window.</p>"
           "</div>"))
    (.appendChild js/document.body div)))

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

(defn- mount! []
  (.ready (tg))
  (.expand (tg))
  (apply-theme!)
  (rf/dispatch-sync [::events/initialize-db])
  (rf/dispatch-sync [::events/set-init-data (.. (tg) -initData)])
  (restore-audio-state!)
  (rf/dispatch-sync [::events/cache-init])
  (audio/init!)
  (check-deep-link)
  (rdom/render [error-boundary [layout/root]] (js/document.getElementById "app")))

(defn- cleanup-legacy! []
  (when (.-serviceWorker js/navigator)
    (-> (.getRegistrations (.-serviceWorker js/navigator))
        (.then (fn [regs] (doseq [r regs] (.unregister r))))))
  (when (.-caches js/window)
    (-> (.keys js/caches)
        (.then (fn [ks] (js/Promise.all (.map ks (fn [k] (.delete js/caches k)))))))))

(defn ^:export init! []
  (cleanup-legacy!)
  (if-let [locks (.. js/navigator -locks)]
    (.request locks "buzz-bot-instance"
      #js{:ifAvailable true}
      (fn [lock]
        (if lock
          (do (mount!) (js/Promise. (fn [_ _])))
          (show-already-open!))))
    (mount!)))
