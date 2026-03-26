(ns buzz-bot.subs.dub
  (:require [re-frame.core :as rf]))

(rf/reg-sub ::dub-state        (fn [db _] (:dub db)))
(rf/reg-sub ::statuses         :<- [::dub-state] (fn [d _] (:statuses d)))
(rf/reg-sub ::active-lang      :<- [::dub-state] (fn [d _] (:active-lang d)))
(rf/reg-sub ::send-error       :<- [::dub-state] (fn [d _] (:send-error d)))
(rf/reg-sub ::picker-open?     :<- [::dub-state] (fn [d _] (:picker-open? d)))
(rf/reg-sub ::original-language (fn [db _] (get-in db [:player :data :original_language])))
(rf/reg-sub ::lang-state
  :<- [::statuses]
  (fn [statuses [_ lang]] (get statuses lang)))
