(ns buzz-bot.core
  (:require [reagent.dom :as rdom]
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
  (let [start  (.. (tg) -initDataUnsafe -start_param)
        url-ep (-> js/window .-location .-search js/URLSearchParams. (.get "episode"))
        ep-id  (or url-ep
                   (when (str/starts-with? (str start) "ep_")
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
        rate  (or (js/parseFloat (js/localStorage.getItem "buzz-playback-speed")) 1)
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

(defn- mount! []
  (.ready (tg))
  (.expand (tg))
  (apply-theme!)
  (rf/dispatch-sync [::events/initialize-db])
  (rf/dispatch-sync [::events/set-init-data (.. (tg) -initData)])
  (restore-audio-state!)
  (audio/init!)
  (check-deep-link)
  (rdom/render [layout/root] (js/document.getElementById "app")))

(defn ^:export init! []
  (if-let [locks (.. js/navigator -locks)]
    (.request locks "buzz-bot-instance"
      #js{:ifAvailable true}
      (fn [lock]
        (if lock
          (do (mount!) (js/Promise. (fn [_ _])))
          (show-already-open!))))
    (mount!)))
