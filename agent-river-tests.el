;;; agent-river-tests.el --- Tests for the focus fold -*- lexical-binding: t; -*-

;;; Commentary:

;; The fold is the part of agent-river that is real logic rather than string
;; formatting: state transitions, streak accounting, thresholds, liveness.
;; It is also deterministic given an event order, which makes it cheap to
;; test -- no Emacs frame, no hooks, no live session.
;;
;; Run:
;;   emacs -Q --batch -l agent-river.el -l agent-river-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-river)

(defmacro agent-river-test--with-session (var &rest body)
  "Bind VAR to a fresh state in an isolated registry and run BODY."
  (declare (indent 1))
  `(let ((agent-river-registry (make-hash-table :test 'equal))
         (agent-river-auto-display nil))
     (let ((,var (agent-river-state "s1" "alpha")))
       ,@body)))

(defun agent-river-test--fail (state n &optional tool)
  "Fold N failures of TOOL into STATE."
  (dotimes (_ n)
    (agent-river-fold state (list :kind "fail" :tool (or tool "Bash") :ms 10))))


;;; Folding

(ert-deftest agent-river-test-prompt-starts-a-task ()
  (agent-river-test--with-session state
    (agent-river-test--fail state 2)
    (agent-river-fold state '(:kind "act" :tool "Edit" :file "a.el"))
    (agent-river-fold state '(:kind "prompt" :text "do the thing"))
    (should (equal (agent-river-state-task state) "do the thing"))
    ;; A new task starts clean: neither the step count nor a failure streak
    ;; from the previous task may leak across the boundary.
    (should (= (agent-river-state-steps state) 0))
    (should (= (agent-river-state-fail-streak state) 0))
    (should (null (agent-river-state-step state)))))

(ert-deftest agent-river-test-act-opens-a-step-and-touches ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :tool "Edit" :file "a.el"))
    (should (equal (plist-get (agent-river-state-step state) :tool) "Edit"))
    (should (= (agent-river-state-steps state) 1))
    (should (= 1 (plist-get (gethash "a.el" (agent-river-state-artifacts state))
                            :touches)))))

(ert-deftest agent-river-test-touches-accumulate-per-path ()
  (agent-river-test--with-session state
    (dotimes (_ 3) (agent-river-fold state '(:kind "act" :file "a.el")))
    (agent-river-fold state '(:kind "act" :file "b.el"))
    (should (= 3 (plist-get (gethash "a.el" (agent-river-state-artifacts state))
                            :touches)))
    (should (= 1 (plist-get (gethash "b.el" (agent-river-state-artifacts state))
                            :touches)))))

(ert-deftest agent-river-test-act-without-file-touches-nothing ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :tool "Bash"))
    (should (= 0 (hash-table-count (agent-river-state-artifacts state))))))

(ert-deftest agent-river-test-think-records-and-clears ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :tool "Bash"))
    (agent-river-fold state '(:kind "think" :tool "Bash" :ms 250))
    (let ((entry (gethash "Bash" (agent-river-state-tools state))))
      (should (= (plist-get entry :count) 1))
      (should (= (plist-get entry :ms) 250))
      (should (= (plist-get entry :failures) 0)))
    (should (null (agent-river-state-step state)))))

(ert-deftest agent-river-test-success-resets-the-streak ()
  (agent-river-test--with-session state
    (agent-river-test--fail state 5)
    (should (= (agent-river-state-fail-streak state) 5))
    (agent-river-fold state '(:kind "think" :tool "Bash" :ms 10))
    (should (= (agent-river-state-fail-streak state) 0))
    (should (null (agent-river-state-fail-tools state)))))

(ert-deftest agent-river-test-failures-count-per-tool ()
  (agent-river-test--with-session state
    (agent-river-test--fail state 2 "Edit")
    (agent-river-test--fail state 1 "Bash")
    (should (= 2 (cdr (assoc "Edit" (agent-river-state-fail-tools state)))))
    (should (= 1 (cdr (assoc "Bash" (agent-river-state-fail-tools state)))))
    (should (= 2 (plist-get (gethash "Edit" (agent-river-state-tools state))
                            :failures)))))


;;; Signals

(ert-deftest agent-river-test-signal-waits-for-the-threshold ()
  (agent-river-test--with-session state
    (let ((agent-river-fail-streak-threshold 3))
      (agent-river-test--fail state 1)
      (should-not (agent-river--signal state))
      (agent-river-test--fail state 1)
      (should-not (agent-river--signal state))
      (agent-river-test--fail state 1)
      (should (agent-river--signal state)))))

(ert-deftest agent-river-test-signal-is-throttled-after-firing ()
  (agent-river-test--with-session state
    (let ((agent-river-fail-streak-threshold 3)
          (agent-river-fail-streak-repeat 3))
      (agent-river-test--fail state 3)
      (should (agent-river--signal state))
      ;; A signal on every subsequent failure would stop being a signal.
      (agent-river-test--fail state 1)
      (should-not (agent-river--signal state))
      (agent-river-test--fail state 1)
      (should-not (agent-river--signal state))
      (agent-river-test--fail state 1)
      (should (agent-river--signal state)))))

(ert-deftest agent-river-test-signal-is-a-single-line ()
  (agent-river-test--with-session state
    (let ((agent-river-fail-streak-threshold 1))
      (agent-river-test--fail state 1)
      (let ((signal (agent-river--signal state)))
        (should signal)
        ;; The hook reads this back through emacsclient and parses prin1's
        ;; output as JSON; an embedded newline would break that silently.
        ;; Only :text travels -- the :id beside it is bookkeeping.
        (should-not (string-match-p "\n" (plist-get signal :text)))))))

(ert-deftest agent-river-test-new-task-clears-only-the-task-tally ()
  (agent-river-test--with-session state
    (dotimes (_ 3) (agent-river-fold state '(:kind "act" :file "a.el")))
    (should (string-match-p "3 touches" (agent-river--hottest state)))
    (should (string-match-p "3 touches" (agent-river--hottest state 'session)))
    (agent-river-fold state '(:kind "prompt" :text "next"))
    ;; The task frame restarts; the session frame is what the contention
    ;; query reads, and must survive a change of subject.
    (should-not (agent-river--hottest state))
    (should (string-match-p "3 touches" (agent-river--hottest state 'session)))))

(ert-deftest agent-river-test-report-separates-the-two-frames ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (dotimes (_ 2)
      (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                   :file "a.el" :detail "Edit a.el")))
    (agent-river-observe '(:kind "prompt" :session "s1" :label "repo"
                                 :text "second task" :detail "second task"))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                 :file "b.el" :detail "Edit b.el"))
    (let ((report (agent-river-report "s1")))
      (should (= (plist-get report :task-steps) 1))
      (should-not (plist-get report :task-hottest))
      (should (string-match-p "a\\.el" (plist-get report :session-hottest))))))

(ert-deftest agent-river-test-touching-survives-a-new-task ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                 :file "shared.el" :detail "Edit"))
    (agent-river-observe '(:kind "prompt" :session "s1" :label "repo"
                                 :text "new" :detail "new"))
    (should (= 1 (length (agent-river-touching "shared.el"))))))

(ert-deftest agent-river-test-panel-reports-what-matters ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "prompt" :session "s1" :label "repo"
                                 :text "fix the queue bug" :detail "fix"))
    (dotimes (_ 2)
      (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                   :file "mpv.el" :detail "Edit")))
    (let ((panel (substring-no-properties
                  (agent-river--panel (gethash "s1" agent-river-registry)))))
      (should (string-match-p "repo" panel))
      (should (string-match-p "fix the queue bug" panel))
      (should (string-match-p "2 steps" panel))
      (should-not (string-match-p "1 steps" panel))
      (should (string-match-p "mpv\\.el (2 touches)" panel))
      ;; Nothing is failing, so the panel must not carry a failure clause.
      (should-not (string-match-p "failing" panel)))))

(ert-deftest agent-river-test-a-broken-fold-is-reported-not-swallowed ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (cl-letf (((symbol-function 'agent-river-fold)
               (lambda (&rest _) (error "simulated slot mismatch"))))
      (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                   :detail "Edit a.el")))
    ;; A fold that dies must leave a visible trace: this exact failure once
    ;; stopped the display with no error anywhere.
    (with-current-buffer (agent-river--buffer)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "fold failed" text))
        (should (string-match-p "agent-river-reset" text))))))

(ert-deftest agent-river-test-panel-surfaces-a-live-failure-run ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (dotimes (_ 2)
      (agent-river-observe '(:kind "fail" :session "s1" :label "repo"
                                   :tool "Bash" :detail "Bash")))
    (should (string-match-p
             "2 failing"
             (substring-no-properties
              (agent-river--panel (gethash "s1" agent-river-registry)))))))

(ert-deftest agent-river-test-panel-stays-on-the-parent ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Agent"))
    (agent-river-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Read"))
    ;; A subagent acting must not turn into a line of its own; it is counted
    ;; on the parent, so the session stays the subject.
    (let ((block (substring-no-properties (agent-river--panel-block))))
      (should (string-match-p "repo" block))
      (should (string-match-p "1 subagent" block))
      (should-not (string-match-p "Explore" block)))))

(ert-deftest agent-river-test-block-gives-each-session-a-line ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    (agent-river-observe '(:kind "act" :session "s2" :label "repo" :detail "Read"))
    (let ((lines (split-string (substring-no-properties
                                (agent-river--panel-block))
                               "\n" t)))
      ;; One line per session, then the rule dividing block from log.
      (should (= (length lines) 3))
      (should (string-prefix-p "──" (nth 2 lines)))
      ;; Same directory, so the labels would otherwise be identical and the
      ;; two agents indistinguishable.
      (should (string-match-p "repo<2>" (nth 1 lines))))))

(ert-deftest agent-river-test-block-drops-a-session-that-went-quiet ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        (agent-river-session-ttl 300))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    (agent-river-observe '(:kind "act" :session "s2" :label "other" :detail "Read"))
    (setf (agent-river-state-last-seen (gethash "s2" agent-river-registry))
          (time-subtract (current-time) 600))
    (let ((block (substring-no-properties (agent-river--panel-block))))
      (should (string-match-p "repo" block))
      (should-not (string-match-p "other" block)))))

(ert-deftest agent-river-test-newest-event-is-at-the-top ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "first"))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "second"))
    (with-current-buffer (agent-river--buffer)
      (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
             (lines (split-string text "\n" t)))
        ;; State block on top, then the log newest-first underneath.
        (should (string-match-p "repo" (nth 0 lines)))
        (should (string-prefix-p "──" (nth 1 lines)))
        (should (string-match-p "second" (nth 2 lines)))
        (should (string-match-p "first" (nth 3 lines)))))))

(ert-deftest agent-river-test-trim-drops-the-oldest ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        (agent-river-max-entries 3))
    (dolist (n '("one" "two" "three" "four"))
      (agent-river-observe (list :kind "act" :session "s1" :label "repo"
                                 :detail n)))
    (with-current-buffer (agent-river--buffer)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "four" text))
        ;; Oldest now sits at the bottom, so trimming works from the tail.
        (should-not (string-match-p "one" text))))))

(ert-deftest agent-river-test-block-is-rewritten-not-appended ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (dotimes (_ 3)
      (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                   :detail "Edit a.el")))
    (with-current-buffer (agent-river--buffer)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        ;; One block at the foot, however many events went through -- the
        ;; separator is what would multiply if it were appended each time.
        (should (= 1 (length (seq-filter
                              (lambda (line) (string-prefix-p "──" line))
                              (split-string text "\n")))))))))

(ert-deftest agent-river-test-hottest-needs-more-than-one-touch ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :file "a.el"))
    (should-not (agent-river--hottest state))
    (agent-river-fold state '(:kind "act" :file "a.el"))
    (should (string-match-p "a\\.el" (agent-river--hottest state)))))


;;; Phase

(defun agent-river-test--acts (state n tool &optional detail)
  "Fold N act events running TOOL with DETAIL into STATE."
  (dotimes (_ n)
    (agent-river-fold state (list :kind "act" :tool tool :detail detail))))

(ert-deftest agent-river-test-phase-abstains-until-there-is-a-tendency ()
  (agent-river-test--with-session state
    (should-not (agent-river--phase state))
    (agent-river-test--acts state 1 "Read")
    ;; One classified step is noise, not a phase.
    (should-not (agent-river--phase state))
    (agent-river-test--acts state 1 "Read")
    (should (equal (agent-river--phase state) "exploring"))))

(ert-deftest agent-river-test-phase-follows-the-dominant-tool ()
  (agent-river-test--with-session state
    (agent-river-test--acts state 4 "Read")
    (should (equal (agent-river--phase state) "exploring"))
    (agent-river-test--acts state 5 "Edit")
    (should (equal (agent-river--phase state) "editing"))))

(ert-deftest agent-river-test-phase-recognises-verification-in-a-shell-call ()
  (agent-river-test--with-session state
    (agent-river-test--acts state 2 "Bash" "Run the test suite: make test")
    (should (equal (agent-river--phase state) "verifying"))))

(ert-deftest agent-river-test-phase-ignores-unclassifiable-shell-calls ()
  (agent-river-test--with-session state
    ;; Shell is used for everything; guessing from it would be worse than
    ;; abstaining, so an ordinary command must not create a phase.
    (agent-river-test--acts state 5 "Bash" "git status")
    (should-not (agent-river--phase state))))

(ert-deftest agent-river-test-phase-verify-pattern-is-shell-only ()
  (agent-river-test--with-session state
    ;; Found live: reading files called Cask and Makefile classified one as
    ;; verifying and one as exploring, so neither reached a majority and the
    ;; panel showed no phase at all.  A file name is not a build step.
    (agent-river-test--acts state 1 "Read" "Cask")
    (agent-river-test--acts state 1 "Read" "Makefile")
    (should (equal (agent-river--phase state) "exploring"))))

(ert-deftest agent-river-test-phase-blocked-overrides-the-tool-mix ()
  (agent-river-test--with-session state
    (agent-river-test--acts state 5 "Edit")
    (should (equal (agent-river--phase state) "editing"))
    (agent-river-test--fail state 2)
    (should (equal (agent-river--phase state) "blocked"))
    (agent-river-fold state '(:kind "think" :tool "Edit" :ms 5))
    (should (equal (agent-river--phase state) "editing"))))

(ert-deftest agent-river-test-phase-says-waiting-once-the-turn-ends ()
  (agent-river-test--with-session state
    (agent-river-test--acts state 3 "Read")
    (should (equal (agent-river--phase state) "exploring"))
    (agent-river-fold state '(:kind "idle"))
    ;; The tool window still holds those reads.  Reporting "exploring" over
    ;; a log line that says the turn is over describes what the work was
    ;; while presenting it as what the work is.
    (should (equal (agent-river--phase state) "waiting"))))

(ert-deftest agent-river-test-waiting-outranks-blocked ()
  (agent-river-test--with-session state
    (agent-river-test--fail state 3)
    (should (equal (agent-river--phase state) "blocked"))
    (agent-river-fold state '(:kind "idle"))
    ;; A turn that ended badly is still a turn that ended.
    (should (equal (agent-river--phase state) "waiting"))))

(ert-deftest agent-river-test-acting-again-ends-waiting ()
  (agent-river-test--with-session state
    (agent-river-test--acts state 3 "Edit")
    (agent-river-fold state '(:kind "idle"))
    (should (equal (agent-river--phase state) "waiting"))
    (agent-river-test--acts state 1 "Edit")
    (should (equal (agent-river--phase state) "editing"))))

(ert-deftest agent-river-test-a-new-prompt-ends-waiting ()
  (agent-river-test--with-session state
    (agent-river-test--acts state 3 "Edit")
    (agent-river-fold state '(:kind "idle"))
    (agent-river-fold state '(:kind "prompt" :text "next"))
    (should-not (agent-river-state-idle state))))

(ert-deftest agent-river-test-phase-window-forgets-old-steps ()
  (agent-river-test--with-session state
    (let ((agent-river-phase-window 4))
      (agent-river-test--acts state 4 "Read")
      (should (equal (agent-river--phase state) "exploring"))
      (agent-river-test--acts state 4 "Edit")
      ;; The reads have fallen out of the window entirely.
      (should (equal (agent-river--phase state) "editing")))))


;;; Stated intent

(ert-deftest agent-river-test-intent-is-recorded-with-its-context ()
  (agent-river-test--with-session state
    (agent-river-test--acts state 3 "Edit" "a.el")
    (agent-river-fold state '(:kind "intent" :text "narrowing the stale queue"))
    (should (equal (agent-river-state-intent state) "narrowing the stale queue"))
    (should (= (agent-river-state-intent-step state) 3))
    (should-not (agent-river--intent-stale-p state))))

(ert-deftest agent-river-test-intent-goes-stale-after-enough-steps ()
  (agent-river-test--with-session state
    (let ((agent-river-intent-stale-steps 4))
      (agent-river-fold state '(:kind "intent" :text "reading the mpv layer"))
      (agent-river-test--acts state 4 "Read")
      (should-not (agent-river--intent-stale-p state))
      (agent-river-test--acts state 1 "Read")
      ;; The agent stopped narrating; that is visible rather than hidden.
      (should (agent-river--intent-stale-p state)))))

(ert-deftest agent-river-test-intent-goes-stale-when-the-work-moves ()
  (agent-river-test--with-session state
    (dotimes (_ 2) (agent-river-fold state '(:kind "act" :file "a.el")))
    (agent-river-fold state '(:kind "intent" :text "fixing a.el"))
    (should-not (agent-river--intent-stale-p state))
    (dotimes (_ 3) (agent-river-fold state '(:kind "act" :file "b.el")))
    ;; Measured state contradicting the claim is the whole point.
    (should (agent-river--intent-stale-p state))))

(ert-deftest agent-river-test-gaining-a-hottest-file-is-not-staleness ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "intent" :text "starting out"))
    (should-not (agent-river--hottest state))
    (dotimes (_ 2) (agent-river-fold state '(:kind "act" :file "a.el")))
    ;; Going from no hottest file to having one is ordinary progress, not
    ;; evidence that the claim was abandoned.
    (should-not (agent-river--intent-stale-p state))))

(ert-deftest agent-river-test-a-new-task-drops-the-intent ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "intent" :text "old goal"))
    (agent-river-fold state '(:kind "prompt" :text "something else"))
    (should-not (agent-river-state-intent state))))

(ert-deftest agent-river-test-intent-never-feeds-a-signal ()
  (agent-river-test--with-session state
    (let ((agent-river-fail-streak-threshold 2))
      (agent-river-fold state '(:kind "intent" :text "everything is fine"))
      (agent-river-test--fail state 2)
      ;; A claim must not be able to talk the measured state out of a signal.
      (should (agent-river--signal state)))))

(ert-deftest agent-river-test-panel-marks-a-stale-claim ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        (agent-river-intent-stale-steps 2))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    (agent-river-set-intent "checking the render path" "s1")
    (let ((panel (substring-no-properties
                  (agent-river--panel (gethash "s1" agent-river-registry)))))
      (should (string-match-p "checking the render path" panel))
      (should-not (string-match-p "stale" panel)))
    (dotimes (_ 3)
      (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit")))
    (should (string-match-p
             "stale"
             (substring-no-properties
              (agent-river--panel (gethash "s1" agent-river-registry)))))))

(ert-deftest agent-river-test-report-marks-the-intent-as-claimed ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    (agent-river-set-intent "a claim" "s1")
    (let ((report (agent-river-report "s1")))
      ;; The key name has to say it is self-reported: this state is fed back
      ;; to the agent, and a claim read as a measurement has no ground truth.
      (should (equal (plist-get report :claimed-intent) "a claim"))
      (should-not (plist-get report :claimed-intent-stale)))))


;;; Task history

(ert-deftest agent-river-test-finished-tasks-are-archived ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "prompt" :text "first task"))
    (agent-river-test--acts state 3 "Edit")
    (agent-river-test--fail state 2)
    (agent-river-fold state '(:kind "prompt" :text "second task"))
    (let ((old (car (agent-river-state-tasks state))))
      (should (equal (plist-get old :task) "first task"))
      (should (= (plist-get old :steps) 3))
      (should (= (plist-get old :failures) 2)))
    ;; The new task starts from zero on both counters.
    (should (= (agent-river-state-steps state) 0))
    (should (= (agent-river-state-task-failures state) 0))))

(ert-deftest agent-river-test-first-prompt-archives-nothing ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "prompt" :text "only task"))
    (should-not (agent-river-state-tasks state))))

(ert-deftest agent-river-test-task-failures-outlive-the-streak ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "prompt" :text "t"))
    (agent-river-test--fail state 2)
    (agent-river-fold state '(:kind "think" :tool "Bash" :ms 5))
    (agent-river-test--fail state 1)
    ;; The streak resets on success; the task tally is what says how rough
    ;; the task has been overall.
    (should (= (agent-river-state-fail-streak state) 1))
    (should (= (agent-river-state-task-failures state) 3))))


;;; Reading the hook payload

(defun agent-river-test--payload (json)
  "Parse JSON the way the hook does."
  (json-parse-string json :object-type 'alist :null-object nil
                     :false-object nil))

(ert-deftest agent-river-test-squish-and-clip ()
  (should (equal (agent-river--squish "  make   test\n  --verbose ")
                 "make test --verbose"))
  (should (equal (agent-river--clip "abcdef" 3) "abc…"))
  (should (equal (agent-river--clip "abc" 3) "abc")))

(ert-deftest agent-river-test-rel-path ()
  (should (equal (agent-river--rel "/repo/sub/a.el" "/repo") "sub/a.el"))
  ;; Outside the session directory it becomes a bare name, so the same
  ;; logical file reached from two checkouts renders identically.
  (should (equal (agent-river--rel "/elsewhere/a.el" "/repo") "a.el"))
  (should (equal (agent-river--rel "/repo/a.el" "") "a.el")))

(ert-deftest agent-river-test-duration-format ()
  (should (equal (agent-river--dur 12) "12ms"))
  (should (equal (agent-river--dur 8432) "8.4s"))
  (should (equal (agent-river--dur 8000) "8s")))

(ert-deftest agent-river-test-detail-prefers-the-description ()
  (let ((payload (agent-river-test--payload
                  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make test\",\"description\":\"Run the suite\"}}")))
    ;; Bash and Task carry a human-written line; it reads better than the
    ;; shell it expands to.
    (should (equal (agent-river--detail "act" payload) "Bash  Run the suite"))))

(ert-deftest agent-river-test-detail-falls-back-through-the-ladder ()
  (should (equal (agent-river--detail
                  "act" (agent-river-test--payload
                         "{\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"defun foo\"}}"))
                 "Grep  defun foo"))
  (should (equal (agent-river--detail
                  "act" (agent-river-test--payload
                         "{\"tool_name\":\"TodoWrite\",\"tool_input\":{\"todos\":[1]}}"))
                 "TodoWrite  {\"todos\":[1]}"))
  (should (equal (agent-river--detail
                  "act" (agent-river-test--payload "{\"tool_name\":\"Nothing\"}"))
                 "Nothing")))

(ert-deftest agent-river-test-detail-marks-outcomes ()
  (should (equal (agent-river--detail
                  "think" (agent-river-test--payload
                           "{\"tool_name\":\"Bash\",\"duration_ms\":12,\"tool_response\":{\"interrupted\":false}}"))
                 "Bash ✓  12ms"))
  ;; An interrupted call must not claim success.
  (should (equal (agent-river--detail
                  "think" (agent-river-test--payload
                           "{\"tool_name\":\"Bash\",\"duration_ms\":2100,\"tool_response\":{\"interrupted\":true}}"))
                 "Bash ✗  2.1s"))
  ;; A failure line carries no inline marker: the kind renders ✗ already.
  (should (equal (agent-river--detail
                  "fail" (agent-river-test--payload
                          "{\"tool_name\":\"Edit\",\"duration_ms\":30}"))
                 "Edit  30ms")))

(ert-deftest agent-river-test-event-carries-structured-fields ()
  (let ((event (agent-river--event
                "act" (agent-river-test--payload
                       "{\"session_id\":\"s1\",\"cwd\":\"/home/x/repo\",\"agent_id\":\"a9\",\"agent_type\":\"Explore\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/home/x/repo/a.el\"}}"))))
    (should (equal (plist-get event :session) "s1"))
    (should (equal (plist-get event :label) "repo"))
    (should (equal (plist-get event :agent) "a9"))
    (should (equal (plist-get event :agent-type) "Explore"))
    (should (equal (plist-get event :file) "a.el"))
    (should (equal (plist-get event :detail) "Edit  a.el"))))

(ert-deftest agent-river-test-event-without-agent-is-a-root ()
  (let ((event (agent-river--event
                "act" (agent-river-test--payload
                       "{\"session_id\":\"s1\",\"cwd\":\"/repo\",\"tool_name\":\"Bash\"}"))))
    (should-not (plist-get event :agent))
    (should-not (plist-get event :file))))


;;; Reading the hook payload of another host

(ert-deftest agent-river-test-the-file-is-found-whatever-the-host-names-it ()
  ;; Gemini CLI's read_file says `absolute_path' and other tools say plain
  ;; `path'.  A name we did not know would not fail -- it would stop
  ;; counting files, which is the failure that must not be silent.
  (should (equal (plist-get
                  (agent-river--event
                   "act" (agent-river-test--payload
                          "{\"cwd\":\"/repo\",\"tool_name\":\"read_file\",\"tool_input\":{\"absolute_path\":\"/repo/a.el\"}}"))
                  :file)
                 "a.el"))
  (should (equal (plist-get
                  (agent-river--event
                   "act" (agent-river-test--payload
                          "{\"cwd\":\"/repo\",\"tool_name\":\"read\",\"tool_input\":{\"path\":\"/repo/b.el\"}}"))
                  :file)
                 "b.el"))
  ;; An empty string is not a path; it used to reach `--rel' as one.
  (should-not (plist-get
               (agent-river--event
                "act" (agent-river-test--payload
                       "{\"cwd\":\"/repo\",\"tool_input\":{\"file_path\":\"\"}}"))
               :file)))

