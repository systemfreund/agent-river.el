;;; agent-focus-tests.el --- Tests for the focus fold -*- lexical-binding: t; -*-

;;; Commentary:

;; The fold is the part of agent-focus that is real logic rather than string
;; formatting: state transitions, streak accounting, thresholds, liveness.
;; It is also deterministic given an event order, which makes it cheap to
;; test -- no Emacs frame, no hooks, no transcript.
;;
;; Run:
;;   emacs -Q --batch -l agent-focus.el -l agent-focus-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-focus)

(defmacro agent-focus-test--with-session (var &rest body)
  "Bind VAR to a fresh state in an isolated registry and run BODY."
  (declare (indent 1))
  `(let ((agent-focus-registry (make-hash-table :test 'equal))
         (agent-focus-auto-display nil))
     (let ((,var (agent-focus-state "s1" "alpha")))
       ,@body)))

(defun agent-focus-test--fail (state n &optional tool)
  "Fold N failures of TOOL into STATE."
  (dotimes (_ n)
    (agent-focus-fold state (list :kind "fail" :tool (or tool "Bash") :ms 10))))


;;; Folding

(ert-deftest agent-focus-test-prompt-starts-a-task ()
  (agent-focus-test--with-session state
    (agent-focus-test--fail state 2)
    (agent-focus-fold state '(:kind "act" :tool "Edit" :file "a.el"))
    (agent-focus-fold state '(:kind "prompt" :text "do the thing"))
    (should (equal (agent-focus-state-task state) "do the thing"))
    ;; A new task starts clean: neither the step count nor a failure streak
    ;; from the previous task may leak across the boundary.
    (should (= (agent-focus-state-steps state) 0))
    (should (= (agent-focus-state-fail-streak state) 0))
    (should (null (agent-focus-state-step state)))))

(ert-deftest agent-focus-test-act-opens-a-step-and-touches ()
  (agent-focus-test--with-session state
    (agent-focus-fold state '(:kind "act" :tool "Edit" :file "a.el"))
    (should (equal (plist-get (agent-focus-state-step state) :tool) "Edit"))
    (should (= (agent-focus-state-steps state) 1))
    (should (= 1 (plist-get (gethash "a.el" (agent-focus-state-artifacts state))
                            :touches)))))

(ert-deftest agent-focus-test-touches-accumulate-per-path ()
  (agent-focus-test--with-session state
    (dotimes (_ 3) (agent-focus-fold state '(:kind "act" :file "a.el")))
    (agent-focus-fold state '(:kind "act" :file "b.el"))
    (should (= 3 (plist-get (gethash "a.el" (agent-focus-state-artifacts state))
                            :touches)))
    (should (= 1 (plist-get (gethash "b.el" (agent-focus-state-artifacts state))
                            :touches)))))

(ert-deftest agent-focus-test-act-without-file-touches-nothing ()
  (agent-focus-test--with-session state
    (agent-focus-fold state '(:kind "act" :tool "Bash"))
    (should (= 0 (hash-table-count (agent-focus-state-artifacts state))))))

(ert-deftest agent-focus-test-think-records-and-clears ()
  (agent-focus-test--with-session state
    (agent-focus-fold state '(:kind "act" :tool "Bash"))
    (agent-focus-fold state '(:kind "think" :tool "Bash" :ms 250))
    (let ((entry (gethash "Bash" (agent-focus-state-tools state))))
      (should (= (plist-get entry :count) 1))
      (should (= (plist-get entry :ms) 250))
      (should (= (plist-get entry :failures) 0)))
    (should (null (agent-focus-state-step state)))))

(ert-deftest agent-focus-test-success-resets-the-streak ()
  (agent-focus-test--with-session state
    (agent-focus-test--fail state 5)
    (should (= (agent-focus-state-fail-streak state) 5))
    (agent-focus-fold state '(:kind "think" :tool "Bash" :ms 10))
    (should (= (agent-focus-state-fail-streak state) 0))
    (should (null (agent-focus-state-fail-tools state)))))

(ert-deftest agent-focus-test-failures-count-per-tool ()
  (agent-focus-test--with-session state
    (agent-focus-test--fail state 2 "Edit")
    (agent-focus-test--fail state 1 "Bash")
    (should (= 2 (cdr (assoc "Edit" (agent-focus-state-fail-tools state)))))
    (should (= 1 (cdr (assoc "Bash" (agent-focus-state-fail-tools state)))))
    (should (= 2 (plist-get (gethash "Edit" (agent-focus-state-tools state))
                            :failures)))))


;;; Signals

(ert-deftest agent-focus-test-signal-waits-for-the-threshold ()
  (agent-focus-test--with-session state
    (let ((agent-focus-fail-streak-threshold 3))
      (agent-focus-test--fail state 1)
      (should-not (agent-focus--signal state))
      (agent-focus-test--fail state 1)
      (should-not (agent-focus--signal state))
      (agent-focus-test--fail state 1)
      (should (agent-focus--signal state)))))

(ert-deftest agent-focus-test-signal-is-throttled-after-firing ()
  (agent-focus-test--with-session state
    (let ((agent-focus-fail-streak-threshold 3)
          (agent-focus-fail-streak-repeat 3))
      (agent-focus-test--fail state 3)
      (should (agent-focus--signal state))
      ;; A signal on every subsequent failure would stop being a signal.
      (agent-focus-test--fail state 1)
      (should-not (agent-focus--signal state))
      (agent-focus-test--fail state 1)
      (should-not (agent-focus--signal state))
      (agent-focus-test--fail state 1)
      (should (agent-focus--signal state)))))

(ert-deftest agent-focus-test-signal-is-a-single-line ()
  (agent-focus-test--with-session state
    (let ((agent-focus-fail-streak-threshold 1))
      (agent-focus-test--fail state 1)
      (let ((signal (agent-focus--signal state)))
        (should signal)
        ;; The hook reads this back through emacsclient and parses prin1's
        ;; output as JSON; an embedded newline would break that silently.
        (should-not (string-match-p "\n" signal))))))

(ert-deftest agent-focus-test-new-task-clears-only-the-task-tally ()
  (agent-focus-test--with-session state
    (dotimes (_ 3) (agent-focus-fold state '(:kind "act" :file "a.el")))
    (should (string-match-p "3 touches" (agent-focus--hottest state)))
    (should (string-match-p "3 touches" (agent-focus--hottest state 'session)))
    (agent-focus-fold state '(:kind "prompt" :text "next"))
    ;; The task frame restarts; the session frame is what the contention
    ;; query reads, and must survive a change of subject.
    (should-not (agent-focus--hottest state))
    (should (string-match-p "3 touches" (agent-focus--hottest state 'session)))))

(ert-deftest agent-focus-test-report-separates-the-two-frames ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (dotimes (_ 2)
      (agent-focus-observe '(:kind "act" :session "s1" :label "repo"
                                   :file "a.el" :detail "Edit a.el")))
    (agent-focus-observe '(:kind "prompt" :session "s1" :label "repo"
                                 :text "second task" :detail "second task"))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo"
                                 :file "b.el" :detail "Edit b.el"))
    (let ((report (agent-focus-report "s1")))
      (should (= (plist-get report :task-steps) 1))
      (should-not (plist-get report :task-hottest))
      (should (string-match-p "a\\.el" (plist-get report :session-hottest))))))

(ert-deftest agent-focus-test-touching-survives-a-new-task ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo"
                                 :file "shared.el" :detail "Edit"))
    (agent-focus-observe '(:kind "prompt" :session "s1" :label "repo"
                                 :text "new" :detail "new"))
    (should (= 1 (length (agent-focus-touching "shared.el"))))))

(ert-deftest agent-focus-test-panel-reports-what-matters ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "prompt" :session "s1" :label "repo"
                                 :text "fix the queue bug" :detail "fix"))
    (dotimes (_ 2)
      (agent-focus-observe '(:kind "act" :session "s1" :label "repo"
                                   :file "mpv.el" :detail "Edit")))
    (let ((panel (substring-no-properties
                  (agent-focus--panel (gethash "s1" agent-focus-registry)))))
      (should (string-match-p "repo" panel))
      (should (string-match-p "fix the queue bug" panel))
      (should (string-match-p "2 steps" panel))
      (should-not (string-match-p "1 steps" panel))
      (should (string-match-p "mpv\\.el (2 touches)" panel))
      ;; Nothing is failing, so the panel must not carry a failure clause.
      (should-not (string-match-p "failing" panel)))))

(ert-deftest agent-focus-test-a-broken-fold-is-reported-not-swallowed ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (cl-letf (((symbol-function 'agent-focus-fold)
               (lambda (&rest _) (error "simulated slot mismatch"))))
      (agent-focus-observe '(:kind "act" :session "s1" :label "repo"
                                   :detail "Edit a.el")))
    ;; A fold that dies must leave a visible trace: this exact failure once
    ;; stopped the display with no error anywhere.
    (with-current-buffer (agent-focus--buffer)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "fold failed" text))
        (should (string-match-p "agent-focus-reset" text))))))

(ert-deftest agent-focus-test-panel-surfaces-a-live-failure-run ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (dotimes (_ 2)
      (agent-focus-observe '(:kind "fail" :session "s1" :label "repo"
                                   :tool "Bash" :detail "Bash")))
    (should (string-match-p
             "2 failing"
             (substring-no-properties
              (agent-focus--panel (gethash "s1" agent-focus-registry)))))))

(ert-deftest agent-focus-test-panel-stays-on-the-parent ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "Agent"))
    (agent-focus-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Read"))
    ;; A subagent acting must not turn into a line of its own; it is counted
    ;; on the parent, so the session stays the subject.
    (let ((block (substring-no-properties (agent-focus--panel-block))))
      (should (string-match-p "repo" block))
      (should (string-match-p "1 subagent" block))
      (should-not (string-match-p "Explore" block)))))

(ert-deftest agent-focus-test-block-gives-each-session-a-line ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    (agent-focus-observe '(:kind "act" :session "s2" :label "repo" :detail "Read"))
    (let ((lines (split-string (substring-no-properties
                                (agent-focus--panel-block))
                               "\n" t)))
      ;; One line per session, then the rule dividing block from log.
      (should (= (length lines) 3))
      (should (string-prefix-p "──" (nth 2 lines)))
      ;; Same directory, so the labels would otherwise be identical and the
      ;; two agents indistinguishable.
      (should (string-match-p "repo<2>" (nth 1 lines))))))

(ert-deftest agent-focus-test-block-drops-a-session-that-went-quiet ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil)
        (agent-focus-session-ttl 300))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    (agent-focus-observe '(:kind "act" :session "s2" :label "other" :detail "Read"))
    (setf (agent-focus-state-last-seen (gethash "s2" agent-focus-registry))
          (time-subtract (current-time) 600))
    (let ((block (substring-no-properties (agent-focus--panel-block))))
      (should (string-match-p "repo" block))
      (should-not (string-match-p "other" block)))))

(ert-deftest agent-focus-test-newest-event-is-at-the-top ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "first"))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "second"))
    (with-current-buffer (agent-focus--buffer)
      (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
             (lines (split-string text "\n" t)))
        ;; State block on top, then the log newest-first underneath.
        (should (string-match-p "repo" (nth 0 lines)))
        (should (string-prefix-p "──" (nth 1 lines)))
        (should (string-match-p "second" (nth 2 lines)))
        (should (string-match-p "first" (nth 3 lines)))))))

(ert-deftest agent-focus-test-trim-drops-the-oldest ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil)
        (agent-focus-max-entries 3))
    (dolist (n '("one" "two" "three" "four"))
      (agent-focus-observe (list :kind "act" :session "s1" :label "repo"
                                 :detail n)))
    (with-current-buffer (agent-focus--buffer)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "four" text))
        ;; Oldest now sits at the bottom, so trimming works from the tail.
        (should-not (string-match-p "one" text))))))

(ert-deftest agent-focus-test-block-is-rewritten-not-appended ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (dotimes (_ 3)
      (agent-focus-observe '(:kind "act" :session "s1" :label "repo"
                                   :detail "Edit a.el")))
    (with-current-buffer (agent-focus--buffer)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        ;; One block at the foot, however many events went through -- the
        ;; separator is what would multiply if it were appended each time.
        (should (= 1 (length (seq-filter
                              (lambda (line) (string-prefix-p "──" line))
                              (split-string text "\n")))))))))

(ert-deftest agent-focus-test-hottest-needs-more-than-one-touch ()
  (agent-focus-test--with-session state
    (agent-focus-fold state '(:kind "act" :file "a.el"))
    (should-not (agent-focus--hottest state))
    (agent-focus-fold state '(:kind "act" :file "a.el"))
    (should (string-match-p "a\\.el" (agent-focus--hottest state)))))


;;; Phase

(defun agent-focus-test--acts (state n tool &optional detail)
  "Fold N act events running TOOL with DETAIL into STATE."
  (dotimes (_ n)
    (agent-focus-fold state (list :kind "act" :tool tool :detail detail))))

(ert-deftest agent-focus-test-phase-abstains-until-there-is-a-tendency ()
  (agent-focus-test--with-session state
    (should-not (agent-focus--phase state))
    (agent-focus-test--acts state 1 "Read")
    ;; One classified step is noise, not a phase.
    (should-not (agent-focus--phase state))
    (agent-focus-test--acts state 1 "Read")
    (should (equal (agent-focus--phase state) "exploring"))))

(ert-deftest agent-focus-test-phase-follows-the-dominant-tool ()
  (agent-focus-test--with-session state
    (agent-focus-test--acts state 4 "Read")
    (should (equal (agent-focus--phase state) "exploring"))
    (agent-focus-test--acts state 5 "Edit")
    (should (equal (agent-focus--phase state) "editing"))))

(ert-deftest agent-focus-test-phase-recognises-verification-in-a-shell-call ()
  (agent-focus-test--with-session state
    (agent-focus-test--acts state 2 "Bash" "Run the test suite: make test")
    (should (equal (agent-focus--phase state) "verifying"))))

(ert-deftest agent-focus-test-phase-ignores-unclassifiable-shell-calls ()
  (agent-focus-test--with-session state
    ;; Shell is used for everything; guessing from it would be worse than
    ;; abstaining, so an ordinary command must not create a phase.
    (agent-focus-test--acts state 5 "Bash" "git status")
    (should-not (agent-focus--phase state))))

(ert-deftest agent-focus-test-phase-verify-pattern-is-shell-only ()
  (agent-focus-test--with-session state
    ;; Found live: reading files called Cask and Makefile classified one as
    ;; verifying and one as exploring, so neither reached a majority and the
    ;; panel showed no phase at all.  A file name is not a build step.
    (agent-focus-test--acts state 1 "Read" "Cask")
    (agent-focus-test--acts state 1 "Read" "Makefile")
    (should (equal (agent-focus--phase state) "exploring"))))

(ert-deftest agent-focus-test-phase-blocked-overrides-the-tool-mix ()
  (agent-focus-test--with-session state
    (agent-focus-test--acts state 5 "Edit")
    (should (equal (agent-focus--phase state) "editing"))
    (agent-focus-test--fail state 2)
    (should (equal (agent-focus--phase state) "blocked"))
    (agent-focus-fold state '(:kind "think" :tool "Edit" :ms 5))
    (should (equal (agent-focus--phase state) "editing"))))

(ert-deftest agent-focus-test-phase-says-waiting-once-the-turn-ends ()
  (agent-focus-test--with-session state
    (agent-focus-test--acts state 3 "Read")
    (should (equal (agent-focus--phase state) "exploring"))
    (agent-focus-fold state '(:kind "idle"))
    ;; The tool window still holds those reads.  Reporting "exploring" over
    ;; a log line that says the turn is over describes what the work was
    ;; while presenting it as what the work is.
    (should (equal (agent-focus--phase state) "waiting"))))

(ert-deftest agent-focus-test-waiting-outranks-blocked ()
  (agent-focus-test--with-session state
    (agent-focus-test--fail state 3)
    (should (equal (agent-focus--phase state) "blocked"))
    (agent-focus-fold state '(:kind "idle"))
    ;; A turn that ended badly is still a turn that ended.
    (should (equal (agent-focus--phase state) "waiting"))))

(ert-deftest agent-focus-test-acting-again-ends-waiting ()
  (agent-focus-test--with-session state
    (agent-focus-test--acts state 3 "Edit")
    (agent-focus-fold state '(:kind "idle"))
    (should (equal (agent-focus--phase state) "waiting"))
    (agent-focus-test--acts state 1 "Edit")
    (should (equal (agent-focus--phase state) "editing"))))

(ert-deftest agent-focus-test-a-new-prompt-ends-waiting ()
  (agent-focus-test--with-session state
    (agent-focus-test--acts state 3 "Edit")
    (agent-focus-fold state '(:kind "idle"))
    (agent-focus-fold state '(:kind "prompt" :text "next"))
    (should-not (agent-focus-state-idle state))))

(ert-deftest agent-focus-test-phase-window-forgets-old-steps ()
  (agent-focus-test--with-session state
    (let ((agent-focus-phase-window 4))
      (agent-focus-test--acts state 4 "Read")
      (should (equal (agent-focus--phase state) "exploring"))
      (agent-focus-test--acts state 4 "Edit")
      ;; The reads have fallen out of the window entirely.
      (should (equal (agent-focus--phase state) "editing")))))


;;; Stated intent

(ert-deftest agent-focus-test-intent-is-recorded-with-its-context ()
  (agent-focus-test--with-session state
    (agent-focus-test--acts state 3 "Edit" "a.el")
    (agent-focus-fold state '(:kind "intent" :text "narrowing the stale queue"))
    (should (equal (agent-focus-state-intent state) "narrowing the stale queue"))
    (should (= (agent-focus-state-intent-step state) 3))
    (should-not (agent-focus--intent-stale-p state))))

(ert-deftest agent-focus-test-intent-goes-stale-after-enough-steps ()
  (agent-focus-test--with-session state
    (let ((agent-focus-intent-stale-steps 4))
      (agent-focus-fold state '(:kind "intent" :text "reading the mpv layer"))
      (agent-focus-test--acts state 4 "Read")
      (should-not (agent-focus--intent-stale-p state))
      (agent-focus-test--acts state 1 "Read")
      ;; The agent stopped narrating; that is visible rather than hidden.
      (should (agent-focus--intent-stale-p state)))))

(ert-deftest agent-focus-test-intent-goes-stale-when-the-work-moves ()
  (agent-focus-test--with-session state
    (dotimes (_ 2) (agent-focus-fold state '(:kind "act" :file "a.el")))
    (agent-focus-fold state '(:kind "intent" :text "fixing a.el"))
    (should-not (agent-focus--intent-stale-p state))
    (dotimes (_ 3) (agent-focus-fold state '(:kind "act" :file "b.el")))
    ;; Measured state contradicting the claim is the whole point.
    (should (agent-focus--intent-stale-p state))))

(ert-deftest agent-focus-test-gaining-a-hottest-file-is-not-staleness ()
  (agent-focus-test--with-session state
    (agent-focus-fold state '(:kind "intent" :text "starting out"))
    (should-not (agent-focus--hottest state))
    (dotimes (_ 2) (agent-focus-fold state '(:kind "act" :file "a.el")))
    ;; Going from no hottest file to having one is ordinary progress, not
    ;; evidence that the claim was abandoned.
    (should-not (agent-focus--intent-stale-p state))))

(ert-deftest agent-focus-test-a-new-task-drops-the-intent ()
  (agent-focus-test--with-session state
    (agent-focus-fold state '(:kind "intent" :text "old goal"))
    (agent-focus-fold state '(:kind "prompt" :text "something else"))
    (should-not (agent-focus-state-intent state))))

(ert-deftest agent-focus-test-intent-never-feeds-a-signal ()
  (agent-focus-test--with-session state
    (let ((agent-focus-fail-streak-threshold 2))
      (agent-focus-fold state '(:kind "intent" :text "everything is fine"))
      (agent-focus-test--fail state 2)
      ;; A claim must not be able to talk the measured state out of a signal.
      (should (agent-focus--signal state)))))

(ert-deftest agent-focus-test-panel-marks-a-stale-claim ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil)
        (agent-focus-intent-stale-steps 2))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    (agent-focus-set-intent "checking the render path" "s1")
    (let ((panel (substring-no-properties
                  (agent-focus--panel (gethash "s1" agent-focus-registry)))))
      (should (string-match-p "checking the render path" panel))
      (should-not (string-match-p "stale" panel)))
    (dotimes (_ 3)
      (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit")))
    (should (string-match-p
             "stale"
             (substring-no-properties
              (agent-focus--panel (gethash "s1" agent-focus-registry)))))))

(ert-deftest agent-focus-test-report-marks-the-intent-as-claimed ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    (agent-focus-set-intent "a claim" "s1")
    (let ((report (agent-focus-report "s1")))
      ;; The key name has to say it is self-reported: this state is fed back
      ;; to the agent, and a claim read as a measurement has no ground truth.
      (should (equal (plist-get report :claimed-intent) "a claim"))
      (should-not (plist-get report :claimed-intent-stale)))))


;;; Task history

(ert-deftest agent-focus-test-finished-tasks-are-archived ()
  (agent-focus-test--with-session state
    (agent-focus-fold state '(:kind "prompt" :text "first task"))
    (agent-focus-test--acts state 3 "Edit")
    (agent-focus-test--fail state 2)
    (agent-focus-fold state '(:kind "prompt" :text "second task"))
    (let ((old (car (agent-focus-state-tasks state))))
      (should (equal (plist-get old :task) "first task"))
      (should (= (plist-get old :steps) 3))
      (should (= (plist-get old :failures) 2)))
    ;; The new task starts from zero on both counters.
    (should (= (agent-focus-state-steps state) 0))
    (should (= (agent-focus-state-task-failures state) 0))))

(ert-deftest agent-focus-test-first-prompt-archives-nothing ()
  (agent-focus-test--with-session state
    (agent-focus-fold state '(:kind "prompt" :text "only task"))
    (should-not (agent-focus-state-tasks state))))

(ert-deftest agent-focus-test-task-failures-outlive-the-streak ()
  (agent-focus-test--with-session state
    (agent-focus-fold state '(:kind "prompt" :text "t"))
    (agent-focus-test--fail state 2)
    (agent-focus-fold state '(:kind "think" :tool "Bash" :ms 5))
    (agent-focus-test--fail state 1)
    ;; The streak resets on success; the task tally is what says how rough
    ;; the task has been overall.
    (should (= (agent-focus-state-fail-streak state) 1))
    (should (= (agent-focus-state-task-failures state) 3))))


;;; Reading the hook payload

(defun agent-focus-test--payload (json)
  "Parse JSON the way the hook does."
  (json-parse-string json :object-type 'alist :null-object nil
                     :false-object nil))

(ert-deftest agent-focus-test-squish-and-clip ()
  (should (equal (agent-focus--squish "  make   test\n  --verbose ")
                 "make test --verbose"))
  (should (equal (agent-focus--clip "abcdef" 3) "abc…"))
  (should (equal (agent-focus--clip "abc" 3) "abc")))

(ert-deftest agent-focus-test-rel-path ()
  (should (equal (agent-focus--rel "/repo/sub/a.el" "/repo") "sub/a.el"))
  ;; Outside the session directory it becomes a bare name, so the same
  ;; logical file reached from two checkouts renders identically.
  (should (equal (agent-focus--rel "/elsewhere/a.el" "/repo") "a.el"))
  (should (equal (agent-focus--rel "/repo/a.el" "") "a.el")))

(ert-deftest agent-focus-test-duration-format ()
  (should (equal (agent-focus--dur 12) "12ms"))
  (should (equal (agent-focus--dur 8432) "8.4s"))
  (should (equal (agent-focus--dur 8000) "8s")))

(ert-deftest agent-focus-test-detail-prefers-the-description ()
  (let ((payload (agent-focus-test--payload
                  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make test\",\"description\":\"Run the suite\"}}")))
    ;; Bash and Task carry a human-written line; it reads better than the
    ;; shell it expands to.
    (should (equal (agent-focus--detail "act" payload) "Bash  Run the suite"))))

(ert-deftest agent-focus-test-detail-falls-back-through-the-ladder ()
  (should (equal (agent-focus--detail
                  "act" (agent-focus-test--payload
                         "{\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"defun foo\"}}"))
                 "Grep  defun foo"))
  (should (equal (agent-focus--detail
                  "act" (agent-focus-test--payload
                         "{\"tool_name\":\"TodoWrite\",\"tool_input\":{\"todos\":[1]}}"))
                 "TodoWrite  {\"todos\":[1]}"))
  (should (equal (agent-focus--detail
                  "act" (agent-focus-test--payload "{\"tool_name\":\"Nothing\"}"))
                 "Nothing")))

(ert-deftest agent-focus-test-detail-marks-outcomes ()
  (should (equal (agent-focus--detail
                  "think" (agent-focus-test--payload
                           "{\"tool_name\":\"Bash\",\"duration_ms\":12,\"tool_response\":{\"interrupted\":false}}"))
                 "Bash ✓  12ms"))
  ;; An interrupted call must not claim success.
  (should (equal (agent-focus--detail
                  "think" (agent-focus-test--payload
                           "{\"tool_name\":\"Bash\",\"duration_ms\":2100,\"tool_response\":{\"interrupted\":true}}"))
                 "Bash ✗  2.1s"))
  ;; A failure line carries no inline marker: the kind renders ✗ already.
  (should (equal (agent-focus--detail
                  "fail" (agent-focus-test--payload
                          "{\"tool_name\":\"Edit\",\"duration_ms\":30}"))
                 "Edit  30ms")))

(ert-deftest agent-focus-test-event-carries-structured-fields ()
  (let ((event (agent-focus--event
                "act" (agent-focus-test--payload
                       "{\"session_id\":\"s1\",\"cwd\":\"/home/x/repo\",\"agent_id\":\"a9\",\"agent_type\":\"Explore\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/home/x/repo/a.el\"}}"))))
    (should (equal (plist-get event :session) "s1"))
    (should (equal (plist-get event :label) "repo"))
    (should (equal (plist-get event :agent) "a9"))
    (should (equal (plist-get event :agent-type) "Explore"))
    (should (equal (plist-get event :file) "a.el"))
    (should (equal (plist-get event :detail) "Edit  a.el"))))

(ert-deftest agent-focus-test-event-without-agent-is-a-root ()
  (let ((event (agent-focus--event
                "act" (agent-focus-test--payload
                       "{\"session_id\":\"s1\",\"cwd\":\"/repo\",\"tool_name\":\"Bash\"}"))))
    (should-not (plist-get event :agent))
    (should-not (plist-get event :file))))

(ert-deftest agent-focus-test-hook-folds-and-answers ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil)
        (agent-focus-fail-streak-threshold 2)
        (in (make-temp-file "af-in"))
        (out (make-temp-file "af-out")))
    (unwind-protect
        (progn
          (dotimes (_ 2)
            (with-temp-file in
              (insert "{\"session_id\":\"s1\",\"cwd\":\"/repo\",\"tool_name\":\"Bash\",\"hook_event_name\":\"PostToolUseFailure\"}"))
            (agent-focus-hook "fail" in out))
          (let ((answer (with-temp-buffer (insert-file-contents out)
                                          (buffer-string))))
            (should (string-match-p "additionalContext" answer))
            (should (string-match-p "consecutive tool failures" answer))))
      (ignore-errors (delete-file in))
      (ignore-errors (delete-file out)))))

(ert-deftest agent-focus-test-hook-consumes-its-input-file ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil)
        (in (make-temp-file "af-in"))
        (out (make-temp-file "af-out")))
    (unwind-protect
        (progn
          (with-temp-file in (insert "{\"session_id\":\"s1\",\"tool_name\":\"Bash\"}"))
          (agent-focus-hook "act" in out)
          ;; Otherwise every tool call would leave a file behind.
          (should-not (file-exists-p in)))
      (ignore-errors (delete-file in))
      (ignore-errors (delete-file out)))))

(ert-deftest agent-focus-test-hook-survives-a-bad-payload ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil)
        (in (make-temp-file "af-in"))
        (out (make-temp-file "af-out")))
    (unwind-protect
        (progn
          (with-temp-file in (insert "this is not json"))
          ;; Must not signal: the HUD may never fail a tool call.  But it
          ;; has to leave a trace, since going quiet is how this has broken
          ;; before.
          (should-not (agent-focus-hook "act" in out))
          (with-current-buffer (agent-focus--buffer)
            (should (string-match-p
                     "hook failed"
                     (buffer-substring-no-properties (point-min) (point-max))))))
      (ignore-errors (delete-file in))
      (ignore-errors (delete-file out)))))


;;; Trailing reasoning

(ert-deftest agent-focus-test-transcript-tail-stops-at-whole-lines ()
  (let ((file (make-temp-file "af-tr")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "one\ntwo\nhalf-writ"))
          (let ((tail (agent-focus--transcript-tail file 0)))
            ;; The partial trailing line must not be consumed, or it would
            ;; be parsed as truncated JSON and lost when completed.
            (should (equal (car tail) "one\ntwo\n"))
            (should (= (cdr tail) 8))
            (should-not (agent-focus--transcript-tail file (cdr tail)))))
      (delete-file file))))

(ert-deftest agent-focus-test-thinking-extracted-from-transcript-lines ()
  (let ((text (concat
               "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"First thought. Second one.\"},{\"type\":\"tool_use\"}]}}\n"
               "{\"type\":\"user\"}\n"
               "not json at all\n"
               "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\"}]}}\n")))
    (should (equal (agent-focus--thinking text) '("First thought")))))

(ert-deftest agent-focus-test-first-sight-of-a-session-is-not-replayed ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil)
        (file (make-temp-file "af-tr")))
    (unwind-protect
        (let ((state (agent-focus-state "s1" "repo"))
              (payload (list (cons 'transcript_path file))))
          (with-temp-file file
            (insert "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"Old backlog.\"}]}}\n"))
          (agent-focus--emit-reasoning state payload)
          ;; The first tool call of a session must not dump its whole
          ;; history into the buffer.
          (with-current-buffer (agent-focus--buffer)
            (should-not (string-match-p
                         "Old backlog"
                         (buffer-substring-no-properties (point-min) (point-max)))))
          (should (> (agent-focus-state-transcript-pos state) 0))
          ;; What appears afterwards is shown.
          (with-temp-buffer
            (insert "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"Fresh thought.\"}]}}\n")
            (append-to-file (point-min) (point-max) file))
          (agent-focus--emit-reasoning state payload)
          (with-current-buffer (agent-focus--buffer)
            (should (string-match-p
                     "Fresh thought"
                     (buffer-substring-no-properties (point-min) (point-max))))))
      (delete-file file))))


;;; Hosted by agent-shell

(defvar agent-shell--state)

(defmacro agent-focus-test--with-shell (specs &rest body)
  "Run BODY with fake agent-shell buffers for SPECS, a list of (NAME ID)."
  (declare (indent 1))
  `(let ((buffers nil))
     (unwind-protect
         (progn
           (dolist (spec ,specs)
             (let ((buffer (generate-new-buffer (car spec))))
               (push buffer buffers)
               (with-current-buffer buffer
                 (setq major-mode 'agent-shell-mode)
                 (setq-local agent-shell--state
                             (list (cons :session
                                         (list (cons :id (cadr spec)))))))))
           ,@body)
       (mapc #'kill-buffer buffers))))

(ert-deftest agent-focus-test-shell-buffer-found-by-session-id ()
  (agent-focus-test--with-shell '(("Claude Agent @ repo" "s1")
                                  ("Claude Agent @ repo<2>" "s2"))
    (let ((found (agent-focus--shell-buffer "s2")))
      ;; Assert the buffer before naming it: (buffer-name nil) quietly
      ;; returns the *current* buffer's name, which turned a nil result
      ;; into a confusing mismatch instead of an obvious one.
      (should (bufferp found))
      (should (equal (buffer-name found) "Claude Agent @ repo<2>")))
    (should-not (agent-focus--shell-buffer "nobody"))))

(ert-deftest agent-focus-test-label-comes-from-the-host ()
  (agent-focus-test--with-shell '(("Claude Agent @ repo<2>" "s2"))
    (let ((agent-focus-registry (make-hash-table :test 'equal)))
      ;; The directory-derived label is overridden: agent-shell already
      ;; numbers its buffers, and its name does not drift when the session
      ;; changes working directory.
      (should (equal (agent-focus-state-label (agent-focus-state "s2" "repo"))
                     "repo<2>")))))

(ert-deftest agent-focus-test-liveness-comes-from-the-buffer ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-session-ttl 300))
    (agent-focus-test--with-shell '(("Claude Agent @ repo" "s1"))
      (let ((state (agent-focus-state "s1" "repo")))
        ;; Long past the TTL, but the process is demonstrably running.
        (setf (agent-focus-state-last-seen state) (time-subtract (current-time) 9999))
        (should (agent-focus--active-p state))))))

(ert-deftest agent-focus-test-a-closed-session-is-not-active ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-session-ttl 300))
    (agent-focus-test--with-shell '(("Claude Agent @ repo" "s1"))
      (agent-focus-state "s1" "repo")
      (agent-focus-state "gone" "repo"))
    ;; Outside the macro the buffers are killed: a hosted session whose
    ;; buffer is gone is gone, however recently it acted.
    (agent-focus-test--with-shell '(("Claude Agent @ repo" "s1"))
      (should (agent-focus--active-p (gethash "s1" agent-focus-registry)))
      (should-not (agent-focus--active-p (gethash "gone" agent-focus-registry))))))

(ert-deftest agent-focus-test-subagents-still-use-the-ttl ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-session-ttl 300))
    (agent-focus-test--with-shell '(("Claude Agent @ repo" "s1"))
      (let ((child (agent-focus-state "s1/a1" "Explore" "s1" "Explore")))
        ;; A subagent has no buffer of its own, so it keeps the fallback.
        (should (agent-focus--active-p child))
        (setf (agent-focus-state-last-seen child) (time-subtract (current-time) 600))
        (should-not (agent-focus--active-p child))))))

