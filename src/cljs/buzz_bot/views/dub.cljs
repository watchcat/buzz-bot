(ns buzz-bot.views.dub
  (:require [re-frame.core :as rf]
            [buzz-bot.subs.dub :as dub-subs]
        [clojure.string :as str]
            [buzz-bot.events.dub :as dub-events]))

(defn language-picker [episode-id]
  (let [preferred @(rf/subscribe [::dub-subs/preferred-dub-language])]
    [:div.dub-picker-overlay
     {:on-click #(rf/dispatch [::dub-events/close-picker])}
     [:div.dub-picker-modal
      {:on-click #(.stopPropagation %)}
      [:div.dub-picker-title "Choose dub language"]
      [:ul.dub-language-list
       (for [{:keys [code name]} dub-events/dub-languages]
         [:li.dub-language-item
          {:key      code
           :class    (when (= code preferred) "selected")
           :on-click #(rf/dispatch [::dub-events/language-selected episode-id code])}
          name
          (when (= code preferred) [:span.dub-lang-check " ✓"])])]]]))

(defn dub-panel [episode-id]
  (let [status      @(rf/subscribe [::dub-subs/dub-status])
        err         @(rf/subscribe [::dub-subs/dub-error])
        lang        @(rf/subscribe [::dub-subs/dub-language])
        translation @(rf/subscribe [::dub-subs/dub-translation])]
    [:div.dub-panel
     (case status
       nil
       [:button.btn-dub
        {:on-click #(rf/dispatch [::dub-events/open-picker])}
        "🎙 Dub Episode"]

       (:pending :processing)
       [:div.dub-status-pending
        [:span.dub-spinner "⏳"]
        " Dubbing… (this may take a few minutes)"]

       :done
       [:div.dub-done
        [:button.btn-play-dubbed
         {:on-click #(rf/dispatch [::dub-events/audio-play-url
                                   @(rf/subscribe [::dub-subs/dub-r2-url])])}
         "▶ Play Dubbed"]
        [:button.btn-send-dubbed
         {:on-click #(rf/dispatch [::dub-events/send-telegram episode-id])}
         "📨 Send Dubbed to Telegram"]
        (when (and translation (not (str/blank? translation)))
          [:details.dub-translation
           [:summary "Translation"]
           [:p.dub-translation-text translation]])]

       :failed
       [:div.dub-status-failed
        [:button.btn-dub.btn-retry
         {:on-click #(rf/dispatch [::dub-events/request episode-id lang])}
         "⚠ Dubbing failed — tap to retry"]
        (when err [:div.dub-error-detail err])]

       :expired
       [:button.btn-dub
        {:on-click #(rf/dispatch [::dub-events/open-picker])}
        "🎙 Dub Episode (expired)"]

       nil)]))