(ert-deftest agent-river-test-a-failure-folds-as-one-without-its-own-event ()
  ;; Codex and Gemini CLI have no `PostToolUseFailure': the one post-tool
  ;; event fires either way, so the outcome has to be read off the
  ;; response or the failure streak never rises on those hosts.
  (dolist (response '("{\"error\":\"no such file\"}"
                      "{\"is_error\":true}"
                      "{\"isError\":true}"
                      "{\"success\":false}"
                      "{\"exit_code\":2}"))
    (should (equal (plist-get
                    (agent-river--event
                     "think" (agent-river-test--payload
                              (format "{\"tool_name\":\"shell\",\"tool_response\":%s}"
                                      response)))
                    :kind)
                   "fail")))
  ;; A call the user stopped is not the agent failing, and a tool that
  ;; says nothing about its outcome is taken at its word.
  (dolist (response '("{\"interrupted\":true}"
                      "{\"success\":true}"
                      "{\"exit_code\":0}"
                      "{\"stdout\":\"ok\"}"))
    (should (equal (plist-get
                    (agent-river--event
                     "think" (agent-river-test--payload
                              (format "{\"tool_name\":\"shell\",\"tool_response\":%s}"
                                      response)))
                    :kind)
                   "think"))))

(ert-deftest agent-river-test-an-argument-of-another-shape-does-not-throw ()
  ;; Codex passes `command' as a vector of words.  Handing that to a
  ;; string function threw inside the hook, which cost the whole event to
  ;; save a few characters of a log line.
  (should (equal (agent-river--detail
                  "act" (agent-river-test--payload
                         "{\"tool_name\":\"shell\",\"tool_input\":{\"command\":[\"make\",\"test\"]}}"))
                 "shell  {\"command\":[\"make\",\"test\"]}")))

