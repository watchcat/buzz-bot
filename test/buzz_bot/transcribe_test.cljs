;; test/buzz_bot/transcribe_test.cljs
(ns buzz-bot.transcribe-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.events :as e]))

(deftest transcribe-url-test
  (testing "builds the transcribe endpoint for an episode"
    (is (= "/episodes/456/transcribe" (e/transcribe-url 456)))))
