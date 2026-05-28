(ns buzz-bot.inbox-dubbed-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.inbox-dubbed :as id]))

(defn- ts [iso] (.getTime (js/Date. iso)))

(deftest fmt-relative-time-handles-seconds-minutes
  (let [now (ts "2026-05-28T12:00:00Z")]
    (is (= "just now" (id/fmt-relative-time (ts "2026-05-28T11:59:30Z") now)))
    (is (= "3m ago"   (id/fmt-relative-time (ts "2026-05-28T11:57:00Z") now)))
    (is (= "59m ago"  (id/fmt-relative-time (ts "2026-05-28T11:01:00Z") now)))))

(deftest fmt-relative-time-handles-hours
  (let [now (ts "2026-05-28T12:00:00Z")]
    (is (= "1h ago"  (id/fmt-relative-time (ts "2026-05-28T11:00:00Z") now)))
    (is (= "5h ago"  (id/fmt-relative-time (ts "2026-05-28T07:00:00Z") now)))
    (is (= "23h ago" (id/fmt-relative-time (ts "2026-05-27T13:00:00Z") now)))))

(deftest fmt-relative-time-handles-days
  (let [now (ts "2026-05-28T12:00:00Z")]
    (is (= "1d ago" (id/fmt-relative-time (ts "2026-05-27T12:00:00Z") now)))
    (is (= "6d ago" (id/fmt-relative-time (ts "2026-05-22T12:00:00Z") now)))))

(deftest fmt-relative-time-handles-weeks-and-beyond
  (let [now (ts "2026-05-28T12:00:00Z")]
    (is (= "1w ago" (id/fmt-relative-time (ts "2026-05-21T12:00:00Z") now)))
    (is (= "4w ago" (id/fmt-relative-time (ts "2026-04-30T12:00:00Z") now)))
    ;; > 8 weeks falls back to a date string
    (let [out (id/fmt-relative-time (ts "2026-01-01T12:00:00Z") now)]
      (is (or (= "Jan 1" out) (= "Jan 1, 2026" out))))))

(deftest fmt-langflow-uppercases-and-arrows
  (is (= "NL → EN" (id/fmt-langflow "nl" "en")))
  (is (= "RU → EN" (id/fmt-langflow "ru" "en")))
  (is (= "DE → FR" (id/fmt-langflow "de" "fr"))))

(deftest fmt-langflow-falls-back-when-source-missing
  ;; When source_lang is nil (the dub pipeline didn't write one), show
  ;; just the target language uppercased — better than rendering "→ EN".
  (is (= "EN" (id/fmt-langflow nil "en")))
  (is (= "RU" (id/fmt-langflow ""  "ru"))))