(ert-deftest agent-river-test-hook-folds-and-answers ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        (agent-river-fail-streak-threshold 2)
        (in (make-temp-file "af-in"))
        (out (make-temp-file "af-out")))
    (unwind-protect
        (progn
          (dotimes (_ 2)
            (with-temp-file in
              (insert "{\"session_id\":\"s1\",\"cwd\":\"/repo\",\"tool_name\":\"Bash\",\"hook_event_name\":\"PostToolUseFailure\"}"))
            (agent-river-hook "fail" in out))
          (let ((answer (with-temp-buffer (insert-file-contents out)
                                          (buffer-string))))
            (should (string-match-p "additionalContext" answer))
            (should (string-match-p "consecutive tool failures" answer))))
      (ignore-errors (delete-file in))
      (ignore-errors (delete-file out)))))

(ert-deftest agent-river-test-hook-consumes-its-input-file ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        (in (make-temp-file "af-in"))
        (out (make-temp-file "af-out")))
    (unwind-protect
        (progn
          (with-temp-file in (insert "{\"session_id\":\"s1\",\"tool_name\":\"Bash\"}"))
          (agent-river-hook "act" in out)
          ;; Otherwise every tool call would leave a file behind.
          (should-not (file-exists-p in)))
      (ignore-errors (delete-file in))
      (ignore-errors (delete-file out)))))

(ert-deftest agent-river-test-hook-survives-a-bad-payload ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        (in (make-temp-file "af-in"))
        (out (make-temp-file "af-out")))
    (unwind-protect
        (progn
          (with-temp-file in (insert "this is not json"))
          ;; Must not signal: the HUD may never fail a tool call.  But it
          ;; has to leave a trace, since going quiet is how this has broken
          ;; before.
          (should-not (agent-river-hook "act" in out))
          (with-current-buffer (agent-river--buffer)
            (should (string-match-p
                     "hook failed"
                     (buffer-substring-no-properties (point-min) (point-max))))))
      (ignore-errors (delete-file in))
      (ignore-errors (delete-file out)))))


;;; Hosted by agent-shell

(defvar agent-shell--state)
(defvar agent-river-test--shell-default)

