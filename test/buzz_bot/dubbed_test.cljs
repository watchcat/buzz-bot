(ns buzz-bot.dubbed-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.events :as e]))

(deftest dubbed-langs-qs-test
  (testing "empty set → no query string"
    (is (= "" (e/dubbed-langs-qs #{} "?"))))
  (testing "sorted, comma-joined, with the given separator"
    (is (= "?langs=en,ru" (e/dubbed-langs-qs #{"ru" "en"} "?")))
    (is (= "&langs=de,en,ru" (e/dubbed-langs-qs #{"ru" "en" "de"} "&"))))
  (testing "single language"
    (is (= "?langs=ru" (e/dubbed-langs-qs #{"ru"} "?")))))
