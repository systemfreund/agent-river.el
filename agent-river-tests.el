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
      ;; One line per session heading.
      (should (= (length lines) 2))
      ;; Every block line is an outline heading (`* ' at column zero).
      (should (string-prefix-p "* " (nth 0 lines)))
      (should (string-prefix-p "* " (nth 1 lines)))
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
        (should (string-match-p "second" (nth 1 lines)))
        (should (string-match-p "first" (nth 2 lines)))))))

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

(ert-deftest agent-river-test-a-blank-line-closes-the-block ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                 :detail "Edit a.el"))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                 :detail "Edit b.el"))
    (with-current-buffer (agent-river--buffer)
      (save-excursion
        (goto-char (point-min))
        ;; One session line, then the separator, then the newest event.
        (should (looking-at-p "\\*+ "))
        (forward-line 1)
        (should (looking-at-p "$"))
        (forward-line 1)
        (should (looking-at-p "[0-9][0-9]:"))
        ;; And the separator belongs to the block, so the marker everything
        ;; downstream reads still points at the newest log line rather than
        ;; at the blank one.
        (should (= (point) (marker-position agent-river--block-end))))
      ;; Redrawn, not accumulated: a block that grew a blank line per event
      ;; would push the log down the buffer one line at a time.
      (agent-river--redraw-block)
      (agent-river--redraw-block)
      (should-not (string-match-p "\n\n\n"
                                  (buffer-substring-no-properties
                                   (point-min) (point-max)))))))

(ert-deftest agent-river-test-block-is-rewritten-not-appended ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (dotimes (_ 3)
      (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                   :detail "Edit a.el")))
    (with-current-buffer (agent-river--buffer)
      ;; The block is rewritten, not appended -- it appears once at the head
      ;; whatever number of events went through.
      (let ((lines (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n")))
        (should (= 1 (length (seq-filter (lambda (l) (string-prefix-p "* repo" l)) lines))))))))

(ert-deftest agent-river-test-block-doubles-as-an-outline ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo" :detail "Read"))
    (with-current-buffer (agent-river--buffer)
      ;; TAB folds each session's details.  The block lines are level-1
      ;; headings.  The fold lives in overlays, so a later redraw unfolds it
      ;; again -- that is accepted, not a bug.
      (should (bound-and-true-p outline-minor-mode))
      (should (eq (lookup-key agent-river-mode-map (kbd "TAB"))
                  #'agent-river-toggle-at-point))
      (should (string-prefix-p
               "* repo"
               (buffer-substring-no-properties (point-min) (line-end-position)))))))

(ert-deftest agent-river-test-details-are-folded-until-asked ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                 :file "a.el" :detail "Edit"))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                 :file "b.el" :detail "Edit"))
    (agent-river-observe '(:kind "act" :session "s1" :label "repo"
                                 :file "b.el" :detail "Edit"))
    ;; Collapsed by default: the header is the whole session line, and the
    ;; block is exactly one line per session.
    (let ((block (substring-no-properties (agent-river--panel-block))))
      (should-not (string-match-p "hottest" block))
      (should-not (string-match-p "files:" block))
      (should (= 1 (length (split-string block "\n" t)))))
    (with-current-buffer (agent-river--buffer)
      (agent-river-toggle-details)
      (let ((block (substring-no-properties (agent-river--panel-block))))
        ;; Unfolded, the same measurement at a finer grain: the whole list,
        ;; most-touched first.  The header's parenthetical is its head, so
        ;; a separate `hottest' heading would only repeat it.
        (should (string-match-p "\\*\\* files: b\\.el 2 · a\\.el 1" block))
        (should-not (string-match-p "hottest" block))
        ;; And it folds back.
        (agent-river-toggle-details)
        (should-not (string-match-p "files:"
                                    (substring-no-properties
                                     (agent-river--panel-block))))))))

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

(ert-deftest agent-river-test-a-response-of-another-shape-does-not-throw ()
  ;; An MCP tool answers with an array of content parts, and the hook parses
  ;; arrays as vectors.  `alist-get' threw on one, and since that happened
  ;; while the event was still being built it cost the whole event: every
  ;; MCP call went unfolded and was logged as `hook failed' instead.
  (let ((payload (json-parse-string
                  "{\"tool_name\":\"mcp__emacs__eval-elisp\",
                    \"tool_response\":[{\"type\":\"text\",\"text\":\"ok\"}]}"
                  :object-type 'alist :null-object nil :false-object nil)))
    (should (equal (agent-river--detail "think" payload)
                   "mcp__emacs__eval-elisp ✓"))
    (should (equal (agent-river--outcome "think" payload) "✓"))
    (should-not (agent-river--interrupted-p payload))))

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
            (should (string-match-p "consecutive tool failures" answer))
            ;; The hook event's *name*.  This used to serialize the whole
            ;; event plist into the field, which handed Claude Code the
            ;; package's internals where it expected one string -- and once
            ;; the event carried a ✓ it also stopped the write to ask which
            ;; coding system to use, in a context where nobody can answer.
            (should (string-match-p "\"hookEventName\":\"PostToolUseFailure\""
                                    answer))))
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
         ;; Both outlive any one session in real use -- what agent-shell has
         ;; hosted here is remembered after the buffer dies, which is the
         ;; whole point of the index.  A test is an Emacs of its own, so it
         ;; starts with neither.
         (agent-river--shell-sessions (make-hash-table :test 'equal))
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
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1")
                                    ("Claude Agent @ other" "gone"))
      (let ((live (agent-river-state "s1" "repo"))
            (closed (agent-river-state "gone" "other")))
        (should (agent-river--active-p live))
        (should (agent-river--active-p closed))
        ;; A hosted session whose buffer is killed is over, however recently
        ;; it acted -- and it is the *index* that says so, since a look at
        ;; the buffers alive now cannot tell a session that lost its buffer
        ;; from one that never had one.
        (kill-buffer (agent-river--shell-buffer "gone"))
        (should (agent-river--active-p live))
        (should-not (agent-river--active-p closed))
        (should (agent-river--gone-p closed))))))

(ert-deftest agent-river-test-a-terminal-session-keeps-the-ttl ()
  ;; What the sticky flag cost: once agent-shell had hosted anything here it
  ;; became the authority over every root, so a session run from a terminal
  ;; -- which has no buffer here and never did -- read as inactive while it
  ;; was working.  Recorded per session, it simply keeps the fallback.
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-session-ttl 300))
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      (agent-river-state "s1" "repo")
      (let ((cli (agent-river-state "cli" "repo")))
        (should-not (agent-river--shell-hosted "cli"))
        (should (agent-river--active-p cli))
        (should-not (agent-river--gone-p cli))
        (setf (agent-river-state-last-seen cli) (time-subtract (current-time) 9999))
        (should-not (agent-river--active-p cli))
        (should-not (agent-river--gone-p cli))))))

(ert-deftest agent-river-test-a-session-is-looked-for-again-for-a-while ()
  ;; A negative remembered forever is cheaper and is a trap: a session whose
  ;; first event beats agent-shell to setting its id would be counted
  ;; unhosted for the rest of the Emacs session, with no label, no reasoning
  ;; lines and no RET, and nothing would ever say so.
  (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
    (should-not (agent-river--shell-buffer "late"))
    ;; The answer is remembered, so nothing is walked again just yet.
    (should (consp (gethash "late" agent-river--shell-sessions)))
    (let ((buffer (generate-new-buffer "Claude Agent @ late")))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (setq major-mode 'agent-shell-mode)
              (setq-local agent-shell--state
                          (list (cons :session (list (cons :id "late"))))))
            ;; Still inside the window, so still nil ...
            (should-not (agent-river--shell-buffer "late"))
            ;; ... and found once it is up.
            (puthash "late" (cons 'none (time-subtract (current-time)
                                                       (1+ agent-river--shell-rescan)))
                     agent-river--shell-sessions)
            (should (eq (agent-river--shell-buffer "late") buffer)))
        (kill-buffer buffer)))))

(ert-deftest agent-river-test-subagents-still-use-the-ttl ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-session-ttl 300))
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      (let ((child (agent-river-state "s1/a1" "Explore" "s1" "Explore")))
        ;; A subagent has no buffer of its own, so it keeps the fallback.
        (should (agent-river--active-p child))
        (setf (agent-river-state-last-seen child) (time-subtract (current-time) 600))
        (should-not (agent-river--active-p child))))))

(ert-deftest agent-river-test-gone-is-narrower-than-inactive ()
  ;; Inactive is an estimate wherever the TTL answers it, and a view that
  ;; withdraws a name or a marker has to act on facts: a buffer that was
  ;; killed, or a SubagentStop.  A session that has merely gone quiet is
  ;; quiet, not gone.
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-session-ttl 300))
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      ;; What the first event through `agent-river-observe' does: the one
      ;; session with a buffer here is recorded as having had one.
      (agent-river--ensure-shell-teardown "s1")
      (let ((hosted (agent-river-state "s1" "repo"))
            (elsewhere (agent-river-state "cli" "repo"))
            (child (agent-river-state "s1/a1" "Explore" "s1" "Explore")))
        (should-not (agent-river--gone-p hosted))
        ;; A session run from a terminal never had a buffer to lose, so its
        ;; silence says nothing -- where `agent-river--active-p', which takes
        ;; agent-shell for the authority over every root once it has seen
        ;; one, calls it inactive.
        (setf (agent-river-state-last-seen elsewhere) (time-subtract (current-time) 9999))
        (should-not (agent-river--active-p elsewhere))
        (should-not (agent-river--gone-p elsewhere))
        ;; A subagent is gone when it says so, and when its root is.
        (setf (agent-river-state-last-seen child) (time-subtract (current-time) 9999))
        (should-not (agent-river--gone-p child))
        (agent-river-fold child '(:kind "done"))
        (should (agent-river--gone-p child))
        (kill-buffer (agent-river--shell-buffer "s1"))
        ;; The kill hook the registration installed schedules a block redraw
        ;; there is no buffer for here.
        (cancel-function-timers #'agent-river--redraw-block)
        (should (agent-river--gone-p hosted))
        (should (agent-river--gone-p (agent-river-state "s1/a2" "Explore" "s1" "Explore")))))))

