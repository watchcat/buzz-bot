(ns buzz-bot.views.dub
  (:require [re-frame.core :as rf]
            [clojure.string :as str]
            [buzz-bot.subs.dub :as dub-subs]
            [buzz-bot.events.dub :as dub-events]))

;; Pipeline step → progress percentage and human label.
(defn- step->progress [step]
  ;; 0..1 fraction driving the progress fill's scaleX.
  (case step
    "queued"                0.05
    "separating"            0.15
    "transcribing"          0.30
    "translating"           0.50
    "synthesizing"          0.70
    "assembling"            0.90
    ("mixing" "uploading")  0.95
    0.05))   ; unknown → minimal fill

(defn- step->label [step]
  (case step
    "queued"                "Starting…"
    "separating"            "Separating audio stems…"
    "transcribing"          "Transcribing audio…"
    "translating"           "Translating…"
    "synthesizing"          "Synthesizing dubbed voice…"
    "assembling"            "Assembling timeline…"
    ("mixing" "uploading")  "Finishing up…"
    "Starting…"))

;; Unified dub section: sits below the meta row.
(defn dub-section [episode-id]
  (let [picker-open? @(rf/subscribe [::dub-subs/picker-open?])
        active       @(rf/subscribe [::dub-subs/active-lang])
        statuses     @(rf/subscribe [::dub-subs/statuses])
        send-error   @(rf/subscribe [::dub-subs/send-error])
        orig-lang    @(rf/subscribe [::dub-subs/original-language])
        existing     (filter (fn [{:keys [code]}]
                               (and (not= code orig-lang)
                                    (contains? statuses code)))
                             dub-events/dub-languages)
        available    (filter (fn [{:keys [code]}]
                               (and (not= code orig-lang)
                                    (not (contains? statuses code))))
                             dub-events/dub-languages)
        in-flight    (filter (fn [{:keys [code]}]
                               (#{:pending :processing} (:status (get statuses code))))
                             existing)]
    (when (or (seq existing) (seq available))
      [:div.dub-section
       ;; Chips row: existing + available (when picker open) + "Dub in…" toggle
       [:div.dub-chips-row
        ;; Existing language chips
        (for [{:keys [code name]} existing]
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
             (str/upper-case code)]))

        ;; Available language chips — inline when picker is open
        (when picker-open?
          (for [{:keys [code name]} available]
            [:button.dub-lang-chip.dub-lang-chip--add
             {:key      code
              :on-click #(do (rf/dispatch [::dub-events/toggle-picker])
                             (rf/dispatch [::dub-events/language-tapped episode-id code]))}
             (str "+ " name)]))

        ;; "Dub in…" / close toggle button
        (when (seq available)
          [:button.dub-add-btn
           {:on-click #(rf/dispatch [::dub-events/toggle-picker])}
           (if picker-open? "✕" "🎙 Dub in…")])]

       ;; Progress bar — shown for each in-flight dub
       (for [{:keys [code name]} in-flight]
         (let [lang-state (get statuses code)
               step       (:step lang-state)
               synth-pct  (:synth-pct lang-state)
               label      (str (str/upper-case code) " — " (step->label step)
                               (when (and (= step "synthesizing") synth-pct)
                                 (str " " synth-pct "%")))]
           [:div.dub-progress
            {:key code}
            [:div.dub-progress-track
             [:div.dub-progress-fill {:style {:transform (str "scaleX(" (step->progress step) ")")}}]]
            [:span.dub-progress-label label]]))

       ;; Active-dub controls shown below the chips row
       (when active
         (let [lang-state  (get statuses active)
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
               [:p.dub-translation-text translation]])]))])))
