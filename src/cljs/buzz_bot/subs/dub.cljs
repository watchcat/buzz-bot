(ns buzz-bot.subs.dub
  (:require [re-frame.core :as rf]))

(rf/reg-sub ::dub-state    (fn [db _] (:dub db)))
(rf/reg-sub ::dub-status   :<- [::dub-state] (fn [d _] (:status d)))
(rf/reg-sub ::dub-r2-url      :<- [::dub-state] (fn [d _] (:r2-url d)))
(rf/reg-sub ::dub-translation :<- [::dub-state] (fn [d _] (:translation d)))
(rf/reg-sub ::dub-error    :<- [::dub-state] (fn [d _] (:error d)))
(rf/reg-sub ::dub-language :<- [::dub-state] (fn [d _] (:language d)))
(rf/reg-sub ::dub-picker-open? :<- [::dub-state] (fn [d _] (:picker-open? d)))
(rf/reg-sub ::preferred-dub-language :<- [::dub-state] (fn [d _] (:preferred-language d)))
