(ns buzz-bot.tag-cloud-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.tag-cloud :as tc]))

(deftest quartile-thresholds-evenly-distributed-test
  (testing "8 evenly-spaced counts → quartile cutoffs at sorted[2,4,6]"
    ;; ⌊0.25·8⌋=2 → 3; ⌊0.50·8⌋=4 → 5; ⌊0.75·8⌋=6 → 7
    (is (= [3 5 7] (tc/quartile-thresholds [1 2 3 4 5 6 7 8])))))

(deftest quartile-thresholds-all-equal-test
  (testing "all counts identical → all thresholds identical"
    (is (= [5 5 5] (tc/quartile-thresholds [5 5 5 5])))))

(deftest quartile-thresholds-empty-test
  (testing "empty input → safe degenerate [0 0 0]"
    (is (= [0 0 0] (tc/quartile-thresholds [])))))

(deftest quartile-thresholds-input-order-irrelevant-test
  (testing "shuffled input yields same thresholds as sorted input"
    (is (= (tc/quartile-thresholds [1 2 3 4 5 6 7 8])
           (tc/quartile-thresholds [8 3 1 6 4 7 2 5])))))

(deftest tag-style-top-tier-test
  (testing "count >= q3 → top tier (800/1.0)"
    (let [s (tc/tag-style 50 [10 20 40])]
      (is (= 800 (:font-weight s)))
      (is (= 1.0 (:opacity s))))))

(deftest tag-style-third-tier-test
  (testing "q2 <= count < q3 → 700/0.9"
    (let [s (tc/tag-style 25 [10 20 40])]
      (is (= 700 (:font-weight s)))
      (is (= 0.9 (:opacity s))))))

(deftest tag-style-second-tier-test
  (testing "q1 <= count < q2 → 500/0.7"
    (let [s (tc/tag-style 15 [10 20 40])]
      (is (= 500 (:font-weight s)))
      (is (= 0.7 (:opacity s))))))

(deftest tag-style-bottom-tier-test
  (testing "count < q1 → bottom tier (400/0.5)"
    (let [s (tc/tag-style 5 [10 20 40])]
      (is (= 400 (:font-weight s)))
      (is (= 0.5 (:opacity s))))))

(deftest tag-style-boundary-inclusive-test
  (testing "count equal to a threshold lands in the higher tier"
    (is (= 500 (:font-weight (tc/tag-style 10 [10 20 40]))))
    (is (= 700 (:font-weight (tc/tag-style 20 [10 20 40]))))
    (is (= 800 (:font-weight (tc/tag-style 40 [10 20 40]))))))

(deftest tag-style-no-font-size-test
  (testing "font-size is intentionally absent (CSS-controlled)"
    (is (nil? (:font-size (tc/tag-style 5 [10 20 40]))))))

(deftest tag-style-monotonic-test
  (testing "weight is non-decreasing as count rises through the tiers"
    (let [ts [10 20 40]
          ws (map #(:font-weight (tc/tag-style % ts)) [5 15 25 50])]
      (is (apply <= ws))))
  (testing "opacity is non-decreasing as count rises through the tiers"
    (let [ts [10 20 40]
          os (map #(:opacity (tc/tag-style % ts)) [5 15 25 50])]
      (is (apply <= os)))))
