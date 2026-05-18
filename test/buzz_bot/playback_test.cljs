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

(deftest should-skip-reload?-test
  (testing "skip ONLY when reopening the actively-playing episode"
    (is (true?  (pb/should-skip-reload? {:same-episode? true  :was-playing? true}))))
  (testing "same episode but paused -> reload (the bug-1 fix)"
    (is (false? (pb/should-skip-reload? {:same-episode? true  :was-playing? false}))))
  (testing "different episode -> never skip"
    (is (false? (pb/should-skip-reload? {:same-episode? false :was-playing? true})))
    (is (false? (pb/should-skip-reload? {:same-episode? false :was-playing? false}))))
  (testing "nil inputs are falsey, not exceptions"
    (is (false? (pb/should-skip-reload? {:same-episode? nil :was-playing? nil})))))