(defmacro agent-river-test--with-shell (specs &rest body)
  "Run BODY with fake agent-shell buffers for SPECS.

A spec is (NAME ID CLIENT DEFAULT).  CLIENT is optional and stands in
for the ACP client; a two-element spec leaves it nil, which is what an
unhosted session looks like.  DEFAULT, when given, is the name
agent-shell's formatter would produce -- a NAME that differs from it is
a human rename.  Omitted, DEFAULT equals NAME, so the buffer looks
untouched, which is the common case.

The two agent-shell functions the label derivation borrows from are
stubbed here so the tests do not depend on agent-shell being installed."
  (declare (indent 1))
  `(let ((buffers nil)
         ;; Both are sticky for the Emacs session in real use; a test is a
         ;; session of its own, so it starts with neither.
         (agent-river--shell-seen nil)
         (agent-river--teardown-hooked (make-hash-table :test 'eq)))
     (unwind-protect
         (progn
           (dolist (spec ,specs)
             (let ((buffer (generate-new-buffer (car spec))))
               (push buffer buffers)
               (with-current-buffer buffer
                 (setq major-mode 'agent-shell-mode)
                 (setq-local agent-shell--state
                             (list (cons :session
                                         (list (cons :id (cadr spec))))
                                   (cons :agent-config
                                         (list (cons :buffer-name "fake")))
                                   (cons :client (caddr spec))))
                 (setq-local agent-river-test--shell-default
                             (or (nth 3 spec) (car spec))))))
           (cl-letf (((symbol-function 'agent-shell--format-buffer-name)
                      (lambda (&rest _)
                        (buffer-local-value 'agent-river-test--shell-default
                                            (current-buffer))))
                     ((symbol-function 'agent-shell--project-name)
                      (lambda () "repo")))
             ,@body))
       (mapc #'kill-buffer buffers))))

(ert-deftest agent-river-test-shell-buffer-found-by-session-id ()
  (agent-river-test--with-shell '(("Claude Agent @ repo" "s1")
                                  ("Claude Agent @ repo<2>" "s2"))
    (let ((found (agent-river--shell-buffer "s2")))
      ;; Assert the buffer before naming it: (buffer-name nil) quietly
      ;; returns the *current* buffer's name, which turned a nil result
      ;; into a confusing mismatch instead of an obvious one.
      (should (bufferp found))
      (should (equal (buffer-name found) "Claude Agent @ repo<2>")))
    (should-not (agent-river--shell-buffer "nobody"))))

(ert-deftest agent-river-test-label-comes-from-the-host ()
  (agent-river-test--with-shell '(("Claude Agent @ repo<2>" "s2"))
    (let ((agent-river-registry (make-hash-table :test 'equal)))
      ;; The directory-derived label is overridden: agent-shell already
      ;; numbers its buffers, and its name does not drift when the session
      ;; changes working directory.
      (should (equal (agent-river-state-label (agent-river-state "s2" "repo"))
                     "repo<2>")))))

(ert-deftest agent-river-test-a-renamed-shell-keeps-its-new-name ()
  (agent-river-test--with-shell '(("my scratch notes" "s1"
                                   nil "Claude Agent @ repo"))
    (let ((agent-river-registry (make-hash-table :test 'equal)))
      ;; The name no longer matches what agent-shell's formatter would
      ;; produce, so it is a human rename and is taken whole -- not parsed
      ;; for a project part that is not there.
      (should (equal (agent-river-state-label (agent-river-state "s1" "repo"))
                     "my scratch notes")))))

(ert-deftest agent-river-test-a-rename-may-itself-contain-at ()
  (agent-river-test--with-shell '(("notes @ home" "s1"
                                   nil "Claude Agent @ repo"))
    (let ((agent-river-registry (make-hash-table :test 'equal)))
      ;; The old `" @ "' split would have rendered "home": a rename is
      ;; whatever the human typed, `" @ "' in it or not.
      (should (equal (agent-river-state-label (agent-river-state "s1" "repo"))
                     "notes @ home")))))

(ert-deftest agent-river-test-liveness-comes-from-the-buffer ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-session-ttl 300))
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      (let ((state (agent-river-state "s1" "repo")))
        ;; Long past the TTL, but the process is demonstrably running.
        (setf (agent-river-state-last-seen state) (time-subtract (current-time) 9999))
        (should (agent-river--active-p state))))))

(ert-deftest agent-river-test-a-closed-session-is-not-active ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-session-ttl 300))
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      (agent-river-state "s1" "repo")
      (agent-river-state "gone" "repo"))
    ;; Outside the macro the buffers are killed: a hosted session whose
    ;; buffer is gone is gone, however recently it acted.
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      (should (agent-river--active-p (gethash "s1" agent-river-registry)))
      (should-not (agent-river--active-p (gethash "gone" agent-river-registry))))))

(ert-deftest agent-river-test-subagents-still-use-the-ttl ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-session-ttl 300))
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      (let ((child (agent-river-state "s1/a1" "Explore" "s1" "Explore")))
        ;; A subagent has no buffer of its own, so it keeps the fallback.
        (should (agent-river--active-p child))
        (setf (agent-river-state-last-seen child) (time-subtract (current-time) 600))
        (should-not (agent-river--active-p child))))))

(ert-deftest agent-river-test-session-line-is-visitable ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                   :detail "Edit a.el"))
      (let ((line (agent-river--panel (gethash "s1" agent-river-registry))))
        (should (equal (get-text-property 1 'agent-river-session line) "s1"))
        (should (get-text-property 1 'keymap line))))))

(ert-deftest agent-river-test-unhosted-line-is-not-visitable ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    ;; Nothing to jump to, so the line must not pretend otherwise.
    (let ((line (agent-river--panel (gethash "s1" agent-river-registry))))
      (should-not (get-text-property 1 'agent-river-session line)))))

(ert-deftest agent-river-test-a-dying-shell-drops-its-line-from-the-block ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                   :detail "Edit a.el"))
      ;; The session is live, so the block offers the jump.
      (should (string-match-p "repo"
                              (with-current-buffer (agent-river--buffer)
                                (buffer-substring-no-properties
                                 (point-min) (point-max)))))
      ;; `agent-shell-restart' kills the buffer and starts a new session.
      ;; No hook event ever addresses the old id again, so the block has to
      ;; be redrawn by the buffer's own death or the line lingers,
      ;; unopenable, for the rest of the Emacs session.
      (kill-buffer (agent-river--shell-buffer "s1"))
      ;; The redraw is deferred by a tick: `kill-buffer-hook' runs while the
      ;; buffer is still live, so doing it inline would find the dying
      ;; buffer and draw the session straight back in.
      (sleep-for 0.05)
      (should-not (string-match-p "repo"
                                  (with-current-buffer (agent-river--buffer)
                                    (buffer-substring-no-properties
                                     (point-min) (point-max)))))
      ;; The state is kept: `agent-river-status' still reports on it.
      (should (gethash "s1" agent-river-registry)))))

(ert-deftest agent-river-test-visiting-a-restarted-away-session-says-so ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        line)
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                   :detail "Edit a.el"))
      ;; Captured while the session is still hosted, so the line carries the
      ;; jump affordance -- which is exactly what is left behind when
      ;; `agent-shell-restart' kills the buffer and hands the next event to
      ;; a new session id.
      (setq line (agent-river--panel (gethash "s1" agent-river-registry))))
    (with-temp-buffer
      (insert line)
      (goto-char (point-min))
      (should (equal (get-text-property (point) 'agent-river-session) "s1"))
      (should-error (agent-river-visit-session) :type 'user-error)
      (should (string-match-p "no longer hosted"
                              (condition-case err
                                  (progn (agent-river-visit-session) "")
                                (user-error (error-message-string err))))))))


;;; Refresh timer

(ert-deftest agent-river-test-working-p-ignores-an-idle-session ()
  (let ((agent-river-registry (make-hash-table :test 'equal)))
    (let ((state (agent-river-state "s1" "repo")))
      (agent-river-fold state '(:kind "act" :tool "Edit"))
      (should (agent-river--working-p))
      (agent-river-fold state '(:kind "idle"))
      ;; A clock ticking over an agent that has finished its turn claims
      ;; work that is not being done -- and would keep the timer alive for
      ;; as long as Emacs runs.
      (should-not (agent-river--working-p)))))

(ert-deftest agent-river-test-working-p-ignores-a-stale-session ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-session-ttl 300))
    (let ((state (agent-river-state "s1" "repo")))
      (agent-river-fold state '(:kind "act" :tool "Edit"))
      (setf (agent-river-state-last-seen state) (time-subtract (current-time) 600))
      (should-not (agent-river--working-p)))))

(ert-deftest agent-river-test-a-working-subagent-keeps-the-clock-running ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Agent"))
    (agent-river-observe '(:kind "idle" :session "s1" :label "repo"
                                 :detail "waiting for you"))
    (should-not (agent-river--working-p))
    (agent-river-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Read"))
    ;; The parent may look idle while a child it spawned is still going.
    (should (agent-river--working-p))))

(ert-deftest agent-river-test-tick-retires-the-timer-when-work-stops ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        (agent-river--timer nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    (agent-river--ensure-timer)
    (should (timerp agent-river--timer))
    ;; Starting twice must not leave a second timer running unnoticed.
    (let ((first agent-river--timer))
      (agent-river--ensure-timer)
      (should (eq first agent-river--timer)))
    (agent-river-observe '(:kind "idle" :session "s1" :label "repo"
                                 :detail "waiting for you"))
    (agent-river--tick)
    (should-not agent-river--timer)
    (cancel-function-timers #'agent-river--tick)))

(ert-deftest agent-river-test-tick-redraws-only-the-block ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                 :detail "Edit a.el"))
    (let ((before (with-current-buffer (agent-river--buffer)
                    (buffer-substring-no-properties (point-min) (point-max)))))
      (agent-river--redraw-block)
      (let ((after (with-current-buffer (agent-river--buffer)
                     (buffer-substring-no-properties (point-min) (point-max)))))
        ;; Same number of lines: the block is replaced, never appended, and
        ;; the log is not touched.
        (should (= (length (split-string before "\n"))
                   (length (split-string after "\n"))))
        (should (string-match-p "Edit a\\.el" after))))))


;;; Registry and queries

(ert-deftest agent-river-test-sessions-fold-independently ()
  (let ((agent-river-registry (make-hash-table :test 'equal)))
    (let ((a (agent-river-state "s1" "alpha"))
          (b (agent-river-state "s2" "beta")))
      (agent-river-test--fail a 3)
      (agent-river-fold b '(:kind "act" :file "b.el"))
      (should (= (agent-river-state-fail-streak a) 3))
      (should (= (agent-river-state-fail-streak b) 0))
      (should (= (hash-table-count agent-river-registry) 2)))))

(ert-deftest agent-river-test-touching-matches-across-sessions ()
  (let ((agent-river-registry (make-hash-table :test 'equal)))
    (let ((a (agent-river-state "s1" "main"))
          (b (agent-river-state "s2" "worktree")))
      ;; Same logical file reached through two checkouts: the query has to
      ;; see one artifact, or it cannot warn about contention at all.
      (agent-river-fold a '(:kind "act" :file "supersonic.el"))
      (agent-river-fold b '(:kind "act" :file "sub/supersonic.el"))
      (should (= 2 (length (agent-river-touching "supersonic.el"))))
      (should (null (agent-river-touching "unrelated.el"))))))

(ert-deftest agent-river-test-active-count-honours-ttl ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-session-ttl 300))
    (let ((a (agent-river-state "s1" "alpha"))
          (b (agent-river-state "s2" "beta")))
      (ignore a)
      (should (= (agent-river--active-count) 2))
      ;; A crashed session must drop out rather than linger as state that
      ;; still looks current.
      (setf (agent-river-state-last-seen b)
            (time-subtract (current-time) 600))
      (should (= (agent-river--active-count) 1)))))

(ert-deftest agent-river-test-label-column-keeps-the-unique-suffix ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-label-width 8))
    (agent-river-state "s1" "supersonic.el")
    (agent-river-state "s2" "supersonic.el")
    (let ((a (agent-river--label-column "supersonic.el"))
          (b (agent-river--label-column "supersonic.el<2>")))
      ;; Plain truncation cuts both to "superson", putting the two agents
      ;; back where uniquifying the labels started.
      (should-not (equal a b))
      (should (string-suffix-p "<2>" b))
      (should (= (length a) (length b))))))

(ert-deftest agent-river-test-label-column-appears-only-when-shared ()
  (let ((agent-river-registry (make-hash-table :test 'equal)))
    (agent-river-state "s1" "alpha")
    (should-not (agent-river--label-column "alpha"))
    (agent-river-state "s2" "beta")
    (should (agent-river--label-column "alpha"))))

;;; Subagents

(ert-deftest agent-river-test-key-composes-session-and-agent ()
  (should (equal (agent-river-key "s1") "s1"))
  (should (equal (agent-river-key "s1" nil) "s1"))
  (should (equal (agent-river-key "s1" "") "s1"))
  (should (equal (agent-river-key "s1" "a9") "s1/a9")))

(ert-deftest agent-river-test-subagent-work-stays-out-of-the-parent ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                 :tool "Bash" :detail "Bash"))
    (dotimes (_ 4)
      (agent-river-observe '(:kind "act" :session "s1" :agent "a9"
                                   :agent-type "Explore"
                                   :tool "Read" :file "x.el" :detail "Read x.el")))
    (let ((parent (gethash "s1" agent-river-registry))
          (child (gethash "s1/a9" agent-river-registry)))
      ;; Subagent calls carry the parent session id, so keying on that alone
      ;; would report five steps here instead of one.
      (should (= (agent-river-state-steps parent) 1))
      (should (= (agent-river-state-steps child) 4))
      (should (equal (agent-river-state-parent child) "s1"))
      (should (equal (agent-river-state-label child) "Explore")))))

(ert-deftest agent-river-test-subagent-failures-do-not-signal-the-parent ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        (agent-river-fail-streak-threshold 3)
        (signals nil))
    (dotimes (_ 3)
      (push (agent-river-observe '(:kind "fail" :session "s1" :agent "a9"
                                         :agent-type "Explore"
                                         :tool "Read" :detail "Read"))
            signals))
    ;; The child hit the threshold and is told nothing, because nothing it
    ;; is told arrives -- see `agent-river--answerable-p'.  This assertion
    ;; used to read the other way round on the assumption that a subagent's
    ;; synchronous hook could answer it; measuring said otherwise.
    (should-not (car signals))
    ;; What the test was always really about: the parent, which did nothing
    ;; wrong, keeps its own streak and its own silence.
    (should (= 0 (agent-river-state-fail-streak
                  (agent-river-state "s1" "repo"))))
    (should-not (agent-river--signal (agent-river-state "s1" "repo")))))

