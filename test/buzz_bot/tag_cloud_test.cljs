(ns buzz-bot.tag-cloud-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.tag-cloud :as tc]))

(deftest tag-style-min-count-test
  (testing "min count → smallest size, lowest opacity, lighter weight"
    (let [s (tc/tag-style 1 1 100)]
      (is (= 13.0 (:font-size s)))
      (is (= 400 (:font-weight s)))
      ;; opacity = 0.45 + 0 * 0.55 = 0.45
      (is (< 0.449 (:opacity s) 0.451)))))

(deftest tag-style-max-count-test
  (testing "max count → largest size, full opacity, heavier weight"
    (let [s (tc/tag-style 100 1 100)]
      (is (= 32.0 (:font-size s)))
      (is (= 600 (:font-weight s)))
      ;; opacity = 0.45 + 1 * 0.55 = 1.0
      (is (< 0.999 (:opacity s) 1.001)))))

(deftest tag-style-all-equal-test
  (testing "all tags same count → ratio 0.5 → middle values"
    (let [s (tc/tag-style 5 5 5)]
      ;; 13 + 0.5 * 19 = 22.5
      (is (= 22.5 (:font-size s)))
      ;; ratio 0.5 is < 0.6 threshold, so 400
      (is (= 400 (:font-weight s)))
      ;; opacity = 0.45 + 0.5 * 0.55 = 0.725
      (is (< 0.724 (:opacity s) 0.726)))))

(deftest tag-style-weight-threshold-test
  (testing "weight = 400 below ratio 0.6"
    ;; count=5 in [1, 100] → log(5)/log(100) ≈ 0.35 → < 0.6 → 400
    (is (= 400 (:font-weight (tc/tag-style 5 1 100)))))
  (testing "weight = 600 at or above ratio 0.6"
    ;; count=20 in [1, 100] → log(20)/log(100) ≈ 0.65 → ≥ 0.6 → 600
    (is (= 600 (:font-weight (tc/tag-style 20 1 100))))))

(deftest tag-style-monotonic-test
  (testing "size strictly increases with count over a typical range"
    (let [sizes (map #(:font-size (tc/tag-style % 1 100)) [1 5 10 25 50 100])]
      (is (apply < sizes))))
  (testing "opacity strictly increases with count over a typical range"
    (let [ops (map #(:opacity (tc/tag-style % 1 100)) [1 5 10 25 50 100])]
      (is (apply < ops)))))
