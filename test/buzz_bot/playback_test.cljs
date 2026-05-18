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

(deftest should-save-progress?-test
  (testing "trustworthy when not recovering, not seeking, readyState >= 2"
    (is (true? (pb/should-save-progress?
                 {:recovering? false :ready-state 2 :seeking? false})))
    (is (true? (pb/should-save-progress?
                 {:recovering? false :ready-state 4 :seeking? false}))))
  (testing "suppressed during reload (recovering?)"
    (is (false? (pb/should-save-progress?
                  {:recovering? true :ready-state 4 :seeking? false}))))
  (testing "suppressed while seeking"
    (is (false? (pb/should-save-progress?
                  {:recovering? false :ready-state 4 :seeking? true}))))
  (testing "suppressed when readyState below HAVE_CURRENT_DATA (covers .load() reset)"
    (is (false? (pb/should-save-progress?
                  {:recovering? false :ready-state 1 :seeking? false})))
    (is (false? (pb/should-save-progress?
                  {:recovering? false :ready-state 0 :seeking? false}))))
  (testing "nil readyState treated as untrustworthy"
    (is (false? (pb/should-save-progress?
                  {:recovering? false :ready-state nil :seeking? false})))))