(ert-deftest agent-river-test-a-subagent-is-never-signalled ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        (agent-river-fail-streak-threshold 1))
    (agent-river-observe '(:kind "fail" :session "s1" :agent "a9"
                                 :agent-type "Explore" :tool "Read" :detail "Read"))
    (let ((child (gethash "s1/a9" agent-river-registry)))
      ;; The streak is measured either way -- the HUD still shows the child
      ;; failing, and the parent's report still aggregates it.
      (should (= (agent-river-state-fail-streak child) 1))
      ;; But nothing is handed over, and nothing is recorded as handed over.
      ;; additionalContext returned from a subagent's hook reaches neither the
      ;; subagent nor the parent, so counting it would make the signals tally
      ;; report a conversation that never happened -- the same lie
      ;; `agent-river-answering-kinds' was added to stop, in the other
      ;; dimension: not which event, but which state.
      (should-not (agent-river-state-signals child))
      (should (agent-river--answerable-p (agent-river-state "s1" "repo")))
      (should-not (agent-river--answerable-p child)))))

(ert-deftest agent-river-test-parent-sees-subagents-aggregated ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                 :tool "Agent" :detail "Agent"))
    (agent-river-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Read"))
    (agent-river-observe '(:kind "act" :session "s1" :agent "a2"
                                 :agent-type "Plan" :detail "Read"))
    (agent-river-observe '(:kind "act" :session "s1" :agent "a2"
                                 :agent-type "Plan" :detail "Read"))
    (let* ((report (agent-river-report "s1"))
           (subs (plist-get report :subagents)))
      (should (= (plist-get report :task-steps) 1))
      (should (= (plist-get subs :total) 2))
      (should (= (plist-get subs :running) 2))
      (should (= (plist-get subs :steps) 3))
      (should (equal (sort (mapcar #'car (plist-get subs :each)) #'string<)
                     '("Explore" "Plan"))))))

(ert-deftest agent-river-test-report-omits-subagents-when-there-are-none ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                 :tool "Bash" :detail "Bash"))
    (should-not (plist-member (agent-river-report "s1") :subagents))))

(ert-deftest agent-river-test-subagent-stop-marks-it-done ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Bash"))
    (agent-river-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Read"))
    (let ((subs (plist-get (agent-river-report "s1") :subagents)))
      (should (= (plist-get subs :running) 1))
      (should (equal (plist-get (cdr (car (plist-get subs :each))) :status)
                     "running")))
    ;; Finishing is an event, not something inferred from going quiet: a
    ;; subagent that just returned is still well inside the TTL.
    (agent-river-observe '(:kind "done" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Explore finished"))
    (let ((subs (plist-get (agent-river-report "s1") :subagents)))
      (should (= (plist-get subs :running) 0))
      (should (equal (plist-get (cdr (car (plist-get subs :each))) :status)
                     "done")))))

(ert-deftest agent-river-test-subagent-without-end-event-goes-stale ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        (agent-river-session-ttl 300))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Bash"))
    (agent-river-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Read"))
    (setf (agent-river-state-last-seen (gethash "s1/a1" agent-river-registry))
          (time-subtract (current-time) 600))
    ;; Distinguished from "done" on purpose: this one vanished without
    ;; saying so, and a report that called it finished would be guessing.
    (let ((subs (plist-get (agent-river-report "s1") :subagents)))
      (should (= (plist-get subs :running) 0))
      (should (equal (plist-get (cdr (car (plist-get subs :each))) :status)
                     "stale")))))

(ert-deftest agent-river-test-done-clears-the-in-flight-step ()
  (let ((agent-river-registry (make-hash-table :test 'equal)))
    (let ((child (agent-river-state "s1/a1" "Explore" "s1" "Explore")))
      (agent-river-fold child '(:kind "act" :tool "Read" :file "a.el"))
      (should (agent-river-state-step child))
      (agent-river-fold child '(:kind "done"))
      (should-not (agent-river-state-step child))
      (should (agent-river-state-done child)))))

(ert-deftest agent-river-test-done-never-retires-a-root-session ()
  (agent-river-test--with-session state
    ;; If SubagentStop turns out not to carry an agent_id, the event lands on
    ;; the parent key.  Marking a live session finished would make every
    ;; later reading wrong, so a done without a parent is dropped.
    (agent-river-fold state '(:kind "done"))
    (should-not (agent-river-state-done state))
    (should (agent-river--active-p state))))

(ert-deftest agent-river-test-observe-returns-signal-and-folds-it-back ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        (agent-river-fail-streak-threshold 2))
    (agent-river-observe '(:kind "fail" :session "s1" :label "alpha"
                                 :tool "Bash" :detail "Bash 10ms"))
    (should-not (agent-river-observe '(:kind "act" :session "s1" :label "alpha"
                                             :tool "Bash" :detail "Bash")))
    (let ((signal (agent-river-observe
                   '(:kind "fail" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash 10ms"))))
      (should signal)
      ;; An emitted observation is itself part of the state, so that "how
      ;; often did the agent have to be told" stays observable.
      (should (= 1 (length (agent-river-state-signals
                            (gethash "s1" agent-river-registry))))))))

;;; Live reasoning, from the ACP stream

(defun agent-river-test--thought (text)
  "Return an `agent_thought_chunk' notification carrying TEXT."
  `((params . ((update . ((sessionUpdate . "agent_thought_chunk")
                          (content . ((type . "text") (text . ,text)))))))))

(defun agent-river-test--update (kind)
  "Return a session update notification of KIND, carrying no thought."
  `((params . ((update . ((sessionUpdate . ,kind)))))))

(defun agent-river-test--hud ()
  "Return the text of the HUD buffer."
  (with-current-buffer (agent-river--buffer)
    (buffer-substring-no-properties (point-min) (point-max))))

