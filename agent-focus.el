;;; agent-focus.el --- Folded focus state for a coding-agent session -*- lexical-binding: t; -*-

;; Author: systemfreund <github@o9z.de>
;; URL: https://github.com/systemfreund/supersonic.el
;; Keywords: tools

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Claude Code hooks report events one at a time.  This file folds that
;; stream into a *state* -- what the agent is working on, which artifacts it
;; keeps returning to, how its tools are faring -- and renders one view of
;; that state into `*agent-focus*' for the stream audience.
;;
;; The state is the point; the buffer is a view.  A flat log answers "what
;; happened"; only a fold answers "where are we", because that question
;; quantifies over a set of events.
;;
;; Two consumers, and they want different things:
;;
;; - The stream audience gets the buffer: one line per event, tailing.
;; - The agent itself gets `agent-focus-observe's return value -- a short,
;;   factual observation when a signal fires, injected back into its context
;;   by the hook as `additionalContext'.
;;
;; That second channel is deliberately narrow.  Signals are heuristics and
;; will sometimes be wrong, so they state facts ("3 consecutive failures")
;; rather than give instructions ("change your approach").  A wrong fact
;; costs a few tokens; a wrong instruction derails a correct solution.
;;
;; State is keyed by session id in `agent-focus-registry', so several
;; sessions can fold side by side.  Nothing here reaches across sessions
;; yet, but the addressing is in place for it -- see `agent-focus-touching'.
;;
;; Load it in the live session:
;;
;;   (load "~/.emacs.d/agent-focus/agent-focus.el")

;;; Code:

(require 'cl-lib)
(require 'seq)

(defgroup agent-focus nil
  "Folded focus state for a coding-agent session."
  :group 'tools
  :prefix "agent-focus-")

(defcustom agent-focus-buffer-name "*agent-focus*"
  "Name of the buffer the agent's attention is logged to."
  :type 'string)

(defcustom agent-focus-max-entries 200
  "How many lines to keep.  Older lines are dropped from the top.
Zero or less keeps everything, which will grow without bound."
  :type 'integer)

(defcustom agent-focus-window-width 56
  "Width of the side window opened by `agent-focus-show'."
  :type 'integer)