(ert-deftest agent-river-test-a-killed-session-marks-the-map-dirty ()
  ;; Nothing else can say so.  A killed session sends no further events, so
  ;; with no other agent running the map would have gone on naming it and
  ;; pointing at it until someone pressed `g'.
  (let ((agent-river--map-dirty nil))
    (unwind-protect
        (with-temp-buffer
          (agent-river--shell-died (current-buffer))
          (should agent-river--map-dirty))
      ;; The block redraw it also schedules has no buffer to draw into here.
      (cancel-function-timers #'agent-river--redraw-block))))

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

(defun agent-river-test--ago (seconds)
  "Return the time SECONDS ago, which is a marker\='s phase input."
  (time-subtract (current-time) seconds))

(ert-deftest agent-river-test-the-marker-cycles-through-its-frames ()
  (let ((agent-river-spinner-frames '("a" "b" "c"))
        (agent-river-spinner-interval 0.1))
    ;; Ages taken mid-frame rather than on a boundary: the age is measured
    ;; when the glyph is asked for, so an age of exactly one frame lands on
    ;; whichever side of the edge the clock happens to be.
    (should (equal (agent-river--spinner-glyph (agent-river-test--ago 0.05)) "a"))
    (should (equal (agent-river--spinner-glyph (agent-river-test--ago 0.15)) "b"))
    ;; The phase is an age rather than a counter, so it climbs without bound
    ;; and has to wrap.
    (should (equal (agent-river--spinner-glyph (agent-river-test--ago 0.35)) "a"))
    (should (equal (agent-river--spinner-glyph (agent-river-test--ago 100.05)) "b"))
    ;; An interval that could not divide anything leaves the bare star rather
    ;; than dividing by it.
    (let ((agent-river-spinner-interval 0))
      (should-not (agent-river--spinner-glyph (agent-river-test--ago 1))))))

(ert-deftest agent-river-test-two-turns-spin-out-of-phase ()
  ;; The markers used to share one counter, so every session showed the same
  ;; frame whatever it was doing -- a row of them moving as one, which reads
  ;; as a single animation about the block.  Two agents prompted a moment
  ;; apart are a moment apart, and the marker is the only thing that can say
  ;; so.
  (let ((agent-river-spinner-frames '("a" "b" "c" "d"))
        (agent-river-spinner-interval 0.1))
    (should-not (equal (agent-river--spinner-glyph (agent-river-test--ago 0.05))
                       (agent-river--spinner-glyph (agent-river-test--ago 0.25))))))

(ert-deftest agent-river-test-the-phase-is-the-turn-not-the-session ()
  ;; The turn is what the marker is about: it appears when a prompt arrives
  ;; and stops when the turn ends, so its phase starts where the work did.
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "prompt" :text "do the thing"))
    (should (equal (agent-river--spinning-since state)
                   (agent-river-state-task-started state)))
    ;; A session folded without a prompt -- a hook stream joined mid-turn --
    ;; still has to spin, so it falls back to its own clock.
    (agent-river-test--with-session fresh
      (should (equal (agent-river--spinning-since fresh)
                     (agent-river-state-started fresh))))))

(ert-deftest agent-river-test-no-frames-means-no-animation ()
  ;; The off switch, and the answer for a font without the glyphs: the bare
  ;; star, not a star with an empty display property over it.
  (agent-river-test--with-session state
    (let ((agent-river-spinner-frames nil))
      (should-not (agent-river--spinner-glyph (agent-river-test--ago 0)))
      (should (equal (agent-river--star state) "* "))
      (should-not (get-text-property 0 'agent-river-spinner
                                     (agent-river--star state))))))

(ert-deftest agent-river-test-only-a-running-turn-spins ()
  (agent-river-test--with-session state
    (let ((agent-river-spinner-frames '("✳")))
      (agent-river-fold state '(:kind "act" :tool "Edit" :file "a.el"))
      (let ((star (agent-river--star state)))
        (should (get-text-property 0 'agent-river-spinner star))
        (should (equal (get-text-property 0 'display star) "✳")))
      ;; The turn ends and the marker stops: a glyph still moving over an
      ;; agent that has finished claims work nobody is doing, which is the
      ;; same lie the refresh timer is gated against telling.
      (agent-river-fold state '(:kind "idle"))
      (should-not (agent-river--state-working-p state))
      (let ((star (agent-river--star state)))
        (should-not (get-text-property 0 'agent-river-spinner star))
        (should-not (get-text-property 0 'display star))))))

(ert-deftest agent-river-test-an-animated-marker-is-still-an-outline-heading ()
  ;; The whole reason the animation is a display property: `outline-regexp'
  ;; is matched against the buffer text, so a session line must read as a
  ;; heading while it spins.  Animating the character itself would make the
  ;; block stop being a document exactly when an agent started working.
  (agent-river-test--with-session state
    (let ((agent-river-spinner-frames '("✽")))
      (agent-river-fold state '(:kind "act" :tool "Edit" :file "a.el"))
      (let ((line (substring-no-properties (agent-river--panel state))))
        (should (string-prefix-p "* " line))
        (should (string-match-p "^\\*+ " line))))))

(ert-deftest agent-river-test-stopping-the-marker-puts-the-star-back ()
  ;; Clearing is part of stopping.  The last frame is a display property, so
  ;; a timer that only cancelled itself would leave every finished session
  ;; showing whichever glyph it stopped on.
  (let ((agent-river-spinner-frames '("✳"))
        (agent-river-spinner-interval 0.1))
    (with-temp-buffer
      (insert (propertize "*" 'agent-river-spinner (agent-river-test--ago 0)
                          'display "✽")
              " alpha\n")
      (setq agent-river--block-end (copy-marker (point) nil))
      ;; The mark carries the phase, so the painter needs nothing else to
      ;; know what this star should be showing.
      (agent-river--spinner-paint (current-buffer))
      (should (equal (get-text-property (point-min) 'display) "✳"))
      (agent-river--spinner-paint (current-buffer) t)
      (should-not (get-text-property (point-min) 'display))
      ;; And the text underneath was never what changed.
      (should (equal (char-after (point-min)) ?*)))))

(ert-deftest agent-river-test-the-animation-stops-when-the-marks-do ()
  ;; The gate the animation runs on.  It used to ask the registry on every
  ;; tick, six times a second, which for an agent-shell session means
  ;; walking every buffer in Emacs -- and the panel had already answered the
  ;; same question when it decided which stars to mark.
  (with-temp-buffer
    (insert "* alpha\n")
    (setq agent-river--block-end (copy-marker (point) nil))
    (should-not (agent-river--spinning-p (current-buffer)))
    (goto-char (point-min))
    (put-text-property (point-min) (1+ (point-min))
                       'agent-river-spinner (agent-river-test--ago 0))
    (should (agent-river--spinning-p (current-buffer)))
    ;; A buffer that is gone is not spinning either, which is what stops the
    ;; timer when the HUD is killed mid-turn.
    (should-not (agent-river--spinning-p nil))))

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

(ert-deftest agent-river-test-the-stream-reads-a-camel-case-edit-path ()
  (agent-river-test--with-watch
    ;; Claude's ACP `rawInput' for an edit names the target `filePath', not
    ;; `file_path'.  While the snake-case ladder missed it every edit went
    ;; uncounted and the dired heat never warmed -- measured, not guessed.
    (let ((event (car (agent-river--shell-events
                       (agent-river-test--tool-call
                        "c1" "pending"
                        '(:raw-input . ((filePath . "/repo/a.el"))))
                       "s1" "/repo"))))
      (should (equal (plist-get event :file) "a.el"))
      (should (equal (plist-get event :path) "/repo/a.el")))))

(ert-deftest agent-river-test-a-call-without-arguments-shows-its-title ()
  (agent-river-test--with-watch
    (should (equal (plist-get (car (agent-river--shell-events
                                    (agent-river-test--tool-call "c1" "pending")
                                    "s1" "/repo"))
                              :detail)
                   "read  Read a.el"))))

(ert-deftest agent-river-test-the-palettes-know-the-streams-dialect ()
  (agent-river-test--with-watch
    ;; A hooks-less session names its tools with the ACP kind, and while the
    ;; tables held Claude Code's names alone it matched none of them: no
    ;; phase ever, and no write ever -- which is the half of the landed
    ;; marker that only the fold can answer.
    (should (agent-river--writing-p "edit"))
    (should (equal (agent-river--bucket "edit" nil) "editing"))
    (should (equal (agent-river--bucket "read" nil) "exploring"))
    ;; The verify pattern reaches a shell call under either name.
    (should (equal (agent-river--bucket "execute" "make test") "verifying"))
    ;; Still abstaining where the kind says nothing about the work.
    (should-not (agent-river--bucket "think" nil))
    (should-not (agent-river--bucket "other" nil))))

(ert-deftest agent-river-test-a-streamed-edit-counts-as-a-write ()
  (agent-river-test--with-watch
    ;; End to end, since the palette is only useful if the kind survives the
    ;; adapter with the case it arrived in.
    (dolist (event (agent-river--shell-events
                    (agent-river-test--tool-call
                     "c1" "pending" '(:kind . "edit")
                     '(:raw-input . ((filePath . "/repo/a.el"))))
                    "s1" "/repo"))
      (agent-river-observe event))
    (let ((entry (gethash "a.el" (agent-river-state-task-artifacts
                                  (gethash "s1" agent-river-registry)))))
      (should (= (plist-get entry :writes) 1)))))

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


;;; Approvals -- what a session is waiting to be told
;;
;; The offer is read in two halves that share a request id: the responder
;; function has the options and does not know whose they are, the event knows
;; whose and has no options.  Neither is folded -- an open question stops
;; being true when it is answered, and answering can happen in the session
;; buffer where nothing here would hear it.

(defun agent-river-test--permission (&optional id respond)
  "Return a permission alist shaped like the one agent-shell hands a responder.
ID names the request; RESPOND is what its `:respond' calls."
  (list (cons :tool-call (list (cons :title "Run `git push`")
                               (cons :kind "execute")
                               (cons :permission-request-id (or id "req-1"))))
        (cons :options (list (list (cons :kind "allow_once")
                                   (cons :option "Allow")
                                   (cons :option-id "allow"))
                             (list (cons :kind "reject_once")
                                   (cons :option "Reject")
                                   (cons :option-id "reject"))))
        (cons :respond (or respond #'ignore))))

(defun agent-river-test--ask (id &optional call-id)
  "Return the `permission-request' event agent-shell emits for ID."
  (list (cons :event 'permission-request)
        (cons :data (list (cons :request-id id)
                          (cons :tool-call-id (or call-id "call-1"))
                          (cons :tool-call (list (cons :title "Run `git push`")))))))

(ert-deftest agent-river-test-noting-an-offer-does-not-answer-it ()
  ;; Non-nil from the responder means agent-shell skips its own dialog, so
  ;; watching a question go past must never be what swallows it.
  (let ((agent-river--offers (make-hash-table :test 'equal))
        (agent-river--responder-before nil))
    (should-not (agent-river--responder (agent-river-test--permission)))
    (let ((offer (gethash "req-1" agent-river--offers)))
      (should offer)
      (should (equal (mapcar (lambda (option) (alist-get :option-id option))
                             (plist-get offer :options))
                     '("allow" "reject"))))))

(ert-deftest agent-river-test-a-responder-already-there-still-decides ()
  ;; The slot holds one function, so taking it means carrying whoever was in
  ;; it -- otherwise turning the HUD on silently retires somebody's
  ;; auto-approval.
  (let* ((asked nil)
         (agent-river--offers (make-hash-table :test 'equal))
         (agent-river--responder-before (lambda (_permission)
                                          (setq asked t)
                                          'handled)))
    (should (eq (agent-river--responder (agent-river-test--permission)) 'handled))
    (should asked)
    ;; And it was still seen on the way past.
    (should (gethash "req-1" agent-river--offers))))

(ert-deftest agent-river-test-an-open-question-reaches-the-panel ()
  (agent-river-test--with-shell '(("*alpha*" "s1" client))
    (let ((agent-river-registry (make-hash-table :test 'equal))
          (agent-river--offers (make-hash-table :test 'equal))
          (agent-river--responder-before nil))
      (let ((state (agent-river-state "s1" "alpha")))
        (agent-river--responder (agent-river-test--permission))
        (with-current-buffer (agent-river--shell-buffer "s1")
          (agent-river--attend (agent-river-test--ask "req-1")))
        ;; The two halves met: the responder's options, under the event's
        ;; session.
        (should (equal (plist-get (gethash "req-1" agent-river--offers) :session)
                       "s1"))
        (should (string-match-p "asks: Run `git push` (Allow · Reject)"
                                (substring-no-properties
                                 (agent-river--panel state))))
        ;; And that it was asked is in the log, which is the half of this
        ;; that is point-in-time.
        (should (string-match-p "asks: Run" (agent-river-test--hud)))
        ;; Answered, it leaves both.
        (with-current-buffer (agent-river--shell-buffer "s1")
          (agent-river--attend
           (list (cons :event 'permission-response)
                 (cons :data (list (cons :request-id "req-1")
                                   (cons :option-id "allow"))))))
        (should-not (agent-river--offer "s1"))
        (should-not (string-match-p "asks:" (substring-no-properties
                                             (agent-river--panel state))))))))

(ert-deftest agent-river-test-an-answered-request-is-not-answered-again ()
  ;; agent-shell's own buttons stay live, so the table here is always the
  ;; account that can be behind.  It clears `:permission-request-id' when it
  ;; answers, expressly so consumers can tell the two apart.
  (agent-river-test--with-shell '(("*alpha*" "s1" client))
    (let ((agent-river--offers (make-hash-table :test 'equal))
          (agent-river--responder-before nil)
          (answers nil))
      (agent-river--responder
       (agent-river-test--permission "req-1" (lambda (id) (push id answers))))
      (with-current-buffer (agent-river--shell-buffer "s1")
        (agent-river--attend (agent-river-test--ask "req-1" "call-1"))
        ;; Pending: the tool call still names the request.
        (setq-local agent-shell--state
                    (cons (cons :tool-calls
                                (list (cons "call-1"
                                            (list (cons :permission-request-id
                                                        "req-1")))))
                          agent-shell--state)))
      (should (agent-river--offer-live-p (gethash "req-1" agent-river--offers)))
      ;; Answered in the session buffer: agent-shell drops the id.
      (with-current-buffer (agent-river--shell-buffer "s1")
        (setq-local agent-shell--state
                    (cons (cons :tool-calls (list (cons "call-1" nil)))
                          agent-shell--state)))
      (should-not (agent-river--offer-live-p (gethash "req-1" agent-river--offers))))))


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

(ert-deftest agent-river-test-a-note-carries-its-file-beside-the-fold ()
  (agent-river-test--with-observers
    (agent-river-observe '(:kind "act" :session "s1" :file "a.el" :detail "Edit"))
    (let (event)
      (add-hook 'agent-river-observers
                (lambda (_state e) (setq event e)))
      (agent-river-note "b.el saved outside the session" "s1" "/repo/b.el")
      ;; The absolute name rides on the event for the observers that have to
      ;; reach the file on disk, exactly as `:path' does on a hook event.
      (should (equal (plist-get event :path) "/repo/b.el"))
      ;; And it is kept out of the fold: the note names the file, the agent
      ;; did not touch it, so the artifact table must not gain an entry.
      (should-not (gethash "b.el"
                           (agent-river-state-task-artifacts
                            (gethash "s1" agent-river-registry)))))))

(ert-deftest agent-river-test-a-noted-save-pulses-the-file-it-names ()
  (agent-river-test--with-observers
    (agent-river-observe '(:kind "act" :session "s1" :file "a.el" :detail "Edit"))
    ;; The observer routes a note's `:path' to the pulse, and an act's too.
    ;; The pulse is rendering, so this asserts the routing -- which file the
    ;; observer hands over -- not the highlight itself.
    (let ((agent-river-heat-mode t)
          pulsed)
      (cl-letf (((symbol-function 'agent-river--pulse-dired)
                 (lambda (path) (push path pulsed))))
        (agent-river--dired-observe (gethash "s1" agent-river-registry)
                                    (list :kind "note" :text "x" :path "/repo/b.el")))
      (should (equal pulsed '("/repo/b.el"))))))

(ert-deftest agent-river-test-a-note-without-a-file-pulses-nothing ()
  (agent-river-test--with-observers
    (agent-river-observe '(:kind "act" :session "s1" :detail "Edit a.el"))
    (let ((agent-river-heat-mode t)
          pulsed)
      (cl-letf (((symbol-function 'agent-river--pulse-dired)
                 (lambda (path) (push path pulsed))))
        (agent-river--dired-observe (gethash "s1" agent-river-registry)
                                    (list :kind "note" :text "just an observation")))
      ;; Nothing to point at, so nothing to pulse -- the observer must not
      ;; invent a path or hand a nil to the pulse.
      (should-not pulsed))))


;;; Heat, derived for dired
;;
;; The derivation is tested, the rendering is not.  Everything that can be
;; wrong in a way that misleads an onlooker -- which frame the count comes
;; from, how two sessions on one file add up, which face a count earns -- is
;; a pure function of the state.  Overlay placement is dired's geometry, and
;; testing it would mean building a listing to assert that dired knows where
;; its own filenames are.

(ert-deftest agent-river-test-heat-counts-touches-by-basename ()
  ;; The raw count is what is aggregated; the half-life is exercised
  ;; separately, so switch the weighting off and read whole numbers here.
  (let ((agent-river-heat-half-life nil))
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
        (should-not (gethash "never-touched.el" table))))))

(ert-deftest agent-river-test-heat-reads-the-frame-it-is-asked-for ()
  (let ((agent-river-heat-half-life nil))
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
      (should (equal (gethash "a.el" (agent-river--heat-table)) 1)))))

(ert-deftest agent-river-test-heat-sums-two-sessions-on-one-file ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-session state
      (let ((other (agent-river-state "s2" "beta")))
        (agent-river-fold state '(:kind "act" :file "shared.el"))
        (agent-river-fold other '(:kind "act" :file "worktree/shared.el"))
        (agent-river-fold other '(:kind "act" :file "worktree/shared.el"))
        ;; Two agents in one file is the case worth seeing, and the same file
        ;; reached from a worktree must not read as a second one -- which is
        ;; exactly what `agent-river-touching' already promises.
        (should (equal (gethash "shared.el" (agent-river--heat-table)) 3))))))

(ert-deftest agent-river-test-heat-cools-with-age ()
  ;; The point of the weighting: a file the agent has moved away from must
  ;; sink below one still being touched, even when its raw count is higher.
  ;; Were the shading read from the cumulative tally it would never move.
  (let ((agent-river-heat-half-life 100)
        (state (agent-river-state "s1" "alpha")))
    ;; One touch at a time an hour before "now", and three touches now.
    (puthash "old.el" (list :touches 20 :last (time-subtract (current-time) 3600))
             (agent-river-state-task-artifacts state))
    (puthash "hot.el" (list :touches 3 :last (current-time))
             (agent-river-state-task-artifacts state))
    (let ((table (agent-river--heat-table 'task)))
      ;; Twenty touches an hour old, at a 100s half-life, weigh a fraction of
      ;; one -- where the raw tally would put old.el far on top.
      (should (< (gethash "old.el" table) 1))
      (should (> (gethash "hot.el" table) (gethash "old.el" table)))
      ;; And the face follows the weight, not the count: old.el earns none.
      (should-not (agent-river--heat-face (gethash "old.el" table)))
      (should (eq (agent-river--heat-face (gethash "hot.el" table))
                  'agent-river-heat-1)))))

(ert-deftest agent-river-test-heat-fresh-touch-weighs-the-raw-count ()
  ;; Off is off and fresh is fresh: with no elapsed time the weight is the
  ;; count, so the thresholds keep meaning what they always meant.
  (let ((agent-river-heat-half-life 60)
        (entry (list :touches 4 :last (current-time))))
    (should (< (agent-river--heat-weight entry) 4))
    (should (> (agent-river--heat-weight entry) 3.99))
    (let ((agent-river-heat-half-life nil))
      (should (equal (agent-river--heat-weight entry) 4)))))

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

(ert-deftest agent-river-test-heat-visible-p-follows-the-thresholds ()
  (let ((agent-river-heat-half-life nil)
        (state (agent-river-state "s1" "alpha")))
    (puthash "warm.el" (list :touches 1 :last (current-time))
             (agent-river-state-task-artifacts state))
    ;; One touch reaches the lowest threshold, so there is something drawn
    ;; and something to cool.
    (let ((agent-river-registry
           (let ((h (make-hash-table :test 'equal)))
             (puthash "s1" state h) h)))
      (should (agent-river--heat-visible-p))
      ;; Empty the frame and the answer turns, which is what lets the timer
      ;; retire instead of redrawing nothing forever.
      (clrhash (agent-river-state-task-artifacts state))
      (should-not (agent-river--heat-visible-p)))))

(ert-deftest agent-river-test-heat-timer-retires-once-nothing-cools ()
  (let ((agent-river-heat-half-life 9999)
        (agent-river-heat-mode t)
        (agent-river--heat-timer nil)
        (agent-river-heat-refresh-interval 60)
        (state (agent-river-state "s1" "alpha")))
    (puthash "warm.el" (list :touches 1 :last (current-time))
             (agent-river-state-task-artifacts state))
    (let ((agent-river-registry
           (let ((h (make-hash-table :test 'equal)))
             (puthash "s1" state h) h)))
      (agent-river--ensure-heat-timer)
      (should (timerp agent-river--heat-timer))
      ;; Starting twice must not leave a second timer running unnoticed.
      (let ((first agent-river--heat-timer))
        (agent-river--ensure-heat-timer)
        (should (eq first agent-river--heat-timer)))
      (clrhash (agent-river-state-task-artifacts state))
      (agent-river--heat-tick)
      (should-not agent-river--heat-timer)
      (cancel-function-timers #'agent-river--heat-tick))))

(ert-deftest agent-river-test-heat-timer-needs-a-half-life ()
  ;; With the weighting off the shading never fades, so a timer would redraw
  ;; the same picture forever -- it must not start at all.
  (let ((agent-river-heat-half-life nil)
        (agent-river-heat-mode t)
        (agent-river--heat-timer nil)
        (state (agent-river-state "s1" "alpha")))
    (puthash "warm.el" (list :touches 6 :last (current-time))
             (agent-river-state-task-artifacts state))
    (let ((agent-river-registry
           (let ((h (make-hash-table :test 'equal)))
             (puthash "s1" state h) h)))
      (agent-river--ensure-heat-timer)
      (should-not agent-river--heat-timer))))


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
    (let (event)
      (add-hook 'agent-river-observers (lambda (_state e) (setq event e)))
      (should (equal (agent-river-note-foreign-save "/repo/a.el") '("s1")))
      ;; The save names its file on the event so the dired view can pulse it,
      ;; giving the human's write the same "look here" the agent's gets.
      (should (equal (plist-get event :path) "/repo/a.el")))
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

(defun agent-river-test--delegating-session (&optional child-file)
  "Set up a root that worked in main.el and a subagent in CHILD-FILE."
  (agent-river-observe '(:kind "prompt" :session "s1" :text "do it" :detail "do it"))
  (agent-river-observe '(:kind "act" :session "s1" :file "main.el" :detail "Edit"))
  (agent-river-observe '(:kind "think" :session "s1" :tool "Edit" :detail "Edit"))
  (when child-file
    (agent-river-observe (list :kind "act" :session "s1" :agent "a1"
                               :agent-type "Explore" :file child-file
                               :detail "Edit"))
    (agent-river-observe '(:kind "think" :session "s1" :agent "a1"
                                 :tool "Edit" :detail "Edit"))))

(ert-deftest agent-river-test-a-file-a-subagent-holds-is-noted-to-the-root ()
  (agent-river-test--with-observers
    (agent-river-test--delegating-session "shared.el")
    ;; A delegated file lands in the subagent's task frame and never in its
    ;; parent's, so asking the root alone produced no note at all -- silence
    ;; in the case with the least supervision in it.
    (should (equal (agent-river-note-foreign-save "/repo/shared.el") '("s1")))
    (let ((root (gethash "s1" agent-river-registry))
          (child (gethash "s1/a1" agent-river-registry)))
      ;; Addressed to the root, because a root is the only thing that can be
      ;; told anything -- and never to the subagent, which cannot.
      (should (= (length (agent-river-state-notes root)) 1))
      (should-not (agent-river-state-notes child)))))

(ert-deftest agent-river-test-a-note-says-who-is-in-the-file ()
  (agent-river-test--with-observers
    (agent-river-test--delegating-session "main.el")
    (agent-river-note-foreign-save "/repo/main.el")
    (let ((text (cdr (car (agent-river-state-notes
                           (gethash "s1" agent-river-registry))))))
      ;; Addressed to the parent and silent about the child, this would read
      ;; as a statement about the parent's own work.
      (should (string-match-p "1 touch," text))
      (should (string-match-p "Explore 1 touch" text))
      ;; And it labels the frame rather than saying "this task" whatever the
      ;; scope happens to be.
      (should (string-match-p "this task" text)))))

(ert-deftest agent-river-test-a-note-labels-the-frame-it-counted ()
  (agent-river-test--with-observers
    (let ((agent-river-foreign-save-scope 'session))
      (agent-river-test--delegating-session)
      (agent-river-observe '(:kind "prompt" :session "s1" :text "next" :detail "next"))
      (agent-river-note-foreign-save "/repo/main.el")
      (let ((text (cdr (car (agent-river-state-notes
                             (gethash "s1" agent-river-registry))))))
        ;; The touch survived the new prompt only in the session frame, so
        ;; calling it "this task" would put the number under a heading that
        ;; cleared it.
        (should (string-match-p "this session" text))
        (should-not (string-match-p "this task" text))))))

(ert-deftest agent-river-test-an-open-call-anywhere-in-the-family-suppresses ()
  (agent-river-test--with-observers
    (agent-river-test--delegating-session "shared.el")
    ;; The subagent opens a call on the file and does not close it: the save
    ;; may be that write landing, and the guard has to reach the whole family
    ;; now that the question does.
    (agent-river-observe '(:kind "act" :session "s1" :agent "a1"
                                 :agent-type "Explore" :file "shared.el"
                                 :detail "Edit"))
    (should-not (agent-river-note-foreign-save "/repo/shared.el"))
    (agent-river-observe '(:kind "think" :session "s1" :agent "a1"
                                 :tool "Edit" :detail "Edit"))
    (should (agent-river-note-foreign-save "/repo/shared.el"))))

(ert-deftest agent-river-test-a-finished-subagent-holds-nothing ()
  (agent-river-test--with-observers
    (agent-river-test--delegating-session "shared.el")
    (agent-river-observe '(:kind "done" :session "s1" :agent "a1"
                                 :agent-type "Explore" :detail "Explore finished"))
    ;; The question is who is in the file now.  A child that has stopped
    ;; cannot be about to overwrite anything, and SubagentStop says so as a
    ;; fact rather than a guess.
    (should-not (agent-river-note-foreign-save "/repo/shared.el"))))

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

;;; Moving about the HUD
;;
;; The same three grains as the map, on the same keys, so these mirror the
;; map's motion tests.  The one thing that is only a problem here is the
;; following: a log that pins itself to the head makes every motion pointless
;; unless it knows to stop.

(defmacro agent-river-test--with-hud (&rest body)
  "Fold two sessions and a handful of events into a fresh HUD, run BODY."
  (declare (indent 0))
  `(let ((agent-river-registry (make-hash-table :test 'equal))
         (agent-river-auto-display nil))
     (agent-river-clear)
     (let ((alpha (agent-river-state "s1" "alpha"))
           (beta (agent-river-state "s2" "beta")))
       (agent-river-fold alpha '(:kind "act" :cwd "/repo" :tool "Edit" :file "a.el"))
       (agent-river-fold beta '(:kind "act" :cwd "/other" :tool "Read" :file "b.el")))
     (agent-river-log "act" "Edit a.el" "alpha")
     (agent-river-log "fail" "Bash exit 1" "alpha")
     (agent-river-log "think" "Read b.el" "beta")
     (agent-river-log "signal" "three failures in a row" "alpha")
     (with-current-buffer (agent-river--buffer)
       ;; Unwound, because the HUD buffer outlives the test: the expansion
       ;; is buffer-local and left behind it made a later test that asserts
       ;; the details start folded fail, in suite order only.
       (unwind-protect
           (progn
             (setq agent-river--panel-expanded t)
             (agent-river--redraw-block)
             (goto-char (point-min))
             ,@body)
         (setq agent-river--panel-expanded nil)))))

(defun agent-river-test--hud-lines (test)
  "Return the lines of the current buffer TEST stops on, top down.
Tests the line point is on first: `agent-river--scan' is a motion and so
starts past it, which is right for a command and would silently drop the
first line from a survey."
  (goto-char (point-min))
  (let (seen)
    (when (funcall test)
      (push (buffer-substring-no-properties (line-beginning-position)
                                            (line-end-position))
            seen))
    (while (agent-river--scan 1 test)
      (push (buffer-substring-no-properties (line-beginning-position)
                                            (line-end-position))
            seen))
    (nreverse seen)))

(ert-deftest agent-river-test-hud-motion-walks-every-marked-line ()
  (agent-river-test--with-hud
    (let ((lines (agent-river-test--hud-lines #'agent-river--entry-line-p)))
      ;; Sessions, their details and the log, in buffer order.
      (should (seq-find (lambda (l) (string-prefix-p "* alpha" l)) lines))
      (should (seq-find (lambda (l) (string-prefix-p "** files:" l)) lines))
      (should (seq-find (lambda (l) (string-match-p "Edit a\\.el" l)) lines))
      ;; Log lines start with timestamps and are all fair game.
      )))

(ert-deftest agent-river-test-hud-session-motion-is-the-selection ()
  (agent-river-test--with-hud
    (let ((lines (agent-river-test--hud-lines #'agent-river--session-line-p)))
      ;; Only the session lines: this is the coarse grain, the one that
      ;; changes which session RET would visit, and it has to reach across
      ;; the whole log rather than stopping where the block does.
      (should (= (length lines) 2))
      (should (string-prefix-p "* alpha" (nth 0 lines)))
      (should (string-prefix-p "* beta" (nth 1 lines))))))

(ert-deftest agent-river-test-hud-notable-motion-finds-the-landmarks ()
  (agent-river-test--with-hud
    (let ((lines (agent-river-test--hud-lines #'agent-river--notable-line-p)))
      ;; What broke and what the agent was told, without the bulk of the
      ;; log in between -- the distinction the motion exists to make.
      (should (= (length lines) 2))
      (should (seq-find (lambda (l) (string-match-p "three failures" l)) lines))
      (should (seq-find (lambda (l) (string-match-p "Bash exit 1" l)) lines))
      (should-not (seq-find (lambda (l) (string-match-p "Read b\\.el" l)) lines)))))

(ert-deftest agent-river-test-hud-motion-lands-past-the-stars ()
  (agent-river-test--with-hud
    ;; Point starts on alpha's line, and a motion moves off it.
    (should (agent-river--scan 1 #'agent-river--session-line-p))
    ;; A cursor parked on an outline star says nothing about the line.
    (should (looking-at-p "beta"))
    ;; A log line starts with its timestamp and is left alone.
    (should (agent-river--scan 1 #'agent-river--notable-line-p))
    (should (= (point) (line-beginning-position)))))

(ert-deftest agent-river-test-hud-motion-refuses-rather-than-drifts ()
  (agent-river-test--with-hud
    (goto-char (point-max))
    (let ((before (point)))
      (should-not (agent-river--scan 1 #'agent-river--entry-line-p))
      (should (= (point) before)))))

(ert-deftest agent-river-test-a-session-line-is-reachable-unhosted ()
  (agent-river-test--with-hud
    ;; Nothing here is hosted by agent-shell, so no session line is
    ;; visitable -- and the motion still has to stop on both.  Tying the two
    ;; together made `n' skip exactly the sessions RET could not open, which
    ;; is the case where looking is all there is.
    (should (= (length (agent-river-test--hud-lines #'agent-river--session-line-p)) 2))
    (goto-char (point-min))
    (agent-river--scan 1 #'agent-river--session-line-p)
    (should-not (get-text-property (line-beginning-position) 'agent-river-session))))

(ert-deftest agent-river-test-the-hud-follows-only-what-is-at-the-head ()
  (agent-river-test--with-hud
    (let ((buffer (current-buffer))
          (window (selected-window)))
      (set-window-buffer window buffer)
      (set-window-point window (point-min))
      ;; At the head, an event keeps it there: there is nothing to tail, and
      ;; the state and the newest event are both up here.
      (should (memq window (agent-river--following-windows buffer)))
      ;; Moved away on purpose, it is no longer following -- pinning it back
      ;; on the next tool call is what made the motion commands pointless
      ;; before they arrived.
      (goto-char (point-max))
      (set-window-point window (point))
      (should-not (memq window (agent-river--following-windows buffer)))
      ;; And the place survives the edit, because every edit is above it.
      (let ((line (buffer-substring-no-properties (line-beginning-position)
                                                  (line-end-position))))
        (agent-river-log "act" "Edit later.el" "alpha")
        (should (equal (save-excursion
                         (goto-char (window-point window))
                         (buffer-substring-no-properties (line-beginning-position)
                                                         (line-end-position)))
                       line))))))

(defun agent-river-test--log-lines ()
  "Return the log lines of the HUD, newest first, without the state block."
  (with-current-buffer (agent-river--buffer)
    (save-excursion
      (goto-char (or (and (markerp agent-river--block-end)
                          (marker-position agent-river--block-end))
                     (point-min)))
      (let (lines)
        (while (not (eobp))
          (when (get-text-property (point) 'agent-river-line)
            (push (buffer-substring-no-properties (line-beginning-position)
                                                  (line-end-position))
                  lines))
          (forward-line 1))
        (nreverse lines)))))

(defmacro agent-river-test--with-calls (&rest body)
  "Run BODY against a cleared HUD and an isolated registry."
  (declare (indent 0))
  `(let ((agent-river-registry (make-hash-table :test 'equal))
         (agent-river-auto-display nil)
         (agent-river-max-entries 100))
     (agent-river-clear)
     ,@body))

(ert-deftest agent-river-test-a-call-ends-on-the-line-that-opened-it ()
  (agent-river-test--with-calls
    ;; Two lines per tool call halves how much history fits in
    ;; `agent-river-max-entries', and the second says nothing the first did
    ;; not except how it went.
    (agent-river-observe '(:kind "act" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash  Run tests"
                           :call "s1\0t1"))
    (agent-river-observe '(:kind "think" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash ✓  250ms"
                           :call "s1\0t1" :outcome "✓  250ms"))
    (let ((lines (agent-river-test--log-lines)))
      (should (= (length lines) 1))
      ;; The timestamp is the one the call started at, not the one it ended
      ;; at: the line answers "when did this begin", and the duration beside
      ;; it already says how long it then took.
      (should (string-match-p "Bash  Run tests (✓  250ms)\\'" (car lines))))))

(ert-deftest agent-river-test-a-failure-still-ends-its-own-line ()
  (agent-river-test--with-calls
    (agent-river-observe '(:kind "act" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash  Run tests"
                           :call "s1\0t1"))
    (agent-river-observe '(:kind "fail" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash  13ms"
                           :call "s1\0t1" :outcome "✗  13ms"))
    (let ((lines (agent-river-test--log-lines)))
      (should (= (length lines) 1))
      (should (string-match-p "(✗  13ms)\\'" (car lines))))))

(ert-deftest agent-river-test-an-outcome-with-no-line-left-takes-one ()
  (agent-river-test--with-calls
    ;; The line may be gone -- trimmed away, or never written because this
    ;; Emacs started mid-run.  Folding it onto nothing would drop the
    ;; outcome entirely, which is worse than the extra line it costs.
    (agent-river-observe '(:kind "think" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash ✓  250ms"
                           :call "s1\0gone" :outcome "✓  250ms"))
    (let ((lines (agent-river-test--log-lines)))
      (should (= (length lines) 1))
      (should (string-match-p "Bash ✓  250ms\\'" (car lines))))))

(ert-deftest agent-river-test-a-host-naming-no-call-still-logs-both ()
  (agent-river-test--with-calls
    ;; Codex and Gemini CLI may name no call at all.  Without an id there is
    ;; nothing to pair on, and guessing by tool name would fold two parallel
    ;; calls of one tool into each other.
    (agent-river-observe '(:kind "act" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash  Run tests"))
    (agent-river-observe '(:kind "think" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash ✓  250ms"
                           :outcome "✓  250ms"))
    (should (= (length (agent-river-test--log-lines)) 2))))

(ert-deftest agent-river-test-parallel-calls-end-on-their-own-lines ()
  (agent-river-test--with-calls
    ;; The case the id exists for: two calls of one tool in flight at once,
    ;; where nearness in the buffer says nothing about which is which.
    (agent-river-observe '(:kind "act" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash  first"
                           :call "s1\0t1"))
    (agent-river-observe '(:kind "act" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash  second"
                           :call "s1\0t2"))
    (agent-river-observe '(:kind "think" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash ✓  9ms"
                           :call "s1\0t1" :outcome "✓  9ms"))
    (let ((lines (agent-river-test--log-lines)))
      (should (= (length lines) 2))
      ;; Newest first, so the still-open second call is above the first.
      (should (string-match-p "Bash  second\\'" (nth 0 lines)))
      (should (string-match-p "Bash  first (✓  9ms)\\'" (nth 1 lines))))))

(ert-deftest agent-river-test-one-call-is-answered-once ()
  (agent-river-test--with-calls
    ;; A repeated terminal status would otherwise write a second verdict
    ;; onto a line that already carries its own.
    (agent-river-observe '(:kind "act" :session "s1" :label "alpha"
                           :tool "Bash" :detail "Bash  Run tests"
                           :call "s1\0t1"))
    (dotimes (_ 2)
      (agent-river-observe '(:kind "think" :session "s1" :label "alpha"
                             :tool "Bash" :detail "Bash ✓  250ms"
                             :call "s1\0t1" :outcome "✓  250ms")))
    (let ((lines (agent-river-test--log-lines)))
      (should (= (length lines) 2))
      (should (string-match-p "Run tests (✓  250ms)\\'" (nth 1 lines))))))

(ert-deftest agent-river-test-the-call-id-carries-its-session ()
  ;; `tool_use_id' is unique everywhere on Claude Code and only within its
  ;; session on ACP, so the session is what makes the pairing safe on both.
  (let ((event (agent-river--event
                "act" (agent-river-test--payload
                       "{\"session_id\":\"s1\",\"tool_name\":\"Bash\",
                         \"tool_use_id\":\"toolu_1\"}"))))
    (should (equal (plist-get event :call) "s1\0toolu_1")))
  ;; A host that names none pairs on nothing rather than on a guess.
  (should-not (plist-get (agent-river--event
                          "act" (agent-river-test--payload
                                 "{\"session_id\":\"s1\",\"tool_name\":\"Bash\"}"))
                         :call)))


;;; Handing the state out as Markdown
;;
;; The export is a third derivation of the state beside the panel and the
;; report, so it inherits none of their labelling and every bit of it is
;; asserted here.  The escaping is the other half: this is the one place the
;; package puts the agent's own words into a format that can act on them.

(defmacro agent-river-test--with-export (&rest body)
  "Fold a session worth reporting on into an isolated registry, run BODY."
  (declare (indent 0))
  `(let ((agent-river-registry (make-hash-table :test 'equal))
         (agent-river-auto-display nil))
     (let ((state (agent-river-state "s1" "alpha")))
       (agent-river-fold state '(:kind "prompt" :cwd "/repo" :text "Rewrite it"))
       (dotimes (_ 5)
         (agent-river-fold state '(:kind "act" :cwd "/repo" :tool "Edit"
                                         :file "src/a.el")))
       (ignore state)
       ,@body)))

(ert-deftest agent-river-test-the-export-labels-both-frames ()
  (agent-river-test--with-export
    (agent-river-fold state '(:kind "prompt" :cwd "/repo" :text "Next thing"))
    (agent-river-fold state '(:kind "act" :cwd "/repo" :tool "Edit" :file "b.el"))
    (let ((markdown (agent-river-markdown)))
      ;; The report gets this for free from its key names -- :task-hottest
      ;; against :session-hottest -- and the export has to say it in words.
      ;; Two numbers on different clocks side by side, unlabelled, read as
      ;; if they were comparable.
      (should (string-match-p "\\*\\*this task\\*\\*" markdown))
      (should (string-match-p "\\*\\*this session\\*\\*" markdown))
      ;; And they are genuinely different readings: the task frame was
      ;; cleared by the second prompt, the session frame was not.
      (should (string-match-p "this task\\*\\* — 1 step" markdown))
      (should (string-match-p "this session.*`a\\.el` ×5" markdown)))))

(ert-deftest agent-river-test-the-export-marks-a-claim-as-one ()
  (agent-river-test--with-export
    (agent-river-fold state '(:kind "intent" :text "narrowing it down"))
    (let ((markdown (agent-river-markdown)))
      ;; Marked twice, and last.  This is the agent talking about itself,
      ;; and a claim a later reader takes for one of the measurements above
      ;; it is exactly the confusion the intent slots are kept apart to
      ;; prevent -- the more so once the text has left this package.
      (should (string-match-p "\\*\\*claims\\*\\* — narrowing it down" markdown))
      (should (string-match-p "self-reported" markdown))
      (should (> (string-match "claims" markdown)
                 (string-match "this session" markdown))))))

(ert-deftest agent-river-test-the-export-neutralises-what-the-agent-wrote ()
  (agent-river-test--with-export
    (agent-river-fold state '(:kind "intent" :text "the *parser* in a_b [see #1]"))
    (let ((markdown (agent-river-markdown)))
      ;; The agent's words do not stop being arbitrary text because they are
      ;; going somewhere Markdown is read.  Unescaped, an asterisk silently
      ;; italicises the rest of the line and a bracket swallows it into a
      ;; link -- the same hazard that keeps the HUD out of Markdown, small
      ;; enough to escape here because only two values are the agent's.
      (should (string-match-p "the \\\\\\*parser\\\\\\* in a\\\\_b" markdown))
      (should (string-match-p "\\\\\\[see \\\\#1\\\\\\]" markdown)))))

(ert-deftest agent-river-test-a-name-cannot-break-out-of-its-code-span ()
  ;; A file name will almost never hold a backtick, and the one that does
  ;; must not be able to close the span it is in and turn the rest of the
  ;; line into markup.
  (should (equal (agent-river--md-code "a.el") "`a.el`"))
  (should (equal (agent-river--md-code "a`b.el") "`` a`b.el ``"))
  (should (equal (agent-river--md-code "a``b.el") "``` a``b.el ```")))

(ert-deftest agent-river-test-the-export-folds-subagents-under-the-parent ()
  (agent-river-test--with-export
    (let ((child (agent-river-state "s1/a1" "Explore" "s1" "Explore")))
      (dotimes (_ 3)
        (agent-river-fold child '(:kind "act" :cwd "/repo" :tool "Read"
                                        :file "README.md"))))
    (let ((markdown (agent-river-markdown)))
      ;; No section of its own, exactly as it gets no panel line: the work
      ;; is counted on the parent and aggregated on demand, so the two
      ;; cannot drift.
      (should-not (string-match-p "^### .*Explore" markdown))
      (should (string-match-p "\\*\\*subagents\\*\\* — 1 of 1 running" markdown))
      (should (string-match-p "    - `Explore` — running · 3 steps" markdown))
      ;; The name comes out as a code span like every other name here, which
      ;; is why this is read off the child's state rather than out of
      ;; `agent-river--child-digest's already-formatted string.
      (should (string-match-p "hottest `README\\.md` ×3" markdown)))))

(ert-deftest agent-river-test-the-export-mirrors-the-block-not-the-registry ()
  (let ((agent-river-registry (make-hash-table :test 'equal))
        (agent-river-auto-display nil))
    ;; Nothing live, nothing to hand out -- and nil rather than an empty
    ;; document, so the command can say so instead of putting a heading with
    ;; no body on the kill ring.
    (should-not (agent-river-markdown))
    (let ((state (agent-river-state "s1" "alpha")))
      (agent-river-fold state '(:kind "act" :cwd "/repo" :tool "Edit" :file "a.el"))
      (should (agent-river-markdown))
      ;; A subagent is never a section, so a registry holding only one has
      ;; nothing to report at the top level.
      (should-not (agent-river-markdown "s1/a1")))))


;;; The anchor -- where a session's keys are relative to
;;
;; The artifact keys stay relative on purpose, so a worktree and its main
;; checkout read as one file.  That makes them unable to say *which* tree
;; they are in, and a view that has to place a key in a real directory needs
;; both halves.  The anchor is the other half.

(ert-deftest agent-river-test-the-cwd-is-folded-with-the-events ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :cwd "/repo" :file "a.el"))
    ;; Folded rather than assigned where the state is addressed, so the
    ;; fold's promise holds: replay the events and the anchor comes back
    ;; with them.
    (should (equal (agent-river-state-cwd state) "/repo"))
    ;; A session that changes directory re-anchors, or its later keys would
    ;; be read against a directory they were never relative to.
    (agent-river-fold state '(:kind "act" :cwd "/other" :file "b.el"))
    (should (equal (agent-river-state-cwd state) "/other"))
    ;; Events made inside Emacs carry none and must leave it alone rather
    ;; than blanking it.
    (agent-river-fold state '(:kind "note" :text "saved"))
    (should (equal (agent-river-state-cwd state) "/other"))))

(ert-deftest agent-river-test-the-cwd-is-stored-without-its-slash ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :cwd "/repo/" :file "a.el"))
    ;; One form, so prefix comparisons against it cannot come out two ways.
    (should (equal (agent-river-state-cwd state) "/repo"))))

(ert-deftest agent-river-test-a-trailing-slash-does-not-eat-the-path ()
  ;; The length was measured off the cwd plus one rather than off its
  ;; slash-terminated form, so a cwd that already ended in a slash cut one
  ;; character too many -- `src/a.el' arriving as `rc/a.el'.  Invisible
  ;; while only the basename was ever read back; not once the key has to
  ;; place the file in a directory tree.
  (should (equal (agent-river--rel "/repo/src/a.el" "/repo") "src/a.el"))
  (should (equal (agent-river--rel "/repo/src/a.el" "/repo/") "src/a.el"))
  ;; Outside the cwd it is still the bare name, which is what keeps a path
  ;; from elsewhere out of this session's tree.
  (should (equal (agent-river--rel "/elsewhere/a.el" "/repo") "a.el")))

(ert-deftest agent-river-test-the-event-carries-the-anchor ()
  (let ((event (agent-river--event
                "act"
                (agent-river-test--payload
                 "{\"session_id\":\"s1\",\"cwd\":\"/repo\",
                   \"tool_name\":\"Edit\",
                   \"tool_input\":{\"file_path\":\"/repo/src/a.el\"}}"))))
    ;; The label is only the last component and cannot stand in for it: two
    ;; checkouts of one project are labelled alike on purpose.
    (should (equal (plist-get event :cwd) "/repo"))
    (should (equal (plist-get event :label) "repo"))))

(ert-deftest agent-river-test-resolving-a-key-needs-an-anchor ()
  ;; Without one the answer is unknown, and guessing would place files in
  ;; directories no agent ever opened.
  (should-not (agent-river--heat-absolute '(:file "src/a.el")))
  (should (equal (agent-river--heat-absolute '(:cwd "/repo" :file "src/a.el"))
                 "/repo/src/a.el"))
  ;; A bare key resolves as a file sitting directly in the cwd, which is
  ;; what it almost always is.
  (should (equal (agent-river--heat-absolute '(:cwd "/repo" :file "a.el"))
                 "/repo/a.el"))
  ;; Except where the key came from outside the cwd, and an anchor says so:
  ;; resolving that one against the cwd drew it inside a project it has
  ;; nothing to do with.
  (should (equal (agent-river--heat-absolute
                  '(:cwd "/repo" :anchor "/home/u/notes" :file "a.el"))
                 "/home/u/notes/a.el")))

(ert-deftest agent-river-test-a-file-outside-the-cwd-keeps-its-directory ()
  (agent-river-test--with-session state
    ;; Under the cwd the cwd already places the key, and a second copy of
    ;; that fact is only a way for the two to disagree.
    (agent-river-fold state (list :kind "act" :cwd "/repo" :file "src/a.el"
                                  :path "/repo/src/a.el"))
    (should-not (gethash "src/a.el" (agent-river-state-anchors state)))
    ;; Outside it `agent-river--rel' has already thrown the path away, so
    ;; without this the file lands wherever the cwd happens to point.
    (agent-river-fold state (list :kind "act" :cwd "/repo" :file "MEMORY.md"
                                  :path "/home/u/notes/MEMORY.md"))
    (should (equal (gethash "MEMORY.md" (agent-river-state-anchors state))
                   "/home/u/notes"))))

(ert-deftest agent-river-test-a-key-that-comes-back-inside-drops-its-anchor ()
  (agent-river-test--with-session state
    ;; The same basename is reachable both ways, so an anchor that is never
    ;; cleared goes on claiming the outside directory after the file is
    ;; being edited in the project itself.
    (agent-river-fold state (list :kind "act" :cwd "/repo" :file "MEMORY.md"
                                  :path "/home/u/notes/MEMORY.md"))
    (should (gethash "MEMORY.md" (agent-river-state-anchors state)))
    (agent-river-fold state (list :kind "act" :cwd "/repo" :file "MEMORY.md"
                                  :path "/repo/MEMORY.md"))
    (should-not (gethash "MEMORY.md" (agent-river-state-anchors state)))))

(ert-deftest agent-river-test-a-stray-file-is-a-root-of-its-own ()
  (agent-river-test--with-session state
    ;; One session, one cwd -- but two trees, because the file it edited
    ;; under ~/.claude is not in the project.  Grouping by cwd alone found
    ;; a single root and drew the stray inside the project.
    (agent-river-fold state (list :kind "act" :cwd "/repo" :file "src/a.el"
                                  :path "/repo/src/a.el"))
    (agent-river-fold state (list :kind "act" :cwd "/repo" :file "MEMORY.md"
                                  :path "/home/u/notes/MEMORY.md"))
    (let ((roots (mapcar #'car (agent-river--map-all-roots 'session))))
      (should (member "/repo" roots))
      (should (member "/home/u/notes" roots)))
    ;; And the stray is reached under its own root, not under the project's.
    (should (equal (mapcar (lambda (n) (plist-get n :rel))
                           (agent-river--map-reach "/home/u/notes" 'session))
                   '("MEMORY.md")))
    (should (equal (mapcar (lambda (n) (plist-get n :rel))
                           (agent-river--map-reach "/repo" 'session))
                   '("src/a.el")))))

(ert-deftest agent-river-test-a-subagent-is-named-under-its-root ()
  (agent-river-test--with-session state
    (let ((child (agent-river-state "s1/a1" "Explore" "s1" "Explore")))
      ;; Folded into the parent's name it would say the parent worked in a
      ;; file it never opened; shown as the bare agent type, two `Explore'
      ;; lines would be indistinguishable.
      (should (equal (agent-river--party-label state) "alpha"))
      (should (equal (agent-river--party-label child) "alpha/Explore")))))


;;; Directory heat -- the aggregate a dired line can carry
;;
;; The file shading is matched on the bare name and stays that way; a
;; directory cannot be, because `src' says nothing about which `src'.  These
;; are the tests for the difference.

(ert-deftest agent-river-test-a-directory-sums-what-lies-beneath-it ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-session state
      (agent-river-fold state '(:kind "act" :cwd "/repo" :file "dialog/src/a.el"))
      (agent-river-fold state '(:kind "act" :cwd "/repo" :file "dialog/src/b.el"))
      (agent-river-fold state '(:kind "act" :cwd "/repo" :file "common/c.el"))
      (let ((dirs (agent-river--heat-dirs "/repo")))
        ;; Only the entry the listing has a line for: `src' is two levels
        ;; down and has no line of its own here.
        (should (equal (gethash "dialog" dirs) 2))
        (should (equal (gethash "common" dirs) 1))
        (should-not (gethash "src" dirs))))))

(ert-deftest agent-river-test-a-bare-key-warms-no-directory ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-session state
      ;; `agent-river--rel' degrades a file outside the cwd to a bare name,
      ;; which is indistinguishable from one sitting in the cwd.  It has no
      ;; directory component, so the worst it can do is put a line in the
      ;; root's own listing -- it can never be summed into a subdirectory.
      (agent-river-fold state '(:kind "act" :cwd "/repo" :file "stray.el"))
      (should (zerop (hash-table-count (agent-river--heat-dirs "/repo")))))))

(ert-deftest agent-river-test-a-directory-elsewhere-stays-cold ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-session state
      (agent-river-fold state '(:kind "act" :cwd "/other" :file "src/a.el"))
      ;; The price of resolving rather than matching on the name: a session
      ;; anchored somewhere else contributes no directory shading here.  It
      ;; is the right way round -- a `src' aggregate matched on the name
      ;; would warm every `src' in every project at once.
      (should (zerop (hash-table-count (agent-river--heat-dirs "/repo"))))
      ;; The file shading is unaffected, because that question a bare name
      ;; can answer.
      (should (equal (gethash "a.el" (agent-river--heat-table)) 1)))))

(ert-deftest agent-river-test-a-listing-table-carries-both-readings ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-session state
      (agent-river-fold state '(:kind "act" :cwd "/repo" :file "dialog/src/a.el"))
      (agent-river-fold state '(:kind "act" :cwd "/repo" :file "README.md"))
      (let ((table (agent-river--heat-listing-table "/repo")))
        ;; One table because a dired line is one name: a directory and a
        ;; file of the same name cannot both be in one listing.
        (should (equal (gethash "dialog" table) 1))
        (should (equal (gethash "README.md" table) 1))))))


;;; The map -- the project, one level at a time
;;
;; The derivation is tested, the rendering is not, for the same reason as
;; the heat: which frame a number came from, how two agents on one directory
;; add up, and where an agent is *now* as against where it has been are pure
;; functions of the state.  Where the lines land on screen is not.

(defmacro agent-river-test--with-tree (var &rest body)
  "Bind VAR to a throwaway project tree and run BODY, then remove it.
The map's listing is the one thing here that genuinely needs a directory:
half of what it shows is what is on disk and untouched."
  (declare (indent 1))
  `(let ((,var (make-temp-file "agent-river-map" t)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "dialog/src/main" ,var) t)
           (make-directory (expand-file-name "common" ,var) t)
           (make-directory (expand-file-name "docs" ,var) t)
           (write-region "" nil (expand-file-name "dialog/src/main/foo.el" ,var))
           (write-region "" nil (expand-file-name "common/c.el" ,var))
           (write-region "" nil (expand-file-name "build.gradle.kts" ,var))
           ,@body)
       (delete-directory ,var t))))

(ert-deftest agent-river-test-the-map-lists-only-what-was-reached ()
  (let ((agent-river-heat-half-life nil)
        (agent-river-map-untouched nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "dialog/src/main/foo.el"))
        ;; Agents spread over several roots turn the full listing into mostly
        ;; context, and the map is opened to find the work in it.
        (should (equal (mapcar (lambda (e) (plist-get e :name))
                               (agent-river--map-entries root))
                       '("dialog")))))))

(ert-deftest agent-river-test-the-map-can-list-the-quiet-entries-too ()
  (let ((agent-river-heat-half-life nil)
        (agent-river-map-untouched t))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "dialog/src/main/foo.el"))
        (let ((entries (agent-river--map-entries root)))
          ;; What the filter costs, and what asking for it back buys: a view
          ;; of only the touched paths answers "where" without saying where
          ;; that is relative to anything else.
          (should (equal (mapcar (lambda (e) (plist-get e :name)) entries)
                         '("common" "dialog" "docs" "build.gradle.kts")))
          ;; Directories first, the way dired lists them.
          (should (plist-get (nth 0 entries) :dir))
          (should-not (plist-get (nth 3 entries) :dir))
          (should-not (plist-get (car entries) :parties)))))))

(defun agent-river-test--cool (state path seconds)
  "Back-date STATE's touches of PATH by SECONDS, in both frames.
The weighting is recomputed from `:last' on every read, so aging a touch
is how a test asks what the view looks like once the work has moved on."
  (dolist (table (list (agent-river-state-artifacts state)
                       (agent-river-state-task-artifacts state)))
    (let ((entry (gethash path table)))
      (when entry
        (puthash path
                 (list :touches (plist-get entry :touches)
                       ;; Carried, not dropped: a write does not stop having
                       ;; happened because the touch is being aged, and the
                       ;; landed marker is read from it.
                       :writes (plist-get entry :writes)
                       :last (time-subtract (plist-get entry :last) seconds))
                 table)))))

(ert-deftest agent-river-test-a-cold-name-stops-being-drawn ()
  ;; The shading has always had a floor and the name had none, so the weights
  ;; decayed toward zero without reaching it and every file a session ever
  ;; touched kept an agent on it.  A view where everything is marked marks
  ;; nothing.
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor 0.25)
        (agent-river-map-untouched nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "dialog/src/main/foo.el"))
        ;; Age the older touch past the floor, leaving the newer one fresh.
        (agent-river-test--cool state "common/c.el" 3600)
        (should (equal (mapcar (lambda (e) (plist-get e :name))
                               (agent-river--map-entries root))
                       '("dialog")))))))

(ert-deftest agent-river-test-a-party-keeps-the-file-it-is-on ()
  ;; Cold is not gone.  The one file a party reached last is the answer to
  ;; "where is this agent now", which is the question an idle agent provokes
  ;; -- so a quiet map settles at one line per agent rather than at none.
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor 0.25)
        (agent-river-map-untouched nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-test--cool state "common/c.el" 3600)
        (let ((entries (agent-river--map-entries root)))
          (should (equal (mapcar (lambda (e) (plist-get e :name)) entries)
                         '("common")))
          (should (plist-get (car (plist-get (car entries) :parties)) :current)))))))

(ert-deftest agent-river-test-the-map-keeps-drawing-until-the-names-fade ()
  ;; Two thresholds fade at different depths.  Asking only whether anything
  ;; is still shaded retired the timer while names were on screen waiting to
  ;; cross the party floor below it, so the map froze mid-fade and they sat
  ;; there until the next event.
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor 0.25)
        (agent-river-map-scope 'session))
    (agent-river-test--with-session state
      (agent-river-fold state '(:kind "act" :cwd "/w" :file "a.el"))
      ;; Cool past the shading, which runs out at 1, but not past the floor.
      (agent-river-test--cool state "a.el" 120)
      (should-not (agent-river--heat-visible-p 'session))
      (should (agent-river--map-cooling-p))
      ;; Past the floor as well: now there is genuinely nothing left to draw.
      (agent-river-test--cool state "a.el" 600)
      (should-not (agent-river--map-cooling-p)))))

(ert-deftest agent-river-test-a-file-that-comes-back-stops-being-struck ()
  ;; `:missing' is derived from the listing on every draw and the shading is
  ;; torn down and rebuilt with it, so the mark follows the disk in both
  ;; directions rather than being remembered anywhere.
  (let ((agent-river-heat-half-life nil)
        (agent-river-map-untouched nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "scratch.el"))
        (should (plist-get (car (agent-river--map-entries root)) :missing))
        (write-region "" nil (expand-file-name "scratch.el" root))
        (should-not (plist-get (car (agent-river--map-entries root)) :missing))
        (delete-file (expand-file-name "scratch.el" root))
        (should (plist-get (car (agent-river--map-entries root)) :missing))))))

(ert-deftest agent-river-test-a-gone-file-is-struck-through ()
  ;; Grey is the map's word for several things at once -- stale, cold,
  ;; elided.  "This file is not there" is worth saying exactly, and once the
  ;; line reads as gone it can no longer be mistaken for a place an agent is
  ;; still working in.
  (should (let ((line (agent-river--map-line 2 "scratch.el"
                                     '((:party "alpha" :weight 3)) t)))
    (text-property-any 0 (length line) 'agent-river-map-face
                       'agent-river-gone line)))
  ;; And a name that is on disk keeps its shading, which is a reading about
  ;; weight and must not be crowded out by one about existence.
  (should-not (let ((line (agent-river--map-line 2 "there.el"
                                       '((:party "alpha" :weight 9)))))
      (text-property-any 0 (length line) 'agent-river-map-face
                         'agent-river-gone line))))

(ert-deftest agent-river-test-a-deletion-is-still-news ()
  ;; A file deleted a moment ago is warm, and the deletion is something the
  ;; agent did.  Dropping it the instant it happens would throw away the one
  ;; thing worth seeing about it.
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor 0.25)
        (agent-river-map-untouched nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "scratch.el"))
        (let ((entries (agent-river--map-entries root)))
          (should (equal (mapcar (lambda (e) (plist-get e :name)) entries)
                         '("scratch.el")))
          (should (plist-get (car entries) :missing)))))))

(ert-deftest agent-river-test-an-agent-is-named-even-on-a-file-that-is-gone ()
  ;; The exemption holds for a deleted file too.  Refusing it left an agent
  ;; whose last act was a deletion named nowhere at all, and losing a party
  ;; off the map is the worse of the two readings -- the strike-through is
  ;; what keeps this one honest.
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor 0.25)
        (agent-river-map-untouched nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "scratch.el"))
        (agent-river-test--cool state "scratch.el" 3600)
        (let ((entries (agent-river--map-entries root)))
          (should (equal (mapcar (lambda (e) (plist-get e :name)) entries)
                         '("scratch.el")))
          (should (plist-get (car entries) :missing))
          (should (plist-get (car (plist-get (car entries) :parties)) :current)))))))

(ert-deftest agent-river-test-a-killed-session-stops-being-pointed-at ()
  ;; The marker is the map's one present-tense reading.  Over a session whose
  ;; agent-shell buffer has been killed it is an arrow pointing at nobody --
  ;; and it was held there for as long as the registry kept the state.
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor 0.25)
        (agent-river-map-untouched nil))
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      (agent-river-test--with-tree root
        (agent-river-test--with-session state
          ;; What the first event through `agent-river-observe' does.
          (agent-river--ensure-shell-teardown "s1")
          (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
          (should (plist-get (car (plist-get (car (agent-river--map-entries root))
                                             :parties))
                             :current))
          (kill-buffer (agent-river--shell-buffer "s1"))
          (let ((parties (plist-get (car (agent-river--map-entries root)) :parties)))
            ;; The file is still warm and still named: it was touched, which
            ;; is history and stays.  Only the claim about now is withdrawn.
            (should parties)
            (should-not (plist-get (car parties) :current))))))))

(ert-deftest agent-river-test-a-killed-session-lets-its-name-fade ()
  ;; The exemption is granted for the sake of a question -- "where is this
  ;; agent now" -- that a session which no longer exists cannot be asked.
  ;; Without this the map accumulated one permanent line per session ever run.
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor 0.25)
        (agent-river-map-untouched nil))
    (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
      (agent-river-test--with-tree root
        (agent-river-test--with-session state
          ;; What the first event through `agent-river-observe' does.
          (agent-river--ensure-shell-teardown "s1")
          (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
          (agent-river-test--cool state "common/c.el" 3600)
          ;; Alive: cold as it is, the file it reached last keeps it named.
          (should (equal (mapcar (lambda (e) (plist-get e :name))
                                 (agent-river--map-entries root))
                         '("common")))
          (kill-buffer (agent-river--shell-buffer "s1"))
          (should-not (agent-river--map-entries root))
          ;; And a root the exemption was the only reason to draw goes too,
          ;; rather than heading a section with nothing under it.
          (should-not (agent-river--map-all-roots)))))))

(ert-deftest agent-river-test-a-finished-subagent-stops-being-pointed-at ()
  ;; SubagentStop is authoritative, so a child that has ended is gone in the
  ;; same sense a killed buffer is.  Its last file says where it was, and
  ;; there is nobody left for the marker to be about.
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor 0.25)
        (agent-river-map-untouched nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (let ((child (agent-river-state "s1/a1" "Explore" "s1" "Explore")))
          (agent-river-fold child (list :kind "act" :cwd root :file "common/c.el"))
          (agent-river-test--cool child "common/c.el" 3600)
          (should (agent-river--map-entries root))
          (agent-river-fold child '(:kind "done"))
          (should-not (agent-river--map-entries root)))))))

(ert-deftest agent-river-test-a-live-sibling-keeps-the-party-named ()
  ;; A party is a label and two sessions can share one -- both `Explore'
  ;; subagents of alpha are `alpha/Explore'.  So whether it has ended is a
  ;; fold over all of them: asked per session, a finished sibling would have
  ;; taken the marker off a party that is still running.
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor 0.25)
        (agent-river-map-untouched nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (let ((live (agent-river-state "s1/a1" "Explore" "s1" "Explore"))
              (done (agent-river-state "s1/a2" "Explore" "s1" "Explore")))
          (agent-river-fold live (list :kind "act" :cwd root :file "docs/d.el"))
          ;; Enough to order the two touches without cooling either past the
          ;; floor, so the party's newest file is the finished one's.
          (agent-river-test--cool live "docs/d.el" 10)
          (agent-river-fold done (list :kind "act" :cwd root :file "common/c.el"))
          (agent-river-fold done '(:kind "done"))
          (let ((common (seq-find (lambda (e) (equal (plist-get e :name) "common"))
                                  (agent-river--map-entries root))))
            (should (equal (plist-get (car (plist-get common :parties)) :party)
                           "alpha/Explore"))
            (should (plist-get (car (plist-get common :parties)) :current))))))))

(ert-deftest agent-river-test-a-quiet-session-keeps-its-name-and-marker ()
  ;; The TTL is a guess at a process we cannot see, and a name is not thrown
  ;; away on a guess.  A CLI session outside Emacs that has simply not been
  ;; given a prompt for a while is still there.
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor 0.25)
        (agent-river-map-untouched nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-test--cool state "common/c.el" 3600)
        (setf (agent-river-state-last-seen state) (time-subtract (current-time) 9999))
        (should-not (agent-river--active-p state))
        (let ((entries (agent-river--map-entries root)))
          (should (equal (mapcar (lambda (e) (plist-get e :name)) entries)
                         '("common")))
          (should (plist-get (car (plist-get (car entries) :parties)) :current)))))))

(ert-deftest agent-river-test-a-cold-root-stops-heading-a-section ()
  ;; Both readings of the artifact tables have to apply the floor, or a root
  ;; kept alive by a touch too cold to name heads a section with nothing
  ;; under it.
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor 0.25))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (should (equal (mapcar #'car (agent-river--map-all-roots)) (list root)))
        (agent-river-test--cool state "common/c.el" 3600)
        ;; Still the one root: it holds the party's current file.
        (should (equal (mapcar #'car (agent-river--map-all-roots)) (list root)))
        ;; Truly nothing left to name, and the root goes with it.
        (agent-river-fold state '(:kind "forget"))
        (should-not (agent-river--map-all-roots))))))

(defmacro agent-river-test--with-worktrees (main linked &rest body)
  "Bind MAIN and LINKED to two trees standing as worktrees of one repository.

Stubbed into `agent-river--worktree-cache' rather than made with git:
what is under test is the grouping and everything the grouping feeds, and
`agent-river--worktree-of' is the one seam git answers through -- a real
`git worktree add' here would test git's parser and cost a subprocess a
test.  Both tables are bound fresh, so a test that groups cannot leave
its members behind for the next one."
  (declare (indent 2))
  `(agent-river-test--with-tree ,main
     (agent-river-test--with-tree ,linked
       (let ((agent-river--worktree-cache (make-hash-table :test 'equal))
             (agent-river--map-member-trees (make-hash-table :test 'equal))
             (agent-river-map-worktrees t))
         (dolist (cell (list (cons ,main ,main) (cons ,linked ,linked)))
           (puthash (car cell)
                    (list :top (cdr cell)
                          :repo (expand-file-name ".git" ,main)
                          :main ,main)
                    agent-river--worktree-cache))
         ,@body))))

(ert-deftest agent-river-test-worktrees-of-one-repository-are-one-tree ()
  ;; The identity was never in doubt -- both sessions fold the key
  ;; `common/c.el', and `agent-river-touching' has always answered for them
  ;; together.  It was only the placement that split them, into two sections
  ;; with nothing saying the two names were one file.
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-worktrees main linked
      (agent-river-test--with-session state
        (let ((other (agent-river-state "s2" "beta")))
          (agent-river-fold state (list :kind "act" :cwd main :file "common/c.el"))
          (agent-river-fold other (list :kind "act" :cwd linked :file "common/c.el"))
          (should (equal (mapcar #'car (agent-river--map-groups)) (list main)))
          (let ((common (seq-find (lambda (e) (equal (plist-get e :name) "common"))
                                  (agent-river--map-entries main))))
            ;; One line, both agents on it -- which is what makes the
            ;; contention marker say something a worktree workflow wants to
            ;; know: these two are going to meet at a merge.
            (should common)
            (should (equal (sort (mapcar (lambda (p) (plist-get p :party))
                                         (plist-get common :parties))
                                 #'string<)
                           '("alpha" "beta")))))))))

(ert-deftest agent-river-test-a-merged-party-is-named-with-its-worktree ()
  ;; Merging answers "is this the same file" and would otherwise delete
  ;; "where is this agent working", which is the more pressing of the two
  ;; once there are worktrees in play.
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-worktrees main linked
      (agent-river-test--with-session state
        (let ((other (agent-river-state "s2" "beta")))
          (agent-river-fold state (list :kind "act" :cwd main :file "common/c.el"))
          (agent-river-fold other (list :kind "act" :cwd linked :file "common/c.el"))
          (agent-river--map-groups)
          (let* ((nodes (agent-river--map-reach main))
                 (rows (gethash (expand-file-name "common/c.el" main)
                                (agent-river--rows-parties
                                 main (list (list :path (expand-file-name
                                                         "common/c.el" main)
                                                  :parties (plist-get (car nodes)
                                                                      :parties)))))))
            (should (seq-find (lambda (row)
                                (string-prefix-p
                                 (concat "beta@" (file-name-nondirectory linked))
                                 (plist-get row :text)))
                              rows))))))))

(ert-deftest agent-river-test-one-tree-names-no-worktree ()
  ;; The tag is what the merge owes, not decoration: a repository with one
  ;; checkout in the state has nothing to disambiguate, and a name carrying
  ;; its own directory there would be noise on every line.
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-worktrees main _linked
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd main :file "common/c.el"))
        (agent-river--map-groups)
        (let ((parties (plist-get (car (agent-river--map-reach main)) :parties)))
          (should parties)
          (should-not (plist-get (car parties) :tree)))))))

(ert-deftest agent-river-test-a-subdirectory-session-still-heads-its-section ()
  ;; Two sessions in one checkout are not worktrees, and grouping them by
  ;; the repository would widen every section to its checkout -- a change
  ;; nobody asked for, wearing this one's clothes.
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-worktrees main _linked
      (agent-river-test--with-session state
        (let* ((other (agent-river-state "s2" "beta"))
               (a (expand-file-name "common" main))
               (b (expand-file-name "docs" main)))
          (dolist (cell (list a b))
            (puthash cell (list :top main :repo (expand-file-name ".git" main)
                                :main main)
                     agent-river--worktree-cache))
          (agent-river-fold state (list :kind "act" :cwd a :file "c.el"))
          (agent-river-fold other (list :kind "act" :cwd b :file "d.el"))
          (should (equal (sort (mapcar #'car (agent-river--map-groups)) #'string<)
                         (sort (list a b) #'string<))))))))

(ert-deftest agent-river-test-a-file-only-one-worktree-has-is-not-gone ()
  ;; The listing is the union across the merged trees.  Taken from the head
  ;; worktree alone, a file living only on the other's branch would be drawn
  ;; struck through -- a deletion the map made up about a file that is
  ;; right there.
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-worktrees main linked
      (agent-river-test--with-session state
        (let ((other (agent-river-state "s2" "beta")))
          (write-region "" nil (expand-file-name "only-here.el" linked))
          (agent-river-fold state (list :kind "act" :cwd main :file "common/c.el"))
          (agent-river-fold other (list :kind "act" :cwd linked
                                        :file "only-here.el"))
          (agent-river--map-groups)
          (let ((entry (seq-find (lambda (e) (equal (plist-get e :name)
                                                    "only-here.el"))
                                 (agent-river--map-entries main))))
            (should entry)
            (should-not (plist-get entry :missing))))))))

(ert-deftest agent-river-test-the-column-is-given-up-where-two-trees-answered ()
  ;; Two worktrees are two working trees on two branches, so a merged line
  ;; has two diffstats and the column has room for one reading.  Summing
  ;; them would state a number true of no tree; picking one would pick which
  ;; worktree the reader meant.  The rows say it per tree instead.
  (let ((agent-river--vc-cache (make-hash-table :test 'equal))
        (agent-river-heat-half-life nil))
    (agent-river-test--with-worktrees main linked
      (agent-river-test--with-session state
        (let ((other (agent-river-state "s2" "beta"))
              (node (list :path (expand-file-name "common/c.el" main))))
          (agent-river-fold state (list :kind "act" :cwd main :file "common/c.el"))
          (agent-river-fold other (list :kind "act" :cwd linked :file "common/c.el"))
          (agent-river--map-groups)
          (puthash main (list :at (current-time)
                              :table (agent-river-test--numstat
                                      "2\t0\tcommon/c.el\0" main))
                   agent-river--vc-cache)
          ;; One tree answering is the ordinary case and keeps its column.
          (let ((rows (gethash (plist-get node :path)
                               (agent-river--rows-vc main (list node)))))
            (should (= (length rows) 1))
            (should (agent-river--vc-summary rows)))
          (puthash linked (list :at (current-time)
                                :table (agent-river-test--numstat
                                        "9\t3\tcommon/c.el\0" linked))
                   agent-river--vc-cache)
          (let ((rows (gethash (plist-get node :path)
                               (agent-river--rows-vc main (list node)))))
            (should (= (length rows) 2))
            (should-not (agent-river--vc-summary rows))
            ;; And each row says whose tree it is reporting, or the two
            ;; would be one fact printed twice with different numbers.
            (should (seq-find (lambda (row)
                                (string-prefix-p
                                 (concat (file-name-nondirectory linked) ": ")
                                 (plist-get row :text)))
                              rows))))))))

(ert-deftest agent-river-test-a-merged-line-reads-the-tree-its-agents-are-in ()
  ;; Both trees answer about every line -- pending changes are a fact about
  ;; a working tree whoever made them -- so giving the column up on two
  ;; answers would have emptied it wherever a checkout was merely dirty.
  ;; The tie-break is the one the whole view rests on: the tree this line's
  ;; agents are in.
  (let ((agent-river--vc-cache (make-hash-table :test 'equal))
        (agent-river-heat-half-life nil))
    (agent-river-test--with-worktrees main linked
      (agent-river-test--with-session state
        (let ((other (agent-river-state "s2" "beta"))
              (node (list :path (expand-file-name "common/c.el" main))))
          ;; One agent in each tree, so the trees are merged, but only the
          ;; one in the checkout has been in this file.
          (agent-river-fold state (list :kind "act" :tool "Edit" :cwd main
                                        :file "common/c.el"))
          (agent-river-fold other (list :kind "act" :tool "Edit" :cwd linked
                                        :file "docs/d.el"))
          (agent-river--map-groups)
          (setq node (list :path (plist-get node :path)
                           :parties (plist-get (car (agent-river--map-reach main))
                                               :parties)))
          (puthash main (list :at (current-time)
                              :table (agent-river-test--numstat
                                      "2\t0\tcommon/c.el\0" main))
                   agent-river--vc-cache)
          (puthash linked (list :at (current-time)
                                :table (agent-river-test--numstat
                                        "9\t9\tcommon/c.el\0" linked))
                   agent-river--vc-cache)
          (let ((rows (gethash (plist-get node :path)
                               (agent-river--rows-vc main (list node)))))
            ;; Both are reported -- the other tree's change is real and the
            ;; row is where it is said -- and the line reads the one whose
            ;; agent is on it.
            (should (= (length rows) 2))
            (should (equal (substring-no-properties
                            (agent-river--vc-summary rows))
                           "+2")))
          ;; And a landing is not claimed for a tree nobody wrote in: the
          ;; file is identical to the main branch in both, and only one of
          ;; them has an agent who put it there.
          (agent-river-test--ahead main nil)
          (agent-river-test--ahead linked nil)
          (let ((rows (gethash (plist-get node :path)
                               (agent-river--rows-vc main (list node)))))
            (should (= (length rows) 1))
            (should (string-prefix-p (concat (file-name-nondirectory main) ": ")
                                     (plist-get (car rows) :text)))))))))

(ert-deftest agent-river-test-splitting-the-worktrees-again-is-one-setting ()
  ;; Split is the other honest reading, not a fallback: the two files
  ;; really are two files, on two branches.
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-worktrees main linked
      (agent-river-test--with-session state
        (let ((other (agent-river-state "s2" "beta"))
              (agent-river-map-worktrees nil))
          (agent-river-fold state (list :kind "act" :cwd main :file "common/c.el"))
          (agent-river-fold other (list :kind "act" :cwd linked :file "common/c.el"))
          (should (equal (sort (mapcar #'car (agent-river--map-groups)) #'string<)
                         (sort (list main linked) #'string<))))))))

(ert-deftest agent-river-test-no-floor-names-every-touch ()
  (let ((agent-river-heat-half-life 120)
        (agent-river-map-party-floor nil)
        (agent-river-map-untouched nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "dialog/src/main/foo.el"))
        (agent-river-test--cool state "common/c.el" 3600)
        ;; The off switch restores what this replaced.
        (should (equal (sort (mapcar (lambda (e) (plist-get e :name))
                                     (agent-river--map-entries root))
                             #'string<)
                       '("common" "dialog")))))))

(ert-deftest agent-river-test-forget-drops-the-files-and-keeps-the-session ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "prompt" :text "land the branch"))
    (agent-river-fold state '(:kind "act" :tool "Edit" :file "a.el"
                                    :path "/w/elsewhere/a.el" :cwd "/w"))
    (agent-river-test--fail state 2)
    (agent-river-fold state '(:kind "forget"))
    (should (= (hash-table-count (agent-river-state-artifacts state)) 0))
    (should (= (hash-table-count (agent-river-state-task-artifacts state)) 0))
    ;; The anchors are keyed on artifact keys, so without them they address
    ;; nothing.
    (should (= (hash-table-count (agent-river-state-anchors state)) 0))
    ;; What the session is and how it is going survives -- this forgets
    ;; where the work was, not that there was any.
    (should (equal (agent-river-state-task state) "land the branch"))
    (should (= (agent-river-state-steps state) 1))
    (should (= (agent-river-state-fail-streak state) 2))))

(ert-deftest agent-river-test-forget-can-name-which-files-to-drop ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :tool "Edit" :file "a.el"
                                    :path "/w/elsewhere/a.el" :cwd "/w"))
    (agent-river-fold state '(:kind "act" :tool "Edit" :file "b.el" :cwd "/w"))
    ;; One branch, one transition, a smaller subject.  A second kind would be
    ;; a second place for "what forgetting means" to be decided.
    (agent-river-fold state '(:kind "forget" :files ("a.el")))
    (should-not (gethash "a.el" (agent-river-state-artifacts state)))
    (should (gethash "b.el" (agent-river-state-artifacts state)))
    (should-not (gethash "a.el" (agent-river-state-task-artifacts state)))
    ;; The anchor goes with the artifact it addressed, and only that one.
    (should (= (hash-table-count (agent-river-state-anchors state)) 0))
    ;; And the session is untouched, as with a whole forget.
    (should (= (agent-river-state-steps state) 2))))

(ert-deftest agent-river-test-a-gone-file-is-measured-against-the-disk ()
  (agent-river-test--with-tree root
    (agent-river-test--with-session state
      (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
      (agent-river-fold state (list :kind "act" :cwd root :file "docs/old.md"))
      ;; Only the one that is not there.  `common/c.el' exists, and a command
      ;; that swept it would be throwing away a measurement about live work.
      (should (equal (agent-river--gone-artifacts state) '("docs/old.md")))
      (delete-file (expand-file-name "common/c.el" root))
      (should (equal (sort (agent-river--gone-artifacts state) #'string<)
                     '("common/c.el" "docs/old.md"))))))

(ert-deftest agent-river-test-a-stray-is-looked-for-where-it-really-was ()
  (agent-river-test--with-tree root
    (agent-river-test--with-session state
      ;; `agent-river--rel' degrades a file outside the cwd to a bare
      ;; basename, so resolving it against the cwd looks for it in a
      ;; directory no agent ever opened -- and would then call a file that
      ;; exists gone.  The anchor is what stops that.
      (agent-river-fold state (list :kind "act" :cwd root
                                    :file (expand-file-name "common/c.el" root)
                                    :path (expand-file-name "common/c.el" root)))
      (should-not (agent-river--gone-artifacts state))
      ;; A key nothing can place is unplaceable rather than gone: a state
      ;; folded without a cwd must not have every artifact it ever recorded
      ;; swept away by a command that never found any of them.
      (should-not (agent-river--artifact-gone-p
                   (agent-river--state-create :id "x" :artifacts nil
                                              :anchors nil)
                   "c.el")))))

(ert-deftest agent-river-test-cleaning-up-gone-files-asks-first ()
  (agent-river-test--with-tree root
    (agent-river-test--with-session state
      (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
      (agent-river-fold state (list :kind "act" :cwd root :file "docs/old.md"))
      ;; A keystroke in a view buffer is easy to hit and nothing undoes this,
      ;; so the question is part of the command rather than a nicety.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (agent-river-forget-gone-files))
      (should (gethash "docs/old.md" (agent-river-state-artifacts state)))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (agent-river-forget-gone-files))
      (should-not (gethash "docs/old.md" (agent-river-state-artifacts state)))
      ;; Where the work actually is survives it.
      (should (gethash "common/c.el" (agent-river-state-artifacts state))))))

(ert-deftest agent-river-test-cleaning-up-gone-files-is-on-the-map-s-keys ()
  ;; The one forgetting command that belongs on a key there: its subject is
  ;; already gone, so what is lost is the record of an absence.
  (dolist (map (list agent-river-map-mode-map agent-river-map-plain-mode-map))
    (should (eq (lookup-key map (kbd "C")) #'agent-river-forget-gone-files)))
  ;; And the one that drops the record of the work itself stays off them.
  (dolist (map (list agent-river-map-mode-map agent-river-map-plain-mode-map))
    (should-not (eq (lookup-key map (kbd "C")) #'agent-river-forget-artifacts))))

(ert-deftest agent-river-test-the-filter-never-hides-activity ()
  ;; The one thing the map exists not to do.  The filter is written as "has
  ;; no parties" rather than "is not on disk", so an entry the state knows
  ;; about and the disk does not survives it -- which is exactly the entry a
  ;; disk-shaped filter would have dropped.
  (let ((agent-river-heat-half-life nil)
        (agent-river-map-untouched nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "deleted/gone.el"))
        (let ((entries (agent-river--map-entries root)))
          (should (equal (mapcar (lambda (e) (plist-get e :name)) entries)
                         '("deleted")))
          (should (plist-get (car entries) :missing)))))))

(ert-deftest agent-river-test-a-map-entry-carries-what-is-beneath-it ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "dialog/src/main/foo.el"))
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "dialog/src/main/foo.el"))
        (let ((dialog (seq-find (lambda (e) (equal (plist-get e :name) "dialog"))
                                (agent-river--map-entries root))))
          ;; The entry's reading is the aggregate of its files and never a
          ;; tally of its own, so the two can never disagree.
          (should (equal (plist-get (car (plist-get dialog :parties)) :weight) 2))
          ;; A file five directories down is still reported under the one
          ;; name that is on screen, with the rest of its path inline.
          (should (equal (mapcar (lambda (f) (plist-get f :rel))
                                 (plist-get dialog :files))
                         '("src/main/foo.el"))))))))

(ert-deftest agent-river-test-the-map-shows-two-agents-on-one-directory ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (let ((other (agent-river-state "s2" "beta")))
          (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
          (agent-river-fold other (list :kind "act" :cwd root :file "common/c.el"))
          (agent-river-fold other (list :kind "act" :cwd root :file "common/c.el"))
          (let* ((common (seq-find (lambda (e) (equal (plist-get e :name) "common"))
                                   (agent-river--map-entries root)))
                 (parties (plist-get common :parties)))
            ;; Two agents in one place is the case the map earns its keep
            ;; on -- and the one thing a dired line has no room to say.
            (should (equal (mapcar (lambda (p) (plist-get p :party)) parties)
                           '("beta" "alpha")))
            (should (equal (plist-get (car parties) :weight) 2))))))))

(ert-deftest agent-river-test-the-map-says-where-an-agent-is-now ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        ;; Weight alone cannot answer this.  After a long task the file with
        ;; the most touches is where the agent *was*; only the newest touch
        ;; says where it is, and those are different places.
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "dialog/src/main/foo.el"))
        (let ((entries (agent-river--map-entries root)))
          (should-not (plist-get (car (plist-get
                                       (seq-find (lambda (e) (equal (plist-get e :name) "common"))
                                                 entries)
                                       :parties))
                                 :current))
          (should (plist-get (car (plist-get
                                   (seq-find (lambda (e) (equal (plist-get e :name) "dialog"))
                                             entries)
                                   :parties))
                             :current)))))))

(ert-deftest agent-river-test-where-an-agent-is-survives-descending ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "dialog/src/main/foo.el"))
        ;; Descending into `common' must not invent a second "most recent"
        ;; file that only looks like one because the real one is out of
        ;; view -- the map would then point at an agent that left.
        (let* ((entries (agent-river--map-entries (expand-file-name "common" root)))
               (c (seq-find (lambda (e) (equal (plist-get e :name) "c.el")) entries)))
          (should (plist-get c :parties))
          (should-not (plist-get (car (plist-get c :parties)) :current)))))))

(ert-deftest agent-river-test-the-map-reads-the-frame-it-is-asked-for ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-fold state '(:kind "prompt" :text "next"))
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "dialog/src/main/foo.el"))
        (let ((session (agent-river--map-entries root 'session))
              (task (agent-river--map-entries root 'task)))
          ;; The map defaults to the session frame and the dired heat to the
          ;; task frame, so the two readings must be genuinely different
          ;; things and the header has to say which is being shown.
          (should (plist-get (seq-find (lambda (e) (equal (plist-get e :name) "common"))
                                       session)
                             :parties))
          (should-not (plist-get (seq-find (lambda (e) (equal (plist-get e :name) "common"))
                                           task)
                                 :parties)))))))

(ert-deftest agent-river-test-the-map-still-shows-a-file-that-is-gone ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "deleted/old.el"))
        (let ((gone (seq-find (lambda (e) (equal (plist-get e :name) "deleted"))
                              (agent-river--map-entries root))))
          ;; Activity the map does not show is the one thing it exists not
          ;; to do, so a path whose top component is gone is listed and
          ;; marked rather than dropped.
          (should gone)
          (should (plist-get gone :missing))
          (should (plist-get gone :parties)))))))

(ert-deftest agent-river-test-a-subagent-is-named-on-the-map ()
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (let ((child (agent-river-state "s1/a1" "Explore" "s1" "Explore")))
          (agent-river-fold child (list :kind "act" :cwd root :file "common/c.el"))
          (let ((common (seq-find (lambda (e) (equal (plist-get e :name) "common"))
                                  (agent-river--map-entries root))))
            ;; The note the map is addressed to a human rather than to the
            ;; agent, but the reasoning is the same as a foreign save's: a
            ;; file a child holds, reported under the parent's name, reads
            ;; as a statement about the parent's own work.
            (should (equal (plist-get (car (plist-get common :parties)) :party)
                           "alpha/Explore"))))))))

(ert-deftest agent-river-test-a-map-fold-made-by-hand-wins ()
  (let ((agent-river--map-folds nil))
    ;; An entry with activity opens by default -- the files are why it is
    ;; annotated at all.
    (should (agent-river--map-open-p '(:name "dialog" :files ((:rel "a.el"))) "/repo"))
    (should-not (agent-river--map-open-p '(:name "docs" :files nil) "/repo"))
    ;; And a toggle wins from then on, because the map is redrawn every few
    ;; seconds and a fold that sprang back each time would not be a fold.
    (let ((agent-river--map-folds '(("/repo/dialog" . nil))))
      (should-not (agent-river--map-open-p '(:name "dialog" :files ((:rel "a.el")))
                                           "/repo"))
      ;; Keyed on the path, so the same name under another root is untouched
      ;; by it -- the overview shows several roots at once.
      (should (agent-river--map-open-p '(:name "dialog" :files ((:rel "a.el")))
                                       "/other")))))

;;; The map, rendered as Markdown
;;
;; The text is the derivation here, so it is tested like one.  What can go
;; wrong silently is the part tree-sitter has an opinion about: which
;; property carries a face, and whether a filename survives inline markup.

(ert-deftest agent-river-test-a-map-line-is-markdown ()
  (let ((agent-river-map-name-width 24))
    ;; A directory has something under it and folds, so it is a heading; a
    ;; file does not, so it is a list item.  Making every file a level-3
    ;; heading would set the whole listing in the heading face and say that
    ;; a file contains the lines after it.
    ;; The gutter sits between the marker and the name, so the heading is
    ;; still a heading and the name is still a code span.
    (should (string-match-p "\\`## +`common/`"
                            (agent-river--map-line 2 "common/" nil)))
    (should (string-match-p "\\`- +`c.el`"
                             (agent-river--map-line 'file "c.el" nil)))
    ;; A file says `file' rather than a number for exactly this reason: the
    ;; overview pushes entries to level 3 to make room for root headings,
    ;; and a file taking its level from its entry would follow it into
    ;; being a heading.
    (should (string-match-p "\\`### +`common/`"
                            (agent-river--map-line 3 "common/" nil)))))

(ert-deftest agent-river-test-a-filename-is-not-eaten-by-markup ()
  ;; Bare in Markdown, `foo_bar_baz.el' renders with `bar' in italics and
  ;; the underscores gone -- a filename the view would be lying about.  A
  ;; code span is both what a path is for and where inline markup stops.
  (should (string-match-p "`foo_bar_baz\\.el`"
                          (agent-river--map-line 'file "foo_bar_baz.el" nil))))

(ert-deftest agent-river-test-map-shading-rides-on-its-own-property ()
  (let* ((parties '((:party "alpha" :weight 9 :current t)))
         (line (agent-river--map-line 2 "common/" parties))
         (row (agent-river--map-row-line '(:text "alpha" :face agent-river-act))))
    ;; tree-sitter owns `face' in this buffer: it refontifies on redisplay
    ;; and appends or removes faces as the structure changes, so a shading
    ;; written there is drawn once and then quietly gone.  The mark is what
    ;; `agent-river--map-shade' turns into an overlay, which sits above all
    ;; of it.
    (should-not (text-property-not-all 0 (length line) 'face nil line))
    (should (text-property-any 0 (length line) 'agent-river-map-face
                               'agent-river-heat-3 line))
    ;; And a contributed row is held to it too -- it is the first text here
    ;; that is not ours, so it is the most likely place for a face to be set
    ;; the wrong way.
    (should-not (text-property-not-all 0 (length row) 'face nil row))
    (should (text-property-any 0 (length row) 'agent-river-map-face
                               'agent-river-act row))))

(ert-deftest agent-river-test-map-annotations-line-up-across-levels ()
  (let* ((agent-river-map-name-width 24)
         (parties '((:party "alpha" :weight 9)))
         (heading (agent-river--map-line 2 "common/" parties nil "+1"))
         (item (agent-river--map-line 'file "c.el" parties nil "+1")))
    ;; The markers are different widths -- `## ' against `- ' -- so the
    ;; padding has to be measured from the whole prefix.  Measured from the
    ;; name alone, every list item's reading sat one column left of every
    ;; heading's and the column stopped being one.
    (should (= (string-match-p "\\+1" heading) (string-match-p "\\+1" item)))))

(ert-deftest agent-river-test-the-line-shows-no-party-names ()
  ;; The names were the one ragged thing on the line, so nothing scannable
  ;; could ever follow them.  They are rows underneath now; what stays is
  ;; what can be read down the listing -- the shading, and the two markers.
  (let ((line (agent-river--map-line 'file "c.el"
                                     '((:party "alpha" :weight 9 :current t)
                                       (:party "beta" :weight 2)))))
    (should-not (string-match-p "alpha" line))
    ;; One fact, one encoding: the weight is the shading, never a number.
    (should-not (string-match-p "[0-9]" line))
    ;; Contention and position are still on the line, because "is anyone
    ;; here" and "where is the work" are questions asked of the whole
    ;; listing at once.
    (should (string-match-p agent-river-map-contended-marker line))
    (should (string-match-p agent-river-map-here-marker line)))
  ;; And the names are where they went.
  (let* ((rows (gethash "/repo/c.el"
                        (agent-river--rows-parties
                         "/repo" '((:path "/repo/c.el"
                                    :parties ((:party "alpha" :weight 9 :writes 2
                                               :current t)))))))
         (text (plist-get (car rows) :text)))
    (should (string-match-p "alpha" text))
    ;; Saying what a bracket never could.
    (should (string-match-p "2 writes" text))
    (should (string-match-p agent-river-map-here-marker text))))

(ert-deftest agent-river-test-the-map-degrades-without-tree-sitter ()
  ;; The mode ships with Emacs 31, the grammars do not.  Without them the
  ;; same Markdown is shown unfontified rather than the map failing at the
  ;; moment it is opened.
  (should (fboundp 'agent-river-map-plain-mode))
  (should (eq (get 'agent-river-map-plain-mode 'derived-mode-parent) 'special-mode))
  (should (eq (get 'agent-river-map-mode 'derived-mode-parent) 'markdown-ts-view-mode))
  ;; Both ways in carry the same keys, or the fallback would be a second
  ;; view to keep in step rather than the same one drawn plainer.
  (dolist (key '("TAB" "RET" "^" "g"))
    (should (eq (lookup-key agent-river-map-mode-map (kbd key))
                (lookup-key agent-river-map-plain-mode-map (kbd key))))))

;;; The disk, beside the stream
;;
;; The diffstat is the one thing on a map line that is not folded from an
;; event, so nothing above tests it.  What is tested is the derivation --
;; git's output in, a reading out -- and never the commands: a test that
;; ran git would be testing git, slowly, and on whatever happened to be
;; uncommitted in the checkout it ran from.

(defun agent-river-test--numstat (output &optional root)
  "Return OUTPUT parsed as a diffstat table under ROOT."
  (agent-river--vc-parse output (or root "/repo") (make-hash-table :test 'equal)))

(ert-deftest agent-river-test-numstat-reads-git-s-three-record-shapes ()
  (let ((table (agent-river-test--numstat
                (concat "2\t0\tREADME.md\0"
                        ;; A rename spends three records: the counts with an
                        ;; empty name, then the old name and the new one.
                        "0\t0\t\0hook.sh\0bridge.sh\0"
                        ;; And a binary file has no line counts to give.
                        "-\t-\tlogo.png\0"))))
    (should (equal (gethash "/repo/README.md" table) '(2 . 0)))
    ;; The new name is the one the listing can have a line for; the old one
    ;; is not there to annotate.
    (should (equal (gethash "/repo/bridge.sh" table) '(0 . 0)))
    (should-not (gethash "/repo/hook.sh" table))
    ;; Recorded at zero rather than dropped: it still differs from HEAD,
    ;; and a file that changed must not read like a file that did not.
    (should (equal (gethash "/repo/logo.png" table) '(0 . 0)))))

(ert-deftest agent-river-test-a-diffstat-covers-the-tree-beneath-a-name ()
  (let ((table (agent-river-test--numstat
                (concat "10\t6\tsrc/a.el\0" "1\t1\tsrc/deep/b.el\0"
                        "3\t0\tdoc.md\0" "5\t5\tsrcaux/c.el\0"))))
    ;; The same grain as the parties: a directory line reports the whole
    ;; subtree, because that is what the listing gives it a line for.
    ;; The fourth element is how many files that was, which only a
    ;; directory's row has room to say.
    (should (equal (agent-river--vc-under table "/repo/src") '(11 7 nil 2)))
    (should (equal (agent-river--vc-under table "/repo/src/a.el") '(10 6 nil 1)))
    (should (equal (agent-river--vc-under table "/repo") '(19 12 nil 4)))
    ;; Matched as a directory, so a sibling whose name merely starts the
    ;; same way does not get counted into it.
    (should-not (member 5 (agent-river--vc-under table "/repo/src")))
    ;; Nothing beneath it is a different answer from nobody having asked,
    ;; and the caller tells them apart by which of the two is nil.
    (should-not (agent-river--vc-under table "/repo/elsewhere"))
    (should-not (agent-river--vc-under nil "/repo/src"))))

(ert-deftest agent-river-test-an-untracked-file-is-marked-rather-than-counted ()
  ;; A file the agent has just written has no HEAD version to have differed
  ;; from -- and it is exactly the line a map of the work most wants
  ;; annotated, so it says so with git's own word rather than nothing.
  (let ((table (make-hash-table :test 'equal)))
    (puthash "/repo/src/new.el" 'new table)
    (puthash "/repo/src/a.el" '(4 . 0) table)
    (should (equal (agent-river--vc-under table "/repo/src") '(4 0 t 2)))
    (should (equal (agent-river--vc-column (agent-river--vc-under table "/repo/src"))
                   "+4 ?"))
    (should (equal (agent-river--vc-column
                    (agent-river--vc-under table "/repo/src/new.el"))
                   "?"))))

(ert-deftest agent-river-test-a-diffstat-shows-only-what-is-not-zero ()
  (should (equal (agent-river--vc-column '(10 6 nil)) "+10 -6"))
  ;; `+12 -0' makes a reader look at a number to find out it means nothing.
  (should (equal (agent-river--vc-column '(12 0 nil)) "+12"))
  (should (equal (agent-river--vc-column '(0 3 nil)) "-3"))
  ;; Nothing to say at all is nil, which the caller turns into an empty
  ;; column rather than into a line that claims a change of size zero.
  (should-not (agent-river--vc-column '(0 0 nil)))
  (should-not (agent-river--vc-column nil)))

(ert-deftest agent-river-test-the-diffstat-rides-on-the-map-s-own-face-property ()
  ;; Same reason as the shading: tree-sitter owns `face' in that buffer and
  ;; refontifies over anything written there.
  (let ((column (agent-river--vc-column '(10 6 nil))))
    (should-not (text-property-not-all 0 (length column) 'face nil column))
    (should (text-property-any 0 (length column) 'agent-river-map-face
                               'agent-river-added column))
    (should (text-property-any 0 (length column) 'agent-river-map-face
                               'agent-river-removed column))))

(ert-deftest agent-river-test-the-summary-column-starts-in-one-place ()
  (let* ((agent-river-map-name-width 24)
         (parties '((:party "alpha" :weight 9 :current t)))
         (deep (agent-river--map-line 3 "a-long-name/" parties nil "+1"))
         (short (agent-river--map-line 'file "a.el" parties nil "+1")))
    ;; The column is what can be read down the listing, and only if it
    ;; starts in the same place whatever the level and the name.
    (should (= (string-match-p "\\+1" deep) (string-match-p "\\+1" short))))
  ;; With nothing to put in it there is no column and no trailing blank: a
  ;; line's own markers live in the gutter before the name now.
  (should-not (string-match-p " \\'" (agent-river--map-line 'file "a.el" nil))))

(ert-deftest agent-river-test-the-diffstat-column-is-reserved-buffer-wide ()
  (let ((table (agent-river-test--numstat "2\t0\ta.el\0")))
    ;; `agent-river--map-draw' decides once for the whole buffer, so the
    ;; reading is empty rather than absent where there is nothing to report.
    (puthash "/repo" (list :at (current-time) :table table :proc nil)
             agent-river--vc-cache)
    (let ((rows (agent-river--rows-vc "/repo" '((:path "/repo/a.el")
                                                (:path "/repo/b.el")))))
      ;; `agent-river--map-draw' decides once for the whole buffer, so the
      ;; reading is empty rather than absent where there is nothing to say.
      (should (equal (agent-river--map-summary
                      (list (cons (list :summary #'agent-river--vc-summary)
                                  (gethash "/repo/a.el" rows)))
                      t)
                     "+2"))
      (should (equal (agent-river--map-summary
                      (list (cons (list :summary #'agent-river--vc-summary)
                                  (gethash "/repo/b.el" rows)))
                      t)
                     ""))
      (should-not (agent-river--map-summary nil nil)))))

(defun agent-river-test--ahead (root paths)
  "Record PATHS as the ones ROOT's branch still has outside the main branch."
  (let ((ahead (make-hash-table :test 'equal)))
    (dolist (path paths) (puthash path t ahead))
    (puthash root (list :at (current-time) :table (make-hash-table :test 'equal)
                        :ahead ahead :main "main" :proc nil)
             agent-river--vc-cache)))

(ert-deftest agent-river-test-a-landed-file-says-so-in-the-column ()
  ;; Merged or rebased look the same from the file's side and are the same
  ;; fact about it: what this branch did to the file is now only in the main
  ;; branch, so there is nothing here to show and nothing left to land.
  (let ((agent-river--vc-cache (make-hash-table :test 'equal))
        (agent-river-map-landed-marker "✓")
        (table (make-hash-table :test 'equal)))
    (ignore table)
    (agent-river-test--ahead "/repo" '("/repo/pending.el"))
    (let ((rows (agent-river--rows-vc
                 "/repo" '((:path "/repo/landed.el" :parties ((:party "a" :writes 3)))
                           (:path "/repo/pending.el" :parties ((:party "a" :writes 3)))))))
      (should (equal (agent-river--vc-summary (gethash "/repo/landed.el" rows)) "✓"))
      ;; And the row spells out what the column abbreviates -- the line is a
      ;; projection of the rows, so the two cannot disagree.
      (should (equal (plist-get (car (gethash "/repo/landed.el" rows)) :text)
                     "in the main branch"))
      ;; Still outside the main branch: nothing to say yet.
      (should-not (gethash "/repo/pending.el" rows)))))

(ert-deftest agent-river-test-a-file-only-read-has-not-landed ()
  ;; Git can say a file is identical to the main branch; it cannot say
  ;; whether that is because the work landed there or because nobody ever
  ;; changed it.  Most of what an agent touches it only read, so marking on
  ;; git's answer alone would put a tick down nearly every line -- a view
  ;; where everything is marked marks nothing.
  (let ((agent-river--vc-cache (make-hash-table :test 'equal))
        (table (make-hash-table :test 'equal)))
    (ignore table)
    (agent-river-test--ahead "/repo" nil)
    (should-not (gethash "/repo/read.el"
                         (agent-river--rows-vc
                          "/repo" '((:path "/repo/read.el"
                                     :parties ((:party "a" :writes 0)))))))
    (should-not (gethash "/repo/read.el"
                         (agent-river--rows-vc
                          "/repo" '((:path "/repo/read.el" :parties nil)))))))

(ert-deftest agent-river-test-an-unanswered-branch-lands-nothing ()
  ;; `:ahead' unset means nobody could ask -- no main branch here, or the
  ;; read is still out.  The marker says work is safely in the main branch,
  ;; which is the last thing to say on a guess.
  (let ((agent-river--vc-cache (make-hash-table :test 'equal))
        (table (make-hash-table :test 'equal)))
    (ignore table)
    (should-not (agent-river--vc-landed-p "/repo" "/repo/a.el"))
    (should-not (gethash "/repo/a.el"
                         (agent-river--rows-vc
                          "/repo" '((:path "/repo/a.el"
                                     :parties ((:party "a" :writes 3)))))))
    ;; And an *empty* answer is the opposite of an absent one: everything
    ;; this branch changed is in the main branch now.
    (agent-river-test--ahead "/repo" nil)
    (should (agent-river--vc-landed-p "/repo" "/repo/a.el"))))

(ert-deftest agent-river-test-pending-work-outranks-a-landing ()
  ;; The three readings are one question -- what state is the work on this
  ;; line in -- so a file with uncommitted changes shows those.  Its earlier
  ;; landings are not the news.
  (let ((agent-river--vc-cache (make-hash-table :test 'equal))
        (table (agent-river-test--numstat "2\t1\ta.el\0")))
    (agent-river-test--ahead "/repo" nil)
    (puthash "/repo" (list :at (current-time) :table table
                           :ahead (make-hash-table :test 'equal) :proc nil)
             agent-river--vc-cache)
    (let ((rows (agent-river--rows-vc
                 "/repo" '((:path "/repo/a.el"
                            :parties ((:party "a" :writes 3)))))))
      (should (equal (agent-river--vc-summary (gethash "/repo/a.el" rows))
                     "+2 -1"))
      (should (string-match-p "vs HEAD"
                              (plist-get (car (gethash "/repo/a.el" rows)) :text))))))

(ert-deftest agent-river-test-a-directory-lands-when-everything-under-it-has ()
  ;; The same grain as the parties: a directory line reports the subtree,
  ;; because that is what the listing gives it a line for.
  (let ((agent-river--vc-cache (make-hash-table :test 'equal))
        (table (make-hash-table :test 'equal)))
    (agent-river-test--ahead "/repo" '("/repo/src/pending.el"))
    (should-not (agent-river--vc-landed-p "/repo" "/repo/src"))
    (should (agent-river--vc-landed-p "/repo" "/repo/docs"))))

(ert-deftest agent-river-test-the-main-branch-is-what-the-remote-says-it-is ()
  ;; `for-each-ref' sorts by refname, so taking git's order would make the
  ;; answer alphabetical and put `master' ahead of what the remote itself
  ;; calls its main branch.
  (should (equal (agent-river--vc-main-rev '("refs/heads/master"
                                             "refs/remotes/origin/HEAD"))
                 "origin/HEAD"))
  (should (equal (agent-river--vc-main-rev '("refs/heads/master")) "master"))
  ;; A project that calls it something else says so, and is not overruled.
  (let ((agent-river-map-main-branch "trunk"))
    (should (equal (agent-river--vc-main-rev '("refs/heads/main")) "trunk")))
  ;; Nothing resolves: no main branch here, which costs the marker only.
  (should-not (agent-river--vc-main-rev '("refs/heads/topic"))))

(ert-deftest agent-river-test-a-write-is-counted-apart-from-a-read ()
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :tool "Read" :file "a.el"))
    (let ((entry (gethash "a.el" (agent-river-state-artifacts state))))
      (should (= (plist-get entry :touches) 1))
      (should (= (plist-get entry :writes) 0)))
    (agent-river-fold state '(:kind "act" :tool "Edit" :file "a.el"))
    (let ((entry (gethash "a.el" (agent-river-state-artifacts state))))
      (should (= (plist-get entry :touches) 2))
      (should (= (plist-get entry :writes) 1)))
    ;; Both frames, like the touches themselves: the map reads the session
    ;; frame and the dired heat the task frame.
    (should (= (plist-get (gethash "a.el" (agent-river-state-task-artifacts state))
                          :writes)
               1))))

(ert-deftest agent-river-test-writes-reach-the-map-line ()
  ;; The count has to survive the derivation the line is built from, or the
  ;; marker cannot be asked for: reach sums it per party, merging sums it
  ;; across them, and a directory's answer is its subtree's.
  (let ((agent-river-heat-half-life nil))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :tool "Edit"
                                      :cwd root :file "common/c.el"))
        (agent-river-fold state (list :kind "act" :tool "Read"
                                      :cwd root :file "common/c.el"))
        (let ((common (seq-find (lambda (e) (equal (plist-get e :name) "common"))
                                (agent-river--map-entries root))))
          (should (= (agent-river--map-writes (plist-get common :parties)) 1))
          (should (= (agent-river--map-weight (plist-get common :parties)) 2)))))))

(defun agent-river-test--contributor (name rows &rest extra)
  "Return a contributor called NAME answering ROWS for every node."
  (append (list :name name
                :read (lambda (_root nodes)
                        (let ((table (make-hash-table :test 'equal)))
                          (dolist (node nodes)
                            (puthash (plist-get node :path) rows table))
                          table)))
          extra))

(ert-deftest agent-river-test-a-contributor-adds-rows-under-a-node ()
  (let ((agent-river-map-contributors
         (list (agent-river-test--contributor 'a '((:key "1" :text "one")))
               (agent-river-test--contributor 'b '((:key "2" :text "two"))))))
    (let* ((rows (agent-river--map-rows "/repo" '((:path "/repo/a.el"))))
           (contributed (gethash "/repo/a.el" rows)))
      ;; Grouped by contributor and in registration order: anything else
      ;; reorders itself between two redraws with nothing having happened.
      (should (equal (mapcar (lambda (pair) (plist-get (car pair) :name)) contributed)
                     '(a b)))
      (should (equal (mapcar (lambda (row) (plist-get row :text))
                             (agent-river--map-row-list contributed))
                     '("one" "two"))))))

(ert-deftest agent-river-test-a-broken-contributor-is-retired ()
  ;; This runs on every redraw, so a broken one is broken thousands of
  ;; times.  A view that dies with it is the worse outcome -- the same
  ;; bargain the observers make.
  (let ((agent-river-map-contributors
         (list (list :name 'broken :read (lambda (&rest _) (error "nope")))
               (agent-river-test--contributor 'fine '((:key "1" :text "one"))))))
    (let ((rows (agent-river--map-rows "/repo" '((:path "/repo/a.el")))))
      ;; The good one still answered.
      (should (gethash "/repo/a.el" rows)))
    (should (equal (mapcar (lambda (c) (plist-get c :name))
                           agent-river-map-contributors)
                   '(fine)))))

(ert-deftest agent-river-test-a-row-the-line-already-says-is-not-drawn ()
  ;; `- +529 -122 vs HEAD' under a line reading `+529 -122' is the line's
  ;; own reading written out again, in the one place this design says there
  ;; must be no second account of anything.  The row still earns the
  ;; column -- it is where the column comes from -- it is just not repeated
  ;; underneath it.
  (let ((agent-river--vc-cache (make-hash-table :test 'equal))
        (table (agent-river-test--numstat "5\t2\ta.el\0")))
    (puthash "/repo" (list :at (current-time) :table table) agent-river--vc-cache)
    (let* ((contributed (list (cons (car agent-river-map-contributors)
                                    (gethash "/repo/a.el"
                                             (agent-river--rows-vc
                                              "/repo" '((:path "/repo/a.el")))))))
           (shown (agent-river--map-shown-rows contributed t)))
      (should (agent-river--map-summary contributed t))
      (should-not shown)
      ;; With no column reserved anywhere in the buffer, the row is the
      ;; whole answer and goes back to being drawn.
      (should (agent-river--map-shown-rows contributed nil)))))

(ert-deftest agent-river-test-a-row-that-says-more-than-the-line-stays ()
  ;; The map cannot tell `+2 -1 vs HEAD' from `+2 -1 vs HEAD in 12 files' by
  ;; looking, and must not learn to: the contributor declares which of its
  ;; rows the column carries whole.
  (let ((agent-river--vc-cache (make-hash-table :test 'equal))
        (table (agent-river-test--numstat "2\t1\tsrc/a.el\0001\t0\tsrc/b.el\0")))
    (puthash "/repo" (list :at (current-time) :table table) agent-river--vc-cache)
    (let* ((contributed (list (cons (car agent-river-map-contributors)
                                    (gethash "/repo/src"
                                             (agent-river--rows-vc
                                              "/repo" '((:path "/repo/src" :dir t)))))))
           (shown (agent-river--map-shown-rows contributed t)))
      (should (= (length shown) 1))
      (should (string-match-p "in 2 files" (plist-get (car shown) :text))))))

(ert-deftest agent-river-test-rows-are-drawn-by-rank-not-by-registration ()
  ;; Between contributors as well as within one: which of them was
  ;; registered first is not a statement about which of their rows is worth
  ;; reading, and the cap has to cut the least of them rather than the last.
  (let* ((agent-river-map-detail-rows 2)
         (contributed
          (list (cons '(:name late) (list '(:key "a" :text "third" :rank 9)
                                          '(:key "b" :text "first" :rank 0)))
                (cons '(:name early) (list '(:key "c" :text "second" :rank 1)))))
         (shown (agent-river--map-shown-rows contributed t)))
    (should (equal (mapcar (lambda (row) (plist-get row :text)) shown)
                   '("first" "second" "third")))
    (with-temp-buffer
      (agent-river--map-rows-insert shown "/repo/a.el")
      (should (string-match-p "second" (buffer-string)))
      (should-not (string-match-p "third" (buffer-string))))))

(ert-deftest agent-river-test-a-refresh-is-offered-on-its-own-clock ()
  ;; The redraw fires every few seconds; a contributor that spawns work
  ;; must not be asked to spawn it again each time.
  (let* ((calls 0)
         (agent-river--map-refreshed (make-hash-table :test 'equal))
         (agent-river-map-contributors
          (list (agent-river-test--contributor
                 'slow nil
                 :ttl 60
                 :refresh (lambda (&rest _) (setq calls (1+ calls)))))))
    (agent-river--map-rows "/repo" '((:path "/repo/a.el")))
    (agent-river--map-rows "/repo" '((:path "/repo/a.el")))
    (should (= calls 1))
    ;; A different root is a different question, not the same one repeated.
    (agent-river--map-rows "/other" '((:path "/other/a.el")))
    (should (= calls 2))))

(ert-deftest agent-river-test-a-refresh-by-hand-asks-again ()
  ;; `g' drops the cached answer, so the column is empty until a new one
  ;; lands -- and the throttle used to survive it, declining to read for as
  ;; long as its TTL had left.  Nothing else asks in the meantime: the
  ;; redraw timer retires while no agent is working, so the numbers came
  ;; back seconds later or not at all.
  (let* ((calls 0)
         (agent-river--map-refreshed (make-hash-table :test 'equal))
         (agent-river-map-contributors
          (list (agent-river-test--contributor
                 'slow nil
                 :ttl 60
                 :refresh (lambda (&rest _) (setq calls (1+ calls)))))))
    (agent-river--map-rows "/repo" '((:path "/repo/a.el")))
    (should (= calls 1))
    ;; No map buffer, so the draw is a no-op and only the clearing is under
    ;; test -- which is the half that was missing.
    (agent-river-map-refresh)
    (agent-river--map-rows "/repo" '((:path "/repo/a.el")))
    (should (= calls 2))))

(ert-deftest agent-river-test-a-contributed-row-cannot-restructure-the-map ()
  ;; The map is Markdown only because every token in it is ours, and a
  ;; contributor's text is the first text here that is not.  A row
  ;; beginning with `#' or carrying an asterisk would restructure the view
  ;; showing it -- which is why the HUD is not Markdown at all.
  (let ((line (agent-river--map-row-line '(:text "# *boom* [x](y)"))))
    (should-not (string-match-p "^- #" line))
    (should (string-match-p "\\\\#" line))
    (should (string-match-p "\\\\\\*" line)))
  ;; And one row is one line: the buffer is line-based, so a newline would
  ;; not make two rows, it would make one broken one.
  (let ((line (agent-river--map-row-line '(:text "first\nsecond"))))
    (should-not (string-match-p "\n" line))
    (should (string-match-p "first second" line))))

(ert-deftest agent-river-test-rows-are-capped-visibly ()
  (let ((agent-river-map-detail-rows 2))
    (with-temp-buffer
      (agent-river--map-rows-insert
       (list '(:key "1" :text "one") '(:key "2" :text "two")
             '(:key "3" :text "three"))
       "/repo/a.el")
      (let ((text (buffer-string)))
        (should (string-match-p "one" text))
        (should-not (string-match-p "three" text))
        ;; A listing that can be arbitrarily long is not a listing, and a
        ;; wall nobody can see is worse than the length.
        (should (string-match-p "…" text))))))

(ert-deftest agent-river-test-a-row-carries-its-own-identity ()
  ;; The redraw finds a line again by what it names.  A row that named only
  ;; its node would share that name with every other row there, and point
  ;; would come back one or two lines off after every draw.
  (with-temp-buffer
    (agent-river--map-rows-insert
     (list '(:key "party/alpha" :text "alpha")) "/repo/a.el")
    (goto-char (point-min))
    (should (equal (get-text-property (point) 'agent-river-map-row) "party/alpha"))
    (should (equal (get-text-property (point) 'agent-river-map-path) "/repo/a.el"))
    ;; And it is not one of the listing's own entries, so the coarse motion
    ;; passes over it -- it inherits the path, which is what makes it
    ;; impossible to tell apart by the path alone.
    (should (agent-river--map-row-line-p))
    (should-not (agent-river--map-top-line-p))
    (should-not (agent-river--map-active-line-p))))

(ert-deftest agent-river-test-a-node-with-rows-opens-and-folds ()
  ;; Rows are enrichment and detail at once: drawn where there are any,
  ;; hidden by the same TAB that hides the files.
  (let ((agent-river--map-folds nil))
    (should (agent-river--map-open-p '(:name "a.el") "/repo" '((nil . (1)))))
    (should-not (agent-river--map-open-p '(:name "a.el") "/repo" nil))
    (let ((agent-river--map-folds '(("/repo/a.el" . nil))))
      (should-not (agent-river--map-open-p '(:name "a.el") "/repo" '((nil . (1))))))))

(ert-deftest agent-river-test-the-step-row-is-present-tense ()
  ;; The parties say where an agent has been; this says what is happening
  ;; in the file right now, which after a long task is a different file.
  (agent-river-test--with-session state
    (agent-river-fold state '(:kind "act" :tool "Edit" :file "a.el" :cwd "/repo"))
    (let ((rows (gethash "/repo/a.el"
                         (agent-river--rows-step "/repo" '((:path "/repo/a.el"))))))
      (should (string-match-p "Edit" (plist-get (car rows) :text))))
    ;; The turn ends and the row goes: a call that has come back is not in
    ;; flight, and nothing should read as though it were.
    (agent-river-fold state '(:kind "idle"))
    (should-not (gethash "/repo/a.el"
                         (agent-river--rows-step "/repo" '((:path "/repo/a.el")))))))

(ert-deftest agent-river-test-turning-the-diffstat-off-asks-git-nothing ()
  (let ((agent-river--vc-cache (make-hash-table :test 'equal))
        (agent-river-map-vc nil))
    (should-not (agent-river--vc-stats "/repo"))
    ;; Not merely undrawn: a view switched off must not be spending
    ;; subprocesses on a column nobody is going to see.
    (should (zerop (hash-table-count agent-river--vc-cache)))))

(ert-deftest agent-river-test-a-failed-read-is-an-answer-like-any-other ()
  (let ((agent-river--vc-cache (make-hash-table :test 'equal)))
    ;; A directory that is not a repository is an ordinary thing for the map
    ;; to be pointed at.  Stored, so the failure is throttled by the TTL
    ;; rather than retried on every redraw for as long as Emacs runs.
    (agent-river--vc-store "/tmp" nil)
    (should-not (agent-river--vc-stats "/tmp"))
    (should (gethash "/tmp" agent-river--vc-cache))
    (should-not (plist-get (gethash "/tmp" agent-river--vc-cache) :proc))))

(defun agent-river-test--changed (root output)
  "Record OUTPUT as the diffstat git last reported for ROOT."
  (puthash root (list :at (current-time)
                      :table (agent-river--vc-parse
                              output root (make-hash-table :test 'equal))
                      :proc nil)
           agent-river--vc-cache))

(ert-deftest agent-river-test-a-changed-file-is-listed-with-nobody-on-it ()
  ;; The class of change the fold cannot see at all: `sed -i', a formatter, a
  ;; codemod, a `git checkout' -- every one of them a tool call whose only
  ;; argument is a string of shell, so no file is ever named and no touch is
  ;; ever recorded.  A map showing only what the hooks named would be quietly
  ;; wrong about all of it.
  (let ((agent-river-heat-half-life nil)
        (agent-river-map-untouched nil)
        (agent-river--vc-cache (make-hash-table :test 'equal)))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root
                                      :file "dialog/src/main/foo.el"))
        (agent-river-test--changed root "3\t1\tcommon/c.el\0")
        (let ((entries (agent-river--map-entries root)))
          (should (equal (mapcar (lambda (e) (plist-get e :name)) entries)
                         '("common" "dialog")))
          (let ((common (car entries)))
            ;; No parties, and that is the whole truth of it rather than a
            ;; gap: git cannot say who changed a file, so the brackets stay
            ;; empty and the column beside them says what is different.
            (should-not (plist-get common :parties))
            (should (plist-get common :changed))
            (should (equal (mapcar (lambda (f) (plist-get f :rel))
                                   (plist-get common :files))
                           '("c.el")))))))))

(ert-deftest agent-river-test-a-reached-file-is-not-listed-twice ()
  ;; Both readings name the same path, and the reached one is the one with
  ;; anything to say.  Listed again from the working tree it would appear a
  ;; second time with no parties on it, which reads as two files.
  (let ((agent-river-heat-half-life nil)
        (agent-river-map-untouched nil)
        (agent-river--vc-cache (make-hash-table :test 'equal)))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-test--changed
         root (concat "3\t1\tcommon/c.el\0" "2\t0\tcommon/o.el\0"))
        (let* ((common (car (agent-river--map-entries root)))
               (files (plist-get common :files)))
          (should (equal (mapcar (lambda (f) (plist-get f :rel)) files)
                         ;; And the work comes first: `agent-river-map-detail-files'
                         ;; cuts from the tail, so what was reached must not be
                         ;; the half that falls off it.
                         '("c.el" "o.el")))
          (should (plist-get (car files) :parties))
          (should-not (plist-get (cadr files) :parties)))))))

(ert-deftest agent-river-test-the-listing-s-ignore-patterns-hold-git-back ()
  ;; The patterns do not apply to a reached path, because activity the map
  ;; does not show is the one thing it exists not to do.  A name only git has
  ;; an opinion about is not activity, and without the filter every editor
  ;; backup a repository happens not to ignore would earn a line.
  (let ((agent-river-heat-half-life nil)
        (agent-river-map-untouched nil)
        (agent-river--vc-cache (make-hash-table :test 'equal)))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-test--changed
         root (concat "1\t0\t.DS_Store\0" "1\t0\tnotes.org~\0"))
        (should (equal (mapcar (lambda (e) (plist-get e :name))
                               (agent-river--map-entries root))
                       '("common")))))))

(ert-deftest agent-river-test-the-second-source-can-be-turned-off ()
  (let ((agent-river-heat-half-life nil)
        (agent-river-map-untouched nil)
        (agent-river-map-dirty nil)
        (agent-river--vc-cache (make-hash-table :test 'equal)))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-test--changed root "9\t9\tdocs/d.md\0")
        ;; A tree with a large amount of uncommitted work in it is most of
        ;; the listing otherwise, and only the reader knows whether that is
        ;; the view they wanted.
        (should (equal (mapcar (lambda (e) (plist-get e :name))
                               (agent-river--map-entries root))
                       '("common")))))))

(ert-deftest agent-river-test-the-listing-starts-no-read-of-its-own ()
  ;; The read is the contributor's to schedule, on its own TTL.  A listing
  ;; that started one as well would be a second caller racing it for the
  ;; same tree -- and would put a subprocess behind every derivation of the
  ;; entries, including the ones no buffer is waiting on.
  (let ((agent-river-heat-half-life nil)
        (agent-river--vc-cache (make-hash-table :test 'equal)))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river--map-entries root)
        (should (zerop (hash-table-count agent-river--vc-cache)))))))

(ert-deftest agent-river-test-a-changed-file-that-is-gone-still-has-a-line ()
  ;; A deletion is a change like any other to git, which is how the listing
  ;; reaches one at all now.  Drawn as missing rather than dropped: the
  ;; deletion is the news, and a line that quietly vanished would be the map
  ;; hiding exactly the thing it was opened to find.
  (let ((agent-river-heat-half-life nil)
        (agent-river-map-untouched nil)
        (agent-river--vc-cache (make-hash-table :test 'equal)))
    (agent-river-test--with-tree root
      (agent-river-test--with-session state
        (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"))
        (agent-river-test--changed root "0\t7\tgone/g.el\0")
        (let ((entry (seq-find (lambda (e) (equal (plist-get e :name) "gone"))
                               (agent-river--map-entries root))))
          (should entry)
          (should (plist-get entry :missing))
          (should (plist-get entry :changed)))))))

(ert-deftest agent-river-test-the-map-header-is-a-name-and-a-count ()
  ;; It used to caption the view as well -- which frame the numbers came
  ;; from, and that the diffstat came from HEAD rather than a frame.  Both
  ;; are still true and are documented where they are decided; a legend
  ;; redrawn every few seconds on a line that is read once is not where a
  ;; reader looks them up.
  (let ((header (agent-river--map-header "/repo" nil)))
    (should (string-match-p "/repo" header))
    (should-not (string-match-p "frame" header))
    (should-not (string-match-p "HEAD" header))))

(ert-deftest agent-river-test-the-map-header-counts-the-agents-that-are-left ()
  ;; A name outlives its session on purpose: it fades through the floor
  ;; rather than vanishing, because the file was still touched.  Counting
  ;; names would then report an audience that has left as though it were
  ;; still there, which is the one thing this number is for.
  (agent-river-test--with-shell '(("Claude Agent @ repo" "s1"))
    (agent-river-test--with-session state
      (agent-river--ensure-shell-teardown "s1")
      (let ((entries (list (list :parties
                                 (list (list :party (agent-river--party-label state)
                                             :weight 4))))))
        (should (string-match-p "1 agent\\'" (agent-river--map-header "/repo" entries)))
        (kill-buffer (agent-river--shell-buffer "s1"))
        (cancel-function-timers #'agent-river--redraw-block)
        (should (string-match-p "quiet\\'" (agent-river--map-header "/repo" entries)))))))

;;; Moving about the map
;;
;; The text here is ours rather than a host package's, so the motion over it
;; is ours to get right and ours to test.  What matters is which lines a
;; motion is allowed to stop on and what it does when there is no such line;
;; where those lines happen to be drawn is not asserted anywhere.

(defmacro agent-river-test--with-map (root &rest body)
  "Draw a map of a throwaway tree into a buffer, bind ROOT, and run BODY.
The plain mode rather than the Markdown one: the grammars are not part of
the suite's world, and the text -- which is all the motion reads -- is the
same either way."
  (declare (indent 1))
  `(let ((agent-river-heat-half-life nil))
     (agent-river-test--with-tree ,root
       (agent-river-test--with-session state
         (dotimes (_ 7)
           (agent-river-fold state (list :kind "act" :cwd ,root :file "common/c.el")))
         (dotimes (_ 2)
           (agent-river-fold state (list :kind "act" :cwd ,root
                                         :file "dialog/src/main/foo.el")))
         (with-temp-buffer
           (rename-buffer agent-river-map-buffer-name)
           (agent-river-map-plain-mode)
           (setq agent-river--map-root ,root)
           (agent-river--map-draw)
           ,@body)))))

(ert-deftest agent-river-test-map-motion-stops-only-on-a-name ()
  (agent-river-test--with-map root
    ;; A fresh map has point on the header, which names nothing -- RET and
    ;; TAB there would both complain, and pressing one of them is the first
    ;; thing anyone does with a new buffer.
    (should (agent-river--map-entry-line-p))
    (should (equal (get-text-property (line-beginning-position)
                                      'agent-river-map-name)
                   "common"))
    ;; And point is on the name, not in column zero: column zero is the
    ;; Markdown marker, and a cursor on `#' reads as though the markup were
    ;; the content.
    (should (eq (char-before) ?`))
    (should (looking-at-p "common/"))))

(ert-deftest agent-river-test-map-motion-walks-files-and-directories ()
  (agent-river-test--with-map root
    (let (seen)
      (while (agent-river--map-scan 1 #'agent-river--map-entry-line-p)
        (push (get-text-property (line-beginning-position) 'agent-river-map-path)
              seen))
      ;; Every entry, files included.  Outline's own n/p stop at headings
      ;; only, which in this view means skipping exactly the lines that say
      ;; which file the work is in.
      (should (member (expand-file-name "common/c.el" root) seen))
      (should (member (expand-file-name "dialog" root) seen)))))

(ert-deftest agent-river-test-map-entry-motion-skips-the-files ()
  (agent-river-test--with-map root
    (should (agent-river--map-scan 1 #'agent-river--map-top-line-p))
    ;; From `common', whose file is unfolded beneath it, the next entry of
    ;; the listing is `dialog' rather than `common/c.el'.
    (should (equal (get-text-property (line-beginning-position)
                                      'agent-river-map-name)
                   "dialog"))))

(ert-deftest agent-river-test-map-active-motion-skips-the-quiet ()
  (agent-river-test--with-map root
    (let (seen)
      (while (agent-river--map-scan 1 #'agent-river--map-active-line-p)
        (push (get-text-property (line-beginning-position)
                                 'agent-river-map-name)
              seen))
      ;; In a thirty-module repository this is the difference between
      ;; reading the view and searching it.
      (should (member "dialog" seen))
      (should-not (member "docs" seen))
      (should-not (member "build.gradle.kts" seen)))))

(ert-deftest agent-river-test-map-motion-refuses-rather-than-drifts ()
  (agent-river-test--with-map root
    (goto-char (point-max))
    (forward-line -1)
    (let ((before (point)))
      ;; A motion that quietly lands somewhere else means the next RET
      ;; visits something the eye never chose.
      (should-not (agent-river--map-scan 1 #'agent-river--map-entry-line-p))
      (should (= (point) before)))))

(ert-deftest agent-river-test-the-map-is-not-on-the-stream-until-opened ()
  ;; No mode to switch on, because the map draws only into its own buffer:
  ;; opening it is the consent, and killing it is the retirement.
  (should-not (memq #'agent-river--map-observe agent-river-observers))
  (should-not (get-buffer agent-river-map-buffer-name)))

(ert-deftest agent-river-test-map-multi-root-collects-all-roots ()
  "The multi-root mode collects all unique roots from touched files."
  (agent-river-test--with-tree root1
    (let* ((root2 (make-temp-file "agent-river-root2" t)))
      (unwind-protect
          (progn
            ;; Create two separate states, one for each root
            (let ((state1 (agent-river-state "s1" "alpha"))
                  (state2 (agent-river-state "s2" "beta")))
              ;; Register both states
              (puthash "s1" state1 agent-river-registry)
              (puthash "s2" state2 agent-river-registry)
              ;; Touch a file in root1
              (agent-river-fold state1 (list :kind "act" :cwd root1 :file "common/c.el"))
              ;; Touch a file in root2
              (agent-river-fold state2 (list :kind "act" :cwd root2 :file "other.el"))
              ;; Get all roots
              (let* ((all-roots (agent-river--map-all-roots 'session))
                     (root-dirs (mapcar #'car all-roots)))
                ;; Should have found both roots
                (should (>= (length all-roots) 2))
                ;; Both roots should be present in the list
                (should (member root1 root-dirs))
                (should (member root2 root-dirs)))))
        (delete-directory root2 t)))))

(defmacro agent-river-test--with-overview (var &rest body)
  "Fold one session across two trees, draw the overview, run BODY.
VAR is bound to the second tree; `agent-river-test--with-tree' names the
first."
  (declare (indent 1))
  `(agent-river-test--with-tree root1
     (agent-river-test--with-session state
       (let ((,var (make-temp-file "agent-river-root2" t)))
         (unwind-protect
             (progn
               ;; Two sessions, because that is what two roots are in
               ;; practice.  One session folding both would only prove that
               ;; its cwd slot holds whichever it saw last.
               (agent-river-fold state (list :kind "act" :cwd root1
                                             :file "common/c.el"
                                             :path (expand-file-name "common/c.el" root1)))
               (let ((other (agent-river-state "s2" "beta")))
                 (agent-river-fold other (list :kind "act" :cwd ,var
                                               :file "other.el"
                                               :path (expand-file-name "other.el" ,var))))
               (with-temp-buffer
                 (rename-buffer agent-river-map-buffer-name)
                 (agent-river-map-plain-mode)
                 (setq agent-river--map-root nil
                       agent-river--map-folds nil)
                 (agent-river--map-draw)
                 ,@body))
           (delete-directory ,var t))))))

(ert-deftest agent-river-test-the-overview-heads-every-tree-and-favours-none ()
  (agent-river-test--with-overview root2
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      ;; Naming the heading after one of the trees -- the most recent, as it
      ;; used to be -- read as though that one were the project and the rest
      ;; were somewhere inside it.  There is no reference project: the state
      ;; spans whatever directories the sessions were started in.
      (should (string-match-p "\\`# 2 roots  ·  " text))
      ;; Each tree heads its own section, one level under the header.
      (dolist (root (list root1 root2))
        (should (string-match-p (concat "^## [^`]*`" (regexp-quote (abbreviate-file-name root)))
                                text)))
      ;; And the entries sit under the tree they belong to, not under the
      ;; first one drawn.
      (should (string-match-p "^### [^`]*`common/`" text))
      (should (string-match-p "^### [^`]*`other.el`" text)))))

(ert-deftest agent-river-test-one-tree-needs-no-heading-of-its-own ()
  (agent-river-test--with-tree root
    (agent-river-test--with-session state
      (agent-river-fold state (list :kind "act" :cwd root :file "common/c.el"
                                    :path (expand-file-name "common/c.el" root)))
      (with-temp-buffer
        (rename-buffer agent-river-map-buffer-name)
        (agent-river-map-plain-mode)
        (setq agent-river--map-root nil agent-river--map-folds nil)
        (agent-river--map-draw)
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          ;; The header already names it; repeating it as a section heading
          ;; would indent the whole listing to say nothing.
          (should (string-match-p (concat "\\`# `" (regexp-quote (abbreviate-file-name root)))
                                  text))
          (should (string-match-p "^## [^`]*`common/`" text))
          (should-not (string-match-p "^### " text)))))))

(ert-deftest agent-river-test-climbing-out-of-a-tree-reaches-the-overview ()
  (agent-river-test--with-overview root2
    ;; A touched root is the top of a tree the state knows about.  Climbing
    ;; past it walked into directories no agent had been near, with the
    ;; other trees still out of view.
    (setq agent-river--map-root root2)
    (agent-river-map-up)
    (should-not agent-river--map-root)
    ;; And from the overview there is nowhere further out.
    (should-error (agent-river-map-up) :type 'user-error)))

(provide 'agent-river-tests)
;;; agent-river-tests.el ends here
