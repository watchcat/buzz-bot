(ns buzz-bot.smoke-test
  (:require [cljs.test :refer [deftest is]]))

(deftest harness-runs
  (is (= 2 (+ 1 1))))