(defmacro agent-river-test--with-stream (&rest body)
  "Run BODY against an empty HUD and a fresh thought-run table."
  (declare (indent 0))
  `(let ((agent-river-registry (make-hash-table :test 'equal))
         (agent-river--thought-runs (make-hash-table :test 'equal))
         (agent-river-auto-display nil))
     (agent-river-clear)
     ,@body))

(ert-deftest agent-river-test-thought-waits-for-a-complete-sentence ()
  (agent-river-test--with-stream
    (agent-river--on-notification "s1" (agent-river-test--thought "Joining on tool_use_id"))
    ;; Mid-stream a chunk ends inside a sentence.  Showing that would put a
    ;; truncated clause on screen and never correct it.
    (should-not (string-match-p "Joining" (agent-river-test--hud)))
    (agent-river--on-notification "s1" (agent-river-test--thought " is more precise. Then"))
    (should (string-match-p "Joining on tool_use_id is more precise"
                            (agent-river-test--hud)))))

(ert-deftest agent-river-test-only-the-first-sentence-of-a-thought-is-shown ()
  (agent-river-test--with-stream
    (agent-river--on-notification "s1" (agent-river-test--thought "First one. Second one."))
    (agent-river--on-notification "s1" (agent-river-test--thought " Third one."))
    ;; Thinking blocks are paragraphs; unabridged they would bury the
    ;; tool-call rhythm the log exists to show.
    (should (string-match-p "First one" (agent-river-test--hud)))
    (should-not (string-match-p "Second one" (agent-river-test--hud)))
    (should-not (string-match-p "Third one" (agent-river-test--hud)))))

(ert-deftest agent-river-test-a-thought-without-a-sentence-is-flushed-at-the-end ()
  (agent-river-test--with-stream
    (agent-river--on-notification "s1" (agent-river-test--thought "Short unfinished thought"))
    (should-not (string-match-p "Short unfinished" (agent-river-test--hud)))
    ;; The agent stopped thinking and acted.  Swallowing the run because it
    ;; never reached a full stop would lose the reasoning entirely.
    (agent-river--on-notification "s1" (agent-river-test--update "tool_call"))
    (should (string-match-p "Short unfinished thought" (agent-river-test--hud)))))

(ert-deftest agent-river-test-a-non-thought-notification-says-nothing ()
  (agent-river-test--with-stream
    (let ((before (agent-river-test--hud)))
      ;; Tool calls are the hooks' job.  Folding them here as well would
      ;; double every step in the log and in the counts.
      (agent-river--on-notification "s1" (agent-river-test--update "tool_call"))
      (agent-river--on-notification "s1" (agent-river-test--update "agent_message_chunk"))
      (should (equal before (agent-river-test--hud))))))

(ert-deftest agent-river-test-thought-runs-are-per-session ()
  (agent-river-test--with-stream
    (agent-river--on-notification "s1" (agent-river-test--thought "Alpha thinking"))
    (agent-river--on-notification "s2" (agent-river-test--thought "Beta thinking"))
    ;; Two agents think side by side; concatenating their chunks would
    ;; produce a sentence neither of them had.
    (agent-river--on-notification "s1" (agent-river-test--thought " about a. x"))
    (should (string-match-p "Alpha thinking about a" (agent-river-test--hud)))
    (should-not (string-match-p "Beta thinking about" (agent-river-test--hud)))))

(ert-deftest agent-river-test-thought-chunk-reads-only-thoughts ()
  (should (equal (agent-river--thought-chunk (agent-river-test--thought "x")) "x"))
  (should-not (agent-river--thought-chunk (agent-river-test--update "tool_call")))
  (should-not (agent-river--thought-chunk '((params . nil))))
  (should-not (agent-river--thought-chunk nil)))


;;; Folded from the stream instead of from hooks

(defmacro agent-river-test--with-watch (&rest body)
  "Run BODY against an empty HUD, with fresh ownership and call tables."
  (declare (indent 0))
  `(let ((agent-river-registry (make-hash-table :test 'equal))
         (agent-river--tool-calls (make-hash-table :test 'equal))
         (agent-river--source (make-hash-table :test 'equal))
         (agent-river-auto-display nil))
     (agent-river-clear)
     ,@body))

(defun agent-river-test--tool-call (id status &rest call)
  "Return the `tool-call-update' agent-shell publishes for ID in STATUS.
CALL overrides fields of the tool call record."
  `((:event . tool-call-update)
    (:data . ((:tool-call-id . ,id)
              (:tool-call . ,(append call `((:status . ,status)
                                            (:kind . "read")
                                            (:title . "Read a.el"))))))))

(defun agent-river-test--kinds (events)
  "Return the kinds of EVENTS, in order."
  (mapcar (lambda (event) (plist-get event :kind)) events))

(ert-deftest agent-river-test-a-tool-call-is-one-step-however-often-it-is-updated ()
  (agent-river-test--with-watch
    (should (equal (agent-river-test--kinds
                    (agent-river--shell-events
                     (agent-river-test--tool-call "c1" "pending") "s1" "/repo"))
                   '("act")))
    ;; A status change is not a second step: the call was announced once,
    ;; and the stream then updates that same announcement.
    (should-not (agent-river--shell-events
                 (agent-river-test--tool-call "c1" "in_progress") "s1" "/repo"))
    (let ((done (agent-river--shell-events
                 (agent-river-test--tool-call "c1" "completed") "s1" "/repo")))
      (should (equal (agent-river-test--kinds done) '("think")))
      ;; ACP carries no duration, so the two sightings supply it.
      (should (integerp (plist-get (car done) :ms))))))

(ert-deftest agent-river-test-a-call-first-seen-finished-is-still-counted ()
  (agent-river-test--with-watch
    ;; A step has to be counted before it can be reported as over, which is
    ;; what the two hook events do between them.
    (should (equal (agent-river-test--kinds
                    (agent-river--shell-events
                     (agent-river-test--tool-call "c1" "completed") "s1" "/repo"))
                   '("act" "think")))))

(ert-deftest agent-river-test-a-failure-comes-off-the-status ()
  (agent-river-test--with-watch
    ;; No guessing from the response here: the protocol says `failed'.
    (should (equal (agent-river-test--kinds
                    (agent-river--shell-events
                     (agent-river-test--tool-call "c1" "failed") "s1" "/repo"))
                   '("act" "fail")))))

(ert-deftest agent-river-test-the-stream-reads-the-fields-the-hooks-do ()
  (agent-river-test--with-watch
    (let ((event (car (agent-river--shell-events
                       (agent-river-test--tool-call
                        "c1" "pending" '(:raw-input . ((file_path . "/repo/a.el"))))
                       "s1" "/repo"))))
      ;; Through the same adapter: normalised against the session's cwd,
      ;; and tallied under the call's kind, since ACP names no tool.
      (should (equal (plist-get event :file) "a.el"))
      (should (equal (plist-get event :tool) "read"))
      (should (equal (plist-get event :detail) "read  a.el")))))

(ert-deftest agent-river-test-a-call-without-arguments-shows-its-title ()
  (agent-river-test--with-watch
    (should (equal (plist-get (car (agent-river--shell-events
                                    (agent-river-test--tool-call "c1" "pending")
                                    "s1" "/repo"))
                              :detail)
                   "read  Read a.el"))))

(ert-deftest agent-river-test-a-turn-ends-the-calls-it-started ()
  (agent-river-test--with-watch
    (agent-river--shell-events (agent-river-test--tool-call "c1" "pending") "s1" "/repo")
    (agent-river--shell-events (agent-river-test--tool-call "c2" "pending") "s2" "/repo")
    (should (equal (agent-river-test--kinds
                    (agent-river--shell-events '((:event . turn-complete)) "s1" "/repo"))
                   '("idle")))
    ;; A call that never reported an end does not outlive its turn -- but
    ;; another session's calls are none of this turn's business.
    (should (= (hash-table-count agent-river--tool-calls) 1))))

(ert-deftest agent-river-test-the-stream-carries-the-prompt ()
  (agent-river-test--with-watch
    (let ((event (car (agent-river--shell-events
                       '((:event . input-submitted) (:data . ((:prompt . "do the thing"))))
                       "s1" "/repo"))))
      (should (equal (plist-get event :kind) "prompt"))
      (should (equal (plist-get event :text) "do the thing")))))

(ert-deftest agent-river-test-hooks-take-a-watched-session-over ()
  (agent-river-test--with-watch
    (should (agent-river--claim "s1" 'shell))
    (agent-river-observe '(:kind "act" :session "s1" :tool "read" :detail "read"))
    (should (gethash "s1" agent-river-registry))
    ;; The hooks win: they are the only way in that can carry an
    ;; observation back.  What the stream folded is dropped whole rather
    ;; than interleaved -- every step would otherwise be counted twice,
    ;; and a doubled failure streak states a fact that is false.
    (should (agent-river--claim "s1" 'hooks))
    (should-not (gethash "s1" agent-river-registry))
    (should-not (agent-river--claim "s1" 'shell))
    ;; Going quiet about it is how this has broken before.
    (should (string-match-p "hooks reach this session" (agent-river-test--hud)))))


;;; Observers -- the side-effect contract
;;
;; What every consumer that reaches outside this package inherits from the
;; runner, so that adding one is writing its own job and nothing else.  These
;; are the tests to point a new observer at.

(defmacro agent-river-test--with-observers (&rest body)
  "Run BODY with an empty observer list and an empty HUD."
  (declare (indent 0))
  `(let ((agent-river-registry (make-hash-table :test 'equal))
         (agent-river-auto-display nil)
         (agent-river-observers nil))
     (agent-river-clear)
     ,@body))

(ert-deftest agent-river-test-an-observer-sees-the-state-and-the-raw-event ()
  (agent-river-test--with-observers
    (let (seen)
      (add-hook 'agent-river-observers
                (lambda (state event) (push (cons state event) seen)))
      (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                   :file "a.el" :path "/repo/a.el"
                                   :detail "Edit a.el"))
      (should (= (length seen) 1))
      ;; The state is the folded account, already updated when the observer
      ;; runs -- an observer that had to fold for itself would be a second,
      ;; unlogged account of the same events.
      (should (= (agent-river-state-steps (car (car seen))) 1))
      ;; And the raw event is where anything the fold drops still lives.
      (should (equal (plist-get (cdr (car seen)) :path) "/repo/a.el")))))

(ert-deftest agent-river-test-a-throwing-observer-retires-and-says-so ()
  (agent-river-test--with-observers
    (let ((calls 0))
      (add-hook 'agent-river-observers
                (lambda (_state _event) (setq calls (1+ calls)) (error "boom")))
      (agent-river-observe '(:kind "act" :session "s1" :detail "Edit a.el"))
      (agent-river-observe '(:kind "act" :session "s1" :detail "Edit b.el"))
      ;; This path runs on every tool call, so a consumer that is broken is
      ;; broken thousands of times; it gets exactly one chance.
      (should (= calls 1))
      (should-not agent-river-observers)
      ;; Retiring quietly is the failure mode this package keeps having.
      (should (string-match-p "observer .* retired" (agent-river-test--hud))))))

(ert-deftest agent-river-test-a-retiring-observer-can-tear-down ()
  (agent-river-test--with-observers
    (let (torn-down)
      (defun agent-river-test--breaking-observer (_state _event) (error "boom"))
      (put 'agent-river-test--breaking-observer 'agent-river-retire
           (lambda () (setq torn-down t)))
      (add-hook 'agent-river-observers #'agent-river-test--breaking-observer)
      (agent-river-observe '(:kind "act" :session "s1" :detail "Edit a.el"))
      ;; Removal alone would leave whatever the observer put into other
      ;; buffers sitting there, and its mode variable claiming to be on.
      (should torn-down))))

(ert-deftest agent-river-test-one-broken-observer-spares-the-rest ()
  (agent-river-test--with-observers
    (let (survived)
      (add-hook 'agent-river-observers (lambda (_state _event) (error "boom")))
      (add-hook 'agent-river-observers (lambda (_state _event) (setq survived t)))
      (agent-river-observe '(:kind "act" :session "s1" :detail "Edit a.el"))
      (should survived))))

(ert-deftest agent-river-test-an-observer-cannot-reach-the-agent ()
  (agent-river-test--with-observers
    (add-hook 'agent-river-observers
              (lambda (_state _event) "agent-river: do something else"))
    ;; The return value is dropped on purpose.  Signals are the one channel
    ;; back into the agent's context and they are kept narrow and factual;
    ;; a side effect that could speak through it would widen that channel
    ;; without any of the discipline that makes it safe.
    (should-not (agent-river-observe '(:kind "act" :session "s1" :detail "Edit")))))

(ert-deftest agent-river-test-a-broken-observer-spares-the-fold ()
  (agent-river-test--with-observers
    (add-hook 'agent-river-observers (lambda (_state _event) (error "boom")))
    (agent-river-observe '(:kind "act" :session "s1" :file "a.el" :detail "Edit"))
    ;; The state must be untouched by a failing side effect, and the failure
    ;; must not be reported as a fold failure -- that message sends the user
    ;; to `agent-river-reset', which throws away every session.
    (should (= (agent-river-state-steps (gethash "s1" agent-river-registry)) 1))
    (should-not (string-match-p "fold failed" (agent-river-test--hud)))))


;;; Notes -- state produced from outside the hook stream

(ert-deftest agent-river-test-one-streak-is-reported-once ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (dotimes (_ 3)
      (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash" :detail "Bash")))
    ;; act is an answering kind and leaves the streak where it is, so the
    ;; throttle -- keyed on the streak alone -- used to fire again on every
    ;; tool call that followed.  One run of failures, four deliveries of the
    ;; identical sentence, which is what the throttle exists to prevent.
    (dotimes (_ 3)
      (should-not (agent-river-observe '(:kind "act" :session "s1" :tool "Read"
                                               :file "a.el" :detail "Read a.el"))))
    (should (= (length (agent-river-state-signals
                        (gethash "s1" agent-river-registry)))
               1))))

(ert-deftest agent-river-test-a-further-streak-is-reported-again ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (dotimes (_ 3)
      (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash" :detail "Bash")))
    (agent-river-observe '(:kind "act" :session "s1" :file "a.el" :detail "Read"))
    ;; Delivered-once must not become delivered-never: the streak reaching 6
    ;; is a different fact from it reaching 3, and earns its own word.
    (dotimes (_ 2)
      (should-not (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash"
                                               :detail "Bash"))))
    (should (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash"
                                         :detail "Bash")))
    (should (= (length (agent-river-state-signals
                        (gethash "s1" agent-river-registry)))
               2))))

(ert-deftest agent-river-test-a-new-streak-may-repeat-a-value ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (dotimes (_ 3)
      (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash" :detail "Bash")))
    ;; A success ends the streak, and a later run of three is a new fact
    ;; about a new stretch of work -- the id must not suppress it as a
    ;; duplicate of the first.  This is why the id is checked against the
    ;; delivery log rather than the streak being remembered as a high-water
    ;; mark.
    (agent-river-observe '(:kind "think" :session "s1" :tool "Bash" :detail "Bash"))
    (dotimes (_ 2)
      (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash" :detail "Bash")))
    (should (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash"
                                         :detail "Bash")))))

(ert-deftest agent-river-test-the-signals-list-is-a-delivery-log ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (dotimes (_ 3)
      (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash" :detail "Bash")))
    (let ((entry (car (agent-river-state-signals
                       (gethash "s1" agent-river-registry)))))
      ;; What was said, when, and what it was about.  The last is what makes
      ;; "exactly once" answerable out of the existing state instead of from
      ;; a second slot that would have to be kept in step with this one.
      (should (plist-get entry :at))
      (should (string-match-p "consecutive tool failures" (plist-get entry :text)))
      (should (equal (plist-get entry :id) '(streak 1 3))))))

(ert-deftest agent-river-test-an-event-that-cannot-answer-does-not-signal ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (dotimes (_ 3)
      (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash" :detail "Bash")))
    ;; idle is Stop, wired async, so its stdout is never read.  This used to
    ;; produce a second signal into a pipe nobody reads -- the streak is
    ;; unchanged by idling, so the threshold simply fired again.
    (should-not (agent-river-observe '(:kind "idle" :session "s1" :detail "waiting")))
    (let ((state (gethash "s1" agent-river-registry)))
      ;; The tally exists to make "how often was the agent told something"
      ;; observable; counting an undelivered one is the tally lying about the
      ;; only thing it measures.
      (should (= (length (agent-river-state-signals state)) 1))
      (should (= (plist-get (agent-river-report "s1") :signals) 1)))))

(ert-deftest agent-river-test-the-answering-kinds-are-the-gate ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil)
        ;; Not a hardcoded pair of kinds: wire idle synchronously and it may
        ;; answer.  The list is what must be kept in step with the config.
        (agent-river-answering-kinds '("idle")))
    (dotimes (_ 3)
      (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash" :detail "Bash")))
    (should-not (agent-river-state-signals (gethash "s1" agent-river-registry)))
    (should (agent-river-observe '(:kind "idle" :session "s1" :detail "waiting")))))

(ert-deftest agent-river-test-suppression-leaves-the-throttle-alone ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (dotimes (_ 3)
      (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash" :detail "Bash")))
    (agent-river-observe '(:kind "idle" :session "s1" :detail "waiting"))
    ;; The throttle counts failures, not signals, so a suppressed one must
    ;; not shift the rhythm: the repeat is still due three failures on.
    (should-not (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash"
                                             :detail "Bash")))
    (should-not (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash"
                                             :detail "Bash")))
    (should (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash"
                                        :detail "Bash")))))

(ert-deftest agent-river-test-a-signal-goes-through-the-fold ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "signal" :text "told the agent something"))
    ;; It used to be pushed onto the slot from `agent-river-observe', which
    ;; made observe a second writer to a state the fold is supposed to own
    ;; alone.  Folding it is what keeps that ownership true.
    (should (= (length (agent-river-state-signals state)) 1))
    (should (equal (plist-get (car (agent-river-state-signals state)) :text)
                   "told the agent something"))))

(ert-deftest agent-river-test-a-signal-event-measures-nothing ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :tool "Edit" :file "a.el"))
    (agent-river-test--fail state 2)
    (agent-river-fold state '(:kind "signal" :text "3 consecutive failures"))
    ;; Something that happened *to* the session, not something it did: a
    ;; signal that moved the step count or the streak would make the agent
    ;; look busier the more often it was spoken to.
    (should (= (agent-river-state-steps state) 1))
    (should (= (agent-river-state-fail-streak state) 2))
    (should-not (gethash "signal" (agent-river-state-tools state)))))

(ert-deftest agent-river-test-observing-still-counts-its-signals ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (dotimes (_ 3)
      (agent-river-observe '(:kind "fail" :session "s1" :tool "Bash"
                                   :detail "Bash")))
    (let ((state (gethash "s1" agent-river-registry)))
      ;; The route changed, the reading must not.
      (should (= (length (agent-river-state-signals state)) 1))
      (should (= (plist-get (agent-river-report "s1") :signals) 1)))))

(ert-deftest agent-river-test-a-note-is-folded-and-counted ()
  (agent-river-test--with-observers
    (agent-river-observe '(:kind "act" :session "s1" :file "a.el" :detail "Edit"))
    (agent-river-note "a.el changed under the agent" "s1")
    (let ((state (gethash "s1" agent-river-registry)))
      (should (= (length (agent-river-state-notes state)) 1))
      (should (equal (cdr (car (agent-river-state-notes state)))
                     "a.el changed under the agent"))
      ;; Observable in the report for the same reason signals are: how often
      ;; something happened to a session is itself worth knowing.
      (should (= (plist-get (agent-river-report "s1") :notes) 1))
      ;; And it measures nothing about the agent's own work.
      (should (= (agent-river-state-steps state) 1)))))

(ert-deftest agent-river-test-a-note-reaches-the-observers ()
  (agent-river-test--with-observers
    (let (kinds)
      (agent-river-observe '(:kind "act" :session "s1" :detail "Edit a.el"))
      (add-hook 'agent-river-observers
                (lambda (_state event) (push (plist-get event :kind) kinds)))
      (agent-river-note "something happened" "s1")
      ;; A note is an event like any other downstream; a consumer that had to
      ;; find out some other way would be reading the state behind its back.
      (should (equal kinds '("note"))))))

(ert-deftest agent-river-test-a-note-about-a-note-is-refused ()
  (agent-river-test--with-observers
    (let ((calls 0))
      (add-hook 'agent-river-observers
                (lambda (_state _event)
                  (setq calls (1+ calls))
                  (agent-river-note "noting again" "s1")))
      (agent-river-observe '(:kind "act" :session "s1" :detail "Edit a.el"))
      ;; Once for the act, once for the note it made.  The note made while
      ;; that note was being handled is refused, or two observers noting at
      ;; each other would loop without bound -- and a log of single lines is
      ;; a bad place to notice that from.
      (should (= calls 2))
      (should (= (length (agent-river-state-notes
                          (gethash "s1" agent-river-registry)))
                 1))
      ;; Refusal is not failure: the observer must survive it.
      (should agent-river-observers))))

(ert-deftest agent-river-test-a-refused-note-says-so-by-returning-nil ()
  (agent-river-test--with-observers
    (agent-river-observe '(:kind "act" :session "s1" :detail "Edit a.el"))
    (should (equal (agent-river-note "first" "s1") "first"))
    (let ((agent-river--noting t))
      (should-not (agent-river-note "second" "s1")))))

(ert-deftest agent-river-test-a-note-needs-a-session ()
  (agent-river-test--with-observers
    (let ((agent-river--current nil))
      (should-error (agent-river-note "nobody to attach this to")
                    :type 'user-error))))


;;; Heat, derived for dired
;;
;; The derivation is tested, the rendering is not.  Everything that can be
;; wrong in a way that misleads an onlooker -- which frame the count comes
;; from, how two sessions on one file add up, which face a count earns -- is
;; a pure function of the state.  Overlay placement is dired's geometry, and
;; testing it would mean building a listing to assert that dired knows where
;; its own filenames are.

(ert-deftest agent-river-test-heat-counts-touches-by-basename ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :file "src/a.el"))
    (agent-river-fold state '(:kind "act" :file "src/a.el"))
    (agent-river-fold state '(:kind "act" :file "b.el"))
    (let ((table (agent-river--heat-table)))
      ;; Keyed on the bare name because that is the only key a dired buffer
      ;; can ask with: it holds absolute paths, the state holds normalised
      ;; ones, and the basename is where the two meet.
      (should (equal (gethash "a.el" table) 2))
      (should (equal (gethash "b.el" table) 1))
      (should-not (gethash "never-touched.el" table)))))

(ert-deftest agent-river-test-heat-reads-the-frame-it-is-asked-for ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :file "a.el"))
    (agent-river-fold state '(:kind "act" :file "a.el"))
    (agent-river-fold state '(:kind "prompt" :text "next"))
    (agent-river-fold state '(:kind "act" :file "a.el"))
    ;; The two frames answer different questions and the shading must not
    ;; blur them: the task frame says what this turn is about, the session
    ;; frame says what the agent has been in all afternoon.
    (should (equal (gethash "a.el" (agent-river--heat-table 'task)) 1))
    (should (equal (gethash "a.el" (agent-river--heat-table 'session)) 3))
    ;; No scope is the task frame, matching the panel.
    (should (equal (gethash "a.el" (agent-river--heat-table)) 1))))

(ert-deftest agent-river-test-heat-sums-two-sessions-on-one-file ()
  (agent-river-test--with-session state
    (let ((other (agent-river-state "s2" "beta")))
      (agent-river-fold state '(:kind "act" :file "shared.el"))
      (agent-river-fold other '(:kind "act" :file "worktree/shared.el"))
      (agent-river-fold other '(:kind "act" :file "worktree/shared.el"))
      ;; Two agents in one file is the case worth seeing, and the same file
      ;; reached from a worktree must not read as a second one -- which is
      ;; exactly what `agent-river-touching' already promises.
      (should (equal (gethash "shared.el" (agent-river--heat-table)) 3)))))

(ert-deftest agent-river-test-heat-face-escalates-with-touches ()
  (let ((agent-river-heat-levels '((6 . agent-river-heat-3)
                                   (3 . agent-river-heat-2)
                                   (1 . agent-river-heat-1))))
    ;; Below every threshold there is no face, which is what stops an
    ;; untouched listing being covered in overlays that mean nothing.
    (should-not (agent-river--heat-face 0))
    (should (eq (agent-river--heat-face 1) 'agent-river-heat-1))
    (should (eq (agent-river--heat-face 2) 'agent-river-heat-1))
    (should (eq (agent-river--heat-face 3) 'agent-river-heat-2))
    (should (eq (agent-river--heat-face 9) 'agent-river-heat-3))))

(ert-deftest agent-river-test-heat-levels-are-read-top-down ()
  ;; The order of the alist decides the answer, so a list written the other
  ;; way round would hand every touched file the coolest face and the
  ;; shading would never escalate at all.
  (let ((agent-river-heat-levels '((1 . agent-river-heat-1)
                                   (6 . agent-river-heat-3))))
    (should (eq (agent-river--heat-face 9) 'agent-river-heat-1))))

(ert-deftest agent-river-test-event-carries-an-absolute-path-unfolded ()
  (let ((event (agent-river--event
                "act"
                (agent-river-test--payload
                 "{\"session_id\":\"s1\",\"cwd\":\"/repo\",
                   \"tool_name\":\"Edit\",
                   \"tool_input\":{\"file_path\":\"/repo/src/a.el\"}}"))))
    ;; Two forms of the same file, and they are not interchangeable: :file
    ;; is normalised and is what the state is keyed on, :path is absolute
    ;; and is the only thing a dired buffer can be asked about.
    (should (equal (plist-get event :file) "src/a.el"))
    (should (equal (plist-get event :path) "/repo/src/a.el"))
    (agent-river-test--with-session state
      (agent-river-fold state event)
      ;; The absolute path must not reach the artifact table.  If it did,
      ;; one file reached from a worktree and from the main checkout would
      ;; count as two and the contention query would stop working.
      (should (gethash "src/a.el" (agent-river-state-task-artifacts state)))
      (should-not (gethash "/repo/src/a.el"
                           (agent-river-state-task-artifacts state))))))

(ert-deftest agent-river-test-heat-mode-is-off-until-asked-for ()
  ;; Writing overlays into buffers the user did not point this at is the one
  ;; thing here that needs consent, so the default has to stay off.
  (should-not (default-value 'agent-river-heat-mode)))


;;; Foreign saves, noted from Emacs
;;
;; The producer decides three things -- is this file one an agent is working
;; in, which sessions does that mean, and is the save plausibly the agent's
;; own -- and all three are pure functions of the state and a file name.
;; `agent-river-note-foreign-save' takes the name rather than reading
;; `buffer-file-name' so none of it needs a buffer, a file or a save.

(ert-deftest agent-river-test-frame-touches-matches-on-the-bare-name ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :file "src/a.el"))
    (agent-river-fold state '(:kind "act" :file "src/a.el"))
    ;; The saved buffer knows an absolute path; the state knows a normalised
    ;; one.  The basename is where they meet, as everywhere else here.
    (should (= (agent-river--frame-touches state "a.el") 2))
    (should-not (agent-river--frame-touches state "untouched.el"))))

(ert-deftest agent-river-test-frame-touches-reads-the-frame-it-is-asked-for ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :file "a.el"))
    (agent-river-fold state '(:kind "prompt" :text "next"))
    ;; A save only costs something while the *current* turn is in the file;
    ;; the session frame is the wider, noisier net.
    (should-not (agent-river--frame-touches state "a.el" 'task))
    (should (= (agent-river--frame-touches state "a.el" 'session) 1))))

(ert-deftest agent-river-test-saving-a-file-the-agent-is-in-is-noted ()
  (agent-river-test--with-observers
    (agent-river-observe '(:kind "act" :session "s1" :file "a.el" :detail "Edit"))
    (agent-river-observe '(:kind "think" :session "s1" :tool "Edit" :detail "Edit"))
    (should (equal (agent-river-note-foreign-save "/repo/a.el") '("s1")))
    (let ((state (gethash "s1" agent-river-registry)))
      (should (= (length (agent-river-state-notes state)) 1))
      (should (string-match-p "a\\.el saved outside the session"
                              (cdr (car (agent-river-state-notes state))))))))

(ert-deftest agent-river-test-saving-a-file-no-agent-is-in-says-nothing ()
  (agent-river-test--with-observers
    (agent-river-observe '(:kind "act" :session "s1" :file "a.el" :detail "Edit"))
    ;; Every save in the editor reaches this; without the relevance filter
    ;; the log would be a list of the user's keystrokes.
    (should-not (agent-river-note-foreign-save "/repo/elsewhere.el"))
    (should-not (agent-river-state-notes (gethash "s1" agent-river-registry)))))

(ert-deftest agent-river-test-a-save-under-an-open-call-is-not-noted ()
  (agent-river-test--with-observers
    ;; act without its think: the tool call is still open on this file, so
    ;; the write landing may be the agent's own.  Feeding that back as
    ;; something observed about the agent would launder its action into an
    ;; observation about it.
    (agent-river-observe '(:kind "act" :session "s1" :file "a.el" :detail "Edit"))
    (should-not (agent-river-note-foreign-save "/repo/a.el"))
    (agent-river-observe '(:kind "think" :session "s1" :tool "Edit" :detail "Edit"))
    ;; Once the call has returned the suppression lifts -- deliberately
    ;; narrow, so a format-on-save a moment later still produces a note.
    (should (agent-river-note-foreign-save "/repo/a.el"))))

(ert-deftest agent-river-test-a-save-is-noted-to-every-session-in-the-file ()
  (agent-river-test--with-observers
    (dolist (id '("s1" "s2"))
      (agent-river-observe (list :kind "act" :session id :file "shared.el"
                                 :detail "Edit"))
      (agent-river-observe (list :kind "think" :session id :tool "Edit"
                                 :detail "Edit")))
    ;; Two agents in one file is the case worth seeing, and the note belongs
    ;; to both of them rather than to whichever was found first.
    (should (= (length (agent-river-note-foreign-save "/repo/shared.el")) 2))
    (dolist (id '("s1" "s2"))
      (should (= (length (agent-river-state-notes (gethash id agent-river-registry)))
                 1)))))

(ert-deftest agent-river-test-a-subagent-is-not-noted-at ()
  (agent-river-test--with-observers
    (agent-river-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :file "a.el"
                                 :detail "Read a.el"))
    (agent-river-observe '(:kind "think" :session "s1" :agent "a1"
                                 :tool "Read" :detail "Read"))
    ;; Subagents are counted on their parent and have no line of their own,
    ;; so a note against one would be addressed to something nothing shows.
    (should-not (agent-river-note-foreign-save "/repo/a.el"))))

(ert-deftest agent-river-test-watching-saves-is-off-until-asked-for ()
  (should-not (default-value 'agent-river-watch-saves-mode))
  (should-not (memq #'agent-river--after-save after-save-hook)))

(ert-deftest agent-river-test-a-broken-save-watch-never-breaks-the-save ()
  (agent-river-test--with-observers
    (cl-letf (((symbol-function 'agent-river-note-foreign-save)
               (lambda (_file) (error "boom"))))
      (let ((buffer-file-name "/repo/a.el"))
        ;; An error here would abandon the rest of `after-save-hook' and land
        ;; in the user's face on every save, over a log line.  It must
        ;; retire instead -- and say so, because going quiet is how this
        ;; package has broken before.
        (agent-river-watch-saves-mode 1)
        ;; Returning normally *is* the assertion; ERT fails the test if this
        ;; throws, which is what a save would do to the user.
        (agent-river--after-save)
        (should-not agent-river-watch-saves-mode)
        (should-not (memq #'agent-river--after-save after-save-hook))
        (should (string-match-p "save watch stopped" (agent-river-test--hud)))))))

(provide 'agent-river-tests)
;;; agent-river-tests.el ends here