(ert-deftest agent-focus-test-session-line-is-visitable ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-test--with-shell '(("Claude Agent @ repo" "s1"))
      (agent-focus-observe '(:kind "act" :session "s1" :label "repo"
                                   :detail "Edit a.el"))
      (let ((line (agent-focus--panel (gethash "s1" agent-focus-registry))))
        (should (equal (get-text-property 1 'agent-focus-session line) "s1"))
        (should (get-text-property 1 'keymap line))))))

(ert-deftest agent-focus-test-unhosted-line-is-not-visitable ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    ;; Nothing to jump to, so the line must not pretend otherwise.
    (let ((line (agent-focus--panel (gethash "s1" agent-focus-registry))))
      (should-not (get-text-property 1 'agent-focus-session line)))))


;;; Refresh timer

(ert-deftest agent-focus-test-working-p-ignores-an-idle-session ()
  (let ((agent-focus-registry (make-hash-table :test 'equal)))
    (let ((state (agent-focus-state "s1" "repo")))
      (agent-focus-fold state '(:kind "act" :tool "Edit"))
      (should (agent-focus--working-p))
      (agent-focus-fold state '(:kind "idle"))
      ;; A clock ticking over an agent that has finished its turn claims
      ;; work that is not being done -- and would keep the timer alive for
      ;; as long as Emacs runs.
      (should-not (agent-focus--working-p)))))

(ert-deftest agent-focus-test-working-p-ignores-a-stale-session ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-session-ttl 300))
    (let ((state (agent-focus-state "s1" "repo")))
      (agent-focus-fold state '(:kind "act" :tool "Edit"))
      (setf (agent-focus-state-last-seen state) (time-subtract (current-time) 600))
      (should-not (agent-focus--working-p)))))

(ert-deftest agent-focus-test-a-working-subagent-keeps-the-clock-running ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "Agent"))
    (agent-focus-observe '(:kind "idle" :session "s1" :label "repo"
                                 :detail "waiting for you"))
    (should-not (agent-focus--working-p))
    (agent-focus-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Read"))
    ;; The parent may look idle while a child it spawned is still going.
    (should (agent-focus--working-p))))

(ert-deftest agent-focus-test-tick-retires-the-timer-when-work-stops ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil)
        (agent-focus--timer nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "Edit"))
    (agent-focus--ensure-timer)
    (should (timerp agent-focus--timer))
    ;; Starting twice must not leave a second timer running unnoticed.
    (let ((first agent-focus--timer))
      (agent-focus--ensure-timer)
      (should (eq first agent-focus--timer)))
    (agent-focus-observe '(:kind "idle" :session "s1" :label "repo"
                                 :detail "waiting for you"))
    (agent-focus--tick)
    (should-not agent-focus--timer)
    (cancel-function-timers #'agent-focus--tick)))

(ert-deftest agent-focus-test-tick-redraws-only-the-block ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo"
                                 :detail "Edit a.el"))
    (let ((before (with-current-buffer (agent-focus--buffer)
                    (buffer-substring-no-properties (point-min) (point-max)))))
      (agent-focus--redraw-block)
      (let ((after (with-current-buffer (agent-focus--buffer)
                     (buffer-substring-no-properties (point-min) (point-max)))))
        ;; Same number of lines: the block is replaced, never appended, and
        ;; the log is not touched.
        (should (= (length (split-string before "\n"))
                   (length (split-string after "\n"))))
        (should (string-match-p "Edit a\\.el" after))))))


;;; Registry and queries

(ert-deftest agent-focus-test-sessions-fold-independently ()
  (let ((agent-focus-registry (make-hash-table :test 'equal)))
    (let ((a (agent-focus-state "s1" "alpha"))
          (b (agent-focus-state "s2" "beta")))
      (agent-focus-test--fail a 3)
      (agent-focus-fold b '(:kind "act" :file "b.el"))
      (should (= (agent-focus-state-fail-streak a) 3))
      (should (= (agent-focus-state-fail-streak b) 0))
      (should (= (hash-table-count agent-focus-registry) 2)))))

(ert-deftest agent-focus-test-touching-matches-across-sessions ()
  (let ((agent-focus-registry (make-hash-table :test 'equal)))
    (let ((a (agent-focus-state "s1" "main"))
          (b (agent-focus-state "s2" "worktree")))
      ;; Same logical file reached through two checkouts: the query has to
      ;; see one artifact, or it cannot warn about contention at all.
      (agent-focus-fold a '(:kind "act" :file "supersonic.el"))
      (agent-focus-fold b '(:kind "act" :file "sub/supersonic.el"))
      (should (= 2 (length (agent-focus-touching "supersonic.el"))))
      (should (null (agent-focus-touching "unrelated.el"))))))

(ert-deftest agent-focus-test-active-count-honours-ttl ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-session-ttl 300))
    (let ((a (agent-focus-state "s1" "alpha"))
          (b (agent-focus-state "s2" "beta")))
      (ignore a)
      (should (= (agent-focus--active-count) 2))
      ;; A crashed session must drop out rather than linger as state that
      ;; still looks current.
      (setf (agent-focus-state-last-seen b)
            (time-subtract (current-time) 600))
      (should (= (agent-focus--active-count) 1)))))

(ert-deftest agent-focus-test-label-column-keeps-the-unique-suffix ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-label-width 8))
    (agent-focus-state "s1" "supersonic.el")
    (agent-focus-state "s2" "supersonic.el")
    (let ((a (agent-focus--label-column "supersonic.el"))
          (b (agent-focus--label-column "supersonic.el<2>")))
      ;; Plain truncation cuts both to "superson", putting the two agents
      ;; back where uniquifying the labels started.
      (should-not (equal a b))
      (should (string-suffix-p "<2>" b))
      (should (= (length a) (length b))))))

(ert-deftest agent-focus-test-label-column-appears-only-when-shared ()
  (let ((agent-focus-registry (make-hash-table :test 'equal)))
    (agent-focus-state "s1" "alpha")
    (should-not (agent-focus--label-column "alpha"))
    (agent-focus-state "s2" "beta")
    (should (agent-focus--label-column "alpha"))))

;;; Subagents

(ert-deftest agent-focus-test-key-composes-session-and-agent ()
  (should (equal (agent-focus-key "s1") "s1"))
  (should (equal (agent-focus-key "s1" nil) "s1"))
  (should (equal (agent-focus-key "s1" "") "s1"))
  (should (equal (agent-focus-key "s1" "a9") "s1/a9")))

(ert-deftest agent-focus-test-subagent-work-stays-out-of-the-parent ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo"
                                 :tool "Bash" :detail "Bash"))
    (dotimes (_ 4)
      (agent-focus-observe '(:kind "act" :session "s1" :agent "a9"
                                   :agent-type "Explore"
                                   :tool "Read" :file "x.el" :detail "Read x.el")))
    (let ((parent (gethash "s1" agent-focus-registry))
          (child (gethash "s1/a9" agent-focus-registry)))
      ;; Subagent calls carry the parent session id, so keying on that alone
      ;; would report five steps here instead of one.
      (should (= (agent-focus-state-steps parent) 1))
      (should (= (agent-focus-state-steps child) 4))
      (should (equal (agent-focus-state-parent child) "s1"))
      (should (equal (agent-focus-state-label child) "Explore")))))

(ert-deftest agent-focus-test-subagent-failures-do-not-signal-the-parent ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil)
        (agent-focus-fail-streak-threshold 3)
        (signals nil))
    (dotimes (_ 3)
      (push (agent-focus-observe '(:kind "fail" :session "s1" :agent "a9"
                                         :agent-type "Explore"
                                         :tool "Read" :detail "Read"))
            signals))
    ;; The child hit the threshold and is told so; the parent, which did
    ;; nothing wrong, must not be.
    (should (car signals))
    (should (= 0 (agent-focus-state-fail-streak
                  (agent-focus-state "s1" "repo"))))
    (should-not (agent-focus--signal (agent-focus-state "s1" "repo")))))

(ert-deftest agent-focus-test-parent-sees-subagents-aggregated ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo"
                                 :tool "Agent" :detail "Agent"))
    (agent-focus-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Read"))
    (agent-focus-observe '(:kind "act" :session "s1" :agent "a2"
                                 :agent-type "Plan" :detail "Read"))
    (agent-focus-observe '(:kind "act" :session "s1" :agent "a2"
                                 :agent-type "Plan" :detail "Read"))
    (let* ((report (agent-focus-report "s1"))
           (subs (plist-get report :subagents)))
      (should (= (plist-get report :task-steps) 1))
      (should (= (plist-get subs :total) 2))
      (should (= (plist-get subs :running) 2))
      (should (= (plist-get subs :steps) 3))
      (should (equal (sort (mapcar #'car (plist-get subs :each)) #'string<)
                     '("Explore" "Plan"))))))

(ert-deftest agent-focus-test-report-omits-subagents-when-there-are-none ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo"
                                 :tool "Bash" :detail "Bash"))
    (should-not (plist-member (agent-focus-report "s1") :subagents))))

(ert-deftest agent-focus-test-subagent-stop-marks-it-done ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "Bash"))
    (agent-focus-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Read"))
    (let ((subs (plist-get (agent-focus-report "s1") :subagents)))
      (should (= (plist-get subs :running) 1))
      (should (equal (plist-get (cdr (car (plist-get subs :each))) :status)
                     "running")))
    ;; Finishing is an event, not something inferred from going quiet: a
    ;; subagent that just returned is still well inside the TTL.
    (agent-focus-observe '(:kind "done" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Explore finished"))
    (let ((subs (plist-get (agent-focus-report "s1") :subagents)))
      (should (= (plist-get subs :running) 0))
      (should (equal (plist-get (cdr (car (plist-get subs :each))) :status)
                     "done")))))

(ert-deftest agent-focus-test-subagent-without-end-event-goes-stale ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil)
        (agent-focus-session-ttl 300))
    (agent-focus-observe '(:kind "act" :session "s1" :label "repo" :detail "Bash"))
    (agent-focus-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Read"))
    (setf (agent-focus-state-last-seen (gethash "s1/a1" agent-focus-registry))
          (time-subtract (current-time) 600))
    ;; Distinguished from "done" on purpose: this one vanished without
    ;; saying so, and a report that called it finished would be guessing.
    (let ((subs (plist-get (agent-focus-report "s1") :subagents)))
      (should (= (plist-get subs :running) 0))
      (should (equal (plist-get (cdr (car (plist-get subs :each))) :status)
                     "stale")))))

(ert-deftest agent-focus-test-done-clears-the-in-flight-step ()
  (let ((agent-focus-registry (make-hash-table :test 'equal)))
    (let ((child (agent-focus-state "s1/a1" "Explore" "s1" "Explore")))
      (agent-focus-fold child '(:kind "act" :tool "Read" :file "a.el"))
      (should (agent-focus-state-step child))
      (agent-focus-fold child '(:kind "done"))
      (should-not (agent-focus-state-step child))
      (should (agent-focus-state-done child)))))

(ert-deftest agent-focus-test-done-never-retires-a-root-session ()
  (agent-focus-test--with-session state
    ;; If SubagentStop turns out not to carry an agent_id, the event lands on
    ;; the parent key.  Marking a live session finished would make every
    ;; later reading wrong, so a done without a parent is dropped.
    (agent-focus-fold state '(:kind "done"))
    (should-not (agent-focus-state-done state))
    (should (agent-focus--active-p state))))

(ert-deftest agent-focus-test-observe-returns-signal-and-folds-it-back ()
  (let ((agent-focus-registry (make-hash-table :test 'equal))
        (agent-focus-auto-display nil)
        (agent-focus-fail-streak-threshold 2))
    (agent-focus-observe '(:kind "fail" :session "s1" :label "alpha"
                                 :tool "Bash" :detail "Bash 10ms"))
    (should-not (agent-focus-observe '(:kind "act" :session "s1" :label "alpha"
                                             :tool "Bash" :detail "Bash")))
    (let ((signal (agent-focus-observe
                   '(:kind "fail" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash 10ms"))))
      (should signal)
      ;; An emitted observation is itself part of the state, so that "how
      ;; often did the agent have to be told" stays observable.
      (should (= 1 (length (agent-focus-state-signals
                            (gethash "s1" agent-focus-registry))))))))

(provide 'agent-focus-tests)
;;; agent-focus-tests.el ends here
