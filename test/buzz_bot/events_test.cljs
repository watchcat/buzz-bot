(ns buzz-bot.events-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.events :as events]))

(deftest dubbed-fetch-skips-when-loaded-and-not-forced
  ;; Preserves the lazy-cache behaviour: navigating to Inbox a second time
  ;; must NOT refetch.
  (is (= {} (events/dubbed-fetch {:inbox-dubbed {:loaded? true}} false))))

(deftest dubbed-fetch-issues-request-when-not-loaded
  (let [fx (events/dubbed-fetch {:inbox-dubbed {:loaded? false}} false)]
    (is (contains? fx :buzz-bot.fx/http-fetch))
    (is (= "/inbox/dubbed" (get-in fx [:buzz-bot.fx/http-fetch :url])))
    (is (true? (get-in fx [:db :inbox-dubbed :loading?])))))

(deftest dubbed-fetch-force-overrides-loaded-guard
  ;; The ↻ button and dub-complete path pass force? = true to bypass the guard.
  (let [fx (events/dubbed-fetch {:inbox-dubbed {:loaded? true}} true)]
    (is (contains? fx :buzz-bot.fx/http-fetch))
    (is (= [:buzz-bot.events/inbox-dubbed-loaded]
           (get-in fx [:buzz-bot.fx/http-fetch :on-ok])))))
