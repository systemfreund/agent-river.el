;;; agent-river.el --- Folded focus state for a coding-agent session -*- lexical-binding: t; -*-

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
;; that state into `*agent-river*' for the stream audience.
;;
;; The state is the point; the buffer is a view.  A flat log answers "what
;; happened"; only a fold answers "where are we", because that question
;; quantifies over a set of events.
;;
;; Two consumers, and they want different things:
;;
;; - The stream audience gets the buffer: one line per event, tailing.
;; - The agent itself gets `agent-river-observe's return value -- a short,
;;   factual observation when a signal fires, injected back into its context
;;   by the hook as `additionalContext'.
;;
;; That second channel is deliberately narrow.  Signals are heuristics and
;; will sometimes be wrong, so they state facts ("3 consecutive failures")
;; rather than give instructions ("change your approach").  A wrong fact
;; costs a few tokens; a wrong instruction derails a correct solution.
;;
;; State is keyed by session id in `agent-river-registry', so several
;; sessions can fold side by side.  Nothing here reaches across sessions
;; yet, but the addressing is in place for it -- see `agent-river-touching'.
;;
;; Load it in the live session:
;;
;;   (load "~/.emacs.d/agent-river/agent-river.el")

;;; Code:

(require 'cl-lib)
(require 'seq)

(defgroup agent-river nil
  "Folded focus state for a coding-agent session."
  :group 'tools
  :prefix "agent-river-")

(defcustom agent-river-buffer-name "*agent-river*"
  "Name of the buffer the agent's attention is logged to."
  :type 'string)

(defcustom agent-river-max-entries 200
  "How many lines to keep.  Older lines are dropped from the top.
Zero or less keeps everything, which will grow without bound."
  :type 'integer)

(defcustom agent-river-window-width 56
  "Width of the side window opened by `agent-river-show'."
  :type 'integer)