(defcustom agent-focus-auto-display t
  "Whether logging pops the HUD open when no window shows it."
  :type 'boolean)

(defcustom agent-focus-fail-streak-threshold 3
  "Consecutive tool failures before the agent is told about it.
Low enough to catch a real loop early, high enough that ordinary
trial-and-error does not trip it."
  :type 'integer)

(defcustom agent-focus-fail-streak-repeat 3
  "Further failures between repeat observations once the streak is live.
Without this the agent would be told on every single failure, and a
signal that arrives constantly stops being a signal."
  :type 'integer)

(defcustom agent-focus-label-width 8
  "Width of the session column shown when several sessions are active."
  :type 'integer)

(defcustom agent-focus-refresh-interval 1
  "Seconds between redraws of the state block while work is in progress.
Elapsed times are only recomputed when the block is drawn, so without a
tick they jump by however long the gap between two events was."
  :type 'number)

(defcustom agent-focus-phase-window 8
  "How many recent steps the phase is read from.
Short enough to turn when the work turns, long enough that one stray
tool call does not repaint the panel."
  :type 'integer)

(defcustom agent-focus-panel-task-width 34
  "How much of the current task or intent the session line shows."
  :type 'integer)

(defcustom agent-focus-phase-blocked-threshold 2
  "Consecutive failures that make the phase read as blocked.
Lower than the threshold for telling the agent: an onlooker may see a
rough patch early, the agent should only be interrupted once it looks
like more than bad luck."
  :type 'integer)

(defcustom agent-focus-phase-buckets
  '(("exploring" . ("Read" "Grep" "Glob" "WebFetch" "WebSearch" "Agent" "LSP"))
    ("editing"   . ("Edit" "Write" "NotebookEdit")))
  "Tools that place a step in a phase, keyed by phase name."
  :type '(alist :key-type string :value-type (repeat string)))

(defcustom agent-focus-shell-tools '("Bash" "BashOutput")
  "Tools whose step text is searched for `agent-focus-verify-regexp'."
  :type '(repeat string))

(defcustom agent-focus-verify-regexp
  (rx (or "make test" "make compile" "ert" "cask" "pytest" "npm test"
          "npm run test" "cargo test" "go test" "flycheck" "flymake"
          "diagnostics"))
  "Matched against a shell step to recognise it as verification.

Shell calls resist classification: the same tool runs the test suite, a
git query and a directory listing.  Rather than guess, only a match here
counts as verifying and everything else stays unclassified, so the phase
abstains instead of inventing one.  Tune it for the project."
  :type 'regexp)

(defcustom agent-focus-intent-stale-steps 10
  "Steps after which a stated intent is treated as possibly out of date."
  :type 'integer)

(defcustom agent-focus-session-ttl 300
  "Seconds without an event after which a session stops counting as active.
Sessions crash and leave state behind.  Stale state that still looks
current is worse than no state, because it is trusted -- so liveness is
a clock, not a flag, and a session that has gone quiet simply drops out."
  :type 'number)


;;; Faces and event kinds

(defface agent-focus-time '((t :inherit shadow))
  "Face for the timestamp column.")

(defface agent-focus-prompt '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a new task arriving from the user.")

(defface agent-focus-act '((t :inherit font-lock-function-name-face))
  "Face for the agent acting -- running a tool.")

(defface agent-focus-think '((t :inherit shadow :slant italic))
  "Face for a tool returning.")

(defface agent-focus-idle '((t :inherit font-lock-comment-face :slant italic))
  "Face for the agent being idle, waiting on the user.")

(defface agent-focus-fail '((t :inherit error))
  "Face for a tool call that errored.")

(defface agent-focus-reason '((t :inherit font-lock-doc-face :slant italic))
  "Face for the agent's own reasoning, lifted from the session transcript.")

(defface agent-focus-signal '((t :inherit warning :weight bold))
  "Face for an observation handed back to the agent.")

(defface agent-focus-session '((t :inherit font-lock-constant-face))
  "Face for the session column.")

(defface agent-focus-intent '((t :inherit font-lock-string-face))
  "Face for what the agent says it is doing -- a claim, not a measurement.")

(defface agent-focus-stale '((t :inherit shadow :slant italic))
  "Face for a claim the measured state has overtaken.")

(defconst agent-focus-kinds
  '(("prompt" "◆" agent-focus-prompt)
    ("act"    "▸" agent-focus-act)
    ("think"  "·" agent-focus-think)
    ("reason" "◇" agent-focus-reason)
    ("intent" "◈" agent-focus-intent)
    ("fail"   "✗" agent-focus-fail)
    ("signal" "!" agent-focus-signal)
    ("done"   "□" agent-focus-idle)
    ("idle"   "■" agent-focus-idle))
  "Alist of (KIND GLYPH FACE) describing how each event kind renders.")


;;; The state

(cl-defstruct (agent-focus-state (:constructor agent-focus--state-create))
  id                ; registry key: "SESSION" or "SESSION/AGENT"
  label             ; human-readable: working directory, or the agent type
  parent            ; key of the session that spawned this one, nil at a root
  agent-type        ; "Explore", "general-purpose", ... nil at a root
  started last-seen ; last-seen is the liveness clock a registry needs
  task task-started ; the current prompt, and when it arrived
  step steps        ; the in-flight step, and how many this turn
  artifacts         ; hash: path -> (:touches N :last TIME), whole session
  task-artifacts    ; the same, but cleared by each new prompt
  tools             ; hash: tool -> (:count N :ms TOTAL :failures N)
  fail-streak       ; consecutive failures, reset by any success
  fail-tools        ; alist tool -> count, for the current streak only
  task-failures     ; failures during this task, not just the current run
  recent            ; newest-first (TOOL . DETAIL), the window phase reads
  transcript-pos    ; bytes of the session transcript already read for ◇
  idle              ; the turn ended; nothing is in progress right now
  ;; Everything above is measured.  The four below are a *claim* the agent
  ;; made about itself, kept apart on purpose: this state is fed back to the
  ;; agent, and a claim read later as an observation closes the loop with no
  ;; ground truth left in it.  They never feed a signal.
  intent intent-at intent-step intent-hottest
  tasks             ; finished tasks, newest first
  done              ; set by SubagentStop: finished, as a fact not a guess
  signals)          ; observations handed back, newest first

(defun agent-focus-key (session &optional agent)
  "Return the registry key for SESSION, or for AGENT running under it.

A subagent's tool calls arrive with their parent's `session_id' and
`transcript_path', and are distinguished only by an extra `agent_id'.
Keying on the session alone would therefore fold a subagent's work into
its parent -- inflating the parent's step count and, worse, letting one
subagent's failures raise a streak reported against the parent."
  (if (and agent (not (string-empty-p agent)))
      (concat session "/" agent)
    session))

(defvar agent-focus--current nil
  "Key of the root session that most recently folded an event.
Lets `agent-focus-set-intent' be called without naming a session.")

(defvar agent-focus-registry (make-hash-table :test 'equal)
  "Map of session id to `agent-focus-state'.
Several sessions fold side by side; Emacs Lisp is single-threaded, so
concurrent emacsclient calls are atomic with respect to each other and
this needs no locking.")

;;; agent-shell, when it is hosting the sessions
;;
;; The sessions run as agent-shell buffers in this very Emacs, and
;; `agent-shell--state' carries the ACP session id -- which is verbatim the
;; `session_id' the hooks report.  That makes the link exact rather than
;; inferred, and lets three pieces of guesswork be deleted: liveness stops
;; being a TTL estimate, labels stop drifting with the working directory,
;; and uniquifying them stops being our job, since agent-shell already
;; numbers its buffers.
;;
;; All of it degrades to the old behaviour when agent-shell is absent.

(defun agent-focus--shell-buffer-p ()
  "Return non-nil when the current buffer hosts an agent-shell session."
  ;; The mode is the whole test: where agent-shell is not loaded there is no
  ;; such buffer, so no separate check for the package is needed -- and one
  ;; on `featurep' would only be a shortcut that is awkward to fake in tests.
  (derived-mode-p 'agent-shell-mode))

(defun agent-focus--shell-buffer (id)
  "Return the agent-shell buffer hosting session ID, or nil."
  (seq-find
   (lambda (buffer)
     (with-current-buffer buffer
       (and (agent-focus--shell-buffer-p)
            (equal id (alist-get :id (alist-get :session
                                                (bound-and-true-p
                                                 agent-shell--state)))))))
   (buffer-list)))

(defun agent-focus--shell-hosted-p ()
  "Return non-nil when agent-shell is hosting sessions in this Emacs."
  (seq-some (lambda (buffer)
              (with-current-buffer buffer (agent-focus--shell-buffer-p)))
            (buffer-list)))

(defun agent-focus--shell-label (id)
  "Return the name agent-shell gives session ID, or nil.
Taken from the buffer name, so the numbering that distinguishes two
sessions in one directory is agent-shell's rather than a second,
parallel scheme of ours."
  (let ((buffer (agent-focus--shell-buffer id)))
    (when buffer
      (let* ((name (buffer-name buffer))
             (at (string-match " @ " name)))
        (if at (substring name (+ at 3)) name)))))

(defun agent-focus--label-base (label)
  "Strip any uniquifying suffix from LABEL."
  (replace-regexp-in-string "<[0-9]+>\\'" "" (or label "")))

(defun agent-focus--unique-label (label id)
  "Return LABEL, made distinct from the labels of states other than ID.

Two sessions in one checkout derive the same name from their directory,
which renders them identically in the session column and in the state
block -- two different agents, indistinguishable.  Suffixed the way Emacs
uniquifies buffers, and the way the session list already displays them."
  (let (taken)
    (maphash (lambda (key state)
               (unless (equal key id)
                 (push (agent-focus-state-label state) taken)))
             agent-focus-registry)
    (if (not (member label taken))
        label
      (let ((n 2))
        (while (member (format "%s<%d>" label n) taken)
          (setq n (1+ n)))
        (format "%s<%d>" label n)))))

(defun agent-focus-state (id &optional label parent agent-type)
  "Return the state keyed by ID, creating it if needed.
LABEL names it for a human and is refreshed on every call, so a session
that changes directory does not keep a stale name.  PARENT and
AGENT-TYPE are set once, when the state is created."
  (let ((state (or (gethash id agent-focus-registry)
                   (puthash id
                            (agent-focus--state-create
                             :id id
                             :parent parent
                             :agent-type agent-type
                             :started (current-time)
                             :artifacts (make-hash-table :test 'equal)
                             :task-artifacts (make-hash-table :test 'equal)
                             :tools (make-hash-table :test 'equal)
                             :fail-streak 0
                             :steps 0)
                            agent-focus-registry))))
    ;; agent-shell's own name wins where it exists: it is stable across a
    ;; change of working directory, and already numbered.
    (let ((hosted (and (null parent) (agent-focus--shell-label id))))
      (cond
       (hosted (setf (agent-focus-state-label state) hosted))
       ;; Refresh so a session that moves does not keep a stale name, but
       ;; leave an assigned suffix alone while the base name still matches.
       ((and label
             (not (equal (agent-focus--label-base
                          (agent-focus-state-label state))
                         label)))
        (setf (agent-focus-state-label state)
              (agent-focus--unique-label label id)))))
    (setf (agent-focus-state-last-seen state) (current-time))
    state))

(defun agent-focus--active-p (state)
  "Return non-nil when STATE is still running.

A finished subagent says so via SubagentStop, which is authoritative.

For a root session hosted by agent-shell the buffer settles it: the
process runs in this Emacs, so whether it is alive is a fact and not an
estimate.  The TTL is what is left for everything else -- subagents, and
sessions nobody here owns -- and it was only ever a way of guessing at
something we could not see."
  (cond
   ((agent-focus-state-done state) nil)
   ((and (null (agent-focus-state-parent state))
         (agent-focus--shell-hosted-p))
    (and (agent-focus--shell-buffer (agent-focus-state-id state)) t))
   (t (let ((seen (agent-focus-state-last-seen state)))
        (and seen (< (float-time (time-subtract (current-time) seen))
                     agent-focus-session-ttl))))))

(defun agent-focus--active-count ()
  "Return how many states are currently running.
Subagents count: while one is running, the view has to say who acted."
  (let ((n 0))
    (maphash (lambda (_id state)
               (when (agent-focus--active-p state) (setq n (1+ n))))
             agent-focus-registry)
    n))

(defun agent-focus-children (key)
  "Return the states spawned by the session registered under KEY.
Derived by walking the registry rather than maintained as a list on the
parent: a subagent's activity then has exactly one home, and a parent's
view of it cannot drift out of step with the child's own state."
  (let (kids)
    (maphash (lambda (_k state)
               (when (equal (agent-focus-state-parent state) key)
                 (push state kids)))
             agent-focus-registry)
    kids))


;;; The fold

(defun agent-focus--touch-1 (table path)
  "Record one touch of PATH in TABLE."
  (let ((entry (gethash path table)))
    (puthash path
             (list :touches (1+ (or (plist-get entry :touches) 0))
                   :last (current-time))
             table)))

(defun agent-focus--touch (state path)
  "Record that the session behind STATE touched PATH.

Kept in two frames on purpose.  The session-wide tally is what
`agent-focus-touching' needs to spot two agents on one file, and it must
survive a change of task.  The per-task tally is what an observer wants:
\"what is being worked on now\", not \"what has been opened all
afternoon\".  Reporting one while labelling it the other is how a panel
starts misleading people."
  (when (and path (not (string-empty-p path)))
    (agent-focus--touch-1 (agent-focus-state-artifacts state) path)
    (agent-focus--touch-1 (agent-focus-state-task-artifacts state) path)))

(defun agent-focus--record-tool (state tool ms failed)
  "Fold one completed call of TOOL taking MS into STATE.
FAILED marks it as an error rather than a success."
  (when (and tool (not (string-empty-p tool)))
    (let* ((table (agent-focus-state-tools state))
           (entry (gethash tool table)))
      (puthash tool
               (list :count (1+ (or (plist-get entry :count) 0))
                     :ms (+ (or (plist-get entry :ms) 0) (or ms 0))
                     :failures (+ (or (plist-get entry :failures) 0)
                                  (if failed 1 0)))
               table))))

(defun agent-focus-fold (state event)
  "Fold EVENT into STATE and return STATE.
EVENT is a plist with :kind, and optionally :tool, :file, :text and :ms.
Deterministic given the event order, so a state can be rebuilt by
replaying a session's events from the start."
  (let ((kind (plist-get event :kind))
        (tool (plist-get event :tool))
        (file (plist-get event :file))
        (ms   (plist-get event :ms)))
    (cond
     ((equal kind "prompt")
      ;; Archive before resetting: without this the tally of every finished
      ;; task is thrown away, and nothing can say whether this one is going
      ;; worse than the last.
      (when (agent-focus-state-task state)
        (push (list :task (agent-focus-state-task state)
                    :steps (agent-focus-state-steps state)
                    :failures (or (agent-focus-state-task-failures state) 0)
                    :elapsed (and (agent-focus-state-task-started state)
                                  (agent-focus--ago
                                   (agent-focus-state-task-started state))))
              (agent-focus-state-tasks state)))
      (setf (agent-focus-state-task-failures state) 0)
      (setf (agent-focus-state-idle state) nil)
      ;; A new task makes any previous claim about the work meaningless.
      (setf (agent-focus-state-intent state) nil
            (agent-focus-state-intent-at state) nil
            (agent-focus-state-intent-step state) nil
            (agent-focus-state-intent-hottest state) nil)
      (setf (agent-focus-state-task state) (plist-get event :text)
            (agent-focus-state-task-started state) (current-time)
            (agent-focus-state-steps state) 0
            (agent-focus-state-step state) nil
            (agent-focus-state-fail-streak state) 0
            (agent-focus-state-fail-tools state) nil)
      (clrhash (agent-focus-state-task-artifacts state)))

     ((equal kind "act")
      (setf (agent-focus-state-idle state) nil
            (agent-focus-state-step state) (list :tool tool :file file
                                                 :at (current-time))
            (agent-focus-state-steps state) (1+ (agent-focus-state-steps state)))
      (push (cons tool (plist-get event :detail))
            (agent-focus-state-recent state))
      (let ((window (nthcdr (1- agent-focus-phase-window)
                            (agent-focus-state-recent state))))
        (when window (setcdr window nil)))
      (agent-focus--touch state file))

     ((equal kind "think")
      (agent-focus--record-tool state tool ms nil)
      ;; Any success ends the streak: the agent is getting somewhere again.
      (setf (agent-focus-state-step state) nil
            (agent-focus-state-fail-streak state) 0
            (agent-focus-state-fail-tools state) nil))

     ((equal kind "fail")
      (agent-focus--record-tool state tool ms t)
      (setf (agent-focus-state-step state) nil
            (agent-focus-state-task-failures state)
            (1+ (or (agent-focus-state-task-failures state) 0))
            (agent-focus-state-fail-streak state)
            (1+ (agent-focus-state-fail-streak state)))
      (let ((cell (assoc tool (agent-focus-state-fail-tools state))))
        (if cell
            (setcdr cell (1+ (cdr cell)))
          (push (cons tool 1) (agent-focus-state-fail-tools state)))))

     ((equal kind "intent")
      (setf (agent-focus-state-intent state) (plist-get event :text)
            (agent-focus-state-intent-at state) (current-time)
            (agent-focus-state-intent-step state) (agent-focus-state-steps state)
            (agent-focus-state-intent-hottest state) (agent-focus--hottest state)))

     ((equal kind "idle")
      (setf (agent-focus-state-step state) nil
            (agent-focus-state-idle state) t))

     ((equal kind "done")
      (setf (agent-focus-state-step state) nil)
      ;; Only ever retires a subagent.  Whether SubagentStop carries an
      ;; agent_id is unverified; if it does not, the event addresses the
      ;; parent key, and marking a live session finished would poison every
      ;; reading taken from it.  Ignoring a stray event is the cheap side of
      ;; that trade.
      (when (agent-focus-state-parent state)
        (setf (agent-focus-state-done state) t))))
    state))


;;; Derived signals

(defun agent-focus--bucket (tool detail)
  "Return the phase bucket for a step running TOOL with DETAIL, or nil.

The verify pattern is only applied to shell tools.  Matching it against
every step misreads a file whose *name* happens to look like a build --
reading `Cask' is exploring, not verifying."
  (cond
   ((null tool) nil)
   ((and (member tool agent-focus-shell-tools)
         detail
         (string-match-p agent-focus-verify-regexp detail))
    "verifying")
   (t (car (seq-find (lambda (cell) (member tool (cdr cell)))
                     agent-focus-phase-buckets)))))

(defun agent-focus--phase (state)
  "Return what STATE looks like it is doing, or nil when unclear.

Blocked is decided by failures rather than by tool mix: a run of errors
says more about where the work stands than which tools produced them.

Waiting outranks both.  The tool window still holds the steps of the
finished turn, so without this the panel keeps announcing \"exploring\"
above a log line that says the turn is over -- describing what the work
*was* while presenting it as what the work *is*."
  (cond
   ((agent-focus-state-idle state) "waiting")
   ((>= (agent-focus-state-fail-streak state)
        agent-focus-phase-blocked-threshold)
    "blocked")
   (t
    (let ((counts nil))
      (dolist (step (agent-focus-state-recent state))
        (let ((bucket (agent-focus--bucket (car step) (cdr step))))
          (when bucket
            (setf (alist-get bucket counts 0 nil #'equal)
                  (1+ (alist-get bucket counts 0 nil #'equal))))))
      (let ((best (car (seq-sort-by #'cdr #'> counts))))
        ;; One classified step is noise; two is a tendency.
        (when (and best (> (cdr best) 1)) (car best)))))))

(defun agent-focus--intent-stale-p (state)
  "Return non-nil when STATE's stated intent has been overtaken by events.

An agent remembers to say what it is doing while things go well, and
forgets precisely when it has lost the thread -- which is when an
onlooker most needs to know.  The measured state is allowed to contradict
the claim, so a forgotten update shows up as stale rather than passing
itself off as current."
  (and (agent-focus-state-intent state)
       (let ((set-at (or (agent-focus-state-intent-step state) 0))
             (was (agent-focus-state-intent-hottest state)))
         (or (> (- (agent-focus-state-steps state) set-at)
                agent-focus-intent-stale-steps)
             ;; Only once there was something to move away from: gaining a
             ;; hottest file where there was none is ordinary progress.
             (and was (not (equal was (agent-focus--hottest state))))))))

(defun agent-focus--ago (time)
  "Format the interval since TIME compactly."
  (let ((s (floor (float-time (time-subtract (current-time) time)))))
    (cond ((< s 60) (format "%ds" s))
          ((< s 3600) (format "%dm%02ds" (/ s 60) (mod s 60)))
          (t (format "%dh%02dm" (/ s 3600) (mod (/ s 60) 60))))))

(defun agent-focus--hottest (state &optional scope)
  "Return the most-touched artifact of STATE as a string, or nil.
SCOPE is `session' for the whole session, or nil for the current task."
  (let (best best-n)
    (maphash (lambda (path entry)
               (let ((n (plist-get entry :touches)))
                 (when (or (null best-n) (> n best-n))
                   (setq best path best-n n))))
             (if (eq scope 'session)
                 (agent-focus-state-artifacts state)
               (agent-focus-state-task-artifacts state)))
    (when (and best (> best-n 1))
      (format "%s (%d touches)" (file-name-nondirectory best) best-n))))

(defun agent-focus--signal (state)
  "Return an observation about STATE for the agent, or nil.

Kept to a single line with no control characters: the hook reads this
back through `emacsclient', whose printed representation of a plain
string is then parsed as JSON, and an embedded newline would break that."
  (let ((streak (agent-focus-state-fail-streak state)))
    (when (and (>= streak agent-focus-fail-streak-threshold)
               (zerop (mod (- streak agent-focus-fail-streak-threshold)
                           agent-focus-fail-streak-repeat)))
      (let ((tools (mapconcat (lambda (cell) (format "%s x%d" (car cell) (cdr cell)))
                              (reverse (agent-focus-state-fail-tools state))
                              ", "))
            (since (and (agent-focus-state-task-started state)
                        (agent-focus--ago (agent-focus-state-task-started state))))
            (hot (agent-focus--hottest state)))
        (concat
         (format "agent-focus: %d consecutive tool failures (%s)" streak tools)
         (if since (format ", %s into the current task" since) "")
         (if hot (format ". Most-revisited file: %s" hot) "")
         ". This is an observation, not an instruction -- weigh it against"
         " what you know; repeated failure is sometimes the right path.")))))


;;; Reading the hook payload
;;
;; This used to be 200 lines of shell and jq that parsed the payload and
;; assembled Elisp *as text*, which meant tool arguments were interpolated
;; into a form this Emacs then evaluated -- safe only for as long as the
;; escaping held.  The payload now arrives as a file and is parsed here, so
;; nothing from a tool call is ever read as code, and the derivation is
;; under test instead of in a shell script nobody exercises.

(defconst agent-focus-detail-width 72
  "How much of a tool argument a log line shows.")

(defun agent-focus--squish (text)
  "Collapse whitespace in TEXT onto one line."
  (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text)))

(defun agent-focus--clip (text width)
  "Shorten TEXT to WIDTH, marking that something was cut."
  (if (> (length text) width)
      (concat (substring text 0 width) "…")
    text))

(defun agent-focus--rel (path cwd)
  "Show PATH relative to CWD when under it, else as a bare name.
Never as a long absolute path: two agents touching one file from a
worktree and from the main checkout have to produce the same string, or
the view renders a collision as two unrelated files."
  (if (and cwd (not (string-empty-p cwd))
           (string-prefix-p (file-name-as-directory cwd) path))
      (substring path (1+ (length cwd)))
    (file-name-nondirectory path)))

(defun agent-focus--dur (ms)
  "Format MS compactly."
  (if (>= ms 1000)
      (concat (replace-regexp-in-string
               "\\.0\\'" "" (format "%.1f" (/ (float ms) 1000)))
              "s")
    (format "%dms" ms)))

(defun agent-focus--salient (input cwd)
  "Return the argument of tool INPUT worth showing, given CWD.
Ordered most- to least-specific.  A description comes before a command
deliberately: Bash and Task carry a human-written line saying what the
call is for, which reads better than the shell it expands to."
  (let ((width agent-focus-detail-width))
    (cond
     ((not (consp input)) "")
     ((alist-get 'file_path input) (agent-focus--rel (alist-get 'file_path input) cwd))
     ((alist-get 'description input)
      (agent-focus--clip (agent-focus--squish (alist-get 'description input)) width))
     ((alist-get 'command input)
      (agent-focus--clip (agent-focus--squish (alist-get 'command input)) width))
     ((alist-get 'pattern input)
      (agent-focus--clip (agent-focus--squish (alist-get 'pattern input)) width))
     ((alist-get 'code input)
      (agent-focus--clip (agent-focus--squish (alist-get 'code input)) width))
     ((alist-get 'url input) (agent-focus--clip (alist-get 'url input) width))
     ;; Keeps unknown and MCP tools legible rather than blank.
     (input (agent-focus--clip (json-serialize input) width))
     (t ""))))

(defun agent-focus--detail (kind payload)
  "Return the line KIND should show for PAYLOAD."
  (let* ((tool (or (alist-get 'tool_name payload) "tool"))
         (input (alist-get 'tool_input payload))
         (ms (alist-get 'duration_ms payload))
         (took (if ms (concat "  " (agent-focus--dur ms)) "")))
    (cond
     ((equal kind "prompt")
      (agent-focus--clip
       (agent-focus--squish (or (alist-get 'prompt payload) "new task")) 100))
     ((equal kind "idle") "waiting for you")
     ((equal kind "done")
      (concat (or (alist-get 'agent_type payload) "subagent") " finished"))
     ;; No inline marker on a failure: the kind already renders ✗ in the
     ;; error face.
     ((equal kind "fail") (concat tool took))
     ((equal kind "think")
      (concat tool
              (if (eq t (alist-get 'interrupted (alist-get 'tool_response payload)))
                  " ✗" " ✓")
              took))
     (t (let ((arg (agent-focus--salient input (alist-get 'cwd payload))))
          (concat tool (if (string-empty-p arg) "" (concat "  " arg))))))))

(defun agent-focus--event (kind payload)
  "Turn hook PAYLOAD into an event plist of KIND.
Structured fields drive the fold; :detail is only a presentation hint,
so the view does not have to re-derive which argument mattered."
  (let* ((input (alist-get 'tool_input payload))
         (cwd (or (alist-get 'cwd payload) ""))
         (file (and (consp input) (alist-get 'file_path input))))
    (list :kind kind
          :session (or (alist-get 'session_id payload) "unknown")
          :label (file-name-nondirectory (directory-file-name cwd))
          :agent (alist-get 'agent_id payload)
          :agent-type (alist-get 'agent_type payload)
          :tool (alist-get 'tool_name payload)
          :file (and file (agent-focus--rel file cwd))
          :ms (alist-get 'duration_ms payload)
          :text (when (equal kind "prompt")
                  (agent-focus--clip
                   (agent-focus--squish (or (alist-get 'prompt payload) "")) 200))
          :detail (agent-focus--detail kind payload))))


;;; Trailing reasoning, lifted from the transcript

(defun agent-focus--transcript-tail (path from)
  "Return (TEXT . NEXT) for whole lines of PATH after byte FROM.
Reads only the new bytes rather than rescanning the file, and stops at
the last newline so a half-written line is never consumed."
  (let ((size (file-attribute-size (file-attributes path))))
    (when (and size (> size from))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path nil from size)
        (goto-char (point-max))
        (when (search-backward "\n" nil t)
          (let ((end (1+ (point))))
            (cons (decode-coding-string
                   (buffer-substring-no-properties (point-min) end) 'utf-8)
                  (+ from (- end (point-min))))))))))

(defun agent-focus--thinking (text)
  "Return the reasoning excerpts in the transcript lines TEXT."
  (delq nil
        (mapcar
         (lambda (line)
           (let* ((record (ignore-errors
                            (json-parse-string line :object-type 'alist
                                               :null-object nil
                                               :false-object nil)))
                  (blocks (and (equal (alist-get 'type record) "assistant")
                               (alist-get 'content (alist-get 'message record))))
                  (thought (seq-some (lambda (b)
                                       (and (equal (alist-get 'type b) "thinking")
                                            (alist-get 'thinking b)))
                                     (or blocks []))))
             (when thought
               ;; First sentence only: thinking blocks are paragraphs, and
               ;; unabridged they would bury the tool-call rhythm.
               (let ((one (car (split-string (agent-focus--squish thought) "\\. "))))
                 (unless (string-empty-p one)
                   (agent-focus--clip one 110))))))
         (split-string text "\n" t))))

(defun agent-focus--emit-reasoning (state payload)
  "Log reasoning added to STATE's transcript, named by PAYLOAD, since last read.

The record for the current tool call is not flushed yet when the hook
fires, so the newest readable reasoning always belongs to the previous
step; emitting it just before the act line puts it under the step it
explains.  A session met for the first time is fast-forwarded rather than
replayed, or its first tool call would dump the whole backlog."
  (let ((path (alist-get 'transcript_path payload))
        (from (agent-focus-state-transcript-pos state)))
    (when (and path (file-readable-p path))
      (let ((tail (agent-focus--transcript-tail path (or from 0))))
        (when tail
          (setf (agent-focus-state-transcript-pos state) (cdr tail))
          (when from
            (dolist (thought (agent-focus--thinking (car tail)))
              (agent-focus-log "reason" thought
                               (agent-focus-state-label state)))))
        (unless tail
          (setf (agent-focus-state-transcript-pos state)
                (or from (file-attribute-size (file-attributes path)) 0)))))))


;;; Entry points -- how state gets in
;;
;; Two ways: the hooks report what happened, and the agent can state what it
;; believes it is doing.  The second is a claim rather than a measurement,
;; which is why it is kept apart everywhere downstream.

;;;###autoload
(defun agent-focus-observe (event)
  "Fold EVENT into its session's state, render it, and return any signal.

EVENT is a plist; :session and :label address the state, :kind selects
the fold, and :detail is the presentation string for the buffer.  The
return value is an observation for the agent, or nil -- the hook turns a
non-nil value into `additionalContext'.

An emitted observation is folded back in as a `signal' event, so how
often the agent had to be told something is itself part of the state."
  (let* ((session (or (plist-get event :session) "unknown"))
         (agent (plist-get event :agent))
         (type (plist-get event :agent-type))
         (id (agent-focus-key session agent))
         ;; A subagent is named by what it is, which says more than the
         ;; directory it inherited from its parent.
         (state (agent-focus-state id
                                   (or type (plist-get event :label))
                                   (and agent (not (string-empty-p agent)) session)
                                   type))
         (kind (or (plist-get event :kind) "act"))
         (detail (or (plist-get event :detail) "")))
    ;; The fold must not be able to take the HUD dark without saying so.
    ;; Reloading this file after changing the struct leaves older states
    ;; short a slot, and the resulting error used to abort `observe' before
    ;; it rendered anything -- the display simply stopped, silently, which
    ;; is the worst way for a stream tool to fail.  Surface it and carry on;
    ;; `agent-focus-reset' is the fix when it says so.
    (condition-case err
        (progn (agent-focus-fold state event)
               (agent-focus--update-panel state))
      (error
       (agent-focus-log "fail" (format "fold failed (%s) -- try M-x agent-focus-reset"
                                       (error-message-string err)))))
    (let ((label (agent-focus-state-label state)))
      (unless (string-empty-p detail)
        (agent-focus-log kind detail label))
      (agent-focus--ensure-timer)
      (let ((signal (agent-focus--signal state)))
        (when signal
          (push (cons (current-time) signal) (agent-focus-state-signals state))
          (agent-focus-log "signal" signal label))
        signal))))


;;;###autoload
(defun agent-focus-hook (kind in-file out-file)
  "Fold the hook payload in IN-FILE as an event of KIND.

Writes the response for Claude Code to OUT-FILE, or leaves it empty when
no signal fired.  Both sides go through files rather than through the
`emacsclient' command line: nothing from a tool call is then interpolated
into a form, and the caller needs no JSON tooling to read the answer
back.

IN-FILE is deleted afterwards, whatever happens."
  (unwind-protect
      (condition-case err
          (let ((payload (with-temp-buffer
                           (insert-file-contents in-file)
                           (json-parse-buffer :object-type 'alist
                                              :null-object nil
                                              :false-object nil))))
            (when (equal kind "act")
              (agent-focus--emit-reasoning
               (agent-focus-state (agent-focus-key
                                   (or (alist-get 'session_id payload) "unknown")
                                   (alist-get 'agent_id payload)))
               payload))
            (let ((signal (agent-focus-observe (agent-focus--event kind payload)))
                  (event (alist-get 'hook_event_name payload)))
              (when (and signal event)
                (with-temp-file out-file
                  (insert (json-serialize
                           `((hookSpecificOutput
                              . ((hookEventName . ,event)
                                 (additionalContext . ,signal)))))))))
            t)
        ;; Never fail a tool call over the HUD -- but say so, rather than
        ;; going quiet, which is how this has broken before.
        (error (ignore-errors
                 (agent-focus-log "fail" (format "hook failed: %s"
                                                 (error-message-string err))))
               nil))
    (ignore-errors (delete-file in-file))))

;;;###autoload
(defun agent-focus-set-intent (text &optional id)
  "Record TEXT as what the agent believes it is working on.

The one thing the hooks cannot derive.  `:task' is literally the user's
prompt, which stays put for twenty minutes while the actual work moves
through several sub-goals; this names the current one.

It is stored as a claim, not a measurement: it never feeds a signal, and
`agent-focus--intent-stale-p' lets the measured state contradict it.  ID
defaults to the session that most recently acted."
  (interactive "sIntent: ")
  (let* ((key (or id agent-focus--current))
         (state (and key (gethash key agent-focus-registry))))
    (cond
     ((null state) (user-error "No session to attach an intent to"))
     (t (agent-focus-fold state (list :kind "intent" :text text))
        (agent-focus--update-panel state)
        (agent-focus-log "intent" text (agent-focus-state-label state))
        text))))


;;; Queries -- the meta level

;;;###autoload
(defun agent-focus-touching (path)
  "Return which sessions have touched PATH, newest first.
Matches on the file name, so the same file reached through a worktree
and through the main checkout counts as one artifact."
  (let ((name (file-name-nondirectory path)) hits)
    (maphash
     (lambda (id state)
       (maphash (lambda (p entry)
                  (when (equal (file-name-nondirectory p) name)
                    (push (list id
                                :label (agent-focus-state-label state)
                                :touches (plist-get entry :touches)
                                :ago (agent-focus--ago (plist-get entry :last)))
                          hits)))
                (agent-focus-state-artifacts state)))
     agent-focus-registry)
    hits))

(defun agent-focus--child-digest (state)
  "Return a compact summary of subagent STATE for its parent's report."
  (list (or (agent-focus-state-agent-type state) "agent")
        :steps (agent-focus-state-steps state)
        :fail-streak (agent-focus-state-fail-streak state)
        :hottest (agent-focus--hottest state 'session)
        :status (cond ((agent-focus-state-done state) "done")
                      ((agent-focus--active-p state) "running")
                      ;; Neither an end event nor recent activity: something
                      ;; went away without saying so.
                      (t "stale"))))

;;;###autoload
(defun agent-focus-report (&optional id)
  "Return a readable digest of session ID, defaulting to the only one."
  (let* ((id (or id (and (= (hash-table-count agent-focus-registry) 1)
                         (let (only)
                           (maphash (lambda (k _v) (setq only k))
                                    agent-focus-registry)
                           only))))
         (state (and id (gethash id agent-focus-registry))))
    (when state
      (let ((kids (agent-focus-children id)))
        (append
         ;; Keys say which frame they are measured in.  steps and the task
         ;; tally reset with every prompt; the session tally does not, and
         ;; two numbers on different clocks sitting side by side unlabelled
         ;; read as if they were comparable.
         (list :label (agent-focus-state-label state)
               :phase (agent-focus--phase state)
               ;; Named to say it is self-reported, so a reader never takes
               ;; it for one of the measured values beside it.
               :claimed-intent (agent-focus-state-intent state)
               :claimed-intent-stale (and (agent-focus-state-intent state)
                                          (agent-focus--intent-stale-p state)
                                          t)
               :task (agent-focus-state-task state)
               :task-elapsed (and (agent-focus-state-task-started state)
                                  (agent-focus--ago
                                   (agent-focus-state-task-started state)))
               :task-steps (agent-focus-state-steps state)
               :task-failures (or (agent-focus-state-task-failures state) 0)
               :task-hottest (agent-focus--hottest state)
               :fail-streak (agent-focus-state-fail-streak state)
               :history (agent-focus-state-tasks state)
               :session-hottest (agent-focus--hottest state 'session)
               :session-elapsed (and (agent-focus-state-started state)
                                     (agent-focus--ago
                                      (agent-focus-state-started state)))
               :signals (length (agent-focus-state-signals state)))
         ;; Subagents fold separately so their failures stay theirs, but the
         ;; parent still has to be able to see what it set in motion.
         (when kids
           (list :subagents
                 (list :running (length (seq-filter #'agent-focus--active-p kids))
                       :total (length kids)
                       :steps (apply #'+ (mapcar #'agent-focus-state-steps kids))
                       :each (mapcar #'agent-focus--child-digest kids)))))))))


;;; The view

(define-derived-mode agent-focus-mode special-mode "Agent-Focus"
  "Major mode for the agent attention HUD."
  ;; Tool lines fit the side window, but reasoning and signal lines are
  ;; prose and do not -- truncating them would hide most of what they say.
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local wrap-prefix (make-string 11 ?\s))
  ;; Explicitly none: the state used to live here, and a value left behind
  ;; by an older version of this file would sit frozen at the top of the
  ;; buffer, showing a step count and an elapsed time from whenever it was
  ;; last written.
  (setq-local header-line-format nil)
  (buffer-disable-undo))

(defun agent-focus--panel (state)
  "Return the header-line summary of STATE.

This is the view of the *state*, as opposed to the buffer below it, which
is the view of the event stream.  A scrolling log shows activity; only
this line answers what is being worked on right now, which is the
question an onlooker actually has."
  (let* ((kids (agent-focus-children (agent-focus-state-id state)))
         (running (seq-count #'agent-focus--active-p kids))
         (task (agent-focus-state-task state))
         (streak (agent-focus-state-fail-streak state))
         (phase (agent-focus--phase state))
         (parts
          (delq nil
                (list
                 (propertize (or (agent-focus-state-label state) "?")
                             'face 'agent-focus-session)
                 (when phase
                   (propertize phase 'face
                               (cond ((equal phase "blocked") 'agent-focus-fail)
                                     ((equal phase "waiting") 'agent-focus-idle)
                                     (t 'agent-focus-act))))
                 ;; The stated intent replaces the prompt when it is fresh:
                 ;; a long task moves through several sub-goals while the
                 ;; prompt that started it stays the same, and the finer
                 ;; one is what an onlooker wants.  Stale, it is shown
                 ;; greyed and marked rather than quietly dropped -- that
                 ;; the agent stopped narrating is itself worth seeing.
                 (cond
                  ((agent-focus-state-intent state)
                   (let ((stale (agent-focus--intent-stale-p state)))
                     (propertize
                      (concat (truncate-string-to-width
                               (agent-focus-state-intent state)
                               agent-focus-panel-task-width nil nil "…")
                              (if stale " (stale)" ""))
                      'face (if stale 'agent-focus-stale 'agent-focus-intent))))
                  ((and task (not (string-empty-p task)))
                   (propertize (truncate-string-to-width
                                task agent-focus-panel-task-width nil nil "…")
                               'face 'agent-focus-prompt)))
                 (when (agent-focus-state-task-started state)
                   (agent-focus--ago (agent-focus-state-task-started state)))
                 (let ((n (agent-focus-state-steps state)))
                   (format "%d step%s" n (if (= n 1) "" "s")))
                 (agent-focus--hottest state)
                 ;; A live failure run is the one thing an onlooker must not
                 ;; have to infer from scrollback.
                 (when (> streak 0)
                   (propertize (format "%d failing" streak)
                               'face 'agent-focus-fail))
                 (when (> running 0)
                   (format "%d subagent%s" running (if (= running 1) "" "s")))))))
    (agent-focus--make-visitable
     (concat " " (mapconcat #'identity parts " · "))
     (agent-focus-state-id state))))

(defvar agent-focus-session-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-focus-visit-session)
    (define-key map [mouse-1] #'agent-focus-visit-session)
    map)
  "Keymap active on a session line in the state block.")

(defun agent-focus--make-visitable (line id)
  "Return LINE carrying the means to jump to session ID."
  (if (not (agent-focus--shell-buffer id))
      line
    (propertize line
                'agent-focus-session id
                'keymap agent-focus-session-line-map
                'mouse-face 'highlight
                'help-echo "RET or mouse-1: go to this session")))

;;;###autoload
(defun agent-focus-visit-session (&optional event)
  "Switch to the agent-shell buffer of the session on this line.
EVENT is the mouse event, when invoked from one."
  (interactive (list last-nonmenu-event))
  (let* ((pos (if (and event (listp event))
                  (posn-point (event-end event))
                (point)))
         (id (get-text-property pos 'agent-focus-session))
         (buffer (and id (agent-focus--shell-buffer id))))
    (cond
     ((null id) (user-error "No session on this line"))
     ((null buffer) (user-error "Session %s is no longer hosted here" id))
     (t (pop-to-buffer buffer)))))

(defun agent-focus--panel-block ()
  "Return one panel line per live session, newest state first.

Lives at the foot of the log rather than in the header line, because a
header line is structurally single-line: with two sessions it could only
show whichever acted last, and the step count would jump between them
with nothing to say they were different agents."
  (let (lines)
    (maphash (lambda (_key state)
               (when (and (null (agent-focus-state-parent state))
                          (agent-focus--active-p state))
                 (push (cons (agent-focus-state-label state)
                             (agent-focus--panel state))
                       lines)))
             agent-focus-registry)
    (when lines
      (concat
       (mapconcat #'cdr
                  ;; Stable order, so a line does not move under the eye
                  ;; just because another session acted.
                  (sort lines (lambda (a b) (string< (car a) (car b))))
                  "\n")
       "\n"
       (propertize (make-string 30 ?─) 'face 'agent-focus-time)))))

(defun agent-focus--update-panel (state)
  "Note STATE as the session that last acted, for `agent-focus-set-intent'.
A subagent resolves to its parent: the session stays the subject, and the
child shows up in the subagent count instead."
  (let* ((parent (and (agent-focus-state-parent state)
                      (gethash (agent-focus-state-parent state)
                               agent-focus-registry)))
         (shown (or parent state)))
    (setq agent-focus--current (agent-focus-state-id shown))))

(defun agent-focus--buffer ()
  "Return the HUD buffer, creating and initialising it if needed."
  (let ((buffer (get-buffer-create agent-focus-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-focus-mode)
        (agent-focus-mode)))
    buffer))

(defun agent-focus--label-column (label)
  "Return LABEL padded to `agent-focus-label-width', or nil if not needed.
The column only appears once a second session is live: with a single
agent it would be a constant, and a constant column is noise."
  (when (and label (> (agent-focus--active-count) 1))
    (let* ((w agent-focus-label-width)
           (suffix (if (string-match "<[0-9]+>\\'" label)
                       (match-string 0 label)
                     ""))
           (base (substring label 0 (- (length label) (length suffix)))))
      (cond
       ((<= (length label) w)
        (concat label (make-string (- w (length label)) ?\s)))
       ;; Truncating from the right would drop the uniquifying suffix, which
       ;; is the only thing telling two sessions in one checkout apart --
       ;; supersonic.el and supersonic.el<2> both cut down to "superson".
       (t (concat (substring base 0 (max 0 (- w (length suffix)))) suffix))))))

(defun agent-focus--render (kind detail &optional label)
  "Return the display line for DETAIL under event KIND, tagged with LABEL."
  (let* ((spec (or (assoc kind agent-focus-kinds)
                   (assoc "act" agent-focus-kinds)))
         (face (nth 2 spec))
         (column (agent-focus--label-column label))
         (line (concat
                (propertize (format-time-string "%H:%M:%S") 'face 'agent-focus-time)
                " "
                (if column
                    (concat (propertize column 'face 'agent-focus-session) " ")
                  "")
                (propertize (nth 1 spec) 'face face)
                " "
                (propertize detail 'face face))))
    ;; wrap-prefix as a text property rather than buffer-locally: the indent
    ;; depends on whether this line carries a session column, so it has to
    ;; be decided per line, not once for the buffer.
    (propertize line 'wrap-prefix
                (make-string (+ 11 (if column (1+ (length column)) 0)) ?\s))))

(defvar-local agent-focus--block-end nil
  "Marker just past the state block, or nil while none is drawn.")

(defun agent-focus--erase-block ()
  "Remove the state block from the head of the current buffer."
  (when (and (markerp agent-focus--block-end)
             (marker-position agent-focus--block-end))
    (delete-region (point-min) agent-focus--block-end)
    (set-marker agent-focus--block-end nil)))

(defun agent-focus--insert-block ()
  "Draw the state block at the head of the current buffer."
  (let ((block (agent-focus--panel-block)))
    (when block
      (goto-char (point-min))
      (insert block "\n")
      (setq agent-focus--block-end (copy-marker (point) nil)))))

(defun agent-focus--trim ()
  "Drop the oldest lines past `agent-focus-max-entries'.
Called with the block erased, so the line count covers only the log.
Oldest is now at the bottom, so this trims the tail."
  (when (> agent-focus-max-entries 0)
    (save-excursion
      (goto-char (point-min))
      (forward-line agent-focus-max-entries)
      (delete-region (point) (point-max)))))

(defun agent-focus--follow (buffer)
  "Keep every window showing BUFFER pinned to the head.
Newest first means there is nothing to tail: the state block and the
latest event are both at the top, and stay put as the log grows."
  (dolist (window (get-buffer-window-list buffer nil t))
    (set-window-point window (with-current-buffer buffer (point-min)))
    (set-window-start window (with-current-buffer buffer (point-min)))))

;;;###autoload
(defun agent-focus-log (kind detail &optional label)
  "Append DETAIL to the HUD as an event of KIND, tagged with session LABEL.
This is the view half, usable on its own; `agent-focus-observe' is the
half that also folds."
  (let ((buffer (agent-focus--buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        ;; Newest first, block on top.  Tear the block down, put the new
        ;; line at the head of the log, trim the tail, rebuild the block --
        ;; so the two things worth seeing never move and never scroll away.
        (agent-focus--erase-block)
        (goto-char (point-min))
        (insert (agent-focus--render kind detail label) "\n")
        (agent-focus--trim)
        (agent-focus--insert-block)))
    (when (and agent-focus-auto-display
               (not (get-buffer-window buffer t)))
      (agent-focus-show))
    (agent-focus--follow buffer)
    kind))

;;;###autoload
(defun agent-focus-show ()
  "Display the HUD in a side window on the right."
  (interactive)
  (display-buffer (agent-focus--buffer)
                  `((display-buffer-in-side-window)
                    (side . right)
                    (slot . 0)
                    (window-width . ,agent-focus-window-width)
                    (window-parameters . ((no-delete-other-windows . t))))))

;;;###autoload
(defun agent-focus-clear ()
  "Empty the HUD buffer.  The folded state is left alone."
  (interactive)
  (with-current-buffer (agent-focus--buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      ;; The marker pointed into what was just erased.
      (setq agent-focus--block-end nil))))

;;;###autoload
(defun agent-focus-reset ()
  "Forget all folded state.  The buffer is left alone."
  (interactive)
  (clrhash agent-focus-registry)
  (agent-focus--stop-timer))

;;;###autoload
(defun agent-focus-status ()
  "Show every folded session in a readable buffer.

The queries are otherwise reachable only by evaluating Elisp, which puts
the state out of reach of exactly the onlookers it was built for."
  (interactive)
  (let ((out (get-buffer-create "*agent-focus-status*")))
    (with-current-buffer out
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (if (zerop (hash-table-count agent-focus-registry))
            (insert "No sessions folded yet.\n")
          (maphash
           (lambda (key state)
             (unless (agent-focus-state-parent state)
               (let ((report (agent-focus-report key)))
                 (insert (propertize (format "%s  [%s]\n"
                                             (agent-focus-state-label state) key)
                                     'face 'agent-focus-session))
                 (dolist (k '(:phase :claimed-intent :claimed-intent-stale
                                     :task :task-elapsed :task-steps
                                     :task-failures :task-hottest
                                     :fail-streak :session-elapsed
                                     :session-hottest :signals))
                   (insert (format "  %-16s %s\n"
                                   (substring (symbol-name k) 1)
                                   (or (plist-get report k) "-"))))
                 (dolist (kid (plist-get (plist-get report :subagents) :each))
                   (insert (format "  subagent         %s  %s steps, %s\n"
                                   (car kid)
                                   (plist-get (cdr kid) :steps)
                                   (plist-get (cdr kid) :status))))
                 ;; Earlier tasks, so this one can be read against them
                 ;; rather than in isolation.
                 (dolist (old (plist-get report :history))
                   (insert (format "  earlier          %s steps, %s failures, %s — %s\n"
                                   (plist-get old :steps)
                                   (plist-get old :failures)
                                   (or (plist-get old :elapsed) "?")
                                   (truncate-string-to-width
                                    (or (plist-get old :task) "?") 40 nil nil "…"))))
                 (insert "\n"))))
           agent-focus-registry))
        (goto-char (point-min))))
    (display-buffer out)))

;;;###autoload
(defun agent-focus-who-touches (path)
  "Report which sessions have touched PATH.
The contention check, made reachable without writing Lisp."
  (interactive "sFile name: ")
  (let ((hits (agent-focus-touching path)))
    (message "%s" (if hits
                      (mapconcat
                       (lambda (hit)
                         (format "%s: %s touches, %s ago"
                                 (plist-get (cdr hit) :label)
                                 (plist-get (cdr hit) :touches)
                                 (plist-get (cdr hit) :ago)))
                       hits " | ")
                    (format "No session has touched %s" path)))))

;;; Refreshing the view
;;
;; Lifecycle rather than rendering: what keeps the elapsed times honest
;; between events, and what makes sure that costs nothing once no agent is
;; working.

(defvar agent-focus--timer nil
  "Repeating timer redrawing the state block, or nil while none runs.")

(defun agent-focus--working-p ()
  "Return non-nil while some agent is actually mid-task.

Deliberately narrower than `agent-focus--active-p': a session that has
ended its turn is still live, but nothing is happening in it, and a clock
ticking over an idle agent claims work that is not being done.  It also
means the timer stops on its own between turns instead of running for as
long as Emacs does."
  (let (working)
    (maphash (lambda (_key state)
               (when (and (agent-focus--active-p state)
                          (not (agent-focus-state-idle state)))
                 (setq working t)))
             agent-focus-registry)
    working))

(defun agent-focus--redraw-block ()
  "Redraw the state block in place, leaving the log untouched."
  (let ((buffer (get-buffer agent-focus-buffer-name)))
    ;; get-buffer, not agent-focus--buffer: a tick must never resurrect a
    ;; buffer the user has killed.
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (save-excursion
            (agent-focus--erase-block)
            (agent-focus--insert-block)))))))

(defun agent-focus--stop-timer ()
  "Stop the refresh timer."
  (when (timerp agent-focus--timer)
    (cancel-timer agent-focus--timer))
  (setq agent-focus--timer nil))

(defun agent-focus--tick ()
  "Redraw the block, or stop the timer once no agent is working."
  (condition-case err
      (if (agent-focus--working-p)
          (agent-focus--redraw-block)
        (agent-focus--stop-timer))
    ;; A timer that throws every second would bury Emacs in messages, so a
    ;; broken redraw retires itself rather than repeating.
    (error (agent-focus--stop-timer)
           (message "agent-focus: refresh stopped (%s)"
                    (error-message-string err)))))

(defun agent-focus--ensure-timer ()
  "Start the refresh timer if work is in progress and none runs."
  (when (and (null agent-focus--timer) (agent-focus--working-p))
    (setq agent-focus--timer
          (run-at-time agent-focus-refresh-interval
                       agent-focus-refresh-interval
                       #'agent-focus--tick))))

(provide 'agent-focus)
;;; agent-focus.el ends here
