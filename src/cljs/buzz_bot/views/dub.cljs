(ns buzz-bot.views.dub
  (:require [re-frame.core :as rf]
            [clojure.string :as str]
            [buzz-bot.subs.dub :as dub-subs]
            [buzz-bot.events.dub :as dub-events]))

(defn dub-panel [episode-id]
  (let [active     @(rf/subscribe [::dub-subs/active-lang])
        statuses   @(rf/subscribe [::dub-subs/statuses])
        send-error @(rf/subscribe [::dub-subs/send-error])
        orig-lang  @(rf/subscribe [::dub-subs/original-language])]
    [:div.dub-panel
     [:div.dub-langs
      (for [{:keys [code name]} dub-events/dub-languages
            :when (and (not= code orig-lang)
                       (contains? statuses code))]
        (let [lang-state (get statuses code)
              status     (:status lang-state)
              is-active  (= active code)
              chip-class (cond
                           is-active                        "dub-lang-chip--active"
                           (= status :done)                 "dub-lang-chip--done"
                           (#{:pending :processing} status) "dub-lang-chip--pending"
                           (= status :failed)               "dub-lang-chip--failed"
                           :else                            nil)]
          [:button.dub-lang-chip
           {:key      code
            :title    (if is-active (str name " — tap to return to original") name)
            :class    chip-class
            :on-click #(rf/dispatch [::dub-events/language-tapped episode-id code])}
           (str/upper-case code)]))]

     ;; Active language controls
     (when active
       (let [lang-state (get statuses active)
             translation (:translation lang-state)]
         [:div.dub-active-controls
          [:button.btn-send-dubbed
           {:on-click #(rf/dispatch [::dub-events/send-telegram episode-id])}
           "📨 Send dubbed to Telegram"]
          (when send-error
            [:div.dub-error-detail send-error])
          (when (and translation (not (str/blank? translation)))
            [:details.dub-translation
             [:summary "Translation"]
             [:p.dub-translation-text translation]])]))]))
