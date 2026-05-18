(ns buzz-bot.playback-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.playback :as pb]))

(deftest resume-start-test
  (testing "completed episode restarts from 0 (decision 1)"
    (is (= 0 (pb/resume-start true 1234))))
  (testing "in-progress episode resumes at saved position"
    (is (= 600 (pb/resume-start false 600))))
  (testing "opened but not advanced (progress=0, not completed) -> 0"
    (is (= 0 (pb/resume-start false 0))))
  (testing "missing/nil progress -> 0"
    (is (= 0 (pb/resume-start false nil)))
    (is (= 0 (pb/resume-start nil nil))))
  (testing "completed wins even if progress present"
    (is (= 0 (pb/resume-start true 999)))))
