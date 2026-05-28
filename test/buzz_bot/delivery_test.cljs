(ns buzz-bot.delivery-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.delivery :as d]))

(deftest next-mode-cycles-off-notify-mp3-off-for-premium
  (is (= :notify (d/next-mode :off    true)))
  (is (= :mp3    (d/next-mode :notify true)))
  (is (= :off    (d/next-mode :mp3    true))))

(deftest next-mode-skips-mp3-for-non-premium
  ;; cycle shortens to off ↔ notify so tap-cycle never lands on mp3
  ;; without entitlement (matches the Send-to-Chat premium gate).
  (is (= :notify (d/next-mode :off    false)))
  (is (= :off    (d/next-mode :notify false)))
  ;; if state somehow holds :mp3 (e.g. premium expired), cycle back to off
  (is (= :off    (d/next-mode :mp3    false))))

(deftest next-mode-defaults-unknown-to-off
  (is (= :off (d/next-mode nil           true)))
  (is (= :off (d/next-mode nil           false)))
  (is (= :off (d/next-mode :anything-else true))))

(deftest mode-label-matches-spec
  (is (= "In-app only" (d/mode->label :off)))
  (is (= "Notify me"   (d/mode->label :notify)))
  (is (= "Send MP3"    (d/mode->label :mp3))))

(deftest mode-icon-key-matches-spec
  (is (= :bell-off (d/mode->icon-key :off)))
  (is (= :bell     (d/mode->icon-key :notify)))
  (is (= :mp3      (d/mode->icon-key :mp3))))

(deftest new?-true-for-id-in-set-false-otherwise
  (is (true?  (d/new? #{1 2 3} 2)))
  (is (false? (d/new? #{1 2 3} 4)))
  (is (false? (d/new? #{} 1)))
  (is (false? (d/new? nil 1))))

(deftest new?-coerces-id-to-number
  ;; Server returns numeric ids; UI may pass them through as strings via :data-* attrs.
  (is (true? (d/new? #{123} "123")))
  (is (true? (d/new? #{123} 123))))