(defcustom agent-river-auto-display t
  "Whether logging pops the HUD open when no window shows it."
  :type 'boolean)

(defcustom agent-river-fail-streak-threshold 3
  "Consecutive tool failures before the agent is told about it.
Low enough to catch a real loop early, high enough that ordinary
trial-and-error does not trip it."
  :type 'integer)

(defcustom agent-river-fail-streak-repeat 3
  "Further failures between repeat observations once the streak is live.
Without this the agent would be told on every single failure, and a
signal that arrives constantly stops being a signal."
  :type 'integer)

(defcustom agent-river-label-width 8
  "Width of the session column shown when several sessions are active."
  :type 'integer)

(defcustom agent-river-refresh-interval 1
  "Seconds between redraws of the state block while work is in progress.
Elapsed times are only recomputed when the block is drawn, so without a
tick they jump by however long the gap between two events was."
  :type 'number)

(defcustom agent-river-phase-window 8
  "How many recent steps the phase is read from.
Short enough to turn when the work turns, long enough that one stray
tool call does not repaint the panel."
  :type 'integer)

(defcustom agent-river-panel-task-width 34
  "How much of the current task or intent the session line shows."
  :type 'integer)

(defcustom agent-river-phase-blocked-threshold 2
  "Consecutive failures that make the phase read as blocked.
Lower than the threshold for telling the agent: an onlooker may see a
rough patch early, the agent should only be interrupted once it looks
like more than bad luck."
  :type 'integer)

(defcustom agent-river-phase-buckets
  '(("exploring" . ("Read" "Grep" "Glob" "WebFetch" "WebSearch" "Agent" "LSP"))
    ("editing"   . ("Edit" "Write" "NotebookEdit")))
  "Tools that place a step in a phase, keyed by phase name."
  :type '(alist :key-type string :value-type (repeat string)))

(defcustom agent-river-shell-tools '("Bash" "BashOutput")
  "Tools whose step text is searched for `agent-river-verify-regexp'."
  :type '(repeat string))

(defcustom agent-river-verify-regexp
  (rx (or "make test" "make compile" "ert" "cask" "pytest" "npm test"
          "npm run test" "cargo test" "go test" "flycheck" "flymake"
          "diagnostics"))
  "Matched against a shell step to recognise it as verification.

Shell calls resist classification: the same tool runs the test suite, a
git query and a directory listing.  Rather than guess, only a match here
counts as verifying and everything else stays unclassified, so the phase
abstains instead of inventing one.  Tune it for the project."
  :type 'regexp)

(defcustom agent-river-intent-stale-steps 10
  "Steps after which a stated intent is treated as possibly out of date."
  :type 'integer)

(defcustom agent-river-session-ttl 300
  "Seconds without an event after which a session stops counting as active.
Sessions crash and leave state behind.  Stale state that still looks
current is worse than no state, because it is trusted -- so liveness is
a clock, not a flag, and a session that has gone quiet simply drops out."
  :type 'number)


;;; Faces and event kinds

(defface agent-river-time '((t :inherit shadow))
  "Face for the timestamp column.")

(defface agent-river-prompt '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a new task arriving from the user.")

(defface agent-river-act '((t :inherit font-lock-function-name-face))
  "Face for the agent acting -- running a tool.")

(defface agent-river-think '((t :inherit shadow :slant italic))
  "Face for a tool returning.")

(defface agent-river-idle '((t :inherit font-lock-comment-face :slant italic))
  "Face for the agent being idle, waiting on the user.")

(defface agent-river-fail '((t :inherit error))
  "Face for a tool call that errored.")

(defface agent-river-reason '((t :inherit font-lock-doc-face :slant italic))
  "Face for the agent's own reasoning, as it streams in.")

(defface agent-river-signal '((t :inherit warning :weight bold))
  "Face for an observation handed back to the agent.")

(defface agent-river-session '((t :inherit font-lock-constant-face))
  "Face for the session column.")

(defface agent-river-intent '((t :inherit font-lock-string-face))
  "Face for what the agent says it is doing -- a claim, not a measurement.")

(defface agent-river-stale '((t :inherit shadow :slant italic))
  "Face for a claim the measured state has overtaken.")

(defface agent-river-note '((t :inherit font-lock-builtin-face))
  "Face for something observed outside the hook stream.")

(defconst agent-river-kinds
  '(("prompt" "◆" agent-river-prompt)
    ("act"    "▸" agent-river-act)
    ("think"  "·" agent-river-think)
    ("reason" "◇" agent-river-reason)
    ("intent" "◈" agent-river-intent)
    ("fail"   "✗" agent-river-fail)
    ("note"   "◉" agent-river-note)
    ("signal" "!" agent-river-signal)
    ("done"   "□" agent-river-idle)
    ("idle"   "■" agent-river-idle))
  "Alist of (KIND GLYPH FACE) describing how each event kind renders.")


;;; The state

(cl-defstruct (agent-river-state (:constructor agent-river--state-create))
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
  idle              ; the turn ended; nothing is in progress right now
  ;; Everything above is measured.  The four below are a *claim* the agent
  ;; made about itself, kept apart on purpose: this state is fed back to the
  ;; agent, and a claim read later as an observation closes the loop with no
  ;; ground truth left in it.  They never feed a signal.
  intent intent-at intent-step intent-hottest
  tasks             ; finished tasks, newest first
  done              ; set by SubagentStop: finished, as a fact not a guess
  signals           ; observations handed back, newest first
  ;; Observations made outside the hook stream, newest first -- see
  ;; `agent-river-note'.  A third category next to the measurements above and
  ;; the claims before them: something that was genuinely seen, but not by a
  ;; hook, so it could never be recomputed from the event stream and has to be
  ;; carried rather than derived.
  notes)

(defun agent-river-key (session &optional agent)
  "Return the registry key for SESSION, or for AGENT running under it.

A subagent's tool calls arrive with their parent's `session_id' and
`transcript_path', and are distinguished only by an extra `agent_id'.
Keying on the session alone would therefore fold a subagent's work into
its parent -- inflating the parent's step count and, worse, letting one
subagent's failures raise a streak reported against the parent."
  (if (and agent (not (string-empty-p agent)))
      (concat session "/" agent)
    session))

(defvar agent-river--current nil
  "Key of the root session that most recently folded an event.
Lets `agent-river-set-intent' be called without naming a session.")

(defvar agent-river-registry (make-hash-table :test 'equal)
  "Map of session id to `agent-river-state'.
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

(defun agent-river--shell-buffer-p ()
  "Return non-nil when the current buffer hosts an agent-shell session."
  ;; The mode is the whole test: where agent-shell is not loaded there is no
  ;; such buffer, so no separate check for the package is needed -- and one
  ;; on `featurep' would only be a shortcut that is awkward to fake in tests.
  (derived-mode-p 'agent-shell-mode))

(defun agent-river--shell-buffer (id)
  "Return the agent-shell buffer hosting session ID, or nil."
  (seq-find
   (lambda (buffer)
     (with-current-buffer buffer
       (and (agent-river--shell-buffer-p)
            (equal id (alist-get :id (alist-get :session
                                                (bound-and-true-p
                                                 agent-shell--state)))))))
   (buffer-list)))

(defun agent-river--shell-hosted-p ()
  "Return non-nil when agent-shell is hosting sessions in this Emacs."
  (seq-some (lambda (buffer)
              (with-current-buffer buffer (agent-river--shell-buffer-p)))
            (buffer-list)))

(defun agent-river--shell-label (id)
  "Return the name agent-shell gives session ID, or nil.
Taken from the buffer name, so the numbering that distinguishes two
sessions in one directory is agent-shell's rather than a second,
parallel scheme of ours."
  (let ((buffer (agent-river--shell-buffer id)))
    (when buffer
      (let* ((name (buffer-name buffer))
             (at (string-match " @ " name)))
        (if at (substring name (+ at 3)) name)))))

(defun agent-river--label-base (label)
  "Strip any uniquifying suffix from LABEL."
  (replace-regexp-in-string "<[0-9]+>\\'" "" (or label "")))

(defun agent-river--unique-label (label id)
  "Return LABEL, made distinct from the labels of states other than ID.

Two sessions in one checkout derive the same name from their directory,
which renders them identically in the session column and in the state
block -- two different agents, indistinguishable.  Suffixed the way Emacs
uniquifies buffers, and the way the session list already displays them."
  (let (taken)
    (maphash (lambda (key state)
               (unless (equal key id)
                 (push (agent-river-state-label state) taken)))
             agent-river-registry)
    (if (not (member label taken))
        label
      (let ((n 2))
        (while (member (format "%s<%d>" label n) taken)
          (setq n (1+ n)))
        (format "%s<%d>" label n)))))

(defun agent-river-state (id &optional label parent agent-type)
  "Return the state keyed by ID, creating it if needed.
LABEL names it for a human and is refreshed on every call, so a session
that changes directory does not keep a stale name.  PARENT and
AGENT-TYPE are set once, when the state is created."
  (let ((state (or (gethash id agent-river-registry)
                   (puthash id
                            (agent-river--state-create
                             :id id
                             :parent parent
                             :agent-type agent-type
                             :started (current-time)
                             :artifacts (make-hash-table :test 'equal)
                             :task-artifacts (make-hash-table :test 'equal)
                             :tools (make-hash-table :test 'equal)
                             :fail-streak 0
                             :steps 0)
                            agent-river-registry))))
    ;; agent-shell's own name wins where it exists: it is stable across a
    ;; change of working directory, and already numbered.
    (let ((hosted (and (null parent) (agent-river--shell-label id))))
      (cond
       (hosted (setf (agent-river-state-label state) hosted))
       ;; Refresh so a session that moves does not keep a stale name, but
       ;; leave an assigned suffix alone while the base name still matches.
       ((and label
             (not (equal (agent-river--label-base
                          (agent-river-state-label state))
                         label)))
        (setf (agent-river-state-label state)
              (agent-river--unique-label label id)))))
    (setf (agent-river-state-last-seen state) (current-time))
    state))

(defun agent-river--active-p (state)
  "Return non-nil when STATE is still running.

A finished subagent says so via SubagentStop, which is authoritative.

For a root session hosted by agent-shell the buffer settles it: the
process runs in this Emacs, so whether it is alive is a fact and not an
estimate.  The TTL is what is left for everything else -- subagents, and
sessions nobody here owns -- and it was only ever a way of guessing at
something we could not see."
  (cond
   ((agent-river-state-done state) nil)
   ((and (null (agent-river-state-parent state))
         (agent-river--shell-hosted-p))
    (and (agent-river--shell-buffer (agent-river-state-id state)) t))
   (t (let ((seen (agent-river-state-last-seen state)))
        (and seen (< (float-time (time-subtract (current-time) seen))
                     agent-river-session-ttl))))))

(defun agent-river--active-count ()
  "Return how many states are currently running.
Subagents count: while one is running, the view has to say who acted."
  (let ((n 0))
    (maphash (lambda (_id state)
               (when (agent-river--active-p state) (setq n (1+ n))))
             agent-river-registry)
    n))

(defun agent-river-children (key)
  "Return the states spawned by the session registered under KEY.
Derived by walking the registry rather than maintained as a list on the
parent: a subagent's activity then has exactly one home, and a parent's
view of it cannot drift out of step with the child's own state."
  (let (kids)
    (maphash (lambda (_k state)
               (when (equal (agent-river-state-parent state) key)
                 (push state kids)))
             agent-river-registry)
    kids))


;;; The fold

(defun agent-river--touch-1 (table path)
  "Record one touch of PATH in TABLE."
  (let ((entry (gethash path table)))
    (puthash path
             (list :touches (1+ (or (plist-get entry :touches) 0))
                   :last (current-time))
             table)))

(defun agent-river--touch (state path)
  "Record that the session behind STATE touched PATH.

Kept in two frames on purpose.  The session-wide tally is what
`agent-river-touching' needs to spot two agents on one file, and it must
survive a change of task.  The per-task tally is what an observer wants:
\"what is being worked on now\", not \"what has been opened all
afternoon\".  Reporting one while labelling it the other is how a panel
starts misleading people."
  (when (and path (not (string-empty-p path)))
    (agent-river--touch-1 (agent-river-state-artifacts state) path)
    (agent-river--touch-1 (agent-river-state-task-artifacts state) path)))

(defun agent-river--record-tool (state tool ms failed)
  "Fold one completed call of TOOL taking MS into STATE.
FAILED marks it as an error rather than a success."
  (when (and tool (not (string-empty-p tool)))
    (let* ((table (agent-river-state-tools state))
           (entry (gethash tool table)))
      (puthash tool
               (list :count (1+ (or (plist-get entry :count) 0))
                     :ms (+ (or (plist-get entry :ms) 0) (or ms 0))
                     :failures (+ (or (plist-get entry :failures) 0)
                                  (if failed 1 0)))
               table))))

(defun agent-river-fold (state event)
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
      (when (agent-river-state-task state)
        (push (list :task (agent-river-state-task state)
                    :steps (agent-river-state-steps state)
                    :failures (or (agent-river-state-task-failures state) 0)
                    :elapsed (and (agent-river-state-task-started state)
                                  (agent-river--ago
                                   (agent-river-state-task-started state))))
              (agent-river-state-tasks state)))
      (setf (agent-river-state-task-failures state) 0)
      (setf (agent-river-state-idle state) nil)
      ;; A new task makes any previous claim about the work meaningless.
      (setf (agent-river-state-intent state) nil
            (agent-river-state-intent-at state) nil
            (agent-river-state-intent-step state) nil
            (agent-river-state-intent-hottest state) nil)
      (setf (agent-river-state-task state) (plist-get event :text)
            (agent-river-state-task-started state) (current-time)
            (agent-river-state-steps state) 0
            (agent-river-state-step state) nil
            (agent-river-state-fail-streak state) 0
            (agent-river-state-fail-tools state) nil)
      (clrhash (agent-river-state-task-artifacts state)))

     ((equal kind "act")
      (setf (agent-river-state-idle state) nil
            (agent-river-state-step state) (list :tool tool :file file
                                                 :at (current-time))
            (agent-river-state-steps state) (1+ (agent-river-state-steps state)))
      (push (cons tool (plist-get event :detail))
            (agent-river-state-recent state))
      (let ((window (nthcdr (1- agent-river-phase-window)
                            (agent-river-state-recent state))))
        (when window (setcdr window nil)))
      (agent-river--touch state file))

     ((equal kind "think")
      (agent-river--record-tool state tool ms nil)
      ;; Any success ends the streak: the agent is getting somewhere again.
      (setf (agent-river-state-step state) nil
            (agent-river-state-fail-streak state) 0
            (agent-river-state-fail-tools state) nil))

     ((equal kind "fail")
      (agent-river--record-tool state tool ms t)
      (setf (agent-river-state-step state) nil
            (agent-river-state-task-failures state)
            (1+ (or (agent-river-state-task-failures state) 0))
            (agent-river-state-fail-streak state)
            (1+ (agent-river-state-fail-streak state)))
      (let ((cell (assoc tool (agent-river-state-fail-tools state))))
        (if cell
            (setcdr cell (1+ (cdr cell)))
          (push (cons tool 1) (agent-river-state-fail-tools state)))))

     ;; Both of the below record something that happened *to* the session
     ;; rather than something it did, which is why neither touches the step,
     ;; the streak or the artifacts.
     ((equal kind "signal")
      (push (cons (current-time) (plist-get event :text))
            (agent-river-state-signals state)))

     ((equal kind "note")
      (push (cons (current-time) (plist-get event :text))
            (agent-river-state-notes state)))

     ((equal kind "intent")
      (setf (agent-river-state-intent state) (plist-get event :text)
            (agent-river-state-intent-at state) (current-time)
            (agent-river-state-intent-step state) (agent-river-state-steps state)
            (agent-river-state-intent-hottest state) (agent-river--hottest state)))

     ((equal kind "idle")
      (setf (agent-river-state-step state) nil
            (agent-river-state-idle state) t))

     ((equal kind "done")
      (setf (agent-river-state-step state) nil)
      ;; Only ever retires a subagent.  Whether SubagentStop carries an
      ;; agent_id is unverified; if it does not, the event addresses the
      ;; parent key, and marking a live session finished would poison every
      ;; reading taken from it.  Ignoring a stray event is the cheap side of
      ;; that trade.
      (when (agent-river-state-parent state)
        (setf (agent-river-state-done state) t))))
    state))


;;; Derived signals

(defun agent-river--bucket (tool detail)
  "Return the phase bucket for a step running TOOL with DETAIL, or nil.

The verify pattern is only applied to shell tools.  Matching it against
every step misreads a file whose *name* happens to look like a build --
reading `Cask' is exploring, not verifying."
  (cond
   ((null tool) nil)
   ((and (member tool agent-river-shell-tools)
         detail
         (string-match-p agent-river-verify-regexp detail))
    "verifying")
   (t (car (seq-find (lambda (cell) (member tool (cdr cell)))
                     agent-river-phase-buckets)))))

(defun agent-river--phase (state)
  "Return what STATE looks like it is doing, or nil when unclear.

Blocked is decided by failures rather than by tool mix: a run of errors
says more about where the work stands than which tools produced them.

Waiting outranks both.  The tool window still holds the steps of the
finished turn, so without this the panel keeps announcing \"exploring\"
above a log line that says the turn is over -- describing what the work
*was* while presenting it as what the work *is*."
  (cond
   ((agent-river-state-idle state) "waiting")
   ((>= (agent-river-state-fail-streak state)
        agent-river-phase-blocked-threshold)
    "blocked")
   (t
    (let ((counts nil))
      (dolist (step (agent-river-state-recent state))
        (let ((bucket (agent-river--bucket (car step) (cdr step))))
          (when bucket
            (setf (alist-get bucket counts 0 nil #'equal)
                  (1+ (alist-get bucket counts 0 nil #'equal))))))
      (let ((best (car (seq-sort-by #'cdr #'> counts))))
        ;; One classified step is noise; two is a tendency.
        (when (and best (> (cdr best) 1)) (car best)))))))

(defun agent-river--intent-stale-p (state)
  "Return non-nil when STATE's stated intent has been overtaken by events.

An agent remembers to say what it is doing while things go well, and
forgets precisely when it has lost the thread -- which is when an
onlooker most needs to know.  The measured state is allowed to contradict
the claim, so a forgotten update shows up as stale rather than passing
itself off as current."
  (and (agent-river-state-intent state)
       (let ((set-at (or (agent-river-state-intent-step state) 0))
             (was (agent-river-state-intent-hottest state)))
         (or (> (- (agent-river-state-steps state) set-at)
                agent-river-intent-stale-steps)
             ;; Only once there was something to move away from: gaining a
             ;; hottest file where there was none is ordinary progress.
             (and was (not (equal was (agent-river--hottest state))))))))

(defun agent-river--ago (time)
  "Format the interval since TIME compactly."
  (let ((s (floor (float-time (time-subtract (current-time) time)))))
    (cond ((< s 60) (format "%ds" s))
          ((< s 3600) (format "%dm%02ds" (/ s 60) (mod s 60)))
          (t (format "%dh%02dm" (/ s 3600) (mod (/ s 60) 60))))))

(defun agent-river--hottest (state &optional scope)
  "Return the most-touched artifact of STATE as a string, or nil.
SCOPE is `session' for the whole session, or nil for the current task."
  (let (best best-n)
    (maphash (lambda (path entry)
               (let ((n (plist-get entry :touches)))
                 (when (or (null best-n) (> n best-n))
                   (setq best path best-n n))))
             (if (eq scope 'session)
                 (agent-river-state-artifacts state)
               (agent-river-state-task-artifacts state)))
    (when (and best (> best-n 1))
      (format "%s (%d touches)" (file-name-nondirectory best) best-n))))

(defun agent-river--signal (state)
  "Return an observation about STATE for the agent, or nil.

Kept to a single line with no control characters: the hook reads this
back through `emacsclient', whose printed representation of a plain
string is then parsed as JSON, and an embedded newline would break that."
  (let ((streak (agent-river-state-fail-streak state)))
    (when (and (>= streak agent-river-fail-streak-threshold)
               (zerop (mod (- streak agent-river-fail-streak-threshold)
                           agent-river-fail-streak-repeat)))
      (let ((tools (mapconcat (lambda (cell) (format "%s x%d" (car cell) (cdr cell)))
                              (reverse (agent-river-state-fail-tools state))
                              ", "))
            (since (and (agent-river-state-task-started state)
                        (agent-river--ago (agent-river-state-task-started state))))
            (hot (agent-river--hottest state)))
        (concat
         (format "agent-river: %d consecutive tool failures (%s)" streak tools)
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

(defconst agent-river-detail-width 72
  "How much of a tool argument a log line shows.")

(defun agent-river--squish (text)
  "Collapse whitespace in TEXT onto one line."
  (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text)))

(defun agent-river--clip (text width)
  "Shorten TEXT to WIDTH, marking that something was cut."
  (if (> (length text) width)
      (concat (substring text 0 width) "…")
    text))

(defun agent-river--rel (path cwd)
  "Show PATH relative to CWD when under it, else as a bare name.
Never as a long absolute path: two agents touching one file from a
worktree and from the main checkout have to produce the same string, or
the view renders a collision as two unrelated files."
  (if (and cwd (not (string-empty-p cwd))
           (string-prefix-p (file-name-as-directory cwd) path))
      (substring path (1+ (length cwd)))
    (file-name-nondirectory path)))

(defun agent-river--dur (ms)
  "Format MS compactly."
  (if (>= ms 1000)
      (concat (replace-regexp-in-string
               "\\.0\\'" "" (format "%.1f" (/ (float ms) 1000)))
              "s")
    (format "%dms" ms)))

(defun agent-river--salient (input cwd)
  "Return the argument of tool INPUT worth showing, given CWD.
Ordered most- to least-specific.  A description comes before a command
deliberately: Bash and Task carry a human-written line saying what the
call is for, which reads better than the shell it expands to."
  (let ((width agent-river-detail-width))
    (cond
     ((not (consp input)) "")
     ((alist-get 'file_path input) (agent-river--rel (alist-get 'file_path input) cwd))
     ((alist-get 'description input)
      (agent-river--clip (agent-river--squish (alist-get 'description input)) width))
     ((alist-get 'command input)
      (agent-river--clip (agent-river--squish (alist-get 'command input)) width))
     ((alist-get 'pattern input)
      (agent-river--clip (agent-river--squish (alist-get 'pattern input)) width))
     ((alist-get 'code input)
      (agent-river--clip (agent-river--squish (alist-get 'code input)) width))
     ((alist-get 'url input) (agent-river--clip (alist-get 'url input) width))
     ;; Keeps unknown and MCP tools legible rather than blank.
     (input (agent-river--clip (json-serialize input) width))
     (t ""))))

(defun agent-river--detail (kind payload)
  "Return the line KIND should show for PAYLOAD."
  (let* ((tool (or (alist-get 'tool_name payload) "tool"))
         (input (alist-get 'tool_input payload))
         (ms (alist-get 'duration_ms payload))
         (took (if ms (concat "  " (agent-river--dur ms)) "")))
    (cond
     ((equal kind "prompt")
      (agent-river--clip
       (agent-river--squish (or (alist-get 'prompt payload) "new task")) 100))
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
     (t (let ((arg (agent-river--salient input (alist-get 'cwd payload))))
          (concat tool (if (string-empty-p arg) "" (concat "  " arg))))))))

(defun agent-river--event (kind payload)
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
          :file (and file (agent-river--rel file cwd))
          ;; The absolute name, for the views that have to reach the file on
          ;; disk.  Carried beside `:file' rather than replacing it, and never
          ;; folded: the artifact tables are keyed on the normalised form, and
          ;; an absolute path in them would make one file reached from a
          ;; worktree and from the main checkout count as two again.
          :path file
          :ms (alist-get 'duration_ms payload)
          :text (when (equal kind "prompt")
                  (agent-river--clip
                   (agent-river--squish (or (alist-get 'prompt payload) "")) 200))
          :detail (agent-river--detail kind payload))))



;;; Live reasoning, from the ACP stream
;;
;; The reasoning rides the same ACP stream that drives the shell:
;; `agent_thought_chunk' notifications carry it, and the client is reachable
;; from the buffer this file already locates by session id.
;;
;; This is the one thing here that agent-shell is required for rather than
;; merely better with.  It replaced lifting the reasoning out of the session
;; transcript, which could only ever yield the *previous* step's thinking --
;; the record for the current tool call is still unflushed when the hook
;; fires -- and so had to compensate by where it placed its line.  A thought
;; chunk arrives when the agent thinks it, which is before the tool call it
;; explains, so the order is now chronological rather than staged.
;;
;; What gets harder: a thought arrives in chunks rather than whole.  Only the
;; first sentence is shown, so a run is emitted the moment one is complete
;; and the rest of that run is dropped; a run that ends without a sentence
;; boundary is flushed by the next notification that is not a thought.

(defconst agent-river-thought-width 110
  "How much of a thought's first sentence the HUD shows.")

(defvar agent-river--thought-runs (make-hash-table :test 'equal)
  "Session id -> (:text ACCUMULATED :done EMITTED-P) for the thought in flight.

Deliberately not a slot on `agent-river-state': this is decoding state for
one ingestion path, nothing folds it and no query reads it, and putting it
in the struct would mean every reload demanded `agent-river-reset'.")

(defvar agent-river--subscribed (make-hash-table :test 'equal)
  "Session id -> the ACP client its notification handler is attached to.

Subscribing twice would double every reasoning line, and a session whose
client was rebuilt needs attaching again -- so the client is compared
rather than a flag being set.")

(defun agent-river--thought-chunk (notification)
  "Return the thinking text carried by NOTIFICATION, or nil for anything else."
  (let ((update (alist-get 'update (alist-get 'params notification))))
    (when (equal (alist-get 'sessionUpdate update) "agent_thought_chunk")
      (alist-get 'text (alist-get 'content update)))))

(defun agent-river--first-sentence (text)
  "Return the first complete sentence of TEXT, or nil when it has none.
Completeness is the point: mid-stream a chunk usually ends inside a
sentence, and showing that would put a truncated clause on screen and then
never correct it."
  (let ((parts (split-string (agent-river--squish text) "\\. ")))
    (when (cdr parts) (car parts))))

(defun agent-river--emit-thought (id text)
  "Log TEXT as the reasoning of session ID."
  (let ((one (agent-river--clip (agent-river--squish text)
                                agent-river-thought-width))
        (state (gethash id agent-river-registry)))
    (unless (string-empty-p one)
      (agent-river-log "reason" one (and state (agent-river-state-label state))))))

(defun agent-river--thought-arrived (id chunk)
  "Add CHUNK to session ID's thought in flight, emitting once it says enough."
  (let* ((run (gethash id agent-river--thought-runs))
         (text (concat (plist-get run :text) chunk)))
    (cond
     ;; The first sentence is already on screen; the rest of this run is
     ;; paragraphs, and showing them would bury the tool-call rhythm.
     ((plist-get run :done))
     ((agent-river--first-sentence text)
      (agent-river--emit-thought id (agent-river--first-sentence text))
      (puthash id (list :text text :done t) agent-river--thought-runs))
     (t (puthash id (list :text text :done nil) agent-river--thought-runs)))))

(defun agent-river--thought-ended (id)
  "Close session ID's thought run, emitting one that never reached a sentence."
  (let ((run (gethash id agent-river--thought-runs)))
    (when run
      (unless (plist-get run :done)
        (agent-river--emit-thought id (plist-get run :text)))
      (remhash id agent-river--thought-runs))))

(defun agent-river--on-notification (id notification)
  "Route NOTIFICATION for session ID into the reasoning line."
  (let ((chunk (agent-river--thought-chunk notification)))
    (if chunk
        (agent-river--thought-arrived id chunk)
      ;; Anything that is not a thought ends the run: the agent stopped
      ;; thinking and did something.
      (agent-river--thought-ended id))))

(defun agent-river--acp-client (id)
  "Return the ACP client of session ID, or nil when agent-shell is not hosting it."
  (let ((buffer (agent-river--shell-buffer id)))
    (when buffer
      (with-current-buffer buffer
        (alist-get :client (bound-and-true-p agent-shell--state))))))

(defun agent-river--ensure-subscribed (id)
  "Attach the reasoning handler to session ID's ACP client, at most once.

A no-op where agent-shell is absent or does not host this session, which is
the one case that gets no reasoning lines at all -- the hooks carry no
thinking text, so there is nothing else to read them from."
  (when (fboundp 'acp-subscribe-to-notifications)
    (let ((client (agent-river--acp-client id)))
      (when (and client (not (eq client (gethash id agent-river--subscribed))))
        (acp-subscribe-to-notifications
         :client client
         :on-notification (lambda (notification)
                            ;; Never let the HUD break the shell it rides on.
                            (condition-case nil
                                (agent-river--on-notification id notification)
                              (error nil))))
        (puthash id client agent-river--subscribed)))))


;;; Entry points -- how state gets in
;;
;; Two ways: the hooks report what happened, and the agent can state what it
;; believes it is doing.  The second is a claim rather than a measurement,
;; which is why it is kept apart everywhere downstream.

;; Side effects hang off `agent-river-observers' rather than being called from
;; `agent-river-observe' by name.  The point is not extensibility for its own
;; sake: every consumer that reaches outside this package needs the same three
;; things, and each one is a mistake that has already been made here.
;;
;; It must not run inside the fold -- the fold is pure, and the tests depend on
;; being able to drive it with no frame, no buffers and no live session.  It
;; must not share the fold's guard, because an error reported as a fold failure
;; sends the user to `agent-river-reset', throwing away every session's state
;; over what may be one overlay.  And it must retire on its first error rather
;; than repeat it, because this path runs on every single tool call, so a
;; consumer that is broken is broken thousands of times.
;;
;; Getting those three right is most of the work of adding a consumer, so the
;; runner owns them and a consumer is left with only its own job.

(defvar agent-river-observers nil
  "Functions called with (STATE EVENT) after each event is folded.

An abnormal hook, run for effect only: the return value is ignored and
nothing downstream reads it, so an observer cannot influence the state,
the signal handed back to the agent, or each other.  That is deliberate --
the state is the one account of what happened, and a consumer that could
edit it on the way past would become a second, unlogged one.

STATE is the `agent-river-state' the event was folded into, and carries
everything measured.  EVENT is the raw plist, which is where to look for
anything the fold deliberately drops -- `:path' being the case in point.")

(defun agent-river--run-observers (state event)
  "Run `agent-river-observers' over STATE and EVENT, each in its own guard.

An observer that throws is removed rather than being allowed to fail on
every tool call for the rest of the session, and says so in the log --
going quiet is how this has broken before.  One that needs to tear
something down on the way out puts a function on its symbol's
`agent-river-retire' property; without it, removal is the whole
retirement."
  (dolist (observer agent-river-observers)
    (condition-case err
        (funcall observer state event)
      (error
       (setq agent-river-observers (delq observer agent-river-observers))
       (when (symbolp observer)
         (let ((retire (get observer 'agent-river-retire)))
           (when retire (ignore-errors (funcall retire)))))
       (agent-river-log "fail" (format "observer %s retired (%s)"
                                       observer (error-message-string err)))))))

;;;###autoload
(defun agent-river-observe (event)
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
         (id (agent-river-key session agent))
         ;; A subagent is named by what it is, which says more than the
         ;; directory it inherited from its parent.
         (state (agent-river-state id
                                   (or type (plist-get event :label))
                                   (and agent (not (string-empty-p agent)) session)
                                   type))
         (kind (or (plist-get event :kind) "act"))
         (detail (or (plist-get event :detail) "")))
    ;; Before anything that can fail: where agent-shell hosts this session the
    ;; reasoning arrives on its ACP stream rather than through us, and the
    ;; subscription has to exist before the first thought is streamed.
    (agent-river--ensure-subscribed session)
    ;; The fold must not be able to take the HUD dark without saying so.
    ;; Reloading this file after changing the struct leaves older states
    ;; short a slot, and the resulting error used to abort `observe' before
    ;; it rendered anything -- the display simply stopped, silently, which
    ;; is the worst way for a stream tool to fail.  Surface it and carry on;
    ;; `agent-river-reset' is the fix when it says so.
    (condition-case err
        (progn (agent-river-fold state event)
               (agent-river--update-panel state))
      (error
       (agent-river-log "fail" (format "fold failed (%s) -- try M-x agent-river-reset"
                                       (error-message-string err)))))
    (agent-river--run-observers state event)
    (let ((label (agent-river-state-label state)))
      (unless (string-empty-p detail)
        (agent-river-log kind detail label))
      (agent-river--ensure-timer)
      (let ((signal (agent-river--signal state)))
        (when signal
          ;; Through the fold, not around it.  This used to push straight onto
          ;; the slot, which made `agent-river-observe' a second writer to a
          ;; state the fold is supposed to own alone -- and left the fold's
          ;; promise that a state can be rebuilt by replaying its events true
          ;; only by accident, because a signal happens to be derivable.
          (agent-river-fold state (list :kind "signal" :text signal))
          (agent-river-log "signal" signal label))
        signal))))


;;;###autoload
(defun agent-river-hook (kind in-file out-file)
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
            (let ((signal (agent-river-observe (agent-river--event kind payload)))
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
                 (agent-river-log "fail" (format "hook failed: %s"
                                                 (error-message-string err))))
               nil))
    (ignore-errors (delete-file in-file))))

;;;###autoload
(defun agent-river-set-intent (text &optional id)
  "Record TEXT as what the agent believes it is working on.

The one thing the hooks cannot derive.  `:task' is literally the user's
prompt, which stays put for twenty minutes while the actual work moves
through several sub-goals; this names the current one.

It is stored as a claim, not a measurement: it never feeds a signal, and
`agent-river--intent-stale-p' lets the measured state contradict it.  ID
defaults to the session that most recently acted."
  (interactive "sIntent: ")
  (let* ((key (or id agent-river--current))
         (state (and key (gethash key agent-river-registry))))
    (cond
     ((null state) (user-error "No session to attach an intent to"))
     (t (agent-river-fold state (list :kind "intent" :text text))
        (agent-river--update-panel state)
        (agent-river-log "intent" text (agent-river-state-label state))
        text))))

(defvar agent-river--noting nil
  "Non-nil while a note is being folded.
Bounds observer re-entry to a single level; see `agent-river-note'.")

;;;###autoload
(defun agent-river-note (text &optional id)
  "Fold TEXT as an observation about session ID made outside the hook stream.

The way a side effect is allowed to produce state.  An observer must not
write to the struct -- the fold owns it, and a second writer would put
transitions in the state that no event accounts for, which is how the
replay promise on `agent-river-fold' quietly stops being true.  A note is
an event instead: it goes through the fold, it is logged, it is counted in
the report, and where it came from stays visible.

What belongs here is what a hook cannot see and the state cannot derive --
the file changing under the agent because a human edited it, a build
finishing elsewhere.  Anything recomputable from the event stream should
be derived at the point it is read, not stored here.

It is a measurement, not a claim: unlike `agent-river-set-intent' this is
something that was observed, so it may feed a signal.  Which means an
observer minting notes about itself would close the same loop the intent
slots are kept apart to prevent -- note what happened, never what you
think about it.

Observers run for a note as they do for a hook event, but only one level
deep: a note made while a note is being handled is refused and returns
nil.  Two observers noting at each other is otherwise an unbounded loop,
and one that is hard to see in a log of single lines.  ID defaults to the
session that most recently acted."
  (let* ((key (or id agent-river--current))
         (state (and key (gethash key agent-river-registry))))
    (cond
     ((null state) (user-error "No session to attach a note to"))
     (agent-river--noting nil)
     (t
      (let ((agent-river--noting t)
            (event (list :kind "note" :text text :session key)))
        (agent-river-fold state event)
        (agent-river--update-panel state)
        (agent-river-log "note" text (agent-river-state-label state))
        (agent-river--run-observers state event)
        text)))))


;;; Queries -- the meta level

;;;###autoload
(defun agent-river-touching (path)
  "Return which sessions have touched PATH, newest first.
Matches on the file name, so the same file reached through a worktree
and through the main checkout counts as one artifact."
  (let ((name (file-name-nondirectory path)) hits)
    (maphash
     (lambda (id state)
       (maphash (lambda (p entry)
                  (when (equal (file-name-nondirectory p) name)
                    (push (list id
                                :label (agent-river-state-label state)
                                :touches (plist-get entry :touches)
                                :ago (agent-river--ago (plist-get entry :last)))
                          hits)))
                (agent-river-state-artifacts state)))
     agent-river-registry)
    hits))

(defun agent-river--child-digest (state)
  "Return a compact summary of subagent STATE for its parent's report."
  (list (or (agent-river-state-agent-type state) "agent")
        :steps (agent-river-state-steps state)
        :fail-streak (agent-river-state-fail-streak state)
        :hottest (agent-river--hottest state 'session)
        :status (cond ((agent-river-state-done state) "done")
                      ((agent-river--active-p state) "running")
                      ;; Neither an end event nor recent activity: something
                      ;; went away without saying so.
                      (t "stale"))))

;;;###autoload
(defun agent-river-report (&optional id)
  "Return a readable digest of session ID, defaulting to the only one."
  (let* ((id (or id (and (= (hash-table-count agent-river-registry) 1)
                         (let (only)
                           (maphash (lambda (k _v) (setq only k))
                                    agent-river-registry)
                           only))))
         (state (and id (gethash id agent-river-registry))))
    (when state
      (let ((kids (agent-river-children id)))
        (append
         ;; Keys say which frame they are measured in.  steps and the task
         ;; tally reset with every prompt; the session tally does not, and
         ;; two numbers on different clocks sitting side by side unlabelled
         ;; read as if they were comparable.
         (list :label (agent-river-state-label state)
               :phase (agent-river--phase state)
               ;; Named to say it is self-reported, so a reader never takes
               ;; it for one of the measured values beside it.
               :claimed-intent (agent-river-state-intent state)
               :claimed-intent-stale (and (agent-river-state-intent state)
                                          (agent-river--intent-stale-p state)
                                          t)
               :task (agent-river-state-task state)
               :task-elapsed (and (agent-river-state-task-started state)
                                  (agent-river--ago
                                   (agent-river-state-task-started state)))
               :task-steps (agent-river-state-steps state)
               :task-failures (or (agent-river-state-task-failures state) 0)
               :task-hottest (agent-river--hottest state)
               :fail-streak (agent-river-state-fail-streak state)
               :history (agent-river-state-tasks state)
               :session-hottest (agent-river--hottest state 'session)
               :session-elapsed (and (agent-river-state-started state)
                                     (agent-river--ago
                                      (agent-river-state-started state)))
               :signals (length (agent-river-state-signals state))
               :notes (length (agent-river-state-notes state)))
         ;; Subagents fold separately so their failures stay theirs, but the
         ;; parent still has to be able to see what it set in motion.
         (when kids
           (list :subagents
                 (list :running (length (seq-filter #'agent-river--active-p kids))
                       :total (length kids)
                       :steps (apply #'+ (mapcar #'agent-river-state-steps kids))
                       :each (mapcar #'agent-river--child-digest kids)))))))))


;;; The view

(define-derived-mode agent-river-mode special-mode "Agent-Focus"
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

(defun agent-river--panel (state)
  "Return the header-line summary of STATE.

This is the view of the *state*, as opposed to the buffer below it, which
is the view of the event stream.  A scrolling log shows activity; only
this line answers what is being worked on right now, which is the
question an onlooker actually has."
  (let* ((kids (agent-river-children (agent-river-state-id state)))
         (running (seq-count #'agent-river--active-p kids))
         (task (agent-river-state-task state))
         (streak (agent-river-state-fail-streak state))
         (phase (agent-river--phase state))
         (parts
          (delq nil
                (list
                 (propertize (or (agent-river-state-label state) "?")
                             'face 'agent-river-session)
                 (when phase
                   (propertize phase 'face
                               (cond ((equal phase "blocked") 'agent-river-fail)
                                     ((equal phase "waiting") 'agent-river-idle)
                                     (t 'agent-river-act))))
                 ;; The stated intent replaces the prompt when it is fresh:
                 ;; a long task moves through several sub-goals while the
                 ;; prompt that started it stays the same, and the finer
                 ;; one is what an onlooker wants.  Stale, it is shown
                 ;; greyed and marked rather than quietly dropped -- that
                 ;; the agent stopped narrating is itself worth seeing.
                 (cond
                  ((agent-river-state-intent state)
                   (let ((stale (agent-river--intent-stale-p state)))
                     (propertize
                      (concat (truncate-string-to-width
                               (agent-river-state-intent state)
                               agent-river-panel-task-width nil nil "…")
                              (if stale " (stale)" ""))
                      'face (if stale 'agent-river-stale 'agent-river-intent))))
                  ((and task (not (string-empty-p task)))
                   (propertize (truncate-string-to-width
                                task agent-river-panel-task-width nil nil "…")
                               'face 'agent-river-prompt)))
                 (when (agent-river-state-task-started state)
                   (agent-river--ago (agent-river-state-task-started state)))
                 (let ((n (agent-river-state-steps state)))
                   (format "%d step%s" n (if (= n 1) "" "s")))
                 (agent-river--hottest state)
                 ;; A live failure run is the one thing an onlooker must not
                 ;; have to infer from scrollback.
                 (when (> streak 0)
                   (propertize (format "%d failing" streak)
                               'face 'agent-river-fail))
                 (when (> running 0)
                   (format "%d subagent%s" running (if (= running 1) "" "s")))))))
    (agent-river--make-visitable
     (concat " " (mapconcat #'identity parts " · "))
     (agent-river-state-id state))))

(defvar agent-river-session-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-river-visit-session)
    (define-key map [mouse-1] #'agent-river-visit-session)
    map)
  "Keymap active on a session line in the state block.")

(defun agent-river--make-visitable (line id)
  "Return LINE carrying the means to jump to session ID."
  (if (not (agent-river--shell-buffer id))
      line
    (propertize line
                'agent-river-session id
                'keymap agent-river-session-line-map
                'mouse-face 'highlight
                'help-echo "RET or mouse-1: go to this session")))

;;;###autoload
(defun agent-river-visit-session (&optional event)
  "Switch to the agent-shell buffer of the session on this line.
EVENT is the mouse event, when invoked from one."
  (interactive (list last-nonmenu-event))
  (let* ((pos (if (and event (listp event))
                  (posn-point (event-end event))
                (point)))
         (id (get-text-property pos 'agent-river-session))
         (buffer (and id (agent-river--shell-buffer id))))
    (cond
     ((null id) (user-error "No session on this line"))
     ((null buffer) (user-error "Session %s is no longer hosted here" id))
     (t (pop-to-buffer buffer)))))

(defun agent-river--panel-block ()
  "Return one panel line per live session, newest state first.

Lives at the foot of the log rather than in the header line, because a
header line is structurally single-line: with two sessions it could only
show whichever acted last, and the step count would jump between them
with nothing to say they were different agents."
  (let (lines)
    (maphash (lambda (_key state)
               (when (and (null (agent-river-state-parent state))
                          (agent-river--active-p state))
                 (push (cons (agent-river-state-label state)
                             (agent-river--panel state))
                       lines)))
             agent-river-registry)
    (when lines
      (concat
       (mapconcat #'cdr
                  ;; Stable order, so a line does not move under the eye
                  ;; just because another session acted.
                  (sort lines (lambda (a b) (string< (car a) (car b))))
                  "\n")
       "\n"
       (propertize (make-string 30 ?─) 'face 'agent-river-time)))))

(defun agent-river--update-panel (state)
  "Note STATE as the session that last acted, for `agent-river-set-intent'.
A subagent resolves to its parent: the session stays the subject, and the
child shows up in the subagent count instead."
  (let* ((parent (and (agent-river-state-parent state)
                      (gethash (agent-river-state-parent state)
                               agent-river-registry)))
         (shown (or parent state)))
    (setq agent-river--current (agent-river-state-id shown))))

(defun agent-river--buffer ()
  "Return the HUD buffer, creating and initialising it if needed."
  (let ((buffer (get-buffer-create agent-river-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-river-mode)
        (agent-river-mode)))
    buffer))

(defun agent-river--label-column (label)
  "Return LABEL padded to `agent-river-label-width', or nil if not needed.
The column only appears once a second session is live: with a single
agent it would be a constant, and a constant column is noise."
  (when (and label (> (agent-river--active-count) 1))
    (let* ((w agent-river-label-width)
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

(defun agent-river--render (kind detail &optional label)
  "Return the display line for DETAIL under event KIND, tagged with LABEL."
  (let* ((spec (or (assoc kind agent-river-kinds)
                   (assoc "act" agent-river-kinds)))
         (face (nth 2 spec))
         (column (agent-river--label-column label))
         (line (concat
                (propertize (format-time-string "%H:%M:%S") 'face 'agent-river-time)
                " "
                (if column
                    (concat (propertize column 'face 'agent-river-session) " ")
                  "")
                (propertize (nth 1 spec) 'face face)
                " "
                (propertize detail 'face face))))
    ;; wrap-prefix as a text property rather than buffer-locally: the indent
    ;; depends on whether this line carries a session column, so it has to
    ;; be decided per line, not once for the buffer.
    (propertize line 'wrap-prefix
                (make-string (+ 11 (if column (1+ (length column)) 0)) ?\s))))

(defvar-local agent-river--block-end nil
  "Marker just past the state block, or nil while none is drawn.")

(defun agent-river--erase-block ()
  "Remove the state block from the head of the current buffer."
  (when (and (markerp agent-river--block-end)
             (marker-position agent-river--block-end))
    (delete-region (point-min) agent-river--block-end)
    (set-marker agent-river--block-end nil)))

(defun agent-river--insert-block ()
  "Draw the state block at the head of the current buffer."
  (let ((block (agent-river--panel-block)))
    (when block
      (goto-char (point-min))
      (insert block "\n")
      (setq agent-river--block-end (copy-marker (point) nil)))))

(defun agent-river--trim ()
  "Drop the oldest lines past `agent-river-max-entries'.
Called with the block erased, so the line count covers only the log.
Oldest is now at the bottom, so this trims the tail."
  (when (> agent-river-max-entries 0)
    (save-excursion
      (goto-char (point-min))
      (forward-line agent-river-max-entries)
      (delete-region (point) (point-max)))))

(defun agent-river--follow (buffer)
  "Keep every window showing BUFFER pinned to the head.
Newest first means there is nothing to tail: the state block and the
latest event are both at the top, and stay put as the log grows."
  (dolist (window (get-buffer-window-list buffer nil t))
    (set-window-point window (with-current-buffer buffer (point-min)))
    (set-window-start window (with-current-buffer buffer (point-min)))))

;;;###autoload
(defun agent-river-log (kind detail &optional label)
  "Append DETAIL to the HUD as an event of KIND, tagged with session LABEL.
This is the view half, usable on its own; `agent-river-observe' is the
half that also folds."
  (let ((buffer (agent-river--buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        ;; Newest first, block on top.  Tear the block down, put the new
        ;; line at the head of the log, trim the tail, rebuild the block --
        ;; so the two things worth seeing never move and never scroll away.
        (agent-river--erase-block)
        (goto-char (point-min))
        (insert (agent-river--render kind detail label) "\n")
        (agent-river--trim)
        (agent-river--insert-block)))
    (when (and agent-river-auto-display
               (not (get-buffer-window buffer t)))
      (agent-river-show))
    (agent-river--follow buffer)
    kind))

;;;###autoload
(defun agent-river-show ()
  "Display the HUD in a side window on the right."
  (interactive)
  (display-buffer (agent-river--buffer)
                  `((display-buffer-in-side-window)
                    (side . right)
                    (slot . 0)
                    (window-width . ,agent-river-window-width)
                    (window-parameters . ((no-delete-other-windows . t))))))

;;;###autoload
(defun agent-river-clear ()
  "Empty the HUD buffer.  The folded state is left alone."
  (interactive)
  (with-current-buffer (agent-river--buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      ;; The marker pointed into what was just erased.
      (setq agent-river--block-end nil))))

;;;###autoload
(defun agent-river-reset ()
  "Forget all folded state.  The buffer is left alone."
  (interactive)
  (clrhash agent-river-registry)
  (agent-river--stop-timer))

;;;###autoload
(defun agent-river-status ()
  "Show every folded session in a readable buffer.

The queries are otherwise reachable only by evaluating Elisp, which puts
the state out of reach of exactly the onlookers it was built for."
  (interactive)
  (let ((out (get-buffer-create "*agent-river-status*")))
    (with-current-buffer out
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (if (zerop (hash-table-count agent-river-registry))
            (insert "No sessions folded yet.\n")
          (maphash
           (lambda (key state)
             (unless (agent-river-state-parent state)
               (let ((report (agent-river-report key)))
                 (insert (propertize (format "%s  [%s]\n"
                                             (agent-river-state-label state) key)
                                     'face 'agent-river-session))
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
           agent-river-registry))
        (goto-char (point-min))))
    (display-buffer out)))

;;;###autoload
(defun agent-river-who-touches (path)
  "Report which sessions have touched PATH.
The contention check, made reachable without writing Lisp."
  (interactive "sFile name: ")
  (let ((hits (agent-river-touching path)))
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

(defvar agent-river--timer nil
  "Repeating timer redrawing the state block, or nil while none runs.")

(defun agent-river--working-p ()
  "Return non-nil while some agent is actually mid-task.

Deliberately narrower than `agent-river--active-p': a session that has
ended its turn is still live, but nothing is happening in it, and a clock
ticking over an idle agent claims work that is not being done.  It also
means the timer stops on its own between turns instead of running for as
long as Emacs does."
  (let (working)
    (maphash (lambda (_key state)
               (when (and (agent-river--active-p state)
                          (not (agent-river-state-idle state)))
                 (setq working t)))
             agent-river-registry)
    working))

(defun agent-river--redraw-block ()
  "Redraw the state block in place, leaving the log untouched."
  (let ((buffer (get-buffer agent-river-buffer-name)))
    ;; get-buffer, not agent-river--buffer: a tick must never resurrect a
    ;; buffer the user has killed.
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (save-excursion
            (agent-river--erase-block)
            (agent-river--insert-block)))))))

(defun agent-river--stop-timer ()
  "Stop the refresh timer."
  (when (timerp agent-river--timer)
    (cancel-timer agent-river--timer))
  (setq agent-river--timer nil))

(defun agent-river--tick ()
  "Redraw the block, or stop the timer once no agent is working."
  (condition-case err
      (if (agent-river--working-p)
          (agent-river--redraw-block)
        (agent-river--stop-timer))
    ;; A timer that throws every second would bury Emacs in messages, so a
    ;; broken redraw retires itself rather than repeating.
    (error (agent-river--stop-timer)
           (message "agent-river: refresh stopped (%s)"
                    (error-message-string err)))))

(defun agent-river--ensure-timer ()
  "Start the refresh timer if work is in progress and none runs."
  (when (and (null agent-river--timer) (agent-river--working-p))
    (setq agent-river--timer
          (run-at-time agent-river-refresh-interval
                       agent-river-refresh-interval
                       #'agent-river--tick))))

;;; Heat and pulse, rendered into dired
;;
;; A second view of the same state.  The panel names the hottest file; this
;; puts that reading where the files actually are, so a dired buffer shows at
;; a glance which entries the current task is living in.
;;
;; Nothing here folds.  The shading is derived from the artifact tables on
;; every redraw, exactly as the panel is, so the two cannot drift -- and the
;; fold stays pure, which is what lets the tests run with no frame and no
;; dired buffer in sight.
;;
;; The lookup runs from the *buffer* to the state rather than the other way
;; round, and that is the whole trick.  State paths are normalised by
;; `agent-river--rel' -- relative to the session cwd, a bare basename outside
;; it -- so they deliberately cannot address a file on disk.  A dired buffer
;; already holds the absolute side; asking it "how hot is this entry" needs
;; only the basename, which is the key `agent-river-touching' already matches
;; on and what keeps a worktree and its main checkout reading as one file.
;;
;; Kept as one contiguous block, faces included, rather than filed into the
;; sections above: it is the only part of this package that writes into
;; buffers the user did not point at it, and that should stay easy to remove.

(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))
(declare-function dired-goto-file "dired" (file))
(declare-function dired-move-to-filename "dired" (&optional raise-error eol))
(declare-function dired-move-to-end-of-filename "dired" (&optional no-error))
(declare-function pulse-momentary-highlight-region "pulse" (start end &optional face))

(defface agent-river-heat-1
  '((((background light)) :background "#edf2fa")
    (((background dark))  :background "#1c232e"))
  "Face for a dired entry the agent has touched once.")

(defface agent-river-heat-2
  '((((background light)) :background "#dbe4f3")
    (((background dark))  :background "#26334a"))
  "Face for a dired entry the agent keeps coming back to.")

(defface agent-river-heat-3
  '((((background light)) :background "#f7e2c9" :weight bold)
    (((background dark))  :background "#4a3724" :weight bold))
  "Face for the dired entry the agent is living in.")

(defcustom agent-river-heat-levels
  '((6 . agent-river-heat-3)
    (3 . agent-river-heat-2)
    (1 . agent-river-heat-1))
  "Touch counts and the face each earns, highest threshold first.
Read top down and the first match wins, so the order is load-bearing;
a count below every threshold gets no face and no overlay at all."
  :type '(alist :key-type integer :value-type face))

(defcustom agent-river-heat-scope 'task
  "Which artifact frame the shading is read from.

`task' answers \"what is this turn about\" and is cleared by every new
prompt, which is what the panel shows.  `session' answers \"what has this
agent been in all afternoon\".  They are different questions and the
package refuses to blur them anywhere else, so the choice is explicit
here too rather than being whichever frame was convenient."
  :type '(choice (const task) (const session)))

;; Defined before the functions that read it, so the byte-compiler sees the
;; variable rather than taking it for a free one.
;;;###autoload
(define-minor-mode agent-river-heat-mode
  "Shade dired entries by how often the agent has touched them.

Off by default, and a mode rather than a variable, because this is the one
thing in the package that writes into buffers the user did not point it
at: turning it on is the consent, and turning it off has to take the
overlays with it."
  :global t
  (if agent-river-heat-mode
      (progn
        (add-hook 'agent-river-observers #'agent-river--dired-observe)
        (add-hook 'dired-after-readin-hook #'agent-river--heat-after-readin)
        (agent-river-heat-refresh))
    (remove-hook 'agent-river-observers #'agent-river--dired-observe)
    (remove-hook 'dired-after-readin-hook #'agent-river--heat-after-readin)
    (dolist (buffer (agent-river--dired-buffers t))
      (agent-river--heat-clear buffer))))

(defun agent-river--heat-table (&optional scope)
  "Return a hash of basename to touch count across every folded session.

Aggregated rather than kept per session on purpose: one file that two
agents are both in is the case worth seeing, and summing them is the same
reading `agent-river-touching' gives.  SCOPE is `session' for the whole
session, `task' or nil for the current task."
  (let ((table (make-hash-table :test 'equal)))
    (maphash
     (lambda (_id state)
       (maphash (lambda (path entry)
                  (let ((name (file-name-nondirectory path)))
                    (puthash name
                             (+ (or (gethash name table) 0)
                                (or (plist-get entry :touches) 0))
                             table)))
                (if (eq scope 'session)
                    (agent-river-state-artifacts state)
                  (agent-river-state-task-artifacts state))))
     agent-river-registry)
    table))

(defun agent-river--heat-face (touches)
  "Return the face a file touched TOUCHES times earns, or nil for none."
  (cdr (seq-find (lambda (cell) (>= touches (car cell)))
                 agent-river-heat-levels)))

(defun agent-river--heat-clear (buffer)
  "Remove every heat overlay this package put into BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (remove-overlays (point-min) (point-max) 'agent-river-heat t))))

(defun agent-river--heat-bounds ()
  "Return the (BEG . END) of the filename on this line, or nil.
Only the name is shaded, not the whole line: the permissions and size
columns are dired's, and colouring them would read as dired saying
something rather than as this package annotating it."
  (let ((beg (dired-move-to-filename))
        (end (dired-move-to-end-of-filename t)))
    (and beg end (cons beg end))))

(defun agent-river--heat-dired (buffer table)
  "Shade the entries of dired BUFFER by their touch count in TABLE."
  (with-current-buffer buffer
    (agent-river--heat-clear buffer)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        ;; Walking the listing, rather than looking each state path up with
        ;; `dired-goto-file', is what makes the mismatch cases harmless: the
        ;; header and total lines simply yield no filename, and a file the
        ;; agent has just created is an entry that is not there yet.
        (let* ((name (ignore-errors (dired-get-filename 'no-dir t)))
               (face (and name (agent-river--heat-face
                                (or (gethash name table) 0))))
               (bounds (and face (agent-river--heat-bounds))))
          (when bounds
            (let ((overlay (make-overlay (car bounds) (cdr bounds))))
              (overlay-put overlay 'agent-river-heat t)
              (overlay-put overlay 'face face)
              (overlay-put overlay 'evaporate t))))
        (forward-line 1)))))

(defun agent-river--dired-buffers (&optional all)
  "Return the dired buffers worth drawing into.

Only those on screen unless ALL: overlays in a buffer nobody is looking
at are work done for no one, and a long session accumulates dired buffers.
`dired-after-readin-hook' catches the rest as they are listed or reverted.
ALL is for tearing the shading down, which has to reach every buffer that
might still be holding an overlay."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (and (derived-mode-p 'dired-mode)
                       (or all (get-buffer-window buffer t)))))
              (buffer-list)))

;;;###autoload
(defun agent-river-heat-refresh ()
  "Redraw the touch shading in every visible dired buffer.
Unconditional, unlike the automatic path: asking for it is asking for it,
whether or not `agent-river-heat-mode' is driving the redraws."
  (interactive)
  (let ((table (agent-river--heat-table agent-river-heat-scope)))
    (dolist (buffer (agent-river--dired-buffers))
      (agent-river--heat-dired buffer table))))

(defun agent-river--heat-after-readin ()
  "Reapply the shading to a dired buffer that was just listed or reverted.
A revert replaces the buffer text and takes every overlay with it, so
without this the shading vanishes at exactly the moment dired refreshes to
show what the agent has written."
  (when agent-river-heat-mode
    (agent-river--heat-dired (current-buffer)
                             (agent-river--heat-table agent-river-heat-scope))))

;; The pulse is event-level, where the heat is state-level.  Heat answers
;; "what is this task about"; the pulse answers "what happened just now",
;; which is a property of the event and of nothing else -- so it rides on
;; `:path', the absolute name carried beside the normalised `:file' and never
;; folded.
;;
;; pulse.el supports exactly one highlight at a time, and not by oversight:
;; `pulse-momentary-highlight-overlay' opens by unhighlighting whatever is
;; running, keeps one global overlay, and animates the background of one
;; global face.  An agent editing four files in a turn would not pulse four
;; times, it would restart a single animation four times and finish none of
;; them.  So the pulse stays the small half of this deliberately: one file,
;; the one this event names, and the heat carries everything that has to be
;; readable at once.

(defun agent-river--pulse-dired (path)
  "Pulse PATH's entry in the first visible dired buffer that lists it."
  (when (and path (require 'pulse nil t))
    (catch 'pulsed
      (dolist (buffer (agent-river--dired-buffers))
        (with-current-buffer buffer
          (save-excursion
            ;; dired-goto-file takes the absolute name and answers nil when
            ;; the file is not in this listing, which is also the answer for
            ;; a file the agent created a moment ago.
            (when (ignore-errors (dired-goto-file path))
              (let ((bounds (agent-river--heat-bounds)))
                (when bounds
                  (pulse-momentary-highlight-region
                   (car bounds) (cdr bounds) 'agent-river-heat-3)
                  (throw 'pulsed buffer))))))))))

(defun agent-river--dired-observe (_state event)
  "Draw EVENT into the dired views: heat from the state, a pulse from EVENT.

Takes no mode check of its own: being on `agent-river-observers' is what
switched it on, and the runner is what takes it off again.  STATE is
ignored because the heat is aggregated across every session rather than
read from the one that just acted -- two agents in one file is the case
worth seeing."
  (agent-river-heat-refresh)
  ;; Only an act names a file that was touched at that moment; a think or a
  ;; fail reports on a call whose pulse has already been shown.
  (when (equal (plist-get event :kind) "act")
    (agent-river--pulse-dired (plist-get event :path))))

;; Removal is not enough of a retirement here: the overlays would stay where
;; they are, and `agent-river-heat-mode' would keep claiming to be on.
(put 'agent-river--dired-observe 'agent-river-retire
     (lambda () (agent-river-heat-mode -1)))

(provide 'agent-river)
;;; agent-river.el ends here
