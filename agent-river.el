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
(require 'outline)

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

(defcustom agent-river-answering-kinds '("act" "fail")
  "Event kinds whose hook is wired synchronously and can carry a signal.

Only a synchronous hook's stdout is read, so only those events can put an
observation into the agent's context.  An observation produced on any
other event is written into a pipe nobody reads -- and worse, it used to
be logged and counted as though it had arrived, which made the `signals'
tally state something false about the one thing it exists to measure.

The direction is deliberate: this list decides which events may answer,
and the hook wiring must then mark exactly those as not `async'.  The
config cannot be read from here, so the two are kept in step by the
invariant rather than by inspection.  Add a kind here only after making
its hook synchronous."
  :type '(repeat string))

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

(defcustom agent-river-panel-detail-files 8
  "How many artifacts a session's unfolded `files' heading lists.
The list is ordered by touch count, so the tail is the least interesting;
an ellipsis marks the files that were left off."
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
  ;; The absolute working directory the hook reported, which is the anchor
  ;; `artifacts' is keyed against.  Kept beside the keys rather than folded
  ;; into them: a key stays relative, so one file reached from a worktree and
  ;; from the main checkout is still one artifact, and a view that needs to
  ;; place a key in a real directory tree combines the two deliberately.
  cwd
  parent            ; key of the session that spawned this one, nil at a root
  agent-type        ; "Explore", "general-purpose", ... nil at a root
  started last-seen ; last-seen is the liveness clock a registry needs
  task task-started ; the current prompt, and when it arrived
  step steps        ; the in-flight step, and how many this turn
  artifacts         ; hash: path -> (:touches N :last TIME), whole session
  task-artifacts    ; the same, but cleared by each new prompt
  tools             ; hash: tool -> (:count N :ms TOTAL :failures N)
  fail-streak       ; consecutive failures, reset by any success
  fail-runs         ; how many separate runs of failures, never reset
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

(declare-function agent-shell--project-name "agent-shell-project" ())
(declare-function agent-shell--format-buffer-name "agent-shell" (agent-name project-name))

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

(defvar agent-river--shell-seen nil
  "Non-nil once agent-shell has been seen hosting a session here.

Sticky on purpose, where `agent-river--shell-hosted-p' is a snapshot of the
buffers alive right now.  Liveness takes the buffer as authoritative only
when agent-shell is in play -- but asking \"is one hosting *now*\" makes the
last buffer's death flip the answer, and every state it left behind falls
back to the TTL.  A session that `agent-shell-restart' killed then reads as
active for the whole TTL, so its panel line lingers, unopenable.  Seen once,
agent-shell stays the authority for as long as this Emacs runs.")

(defun agent-river--shell-default-name (buffer)
  "Return the name agent-shell would give BUFFER, or nil.
Reconstructed with agent-shell's own formatter rather than guessed
at, so a customised `agent-shell-buffer-name-format' is honoured --
the `\" @ \"' split cannot tell a default name from a renamed one, and
a rename may itself contain `\" @ \"'."
  (when (fboundp 'agent-shell--format-buffer-name)
    (with-current-buffer buffer
      (let ((config (alist-get :agent-config (bound-and-true-p agent-shell--state))))
        (agent-shell--format-buffer-name (alist-get :buffer-name config)
                                         (agent-shell--project-name))))))

(defun agent-river--shell-label (id)
  "Return the name agent-shell gives session ID, or nil.

The default name is reduced to the project part -- the numbering that
distinguishes two sessions in one directory is agent-shell's rather than
a second, parallel scheme of ours, and it is already numbered.  A buffer
the human renamed with `rename-buffer' no longer matches what
agent-shell's formatter would produce, and is taken whole: the new name
is what they want to see, whatever it looks like."
  (let ((buffer (agent-river--shell-buffer id)))
    (when buffer
      (let* ((name (buffer-name buffer))
             (default (agent-river--shell-default-name buffer))
             (at (string-match " @ " name)))
        (if (and at default
                 (equal (agent-river--label-base name)
                        (agent-river--label-base default)))
            (substring name (+ at 3))
          name)))))

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
                             :fail-runs 0
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
         (or agent-river--shell-seen (agent-river--shell-hosted-p)))
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
    ;; Folded rather than set where the state is addressed, so it keeps the
    ;; promise the docstring makes: replay the events and the anchor comes
    ;; back with them.  Refreshed on every event that carries one, because a
    ;; session that changes directory re-anchors its later keys and the two
    ;; must not disagree.  Events made inside Emacs -- a note, a signal --
    ;; carry none and leave it alone.
    (let ((cwd (plist-get event :cwd)))
      (when (and cwd (not (string-empty-p cwd)))
        (setf (agent-river-state-cwd state) (directory-file-name cwd))))
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
      ;; A failure that follows a success opens a new run.  Counted because
      ;; the streak value alone cannot tell two runs apart: a session that
      ;; recovers and then fails three times again is in a new predicament,
      ;; not still in the old one, and an observation about it must not be
      ;; suppressed as a repeat of the first.  Never reset, so the id built
      ;; from it stays unique for the life of the session -- a new prompt
      ;; clears the streak but must not make old ids collide with new ones.
      (when (zerop (agent-river-state-fail-streak state))
        (setf (agent-river-state-fail-runs state)
              (1+ (or (agent-river-state-fail-runs state) 0))))
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
      ;; :id is what makes this list a delivery log rather than a tally --
      ;; `agent-river--signalled-p' reads it back to keep one observation
      ;; from being handed over twice.
      (push (list :at (current-time)
                  :text (plist-get event :text)
                  :id (plist-get event :id))
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
      ;; Only ever retires a subagent.  SubagentStop does carry an agent_id --
      ;; measured on 2026-09-13 by tracing the argv against the folded event,
      ;; where the done arrived addressed to the subagent's own key -- so this
      ;; guard no longer stands in for an unknown.  It stays because it still
      ;; holds the line that matters and costs nothing: were the event ever to
      ;; address a root key, marking a live session finished would poison
      ;; every reading taken from it.
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

(defun agent-river--answerable-p (state)
  "Return non-nil when an observation folded into STATE can reach an agent.

Measured rather than assumed.  A subagent's hook call carries its parent's
session id and its own agent_id, `PostToolUseFailure' is wired
synchronously, and `agent-river-hook' duly writes `additionalContext' for
it -- and the text arrives nowhere.  Two subagents asked outright reported
never seeing it, a trace confirmed the signal was produced on a genuinely
synchronous hook rather than on a `think' refined into a `fail', and the
session transcript holds no sidechain entry containing it.

A signal produced for a subagent is therefore written into a pipe nobody
reads, and counting it in `signals' would repeat the very lie the gate on
`agent-river-answering-kinds' exists to stop: a tally whose whole purpose
is to make \"how often was the agent told something\" observable,
reporting conversations that never happened.

Dropped rather than redirected to the parent.  A child's failures are a
statement about a different subject, and minting it here would be this
function deciding what a parent should make of its children --
`agent-river-children' aggregates them on demand and says whose they are.

Claude Code as measured on 2026-09-13; nothing is known about whether
Codex or Gemini CLI behave the same way."
  (null (agent-river-state-parent state)))

(defun agent-river--signalled-p (state id)
  "Return non-nil when ID has already been handed to the agent in STATE.

The signals list doubles as the delivery log, which is what makes
\"exactly once\" answerable without a second slot that would have to be
kept in step with it."
  (seq-find (lambda (entry) (equal (plist-get entry :id) id))
            (agent-river-state-signals state)))

(defun agent-river--signal (state)
  "Return the observation STATE has earned as (:text S :id ID), or nil.

:text is kept to a single line with no control characters: the hook reads
it back through `emacsclient', whose printed representation of a plain
string is then parsed as JSON, and an embedded newline would break that.

:id names *what* is being reported rather than what was said about it, and
an id already in `signals' is not reported again.  Without it the throttle
keyed on the failure streak alone -- a number that does not move when the
agent merely acts -- so a single run of failures was re-delivered on every
tool call that followed it, which is the exact thing the throttle exists
to prevent.

The two do different jobs and both are needed: the throttle decides which
streaks are worth a word, the id decides that each of them gets one."
  (let* ((streak (agent-river-state-fail-streak state))
         ;; Which run, and how deep into it.  The run number is what keeps a
         ;; later stretch of three failures from being mistaken for the
         ;; earlier one; the streak is what earns each of 3, 6, 9 its own word
         ;; within a run.
         (id (list 'streak (or (agent-river-state-fail-runs state) 0) streak)))
    (when (and (>= streak agent-river-fail-streak-threshold)
               (zerop (mod (- streak agent-river-fail-streak-threshold)
                           agent-river-fail-streak-repeat))
               (not (agent-river--signalled-p state id)))
      (let ((tools (mapconcat (lambda (cell) (format "%s x%d" (car cell) (cdr cell)))
                              (reverse (agent-river-state-fail-tools state))
                              ", "))
            (since (and (agent-river-state-task-started state)
                        (agent-river--ago (agent-river-state-task-started state))))
            (hot (agent-river--hottest state)))
        (list :id id
              :text
              (concat
               (format "agent-river: %d consecutive tool failures (%s)" streak tools)
               (if since (format ", %s into the current task" since) "")
               (if hot (format ". Most-revisited file: %s" hot) "")
               ". This is an observation, not an instruction -- weigh it against"
               " what you know; repeated failure is sometimes the right path."))))))


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
  (let ((dir (and cwd (not (string-empty-p cwd)) (file-name-as-directory cwd))))
    (if (and dir (string-prefix-p dir path))
        ;; Measured off the slash-terminated form, not off CWD plus one: a
        ;; cwd that already ends in a slash then had a character too many
        ;; cut, which silently ate the first letter of the top component --
        ;; `common/Foo.java' arriving as `ommon/Foo.java'.  Harmless while
        ;; only a basename was ever read back; not once the key has to place
        ;; the file in a directory tree.
        (substring path (length dir))
      (file-name-nondirectory path))))

(defun agent-river--dur (ms)
  "Format MS compactly."
  (if (>= ms 1000)
      (concat (replace-regexp-in-string
               "\\.0\\'" "" (format "%.1f" (/ (float ms) 1000)))
              "s")
    (format "%dms" ms)))

(defun agent-river--arg (input key)
  "Return INPUT's KEY when it is a non-empty string, else nil.
Guards the ladder below against a host that gives an argument another
shape: Codex passes `command' as a vector of words, and handing that to
a string function would throw inside the hook -- losing the whole event
to save a few characters of a log line."
  (let ((value (and (consp input) (alist-get key input))))
    (and (stringp value) (not (string-empty-p value)) value)))

(defun agent-river--tool-file (input)
  "Return the file path named in tool INPUT, whichever host named it.
Claude Code and Codex say `file_path', Gemini CLI says `absolute_path'
for a read and `file_path' for a write, and several tools say plain
`path'.  An agent-shell session adds `filePath' and `filepath' -- the ACP
`rawInput' for a Claude edit carries the target under the camel-case
`filePath', which the snake-case ladder missed, so every edit went
uncounted and the dired heat stayed cold.  `fileName' is what a
Copilot-style diff names.  The artifact tables are keyed on this, so a
name we did not know would not fail -- it would quietly stop counting
files, which is the failure mode this whole file is written against."
  (seq-some (lambda (key) (agent-river--arg input key))
            '(file_path filePath filepath absolute_path path fileName)))

(defun agent-river--salient (input cwd)
  "Return the argument of tool INPUT worth showing, given CWD.
Ordered most- to least-specific.  A description comes before a command
deliberately: Bash and Task carry a human-written line saying what the
call is for, which reads better than the shell it expands to."
  (let ((width agent-river-detail-width)
        (file (agent-river--tool-file input)))
    (cond
     ((not (consp input)) "")
     (file (agent-river--rel file cwd))
     ((agent-river--arg input 'description)
      (agent-river--clip (agent-river--squish (agent-river--arg input 'description)) width))
     ((agent-river--arg input 'command)
      (agent-river--clip (agent-river--squish (agent-river--arg input 'command)) width))
     ((agent-river--arg input 'pattern)
      (agent-river--clip (agent-river--squish (agent-river--arg input 'pattern)) width))
     ((agent-river--arg input 'code)
      (agent-river--clip (agent-river--squish (agent-river--arg input 'code)) width))
     ((agent-river--arg input 'url)
      (agent-river--clip (agent-river--arg input 'url) width))
     ;; Keeps unknown and MCP tools legible rather than blank.
     (input (agent-river--clip (json-serialize input) width))
     (t ""))))

(defun agent-river--failed-p (payload)
  "Non-nil when PAYLOAD's tool response says the call did not succeed.

Only Claude Code has a hook event of its own for a failed tool call.  On
Codex and Gemini CLI the one post-tool event fires either way and the
outcome sits in `tool_response', so without this the failure streak --
the one measurement here that reads back to the agent -- could never
rise on those hosts.

Narrow on purpose.  `interrupted' is deliberately not a failure: the
user stopped the call, and counting that would have the HUD hold being
steered against the agent.  A tool that says nothing about its outcome
is taken at its word."
  (let ((response (alist-get 'tool_response payload)))
    (and (consp response)
         (or (alist-get 'error response)
             (eq t (alist-get 'is_error response))
             (eq t (alist-get 'isError response))
             ;; `false' and "absent" both parse to nil, so the key has to be
             ;; found before its value means anything.
             (let ((claim (assq 'success response)))
               (and claim (null (cdr claim))))
             ;; Codex reports a shell failure as an exit status and nothing
             ;; else; on the hosts that have a failure event of their own
             ;; this key is absent, so it cannot double-count.
             (let ((code (alist-get 'exit_code response)))
               (and (integerp code) (/= code 0))))
         t)))

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
so the view does not have to re-derive which argument mattered.

This is the one place that knows a host's dialect.  KIND still comes
from the config as an argv, so the hook-event to fold-event mapping
stays readable there; but a host without a failure event of its own
reports one as an ordinary post-tool call, and refining KIND here is
what keeps that from folding as a success."
  (let* ((input (alist-get 'tool_input payload))
         (cwd (or (alist-get 'cwd payload) ""))
         (file (agent-river--tool-file input))
         (kind (if (and (equal kind "think") (agent-river--failed-p payload))
                   "fail"
                 kind)))
    (list :kind kind
          :session (or (alist-get 'session_id payload) "unknown")
          :label (file-name-nondirectory (directory-file-name cwd))
          ;; The directory `:file' is relative to, folded so the state can
          ;; say where its keys are anchored.  The label is only the last
          ;; component of it and cannot stand in: two checkouts of one
          ;; project are labelled alike on purpose.
          :cwd cwd
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

(defvar agent-river--teardown-hooked (make-hash-table :test 'eq)
  "Shell buffers agent-river has put its teardown on, so it goes on once.")

(defun agent-river--shell-died (buffer)
  "Note BUFFER's session as gone and redraw the block.
Called from BUFFER's `kill-buffer-hook'.

`agent-shell-restart' kills the shell buffer and starts a new session with
a new id, so the state the old id folded to can no longer be jumped to --
and it is kept, not dropped, because `agent-river-status' still reports on
a session that has ended.  What must not survive is the *view*: the block
is drawn on the next event, and after a restart no event ever addresses
the old id again, so without this the line sits there inviting a RET that
can only fail.  The state is left to `agent-river--active-p', which already
calls a hosted session whose buffer is gone by what it is.

Deferred by a tick, because `kill-buffer-hook' runs while the buffer is
still live: redrawn inline, `agent-river--shell-buffer' would still find
the dying buffer and draw the session straight back in."
  (remhash buffer agent-river--teardown-hooked)
  (run-at-time 0 nil #'agent-river--redraw-block))

(defun agent-river--ensure-shell-teardown (id)
  "Ensure BUFFER's session teardown is installed for session ID at most once.
Where agent-shell hosts ID, its buffer dying is how a restart or a kill
reaches us -- no hook event reports it, and a watched session sees only
`clean-up', which folds nothing."
  (let ((buffer (agent-river--shell-buffer id)))
    (when buffer
      (setq agent-river--shell-seen t)
      (unless (gethash buffer agent-river--teardown-hooked)
        (puthash buffer t agent-river--teardown-hooked)
        (with-current-buffer buffer
          (add-hook 'kill-buffer-hook
                    (apply-partially #'agent-river--shell-died buffer)
                    nil t))))))


;;; A second way in, for sessions no hook reaches
;;
;; Claude Code, Codex and Gemini CLI report themselves through hooks.  The
;; other agents agent-shell hosts do not -- but agent-shell already reads
;; their ACP stream, and publishes what it learns through
;; `agent-shell-subscribe-to', which is a documented API rather than
;; something read over its shoulder.  Three of its events carry what the
;; fold wants: `input-submitted' the prompt, `tool-call-update' a step with
;; its status and its raw arguments, `turn-complete' the end of the turn.
;;
;; So this path translates them into the payload shape the hooks report and
;; hands that to `agent-river--event' -- the same adapter, not a second one.
;; A file argument that path learns to count is then counted here too, and
;; nothing downstream ever learns that a second source exists.
;;
;; Two things it cannot do.  It cannot talk back: a signal still reaches the
;; buffer, but there is no `additionalContext' on a stream we only listen
;; to.  And ACP has no notion of a subagent, so a delegated task folds as
;; one step of its parent rather than as a session of its own.

(defvar agent-river--source (make-hash-table :test 'equal)
  "Session id -> the way in that owns it, `hooks' or `shell'.")

(defun agent-river--claim (session source)
  "Return non-nil when SOURCE may fold SESSION, claiming it if it is free.

Both ways in describe the same session -- the hooks report what the CLI
did, agent-shell reports what its ACP stream said -- so folding both
would count every step twice.  That is not merely untidy: a doubled
failure streak states a fact that is false, to the agent itself.

The hooks win, because only they can carry an observation back.  A
watched session that turns out to have hooks is given up whole rather
than interleaved: what the stream folded is dropped, and the hooks build
it again from their first event."
  (let ((owner (gethash session agent-river--source)))
    (cond
     ((or (null owner) (eq owner source))
      (puthash session source agent-river--source)
      t)
     ((eq source 'hooks)
      (puthash session source agent-river--source)
      (remhash session agent-river-registry)
      (agent-river-log "signal" "hooks reach this session; folding those instead"
                       (agent-river--shell-label session))
      t))))

(defvar agent-river--tool-calls (make-hash-table :test 'equal)
  "\"SESSION\\0CALL-ID\" -> when that tool call was first seen.

A tool call is announced once and then updated, so this is what keeps
one step from being counted at every status change -- and what makes a
duration out of two sightings, which the stream does not carry.

Deliberately not a slot on `agent-river-state', for the same reason
`agent-river--thought-runs' is not one: nothing folds it, and a reload
would otherwise demand `agent-river-reset'.")

(defun agent-river--shell-payload (call session cwd &optional ms)
  "Return tool CALL of SESSION in the shape the hooks report, given CWD.
MS is how long the call took, where that is known.

Same shape on purpose.  `agent-river--event' is the one place that
resolves a host's dialect, and a second event builder here would be a
second place for a file argument to go uncounted.

ACP names no tool, so the call's `kind' -- read, edit, execute and a
handful more -- stands in for one.  Coarser than a tool name and stabler
than the title, which is free text; the tallies want a small vocabulary,
and the title reads better on the log line, which it reaches as a
description when the call carries no arguments worth showing."
  (let ((input (or (alist-get :raw-input call)
                   (when (alist-get :title call)
                     `((description . ,(alist-get :title call)))))))
    (append `((session_id . ,session)
              (cwd . ,cwd)
              (tool_name . ,(or (alist-get :kind call) "tool"))
              (tool_input . ,input))
            (when ms `((duration_ms . ,ms))))))

(defun agent-river--shell-events (event session cwd)
  "Return the events agent-shell's EVENT amounts to for SESSION, given CWD.

EVENT is what `agent-shell-subscribe-to' hands a subscriber.  Most
amount to one; a tool call first seen in a terminal state amounts to
two, because a step has to be counted before it can be reported as
over -- which is exactly what `PreToolUse' and `PostToolUse' do."
  (let ((data (alist-get :data event)))
    (pcase (alist-get :event event)
      ('input-submitted
       (list (agent-river--event
              "prompt" `((session_id . ,session) (cwd . ,cwd)
                         (prompt . ,(or (alist-get :prompt data) ""))))))
      ('turn-complete
       ;; Nothing outlives the turn it was called in, so a call that never
       ;; reported an end is dropped here rather than kept for ever.
       (agent-river--forget-tool-calls session)
       (list (agent-river--event
              "idle" `((session_id . ,session) (cwd . ,cwd)))))
      ('tool-call-update
       (let* ((call (alist-get :tool-call data))
              (key (format "%s\0%s" session (alist-get :tool-call-id data)))
              (started (gethash key agent-river--tool-calls))
              (ended (pcase (alist-get :status call)
                       ("completed" "think")
                       ("failed" "fail")))
              events)
         (unless started
           (setq started (current-time))
           (puthash key started agent-river--tool-calls)
           (push (agent-river--event
                  "act" (agent-river--shell-payload call session cwd))
                 events))
         (when ended
           (remhash key agent-river--tool-calls)
           (push (agent-river--event
                  ended (agent-river--shell-payload
                         call session cwd
                         (round (* 1000 (float-time
                                         (time-subtract (current-time)
                                                        started))))))
                 events))
         (nreverse events))))))

(defun agent-river--forget-tool-calls (session)
  "Drop what is remembered about SESSION's tool calls in flight."
  (let (stale)
    (maphash (lambda (key _)
               (when (string-prefix-p (concat session "\0") key)
                 (push key stale)))
             agent-river--tool-calls)
    (mapc (lambda (key) (remhash key agent-river--tool-calls)) stale)))

(defun agent-river--shell-session ()
  "Return the ACP session id of the agent-shell buffer, or nil.
Read per event rather than once at subscription: a shell buffer exists
before its session does."
  (and (agent-river--shell-buffer-p)
       (alist-get :id (alist-get :session (bound-and-true-p agent-shell--state)))))

(defun agent-river--shell-observe (event)
  "Fold agent-shell's EVENT for the session of the current buffer."
  (let ((session (agent-river--shell-session)))
    (when (and session (agent-river--claim session 'shell))
      (dolist (one (agent-river--shell-events
                    event session (directory-file-name
                                   (expand-file-name default-directory))))
        (agent-river-observe one)))))

(defvar-local agent-river--watching nil
  "This buffer's agent-shell subscription token, while it is watched.")

;;;###autoload
(defun agent-river-watch-shell (&optional buffer)
  "Fold BUFFER's agent-shell session from the stream agent-shell reads.

For the agents whose hooks are not wired to `agent-river-hook.sh'.  A
session that does run hooks needs nothing: they take it over on their
first event, and this path lets them (`agent-river--claim').

Idempotent, and a no-op outside an agent-shell buffer."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (when (and (agent-river--shell-buffer-p)
               (null agent-river--watching)
               (fboundp 'agent-shell-subscribe-to))
      (let ((shell (current-buffer)))
        (setq agent-river--watching
              (agent-shell-subscribe-to
               :shell-buffer shell
               :on-event
               (lambda (event)
                 ;; Never let the HUD break the shell it rides on -- but
                 ;; never go quiet either.
                 (condition-case err
                     (with-current-buffer shell
                       (agent-river--shell-observe event))
                   (error
                    (ignore-errors
                      (agent-river-log
                       "fail" (format "shell fold failed: %s"
                                      (error-message-string err)))))))))))))

;;;###autoload
(defun agent-river-unwatch-shell (&optional buffer)
  "Stop folding BUFFER's agent-shell session from the stream."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (when (and agent-river--watching (fboundp 'agent-shell-unsubscribe))
      (agent-shell-unsubscribe :subscription agent-river--watching)
      (setq agent-river--watching nil))))

;;;###autoload
(define-minor-mode agent-river-watch-mode
  "Fold every agent-shell session from the stream, hooks or no hooks.

What to turn on when the agent has no hook wiring at all.  Sessions that
do report through hooks are unaffected: the hooks own them, so this only
ever supplies the sessions the first way in cannot reach."
  :global t
  :group 'agent-river
  (if agent-river-watch-mode
      (progn
        (add-hook 'agent-shell-mode-hook #'agent-river-watch-shell)
        (mapc #'agent-river-watch-shell (buffer-list)))
    (remove-hook 'agent-shell-mode-hook #'agent-river-watch-shell)
    (mapc #'agent-river-unwatch-shell (buffer-list))))


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
    ;; subscription has to exist before the first thought is streamed.  Its
    ;; buffer dying is likewise how a restart reaches us, and no hook event
    ;; says so.
    (agent-river--ensure-subscribed session)
    (agent-river--ensure-shell-teardown session)
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
      ;; Only ask for an observation on an event that can actually deliver
      ;; one.  Computing it regardless meant a fail streak still standing when
      ;; the turn ended produced a signal on `idle' -- whose hook is async, so
      ;; its stdout is never read.  It was logged and folded all the same, and
      ;; the `signals' count then claimed the agent had been told twice what
      ;; it had been told once.  A tally that exists to make "how often was
      ;; the agent told something" observable must not be the thing that
      ;; misreports it.
      (let ((signal (and (member kind agent-river-answering-kinds)
                         (agent-river--answerable-p state)
                         (agent-river--signal state))))
        (when signal
          ;; Through the fold, not around it.  This used to push straight onto
          ;; the slot, which made `agent-river-observe' a second writer to a
          ;; state the fold is supposed to own alone -- and left the fold's
          ;; promise that a state can be rebuilt by replaying its events true
          ;; only by accident, because a signal happens to be derivable.
          (agent-river-fold state (list :kind "signal"
                                        :text (plist-get signal :text)
                                        :id (plist-get signal :id)))
          (agent-river-log "signal" (plist-get signal :text) label))
        ;; Only the text goes back to the agent; the id is bookkeeping.
        (plist-get signal :text)))))


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
            (let* ((event (agent-river--event kind payload))
                   ;; The hooks own whatever session they report on, taking
                   ;; it back from the stream if it was being watched -- a
                   ;; session folded from both would count every step twice.
                   (_ (agent-river--claim (plist-get event :session) 'hooks))
                   (signal (agent-river-observe event))
                   (name (alist-get 'hook_event_name payload)))
              (when (and signal name)
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
(defun agent-river-note (text &optional id path)
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

PATH, when given, is the absolute name of a file the note is *about*.  It
is carried on the event exactly as `:path' is on a hook event -- beside
the fold, never in it: the `note' branch stores the text and the time and
nothing else, and the artifact tables are left alone, so a note can never
warm a file the agent did not touch.  It is there for observers that need
to reach the file on disk, which is how a foreign save can pulse its dired
entry without the note claiming the agent acted on it.

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
            (event (list :kind "note" :text text :session key :path path)))
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
               :fail-runs (or (agent-river-state-fail-runs state) 0)
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

;;; Handing the state out -- Markdown, for where it is going to be read
;;
;; The one place Markdown belongs in this package.  The HUD is deliberately
;; not rendered as Markdown and should stay that way: its log carries
;; prompts, reasoning and tool arguments -- text the package does not
;; control -- and Markdown would hand that text the power to restructure the
;; view that is watching it.  Here the state is *leaving*, and where it
;; lands -- an issue, a pull request, a message -- Markdown is what gets
;; read.
;;
;; A third derivation of the state, beside the panel and the report, and not
;; built on either.  The report's values are already formatted for a human
;; reading a plist, and re-formatting a formatted string is the
;; second-account problem wearing a different hat.  What the report gets for
;; free from its key names -- `:task-hottest' against `:session-hottest' --
;; has to be done by hand here, so it is, and tested: two numbers on
;; different clocks sitting side by side unlabelled read as if they were
;; comparable.

(defun agent-river--md-escape (text)
  "Return TEXT with its Markdown-active punctuation neutralised.

For the values the agent wrote: a prompt, a stated intent.  They do not
stop being arbitrary text because the export is going somewhere Markdown
is read -- an intent containing an asterisk would silently italicise the
rest of the line, and one containing a bracket would swallow it into a
link.  This is the same hazard that keeps the HUD out of Markdown; here it
is small enough to escape, because only two values are the agent's."
  (replace-regexp-in-string "[][\\\\`*_<>&#|~]" "\\\\\\&" (or text "")))

(defun agent-river--md-code (text)
  "Return TEXT as a Markdown code span, fenced long enough to hold it.

A file name will almost never contain a backtick, and the one that does
must not be able to close the span it is sitting in and turn the rest of
the line into markup."
  (let ((longest 0))
    (dolist (run (split-string (or text "") "[^`]+" t))
      (setq longest (max longest (length run))))
    (let ((fence (make-string (1+ longest) ?`)))
      ;; CommonMark strips one space from each end, which is how a span
      ;; whose content touches a backtick is written.
      (if (zerop longest)
          (concat fence text fence)
        (concat fence " " text " " fence)))))

(defun agent-river--md-files (state scope)
  "Return STATE's artifacts in SCOPE as Markdown, or nil for none.

Capped by `agent-river-panel-detail-files' rather than by a setting of its
own: it is the same question the HUD's `files' heading asks, and two
answers would let a snapshot disagree with the view it is a snapshot of."
  (let* ((files (agent-river--artifact-list state scope))
         (shown (seq-take files agent-river-panel-detail-files)))
    (when files
      (concat (mapconcat (lambda (pair)
                           (format "%s ×%d"
                                   (agent-river--md-code (car pair)) (cdr pair)))
                         shown " · ")
              (if (> (length files) (length shown)) " · …" "")))))

(defun agent-river--md-child (child)
  "Return one Markdown line for subagent CHILD, indented under its parent.

Read off the child's own state rather than through
`agent-river--child-digest', whose `:hottest' is a string already
formatted for a plist a human reads.  Re-formatting that would mean taking
a file name back out of prose, and the name is the one thing on this line
that has to come out as a code span like every other name in the export."
  (let* ((steps (agent-river-state-steps child))
         (streak (agent-river-state-fail-streak child))
         (hottest (car (agent-river--artifact-list child 'session))))
    (format "    - %s — %s · %d step%s%s%s"
            (agent-river--md-code (or (agent-river-state-agent-type child) "agent"))
            (cond ((agent-river-state-done child) "done")
                  ((agent-river--active-p child) "running")
                  ;; Neither an end event nor recent activity: something went
                  ;; away without saying so, and the export should say that
                  ;; rather than quietly count it as running.
                  (t "stale"))
            steps (if (= steps 1) "" "s")
            (if hottest
                (format " · hottest %s ×%d"
                        (agent-river--md-code (car hottest)) (cdr hottest))
              "")
            (if (> streak 0) (format " · %d failing" streak) ""))))

(defun agent-river--md-session (state)
  "Return the Markdown for root STATE, its subagents folded in under it.

Subagents get no section of their own, exactly as they get no panel line:
their work is counted on the parent and aggregated on demand, so that the
two cannot drift."
  (let* ((kids (agent-river-children (agent-river-state-id state)))
         (task (agent-river-state-task state))
         (intent (agent-river-state-intent state))
         (streak (agent-river-state-fail-streak state))
         (phase (agent-river--phase state))
         lines)
    (push (format "### %s%s\n"
                  (agent-river--md-escape (or (agent-river-state-label state) "?"))
                  (if phase (format " — %s" phase) ""))
          lines)
    (when (and task (not (string-empty-p task)))
      (push (format "- **prompt** — %s" (agent-river--md-escape task)) lines))
    ;; The frame is in the name of the bullet, not left to the reader.  The
    ;; task tally resets with every prompt and the session tally does not.
    (push (format "- **this task** — %d step%s · %d failure%s%s%s"
                  (agent-river-state-steps state)
                  (if (= (agent-river-state-steps state) 1) "" "s")
                  (or (agent-river-state-task-failures state) 0)
                  (if (= (or (agent-river-state-task-failures state) 0) 1) "" "s")
                  (let ((started (agent-river-state-task-started state)))
                    (if started (concat " · " (agent-river--ago started)) ""))
                  (let ((files (agent-river--md-files state nil)))
                    (if files (concat " · " files) "")))
          lines)
    (push (format "- **this session** — %s%s"
                  (let ((started (agent-river-state-started state)))
                    (if started (agent-river--ago started) "just started"))
                  (let ((files (agent-river--md-files state 'session)))
                    (if files (concat " · " files) "")))
          lines)
    ;; A live failure run is the one thing a reader must not have to infer.
    (when (> streak 0)
      (push (format "- **failing** — %d in a row" streak) lines))
    ;; Last, and marked twice.  This is the agent talking about itself, and a
    ;; claim that a later reader takes for one of the measurements above it
    ;; is exactly the confusion the `intent' slots are kept apart to prevent.
    (when intent
      (push (format "- **claims** — %s *(self-reported%s)*"
                    (agent-river--md-escape intent)
                    (if (agent-river--intent-stale-p state) ", stale" ""))
            lines))
    ;; Only the halves that happened.  A tally reading "0 notes" is noise in
    ;; a snapshot someone is about to paste somewhere, and it makes the two
    ;; counts that did happen harder to find.
    (let* ((signals (length (agent-river-state-signals state)))
           (notes (length (agent-river-state-notes state)))
           (parts (delq nil
                        (list (when (> signals 0)
                                (format "%d observation%s"
                                        signals (if (= signals 1) "" "s")))
                              (when (> notes 0)
                                (format "%d note%s"
                                        notes (if (= notes 1) "" "s")))))))
      (when parts
        (push (concat "- **handed back** — " (string-join parts " · ")) lines)))
    (when kids
      (push (format "- **subagents** — %d of %d running · %d step%s"
                    (seq-count #'agent-river--active-p kids) (length kids)
                    (apply #'+ (mapcar #'agent-river-state-steps kids))
                    (if (= (apply #'+ (mapcar #'agent-river-state-steps kids)) 1)
                        "" "s"))
            lines)
      (dolist (child (sort kids (lambda (a b)
                                  (string< (or (agent-river-state-agent-type a) "")
                                           (or (agent-river-state-agent-type b) "")))))
        (push (agent-river--md-child child) lines)))
    (string-join (nreverse lines) "\n")))

;;;###autoload
(defun agent-river-markdown (&optional id)
  "Return the state as Markdown, or nil when there is nothing to say.

Every live root session, in the order and by the rule the state block
shows them, so this is a snapshot of that block and not a second opinion
about which sessions count.  ID narrows it to one."
  (let (states)
    (maphash (lambda (key state)
               (when (and (null (agent-river-state-parent state))
                          (agent-river--active-p state)
                          (or (null id) (equal key id)))
                 (push state states)))
             agent-river-registry)
    (when states
      (setq states (sort states (lambda (a b)
                                  (string< (or (agent-river-state-label a) "")
                                           (or (agent-river-state-label b) "")))))
      (concat (format "## agent-river — %d session%s, %s\n\n"
                      (length states) (if (= (length states) 1) "" "s")
                      (format-time-string "%Y-%m-%d %H:%M"))
              (mapconcat #'agent-river--md-session states "\n\n")
              "\n"))))

;;;###autoload
(defun agent-river-copy-report (&optional id)
  "Put the state on the kill ring as Markdown, and return it.

For where the state is going to be read rather than watched: an issue, a
pull request, a message.  Called with point on a session line in the HUD
it takes that session alone, which is what the line under the cursor is
for; anywhere else it takes them all.  ID overrides both."
  (interactive
   (list (get-text-property (line-beginning-position) 'agent-river-session)))
  (let ((markdown (agent-river-markdown id)))
    (unless markdown
      (user-error "No live session to report on"))
    (kill-new markdown)
    (when (called-interactively-p 'interactive)
      (message "Copied %s as Markdown"
               (if id (format "session %s" id) "the state")))
    markdown))


;;; The view

(define-derived-mode agent-river-mode special-mode "Agent-Focus"
  "Major mode for the agent attention HUD."
  ;; Tool lines fit the side window, but reasoning and signal lines are
  ;; prose and do not -- truncating them would hide most of what they say.
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local wrap-prefix (make-string 11 ?\s))
  ;; The block doubles as an outline: every session line and the eventlog
  ;; divider are level-1 headings, so `outline-cycle' (TAB) can fold the log
  ;; away and leave just the state.  The fold is for looking, not state: it
  ;; lives in overlays, and the block is erased and rebuilt on every fold,
  ;; so the next event naturally unfolds it again.
  (setq-local outline-regexp "^\\*+ ")
  (outline-minor-mode 1)
  ;; Explicitly none: the state used to live here, and a value left behind
  ;; by an older version of this file would sit frozen at the top of the
  ;; buffer, showing a step count and an elapsed time from whenever it was
  ;; last written.
  (setq-local header-line-format nil)
  (buffer-disable-undo))

(defvar-local agent-river--panel-expanded nil
  "When non-nil, the block unfolds each session's detail headings.

Kept as a buffer-local flag rather than left to outline overlay visibility,
because the block is erased and rebuilt on every event: an overlay fold
would spring open on the next tool call.  A flag means the block is simply
rendered already open, so the fold survives as long as the user wants it.")

(defun agent-river--artifact-list (state &optional scope)
  "Return STATE's artifacts as (NAME . TOUCHES), most-touched first.

NAME is the bare basename, summed the way `agent-river-touching' matches,
so a file reached from a worktree and from the main checkout counts once.
SCOPE is `session' for the whole session, nil for the current task."
  (let ((totals (make-hash-table :test 'equal)))
    (maphash (lambda (path entry)
               (let ((name (file-name-nondirectory path)))
                 (puthash name (+ (gethash name totals 0)
                                  (or (plist-get entry :touches) 0))
                          totals)))
             (if (eq scope 'session)
                 (agent-river-state-artifacts state)
               (agent-river-state-task-artifacts state)))
    (let (pairs)
      (maphash (lambda (name n) (push (cons name n) pairs)) totals)
      (sort pairs (lambda (a b) (> (cdr a) (cdr b)))))))

(defun agent-river--panel-details (state)
  "Return STATE's detail headings, one outline level below its block line.

The header condenses the numbers -- one artifact, and only sometimes, as a
parenthetical.  The `files' heading unfolds the same measurement at a finer
grain, never a second tally, so an onlooker can see which files the step
count is made of.  Most-touched first, so the header's parenthetical is
simply the head of this list.  Empty while nothing has been touched."
  (let ((files (agent-river--artifact-list state)))
    (when files
      (let* ((limit agent-river-panel-detail-files)
             (shown (seq-take files limit)))
        (list (format "** files: %s%s"
                      (mapconcat (lambda (pair)
                                   (format "%s %d" (car pair) (cdr pair)))
                                 shown " · ")
                      (if (> (length files) limit) " …" "")))))))

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
    ;; The `* ' at column zero makes the line an outline heading, so outline
    ;; navigation and `outline-cycle' (TAB) can treat the block as a
    ;; document.  It stays inside the make-visitable call so the whole line,
    ;; star included, is the visitable region: pressing RET on the star must
    ;; still jump to the session.
    ;;
    ;; Only the header is made visitable: the detail headings below it are a
    ;; finer reading of the same state, and RET on one of them jumping to the
    ;; session would be a link nobody asked for.
    ;; `agent-river-line' is marked on both kinds regardless of whether the
    ;; session turned out to be visitable: a line the motion can stop on and
    ;; a line RET can act on are different questions, and tying them together
    ;; made `n' skip every session agent-shell does not host.
    (let ((header (propertize
                   (agent-river--make-visitable
                    (concat "* " (mapconcat #'identity parts " · "))
                    (agent-river-state-id state))
                   'agent-river-line 'session))
          (details (and agent-river--panel-expanded
                        (mapcar (lambda (line)
                                  (propertize line 'agent-river-line 'detail))
                                (agent-river--panel-details state)))))
      (if details
          (concat header "\n" (mapconcat #'identity details "\n"))
        header))))

;;; Moving about the HUD
;;
;; The same three grains as the map, on the same keys, because they are the
;; same question asked of different content: every line worth stopping on,
;; the coarse structure alone, and the lines that want attention.  A session
;; line here is a map entry; a detail heading is a map file line; a log line
;; is what neither view has an analogue for and so takes the fine grain with
;; the entries.
;;
;; Which lines those are is read off `agent-river-line', marked where the
;; line is built.  Matching a regexp over the rendered text instead would
;; mean that changing how a line looks quietly changes what `n' stops on --
;; and the rendering here is customisable, so it would change under people.

(defcustom agent-river-notable-kinds '("fail" "signal" "note")
  "Event kinds `agent-river-next-notable' stops on.

The lines someone scanning a long log is looking for: what broke, what the
agent was told, and what was seen outside the hook stream.  Reasoning and
tool calls are the log's bulk rather than its landmarks, which is the whole
distinction this motion exists to make."
  :type '(repeat string))

(defun agent-river--entry-line-p ()
  "Return non-nil on a line any motion may stop on."
  (and (get-text-property (line-beginning-position) 'agent-river-line) t))

(defun agent-river--session-line-p ()
  "Return non-nil on a session line of the state block."
  (eq (get-text-property (line-beginning-position) 'agent-river-line) 'session))

(defun agent-river--notable-line-p ()
  "Return non-nil on a log line worth finding in a long log."
  (member (get-text-property (line-beginning-position) 'agent-river-kind)
          agent-river-notable-kinds))

(defun agent-river--beginning-of-entry ()
  "Put point past the outline stars on this line, if it has any.
A log line starts with its timestamp and is left alone; a heading's stars
are structure, and a cursor parked on one says nothing about the line."
  (goto-char (line-beginning-position))
  (when (looking-at "\\*+ ")
    (goto-char (match-end 0))))

(defun agent-river--scan (count test)
  "Move to the COUNTth line satisfying TEST, forward when COUNT is positive.
Returns nil and leaves point alone when there is none -- the same bargain
`agent-river--map-scan' makes, for the same reason: a motion that lands
somewhere near is one the next RET acts on by mistake."
  (let ((found nil)
        (step (if (> count 0) 1 -1))
        (left (abs count)))
    (save-excursion
      (catch 'done
        (while t
          (unless (zerop (forward-line step)) (throw 'done nil))
          (when (funcall test)
            (setq left (1- left))
            (when (zerop left)
              (setq found (point))
              (throw 'done nil))))))
    (when found
      (goto-char found)
      (agent-river--beginning-of-entry)
      t)))

(defun agent-river-next-line (&optional n)
  "Move to the Nth next session, detail or event line."
  (interactive "p")
  (or (agent-river--scan (or n 1) #'agent-river--entry-line-p)
      (user-error "No further line")))

(defun agent-river-previous-line (&optional n)
  "Move to the Nth previous session, detail or event line."
  (interactive "p")
  (agent-river-next-line (- (or n 1))))

(defun agent-river-next-session (&optional n)
  "Move to the Nth next session line, past its details and the log."
  (interactive "p")
  (or (agent-river--scan (or n 1) #'agent-river--session-line-p)
      (user-error "No further session")))

(defun agent-river-previous-session (&optional n)
  "Move to the Nth previous session line."
  (interactive "p")
  (agent-river-next-session (- (or n 1))))

(defun agent-river-next-notable (&optional n)
  "Move to the Nth next line of a kind in `agent-river-notable-kinds'."
  (interactive "p")
  (or (agent-river--scan (or n 1) #'agent-river--notable-line-p)
      (user-error "No further failure, signal or note")))

(defun agent-river-previous-notable (&optional n)
  "Move to the Nth previous line of a kind in `agent-river-notable-kinds'."
  (interactive "p")
  (agent-river-next-notable (- (or n 1))))

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
  "Return one panel line per live session, newest state first,
closed by the `* -- eventlog' heading that starts the log.

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
       ;; The block's closing line is itself a heading, so the log
       ;; underneath reads as its subtree: TAB folds the log away and
       ;; leaves just the state.
       (propertize "* -- eventlog" 'face 'agent-river-time)))))

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
                (make-string (+ 11 (if column (1+ (length column)) 0)) ?\s)
                ;; What the motion commands read.  Marked here rather than
                ;; matched by a regexp over the rendered text, so changing
                ;; how a line looks cannot quietly change what `n' stops on.
                'agent-river-line 'event
                'agent-river-kind kind)))

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

(defun agent-river--head-end ()
  "Return the end of the HUD's head: the state block and the newest event.
`agent-river--block-end' sits at the start of the newest log line, so the
head runs to the end of it -- somebody reading the top of the buffer is
reading the state and what just happened, and both should keep following."
  (save-excursion
    (goto-char (or (and (markerp agent-river--block-end)
                        (marker-position agent-river--block-end))
                   (point-min)))
    (line-end-position)))

(defun agent-river--following-windows (buffer)
  "Return the windows on BUFFER that are still showing its head.

Read before the buffer is touched, because the head is about to move.
Only these get pinned back afterwards: a window someone has scrolled or
navigated away from is one they moved on purpose, and snapping it to the
top on the next tool call makes the buffer unreadable by hand.  That is
what it used to do, which is why the motion commands had to arrive with
this."
  (with-current-buffer buffer
    (let ((head (agent-river--head-end)))
      (seq-filter (lambda (window) (<= (window-point window) head))
                  (get-buffer-window-list buffer nil t)))))

(defun agent-river--follow (buffer windows)
  "Pin WINDOWS on BUFFER back to the head.
Newest first means there is nothing to tail: the state block and the
latest event are both at the top, and stay put as the log grows."
  (dolist (window windows)
    (when (window-live-p window)
      (set-window-point window (with-current-buffer buffer (point-min)))
      (set-window-start window (with-current-buffer buffer (point-min))))))

;;;###autoload
(defun agent-river-log (kind detail &optional label)
  "Append DETAIL to the HUD as an event of KIND, tagged with session LABEL.
This is the view half, usable on its own; `agent-river-observe' is the
half that also folds."
  (let* ((buffer (agent-river--buffer))
         (shown (get-buffer-window buffer t))
         ;; Asked before the edit, because the edit moves the head.
         (following (agent-river--following-windows buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        ;; Newest first, block on top.  Tear the block down, put the new
        ;; line at the head of the log, trim the tail, rebuild the block --
        ;; so the two things worth seeing never move and never scroll away.
        ;;
        ;; `save-excursion' is what lets a reader keep their place.  Every
        ;; edit here is above them, so the marker it restores rides the text
        ;; they were on rather than the offset they were at.  Without it the
        ;; `goto-char' below moved buffer point, and in the selected window
        ;; buffer point *is* window point -- so the one window most likely
        ;; to be the one being read was dragged back to the top by every
        ;; tool call, whatever `agent-river--following-windows' had decided.
        (save-excursion
          (agent-river--erase-block)
          (goto-char (point-min))
          (insert (agent-river--render kind detail label) "\n")
          (agent-river--trim)
          (agent-river--insert-block))))
    (when (and agent-river-auto-display (not shown))
      (agent-river-show)
      ;; A window that has only just appeared has never been navigated, so
      ;; it follows whatever the windows before it were doing.
      (setq following (get-buffer-window-list buffer nil t)))
    (agent-river--follow buffer following)
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
  ;; Which way in owns a session, and which tool calls are in flight, are
  ;; state about the same sessions: left behind, they would have the fold
  ;; start again while ownership and half-timed calls referred to states
  ;; that no longer exist.  The subscriptions themselves survive -- they
  ;; belong to buffers, not to what was folded out of them.
  (clrhash agent-river--source)
  (clrhash agent-river--tool-calls)
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

;;;###autoload
(defun agent-river-refresh ()
  "Redraw the state block now.
The block redraws itself while an agent is working; this is for looking at
it after everything has gone quiet and the timer has retired."
  (interactive)
  (agent-river--redraw-block))

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

;;;###autoload
(defun agent-river-toggle-details ()
  "Fold or unfold every session's detail headings in the HUD.

The fold is remembered in `agent-river--panel-expanded' rather than left to
outline overlay visibility, because the block is erased and rebuilt on
every event: an overlay fold would spring open on the next tool call.  A
flag means the rebuilt block is drawn already open, and stays that way
until asked to close."
  (interactive)
  (let ((buffer (get-buffer agent-river-buffer-name)))
    (unless (buffer-live-p buffer)
      (user-error "No agent-river buffer"))
    (with-current-buffer buffer
      (setq agent-river--panel-expanded (not agent-river--panel-expanded))
      (agent-river--redraw-block))))

(defun agent-river-toggle-at-point ()
  "Toggle the block heading on this line of the HUD.

On the `* -- eventlog' heading this folds the log away, as in any outline;
on a session heading it unfolds that session's detail headings.  Both live
on TAB because they are the same gesture -- open or close the thing under
the heading -- applied to the two kinds of heading the block has."
  (interactive)
  (if (save-excursion
        (goto-char (line-beginning-position))
        (looking-at "^\\* -- eventlog"))
      (outline-cycle)
    (agent-river-toggle-details)))

;; `outline-minor-mode-cycle' binds TAB only when the user opted in, so the
;; heading navigation has to be on the mode's own map to be there at all.
(define-key agent-river-mode-map (kbd "TAB") #'agent-river-toggle-at-point)

;; The map's keys, on the same gestures, because the two buffers are two
;; views of one state and learning each separately is a cost with nothing
;; bought by it.  SPC and DEL give up `special-mode's scrolling for line
;; motion, the way dired's do.
(define-key agent-river-mode-map (kbd "n") #'agent-river-next-line)
(define-key agent-river-mode-map (kbd "p") #'agent-river-previous-line)
(define-key agent-river-mode-map (kbd "SPC") #'agent-river-next-line)
(define-key agent-river-mode-map (kbd "DEL") #'agent-river-previous-line)
(define-key agent-river-mode-map [remap next-line] #'agent-river-next-line)
(define-key agent-river-mode-map [remap previous-line] #'agent-river-previous-line)
(define-key agent-river-mode-map (kbd "M-n") #'agent-river-next-session)
(define-key agent-river-mode-map (kbd "M-p") #'agent-river-previous-session)
(define-key agent-river-mode-map (kbd ">") #'agent-river-next-notable)
(define-key agent-river-mode-map (kbd "<") #'agent-river-previous-notable)
;; RET works on a session line through a keymap text property, which leaves
;; it doing nothing everywhere else.  Bound here it says why instead.
(define-key agent-river-mode-map (kbd "RET") #'agent-river-visit-session)
;; `special-mode' puts `revert-buffer' on g, which has nothing to revert to.
(define-key agent-river-mode-map (kbd "g") #'agent-river-refresh)

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
;; Special variables, bound around a pulse to set its length.  Declared so
;; the byte-compiler treats them as the dynamic bindings pulse.el reads
;; rather than as unused lexicals the `let' would silently drop.
(defvar pulse-iterations)
(defvar pulse-delay)

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

(defface agent-river-pulse
  '((((background light)) :background "#ffd34d" :foreground "#3a2a00" :weight bold)
    (((background dark))  :background "#ffcf5c" :foreground "#241a00" :weight bold))
  "Face a just-touched entry flashes in, briefly, when an event names it.

Separate from `agent-river-heat-3' on purpose, and brighter.  The heat is a
steady reading -- \"the agent works here\" -- and is meant to be lived with,
so its shades stay muted.  The pulse is a one-off \"look here\" that has a
second to do its job, so it has to stand out against every heat level,
including the hottest; reusing heat-3's shade made a flash on the hottest
file indistinguishable from the file just sitting there.")

(defcustom agent-river-pulse-iterations 20
  "How many times a pulse fades in and out.
`pulse-momentary-highlight-region' runs `pulse-iterations' cycles with
`pulse-delay' seconds between them, so the two together set how long the
highlight lasts.  The defaults (10, 0.03) make about a third of a second,
which is easy to miss when the file being pulsed is not where the eye
already is -- which is the whole point of pulsing it."
  :type 'integer)

(defcustom agent-river-pulse-delay 0.06
  "Seconds between a pulse's fade cycles, with `agent-river-pulse-iterations'.
Raised from the `pulse' default of 0.03 so a touched file stays lit long
enough to catch: the pulse points the eye at the file an event just named,
and an animation that is over before the glance arrives points at nothing."
  :type 'number)

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

(defcustom agent-river-heat-half-life 120
  "Seconds after which a touch counts half as much as a fresh one.

The raw touch count is cumulative and never forgets, so after a long task
the file with the most historical touches keeps the top shading even when
the agent moved on ten minutes ago -- exactly the shift in attention the
view is for, drawn backwards.  Weighting each touch by its age turns the
reading into \"where is the work now\": a touch `agent-river-heat-half-life'
seconds old weighs 1/2, two half-lives old 1/4, and so on.

Nothing is mutated as it cools.  `:last' already holds the time of every
touch, so the weighting is recomputed from it on each redraw and the view
is correct whenever the next refresh happens to look.  `agent-river-heat-
refresh-interval' is what makes the cooling visible while the agent sits
idle; the overlay itself carries no decaying state.  Nil disables the
weighting and shades by raw count."
  :type '(choice (const :tag "Off, shade by raw count" nil) (number :tag "Half-life in seconds")))

(defcustom agent-river-heat-refresh-interval 5
  "Seconds between redraws of the heat while something is still cooling.

The state block's timer (`agent-river-refresh-interval') stops the moment
no agent is mid-task, which is exactly when the shading has the most to
show: the work has moved on and the old file should be fading.  Rather
than leave that to the next event, this timer keeps the dired shading
honest on its own -- slowly, since a fade is not a clock.

It runs only while `agent-river-heat-mode' is on and stops itself on the
first tick that finds nothing left above the lowest threshold, so an idle
Emacs pays for no redraws."
  :type 'number)

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
        (agent-river-heat-refresh)
        (agent-river--ensure-heat-timer))
    (remove-hook 'agent-river-observers #'agent-river--dired-observe)
    (remove-hook 'dired-after-readin-hook #'agent-river--heat-after-readin)
    (agent-river--stop-heat-timer)
    (dolist (buffer (agent-river--dired-buffers t))
      (agent-river--heat-clear buffer))))

(defun agent-river--heat-weight (entry)
  "Return ENTRY's age-weighted touch count.

Fresh touches count fully and older ones fade by `agent-river-heat-half-life',
so a file the agent left alone sinks through the thresholds and the shading
follows the work rather than the history.  With the half-life off, or an
entry carrying no `:last' time, this is the plain count."
  (let ((touches (or (plist-get entry :touches) 0))
        (last (plist-get entry :last)))
    (if (or (null agent-river-heat-half-life)
            (null last)
            (<= agent-river-heat-half-life 0))
        touches
      (let ((age (float-time (time-subtract (current-time) last))))
        (* touches (expt 0.5 (/ age agent-river-heat-half-life)))))))

(defun agent-river--party-label (state)
  "Return the name STATE goes by in a view that shows several of them.

A subagent is named under its root -- `alpha/Explore' -- because its
artifacts are its own and never its parent's.  A view that folded them
into the parent's name would state that the parent worked in a file it
never opened; one that showed the bare agent type would leave an onlooker
with two `Explore' lines and no way to tell whose."
  (if (agent-river-state-parent state)
      (let ((root (gethash (agent-river-state-parent state) agent-river-registry)))
        (format "%s/%s"
                (if root (or (agent-river-state-label root) "?") "?")
                (or (agent-river-state-agent-type state) "subagent")))
    (or (agent-river-state-label state) "?")))

(defun agent-river--heat-entries (&optional scope)
  "Return one plist per artifact of per folded session.

Each carries `:party' (`agent-river--party-label'), `:cwd' (the anchor its
`:file' is relative to), `:file', the age-weighted `:weight' and `:last'.
SCOPE is `session' for the whole session, `task' or nil for the current
task.

The one derivation every view of the artifact tables is built from, rather
than each walking the registry for itself: the basename table below, the
directory aggregate beside it and the project map all have to answer with
the same weighting, and a second walk is a second place for them to drift."
  (let (entries)
    (maphash
     (lambda (_id state)
       (let ((party (agent-river--party-label state))
             (cwd (agent-river-state-cwd state)))
         (maphash (lambda (path entry)
                    (push (list :party party
                                :cwd cwd
                                :file path
                                :weight (agent-river--heat-weight entry)
                                :last (plist-get entry :last))
                          entries))
                  (if (eq scope 'session)
                      (agent-river-state-artifacts state)
                    (agent-river-state-task-artifacts state)))))
     agent-river-registry)
    entries))

(defun agent-river--heat-absolute (entry)
  "Return ENTRY's file as an absolute name, or nil when nothing anchors it.

Nil for a state folded with no cwd -- one restored from before the slot
existed, or reported by a source that names none.  The answer is then
unknown, and guessing at it would place files in directories no agent
ever opened.

A key that is a bare name is resolved as a file sitting directly in the
cwd, which is what it almost always is; `agent-river--rel' degrades a file
*outside* the cwd to the same shape, and those land here as a file of that
name in the root.  Contained rather than corrected: a bare name has no
directory component, so it can never be summed into a subdirectory, and
the worst it can do is put one line in a listing it does not belong to."
  (let ((cwd (plist-get entry :cwd))
        (file (plist-get entry :file)))
    (and cwd (not (string-empty-p cwd)) file (not (string-empty-p file))
         (expand-file-name file (file-name-as-directory cwd)))))

(defun agent-river--heat-table (&optional scope)
  "Return a hash of basename to weighted touch count across every folded session.

Aggregated rather than kept per session on purpose: one file that two
agents are both in is the case worth seeing, and summing them is the same
reading `agent-river-touching' gives.  SCOPE is `session' for the whole
session, `task' or nil for the current task.

The value is `agent-river--heat-weight', not the raw count: a file still
being touched keeps its shading, one the agent has moved away from cools
toward the thresholds and eventually loses its overlay entirely."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry (agent-river--heat-entries scope))
      (let ((name (file-name-nondirectory (plist-get entry :file))))
        (puthash name
                 (+ (or (gethash name table) 0) (plist-get entry :weight))
                 table)))
    table))

(defun agent-river--heat-dirs (dir &optional scope)
  "Return a hash of subdirectory name to weight, for the listing of DIR.

Only the entries DIR itself has a line for: a key resolving to
DIR/a/b/c.el warms `a' and nothing deeper, because `a' is all the listing
shows of it.

Summed from keys resolved against each session's own cwd, where the file
shading is matched on the bare name.  The two rules differ because the
questions do.  A name is enough to ask \"how hot is this file\" and is
what keeps a worktree and its main checkout reading as one file; it is not
enough to ask \"how hot is this directory\", because `src' says nothing
about which `src', and a directory aggregate matched that way would warm
every `src' in every project at once.  The price is that a session whose
anchor does not reach this listing -- a worktree, against the main
checkout -- contributes no directory shading, only file shading."
  (let ((prefix (file-name-as-directory (expand-file-name dir)))
        (table (make-hash-table :test 'equal)))
    (dolist (entry (agent-river--heat-entries scope))
      (let ((abs (agent-river--heat-absolute entry)))
        (when (and abs (string-prefix-p prefix abs))
          (let* ((rel (substring abs (length prefix)))
                 (slash (string-search "/" rel)))
            (when slash
              (let ((top (substring rel 0 slash)))
                (puthash top
                         (+ (or (gethash top table) 0) (plist-get entry :weight))
                         table)))))))
    table))

(defun agent-river--heat-listing-table (dir &optional scope)
  "Return the table the listing of DIR is shaded with.
The file names every session has touched, plus the aggregate weight of
each of DIR's subdirectories.  One table because a dired line is one name:
a directory and a file of the same name cannot both be in one listing, so
the two halves cannot collide on a real entry."
  (let ((table (agent-river--heat-table scope)))
    (maphash (lambda (name weight)
               (puthash name (+ (or (gethash name table) 0) weight) table))
             (agent-river--heat-dirs dir scope))
    table))

(defun agent-river--heat-face (touches)
  "Return the face a file weighing TOUCHES earns, or nil for none.
TOUCHES is the age-weighted reading from `agent-river--heat-table', so it
is a float while a half-life is set; the thresholds stay whole numbers."
  (cdr (seq-find (lambda (cell) (>= touches (car cell)))
                 agent-river-heat-levels)))

(defun agent-river--heat-visible-p (&optional scope)
  "Return non-nil while some artifact still weighs enough to be shaded.
Read from the same weighted table the overlays are, so \"is there anything
left to cool\" and \"is anything drawn\" cannot disagree.  Once this is nil
the cooling timer has nothing to show and stops."
  (let ((table (agent-river--heat-table scope))
        found)
    (maphash (lambda (_name weight)
               (when (agent-river--heat-face weight)
                 (setq found t)))
             table)
    found))

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

(defun agent-river--heat-dired (buffer)
  "Shade the entries of dired BUFFER by what the agents have touched.

The table is built per buffer rather than once for all of them, because
half of it is: a directory's weight is the sum of what lies beneath it in
*this* listing, and there is no such thing as the weight of `src' in the
abstract."
  (with-current-buffer buffer
    (let ((table (agent-river--heat-listing-table
                  (expand-file-name default-directory)
                  agent-river-heat-scope)))
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
          (forward-line 1))))))

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
  (dolist (buffer (agent-river--dired-buffers))
    (agent-river--heat-dired buffer)))

;; The cooling timer, kept deliberately separate from the state block's.
;; `agent-river--ensure-timer' runs only while an agent is mid-task; the
;; moment it goes idle the shading has the most to say -- the work moved and
;; the old file should be fading -- so it needs a tick the block does not.
;; Slower, too: an elapsed-time clock wants a second, a fade does not.

(defvar agent-river--heat-timer nil
  "Repeating timer fading the dired shading, or nil while none runs.")

(defun agent-river--stop-heat-timer ()
  "Stop the heat cooling timer."
  (when (timerp agent-river--heat-timer)
    (cancel-timer agent-river--heat-timer))
  (setq agent-river--heat-timer nil))

(defun agent-river--heat-tick ()
  "Redraw the shading, or stop the timer once nothing is left to cool."
  (condition-case err
      (if (and agent-river-heat-mode
               (agent-river--heat-visible-p agent-river-heat-scope))
          (agent-river-heat-refresh)
        (agent-river--stop-heat-timer))
    ;; Same reasoning as the block's tick: a timer that throws every few
    ;; seconds would bury Emacs in messages, so a broken redraw retires
    ;; rather than repeats.
    (error (agent-river--stop-heat-timer)
           (message "agent-river: heat refresh stopped (%s)"
                    (error-message-string err)))))

(defun agent-river--ensure-heat-timer ()
  "Start the cooling timer if anything is still cooling and none runs.
Called on mode entry and from the event observer, so a session that keeps
working never loses its faintest overlay between ticks."
  (when (and agent-river-heat-mode
             agent-river-heat-half-life
             (null agent-river--heat-timer)
             (agent-river--heat-visible-p agent-river-heat-scope))
    (setq agent-river--heat-timer
          (run-at-time agent-river-heat-refresh-interval
                       agent-river-heat-refresh-interval
                       #'agent-river--heat-tick))))

(defun agent-river--heat-after-readin ()
  "Reapply the shading to a dired buffer that was just listed or reverted.
A revert replaces the buffer text and takes every overlay with it, so
without this the shading vanishes at exactly the moment dired refreshes to
show what the agent has written."
  (when agent-river-heat-mode
    (agent-river--heat-dired (current-buffer))))

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
  "Pulse PATH's entry in the first visible dired buffer that lists it.
The pulse's length comes from `agent-river-pulse-iterations' and
`agent-river-pulse-delay' rather than pulse.el's terse defaults, so a
file an event just named stays lit long enough for the eye to find it."
  (when (and path (require 'pulse nil t))
    (catch 'pulsed
      (dolist (buffer (agent-river--dired-buffers))
        (with-current-buffer buffer
          (save-excursion
            ;; dired-goto-file takes the absolute name and answers nil when
            ;; the file is not in this listing, which is also the answer for
            ;; a file the agent created a moment ago.
            (when (ignore-errors (dired-goto-file path))
              (let ((bounds (agent-river--heat-bounds))
                    (pulse-iterations agent-river-pulse-iterations)
                    (pulse-delay agent-river-pulse-delay))
                (when bounds
                  (pulse-momentary-highlight-region
                   (car bounds) (cdr bounds) 'agent-river-pulse)
                  (throw 'pulsed buffer))))))))))

(defun agent-river--dired-observe (_state event)
  "Draw EVENT into the dired views: heat from the state, a pulse from EVENT.

Takes no mode check of its own: being on `agent-river-observers' is what
switched it on, and the runner is what takes it off again.  STATE is
ignored because the heat is aggregated across every session rather than
read from the one that just acted -- two agents in one file is the case
worth seeing."
  (agent-river-heat-refresh)
  ;; A working agent keeps its heat fresh, but the timer it started on some
  ;; earlier quiet moment may already have stopped itself -- once the last
  ;; overlay fell below the threshold there was nothing to cool.  Restart it
  ;; here, where an event has just proven there is something to draw.
  (agent-river--ensure-heat-timer)
  ;; An act names a file that was touched at that moment; a think or a fail
  ;; reports on a call whose pulse has already been shown.  A note can name
  ;; one too -- a foreign save points at its file through `:path' -- and it
  ;; pulses for the same reason: something happened to this file just now,
  ;; even though the agent is not the one that did it.  The note still does
  ;; not warm the entry; the pulse says "look here", the heat says "the agent
  ;; works here", and running them together would blur the two.
  (when (and (member (plist-get event :kind) '("act" "note"))
             (plist-get event :path))
    (agent-river--pulse-dired (plist-get event :path))))

;; Removal is not enough of a retirement here: the overlays would stay where
;; they are, and `agent-river-heat-mode' would keep claiming to be on.
(put 'agent-river--dired-observe 'agent-river-retire
     (lambda () (agent-river-heat-mode -1)))

;;; The map -- the project as a whole, one level at a time
;;
;; The heat shades the directory you are already in.  This answers the
;; question that directory cannot: in a repository spread over thirty
;; modules, with several agents running at once, *where is everyone*.  Same
;; state, same weighting, a coarser grain -- derived on every redraw like
;; everything else here, so the two views cannot drift and neither
;; accumulates anything of its own.
;;
;; One level of full breadth, and depth only where there is activity.  A
;; whole tree unfolded is unreadable in a monorepo; a view of only the
;; touched paths answers "where" without ever saying where that is relative
;; to anything else.  So one directory is always listed in full, each entry
;; carries what has happened beneath it, and RET descends -- the lens is
;; moved rather than widened.
;;
;; Placing a key in a real directory tree is the one thing the artifact
;; tables were built not to do: they are keyed relative to a session's cwd
;; precisely so that a worktree and its main checkout read as one file.  The
;; anchor sits beside them in `agent-river-state-cwd', and putting the two
;; back together is a deliberate act, done here in the view and nowhere in
;; the fold.
;;
;; Two readings, kept apart on purpose.  The weights say where an agent has
;; *been*; only `:current' says where it *is*, and after a long task those
;; are different places.  Folding the second into the first -- a big enough
;; number must be where the work is -- is exactly the mistake the half-life
;; was added to stop, one grain up.

(defcustom agent-river-map-scope 'session
  "Which artifact frame the map is read from.

Defaults the other way round from `agent-river-heat-scope', because the
questions are different.  A dired buffer is where you already are and the
useful reading is this turn; the map is opened to find out where everyone
has been working, and a frame cleared by every prompt would blank half of
it each time an agent was given its next instruction."
  :type '(choice (const task) (const session)))

(defcustom agent-river-map-ignore
  '("\\`\\.git\\'" "\\`\\.#" "\\`#" "~\\'" "\\`\\.DS_Store\\'")
  "Entries the map leaves out of a listing, as regexps on the bare name.
Only the listing: an entry dropped here that an agent has nonetheless
touched still appears, because activity the map does not show is the one
thing it exists not to do."
  :type '(repeat regexp))

(defcustom agent-river-map-refresh-interval 3
  "Seconds between map redraws while anything is still moving.

The map is redrawn on a timer rather than on every event, and that is
deliberate.  Drawing a whole listing on each tool call means a redraw
thousands of times a task, and every one of them moves point in a buffer
someone is reading.  An event marks the map dirty; this decides how often
dirt is worth a redraw."
  :type 'number)

(defcustom agent-river-map-name-width 32
  "Column the map's annotations start at.
Names longer than this push their annotation right rather than being
truncated: a path is what the line is for."
  :type 'integer)

(defcustom agent-river-map-contended-marker "⇄"
  "Marker for an entry more than one agent is working in.

A marker rather than a fourth colour.  Weight is already drawn as shading,
and encoding a second, unrelated fact the same way leaves a reader unable
to say which of the two any given colour means.  This is also the thing
most worth being able to scan a whole listing for."
  :type 'string)

(defcustom agent-river-map-here-marker "▸"
  "Marker for the entry holding an agent's most recent touch."
  :type 'string)

(defun agent-river--map-weight (parties)
  "Return the total weight across PARTIES."
  (apply #'+ (mapcar (lambda (party) (plist-get party :weight)) parties)))

(defun agent-river--map-later (a b)
  "Return the later of times A and B, either of which may be nil."
  (cond ((null a) b)
        ((null b) a)
        ((time-less-p a b) b)
        (t a)))

(defun agent-river--map-reach (root &optional scope)
  "Return what the agents have reached inside ROOT, deepest detail kept.

A list of plists, heaviest first, each carrying `:rel' -- the file's path
relative to ROOT -- and `:parties', an alist-like list of plists with
`:party', `:weight', `:last' and `:current'.

`:current' marks the one file a party touched most recently, which is the
only thing here that says where an agent is now rather than where it has
been.  Computed across everything the party reached, not just what fell
inside ROOT, so descending into a subdirectory cannot invent a second
\"most recent\" file that only looks like one because the real one was out
of view."
  (let ((prefix (file-name-as-directory (expand-file-name root)))
        (by-rel (make-hash-table :test 'equal))
        (newest (make-hash-table :test 'equal))
        (entries (agent-river--heat-entries scope)))
    (dolist (entry entries)
      (let ((abs (agent-river--heat-absolute entry))
            (party (plist-get entry :party))
            (last (plist-get entry :last)))
        (when abs
          (let ((seen (gethash party newest)))
            (when (or (null seen)
                      (eq last (agent-river--map-later (plist-get seen :last) last)))
              (puthash party (list :abs abs :last last) newest))))
        (when (and abs (string-prefix-p prefix abs))
          (let* ((rel (substring abs (length prefix)))
                 (parties (or (gethash rel by-rel)
                              (puthash rel (make-hash-table :test 'equal) by-rel)))
                 (cell (gethash party parties)))
            (puthash party
                     (list :weight (+ (or (plist-get cell :weight) 0)
                                      (plist-get entry :weight))
                           :last (agent-river--map-later (plist-get cell :last) last)
                           ;; The absolute name, so `:current' is decided by
                           ;; identity rather than by a path that two roots
                           ;; could both produce.
                           :abs abs)
                     parties)))))
    (let (nodes)
      (maphash
       (lambda (rel parties)
         (let (plists)
           (maphash (lambda (party cell)
                      (push (list :party party
                                  :weight (plist-get cell :weight)
                                  :last (plist-get cell :last)
                                  :current (equal (plist-get cell :abs)
                                                  (plist-get (gethash party newest) :abs)))
                            plists))
                    parties)
           (push (list :rel rel
                       :parties (sort plists (lambda (a b)
                                               (> (plist-get a :weight)
                                                  (plist-get b :weight)))))
                 nodes)))
       by-rel)
      (sort nodes (lambda (a b)
                    (> (agent-river--map-weight (plist-get a :parties))
                       (agent-river--map-weight (plist-get b :parties))))))))

(defun agent-river--map-merge-parties (nodes)
  "Return the parties of NODES summed into one list, heaviest first.
How a directory's reading is made: it is the aggregate of what lies
beneath it and never a tally of its own, so the entry and the files under
it can never disagree about who has been where."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (node nodes)
      (dolist (party (plist-get node :parties))
        (let ((cell (gethash (plist-get party :party) table)))
          (puthash (plist-get party :party)
                   (list :party (plist-get party :party)
                         :weight (+ (or (plist-get cell :weight) 0)
                                    (plist-get party :weight))
                         :last (agent-river--map-later (plist-get cell :last)
                                                       (plist-get party :last))
                         :current (or (plist-get cell :current)
                                      (plist-get party :current)))
                   table))))
    (let (out)
      (maphash (lambda (_party cell) (push cell out)) table)
      (sort out (lambda (a b) (> (plist-get a :weight) (plist-get b :weight)))))))

(defun agent-river--map-listing (root)
  "Return ROOT's own directory entries, directories first, ignores dropped.
Unreadable or missing, the answer is no entries rather than an error: the
map still has the reached paths to show, and a root that went away should
not take the view with it."
  (let (dirs files)
    (dolist (name (ignore-errors (directory-files root nil nil t)))
      (unless (or (member name '("." ".."))
                  (seq-some (lambda (re) (string-match-p re name))
                            agent-river-map-ignore))
        (if (file-directory-p (expand-file-name name root))
            (push name dirs)
          (push name files))))
    (append (sort dirs #'string<) (sort files #'string<))))

(defun agent-river--map-entries (root &optional scope)
  "Return ROOT's listing, annotated with what the agents have done in it.

One plist per entry in listing order -- directories first -- carrying
`:name', `:dir', `:parties', `:files' and `:missing'.  `:parties' is the
aggregate beneath the entry; `:files' are the reached paths under it, each
`:rel' relative to the entry, heaviest first.  A file entry has no
`:files' and carries its own parties.

The listing is the union of what is on disk and what has been reached.
`:missing' marks an entry only the state knows about -- deleted, renamed,
or reached through an anchor this root has nothing to do with.  Showing it
anyway is the point: an artifact whose top component is gone would
otherwise be activity the map silently drops."
  (let* ((reach (agent-river--map-reach root scope))
         (grouped (make-hash-table :test 'equal))
         (names (agent-river--map-listing root))
         entries)
    ;; Group the reached paths by the entry the listing has a line for --
    ;; the top component -- so a file five directories down is still
    ;; reported under the one name that is on screen.
    (dolist (node reach)
      (let* ((rel (plist-get node :rel))
             (slash (string-search "/" rel))
             (top (if slash (substring rel 0 slash) rel))
             (under (if slash (substring rel (1+ slash)) nil)))
        (push (list :rel under :parties (plist-get node :parties))
              (gethash top grouped))))
    (dolist (name names)
      (let* ((under (nreverse (gethash name grouped)))
             (dir (file-directory-p (expand-file-name name root))))
        (remhash name grouped)
        (push (list :name name
                    :dir dir
                    :parties (agent-river--map-merge-parties under)
                    ;; A file entry's own node comes through the grouping
                    ;; with a nil `:rel'; there is nothing to unfold under it.
                    :files (and dir under))
              entries)))
    (let (orphans)
      (maphash (lambda (name under)
                 (setq under (nreverse under))
                 (push (list :name name
                             :dir (seq-some (lambda (n) (plist-get n :rel)) under)
                             :parties (agent-river--map-merge-parties under)
                             :files (and (seq-some (lambda (n) (plist-get n :rel)) under)
                                         under)
                             :missing t)
                       orphans))
               grouped)
      (append (nreverse entries) (sort orphans (lambda (a b)
                                                 (string< (plist-get a :name)
                                                          (plist-get b :name))))))))

(defcustom agent-river-map-detail-files 8
  "How many reached files an unfolded map entry lists.
Ordered by weight, so the tail is the least interesting; an ellipsis
marks what was left off."
  :type 'integer)

(defconst agent-river-map-buffer-name "*agent-river-map*"
  "Name of the project map buffer.")

(defvar-local agent-river--map-root nil
  "The directory the map buffer is currently showing.")

(defvar-local agent-river--map-folds nil
  "Alist of entry name to whether its files are shown, where the user said.

Only the entries that were toggled by hand.  Everything else falls back to
the default in `agent-river--map-open-p', so a new directory an agent has
just moved into opens without needing an entry here -- and a fold made by
hand survives the redraws, which is the whole reason this is data rather
than outline overlays.  The block is rebuilt every few seconds and an
overlay fold would spring open on each one.")

(defvar agent-river--map-dirty nil
  "Non-nil when an event has landed that the map has not yet drawn.")

;; The buffer is Markdown, and tree-sitter owns the `face' property in it: it
;; refontifies on redisplay and appends or removes faces as the structure
;; changes, so a shading written as a text property is drawn once and then
;; quietly gone.  Every face this view wants is therefore marked with a
;; property of its own and turned into an overlay after the text is in
;; (`agent-river--map-shade') -- an overlay sits above the fontification, the
;; same way the dired heat sits above dired's.

(defun agent-river--map-mark (text face)
  "Return TEXT marked to be shaded with FACE once it is in the buffer.
Unmarked when FACE is nil, which is what a weight below every threshold
earns -- and what keeps the quiet entries quiet."
  (if face (propertize text 'agent-river-map-face face) text))

(defun agent-river--map-name (name)
  "Return NAME as a Markdown code span.

Backticks rather than bare text, for two reasons that happen to agree: a
path is what a code span is for, and inline markup does not apply inside
one -- without it `foo_bar_baz.el' renders with `bar' in italics and half
the underscores eaten, which is a filename the view would be lying about."
  (concat "`" name "`"))

(defun agent-river--map-annotation (parties)
  "Return PARTIES as the bracketed reading a map line ends with, or nil.

The marker is repeated inside the brackets, against the party it belongs
to.  In the left-hand column it is scannable but anonymous -- on a line
three agents share it says only that one of them is here -- and \"where is
this agent now\" is a question about a party rather than about a line."
  (when parties
    (concat
     "["
     (mapconcat (lambda (party)
                  (concat (agent-river--map-mark (plist-get party :party)
                                                 'agent-river-session)
                          ;; Never zero: a weight below one still earned a
                          ;; line, and `[alpha:0]' would read as a party
                          ;; that is listed for having done nothing.
                          (format ":%d" (max 1 (round (plist-get party :weight))))
                          (if (plist-get party :current)
                              agent-river-map-here-marker "")))
                parties " ")
     "]")))

(defun agent-river--map-marker (level)
  "Return the Markdown that opens a map line at LEVEL.

Directories are headings and files are list items, which is what each of
them is: a heading has something under it and folds, a leaf does not.
Making every file a level-3 heading instead would set the whole listing in
the heading face and leave the structure saying that a file contains the
lines after it.

The markup is left visible.  Hiding it is `markdown-ts-view-mode's own
default and it looks better on prose, but here the marker is the
indentation -- hidden, a directory and the files under it start in the
same column and the tree stops being one."
  (pcase level (1 "# ") (2 "## ") (_ "- ")))

(defun agent-river--map-line (level name parties &optional missing)
  "Return one map line: NAME at LEVEL, annotated with PARTIES.
MISSING marks a name only the state knows about, which is greyed rather
than shaded -- there is no file on disk for the shading to be about."
  (let* ((marker (agent-river--map-marker level))
         (face (if missing
                   'agent-river-stale
                 (agent-river--heat-face (agent-river--map-weight parties))))
         (shown (agent-river--map-name name))
         (pad (max 1 (- agent-river-map-name-width
                        (length marker) (string-width shown))))
         (markers
          (concat (if (> (length parties) 1) agent-river-map-contended-marker " ")
                  (if (seq-some (lambda (party) (plist-get party :current)) parties)
                      agent-river-map-here-marker " "))))
    (string-trim-right
     (concat marker
             (agent-river--map-mark shown face)
             (make-string pad ?\s)
             markers " "
             (or (agent-river--map-annotation parties) "")))))

(defun agent-river--map-shade ()
  "Turn this buffer's face marks into overlays, replacing the last set."
  (remove-overlays (point-min) (point-max) 'agent-river-map-shade t)
  (let ((pos (point-min)))
    (while (< pos (point-max))
      (let ((face (get-text-property pos 'agent-river-map-face))
            (next (next-single-property-change pos 'agent-river-map-face
                                               nil (point-max))))
        (when face
          (let ((overlay (make-overlay pos next)))
            (overlay-put overlay 'agent-river-map-shade t)
            (overlay-put overlay 'face face)
            (overlay-put overlay 'evaporate t)))
        (setq pos next)))))

(defun agent-river--map-open-p (entry)
  "Return non-nil when ENTRY's reached files are shown beneath it.

An entry with activity opens by default -- the files are the reason the
entry is annotated at all -- and a toggle by hand wins from then on."
  (let ((cell (assoc (plist-get entry :name) agent-river--map-folds)))
    (if cell (cdr cell) (and (plist-get entry :files) t))))

(defun agent-river--map-header (root entries)
  "Return the map's own heading for ROOT, given its ENTRIES.
Says which frame the numbers below come from.  The map defaults to the
session frame and the dired heat to the task frame, so a reading lifted
from one and compared against the other is a mistake waiting to be made
unless the line says which is which."
  (let ((parties (agent-river--map-merge-parties
                  (mapcar (lambda (entry)
                            (list :parties (plist-get entry :parties)))
                          entries))))
    (concat (agent-river--map-marker 1)
            (agent-river--map-mark (agent-river--map-name
                                    (abbreviate-file-name root))
                                   'agent-river-prompt)
            (format "  ·  %s frame" (if (eq agent-river-map-scope 'session)
                                        "session" "task"))
            (if parties
                (format "  ·  %d agent%s" (length parties)
                        (if (= (length parties) 1) "" "s"))
              "  ·  quiet"))))

(defun agent-river--map-here ()
  "Return what identifies the line point is on, for a redraw to find again."
  (let ((beg (line-beginning-position)))
    (list (get-text-property beg 'agent-river-map-name)
          (get-text-property beg 'agent-river-map-rel)
          (line-number-at-pos))))

(defun agent-river--map-goto (here)
  "Put point back where HERE was, by name if the line is still there.
By line number otherwise, rather than at the top: an entry that cooled
out of the listing should not send whoever was reading it back to the
start of the buffer."
  (goto-char (point-min))
  (let ((found nil))
    (when (nth 0 here)
      (while (and (not found) (not (eobp)))
        (if (and (equal (nth 0 here)
                        (get-text-property (line-beginning-position)
                                           'agent-river-map-name))
                 (equal (nth 1 here)
                        (get-text-property (line-beginning-position)
                                           'agent-river-map-rel)))
            (setq found t)
          (forward-line 1))))
    (unless found
      (goto-char (point-min))
      (forward-line (1- (max 1 (or (nth 2 here) 1)))))))

(defun agent-river--map-draw ()
  "Redraw the map buffer from the state, if it is still alive."
  (let ((buffer (get-buffer agent-river-map-buffer-name)))
    (when buffer
      (with-current-buffer buffer
        (let* ((root agent-river--map-root)
               (entries (agent-river--map-entries root agent-river-map-scope))
               (here (agent-river--map-here))
               (inhibit-read-only t))
          (erase-buffer)
          (insert (agent-river--map-header root entries) "\n")
          (dolist (entry entries)
            (let* ((name (plist-get entry :name))
                   (dir (plist-get entry :dir))
                   (path (expand-file-name name root)))
              (insert (propertize
                       (concat (agent-river--map-line
                                2 (concat name (if dir "/" ""))
                                (plist-get entry :parties)
                                (plist-get entry :missing))
                               "\n")
                       'agent-river-map-name name
                       'agent-river-map-path path
                       'agent-river-map-dir dir
                       ;; What `agent-river-map-next-active' stops on.  Read
                       ;; off the parties rather than off the annotation
                       ;; text, so the motion and the reading cannot come
                       ;; apart if the line is ever formatted differently.
                       'agent-river-map-active (and (plist-get entry :parties) t)))
              (when (agent-river--map-open-p entry)
                (let* ((files (plist-get entry :files))
                       (shown (seq-take files agent-river-map-detail-files)))
                  (dolist (file shown)
                    (insert (propertize
                             (concat (agent-river--map-line
                                      3 (plist-get file :rel)
                                      (plist-get file :parties))
                                     "\n")
                             'agent-river-map-name name
                             'agent-river-map-rel (plist-get file :rel)
                             'agent-river-map-path
                             (expand-file-name (plist-get file :rel) path)
                             'agent-river-map-active
                             (and (plist-get file :parties) t))))
                  (when (> (length files) (length shown))
                    (insert (propertize
                             (concat (agent-river--map-marker 3) "…\n")
                             'agent-river-map-face 'agent-river-stale
                             'agent-river-map-name name)))))))
          (agent-river--map-shade)
          (agent-river--map-goto here)
          (agent-river--map-settle-point)
          (setq agent-river--map-dirty nil))))))

(defun agent-river--map-default-root ()
  "Return the directory the map opens on.

The cwd of the most recently seen root session, widened to its project
root where `project' can say where that is: a session started in one
module of a monorepo has a cwd well below the repository, and opening the
map there would show that module and label it the project.  With nothing
folded yet, this buffer's own directory."
  (let (best)
    (maphash (lambda (_id state)
               (when (and (null (agent-river-state-parent state))
                          (agent-river-state-cwd state)
                          (or (null best)
                              (time-less-p (agent-river-state-last-seen best)
                                           (agent-river-state-last-seen state))))
                 (setq best state)))
             agent-river-registry)
    (let ((dir (if best
                   (agent-river-state-cwd best)
                 (directory-file-name (expand-file-name default-directory)))))
      (or (and (fboundp 'project-current) (fboundp 'project-root)
               (let ((project (ignore-errors
                                (project-current nil (file-name-as-directory dir)))))
                 (and project (directory-file-name
                               (expand-file-name (project-root project))))))
          dir))))

;;; Moving about the map
;;
;; Dired's gestures, because the map is answering dired's question over a
;; wider area.  Point belongs on the name rather than in column zero: column
;; zero is the Markdown marker, which is not what the line is about, and a
;; cursor sitting on `#' reads as though the markup were the content.
;;
;; Three motions, because the map has three grains of "next thing" and
;; collapsing them would lose the one a reader actually wants.  Every entry
;; is the fine one; the top-level entries alone skip past an unfolded
;; directory's files; and the entries with agents on them are why the map was
;; opened at all -- in a thirty-module repository that last one is the
;; difference between reading the view and searching it.

(defun agent-river--map-line-path ()
  "Return what this line names, or nil when it names nothing.
The root heading and the elision line carry no path, which is exactly what
makes them the lines no motion should ever stop on."
  (get-text-property (line-beginning-position) 'agent-river-map-path))

(defun agent-river--map-entry-line-p ()
  "Return non-nil on a line naming a file or a directory."
  (and (agent-river--map-line-path) t))

(defun agent-river--map-top-line-p ()
  "Return non-nil on one of the listing's own entries.
A file shown under an unfolded directory carries `agent-river-map-rel';
the entry itself does not, which is the difference between the two grains
of motion."
  (and (agent-river--map-entry-line-p)
       (null (get-text-property (line-beginning-position) 'agent-river-map-rel))))

(defun agent-river--map-active-line-p ()
  "Return non-nil on a line some agent has been working under."
  (and (agent-river--map-entry-line-p)
       (get-text-property (line-beginning-position) 'agent-river-map-active)))

(defun agent-river--map-beginning-of-name ()
  "Put point on the first character of the name on this line.
Falls back to the start of the line, so this is safe to call anywhere --
the header has no name and point should not end up inside its markup."
  (goto-char (line-beginning-position))
  (re-search-forward "`" (line-end-position) t))

(defun agent-river--map-scan (count test)
  "Move to the COUNTth line satisfying TEST, forward when COUNT is positive.

Returns nil and leaves point alone when there is no such line.  Refusing
to move is the point: a motion that quietly lands somewhere else means the
next RET visits something the eye never chose, and in a view whose whole
job is to be trusted about where things are, that is worse than a beep."
  (let ((found nil)
        (step (if (> count 0) 1 -1))
        (left (abs count)))
    (save-excursion
      (catch 'done
        (while t
          (unless (zerop (forward-line step)) (throw 'done nil))
          (when (funcall test)
            (setq left (1- left))
            (when (zerop left)
              (setq found (point))
              (throw 'done nil))))))
    (when found
      (goto-char found)
      (agent-river--map-beginning-of-name)
      t)))

(defun agent-river-map-next-line (&optional n)
  "Move to the Nth next file or directory on the map."
  (interactive "p")
  (or (agent-river--map-scan (or n 1) #'agent-river--map-entry-line-p)
      (user-error "No further entry")))

(defun agent-river-map-previous-line (&optional n)
  "Move to the Nth previous file or directory on the map."
  (interactive "p")
  (agent-river-map-next-line (- (or n 1))))

(defun agent-river-map-next-entry (&optional n)
  "Move to the Nth next entry of the listing, past any files shown under it."
  (interactive "p")
  (or (agent-river--map-scan (or n 1) #'agent-river--map-top-line-p)
      (user-error "No further entry")))

(defun agent-river-map-previous-entry (&optional n)
  "Move to the Nth previous entry of the listing."
  (interactive "p")
  (agent-river-map-next-entry (- (or n 1))))

(defun agent-river-map-next-active (&optional n)
  "Move to the Nth next line an agent is working under."
  (interactive "p")
  (or (agent-river--map-scan (or n 1) #'agent-river--map-active-line-p)
      (user-error "No further agent")))

(defun agent-river-map-previous-active (&optional n)
  "Move to the Nth previous line an agent is working under."
  (interactive "p")
  (agent-river-map-next-active (- (or n 1))))

(defun agent-river--map-settle-point ()
  "Put point somewhere a motion could have left it.
Called after every redraw.  A freshly drawn map has point on the header,
which names nothing -- RET and TAB there would both complain, and the
first thing anyone does with a new buffer is press one of them."
  (if (agent-river--map-entry-line-p)
      (agent-river--map-beginning-of-name)
    (goto-char (point-min))
    (unless (agent-river--map-scan 1 #'agent-river--map-entry-line-p)
      (goto-char (point-min)))))

(defun agent-river-map-refresh ()
  "Redraw the map now."
  (interactive)
  (agent-river--map-draw))

(defun agent-river-map-toggle ()
  "Show or hide the reached files under the entry at point."
  (interactive)
  (let ((name (get-text-property (line-beginning-position) 'agent-river-map-name)))
    (unless name (user-error "No entry on this line"))
    (let* ((entry (seq-find (lambda (e) (equal (plist-get e :name) name))
                            (agent-river--map-entries agent-river--map-root
                                                      agent-river-map-scope)))
           (open (and entry (agent-river--map-open-p entry)))
           (cell (assoc name agent-river--map-folds)))
      (if cell
          (setcdr cell (not open))
        (push (cons name (not open)) agent-river--map-folds)))
    (agent-river--map-draw)))

(defun agent-river-map-visit ()
  "Descend into the directory at point, or open the file at point.
The lens is moved rather than widened: one directory is always listed in
full, and going deeper means looking somewhere else."
  (interactive)
  (let ((path (get-text-property (line-beginning-position) 'agent-river-map-path))
        (dir (get-text-property (line-beginning-position) 'agent-river-map-dir)))
    (cond
     ((null path) (user-error "Nothing to visit on this line"))
     (dir (agent-river-map-descend path))
     ((file-exists-p path) (find-file path))
     (t (user-error "%s is not on disk" (abbreviate-file-name path))))))

(defun agent-river-map-descend (dir)
  "Point the map at DIR.
The hand-made folds are dropped with the listing they were about: the
names in them belong to the directory being left, and carrying them over
would fold entries in the new one that happen to share a name."
  (setq agent-river--map-root (directory-file-name (expand-file-name dir))
        agent-river--map-folds nil)
  (agent-river--map-draw))

(defun agent-river-map-up ()
  "Point the map at the parent of the directory it is showing."
  (interactive)
  (let ((up (file-name-directory (directory-file-name agent-river--map-root))))
    (if (or (null up) (equal (directory-file-name up) agent-river--map-root))
        (user-error "Already at the root")
      (agent-river-map-descend up))))

(declare-function markdown-ts-view-mode "markdown-ts-mode" ())
;; Declared so the byte-compiler sees a special variable rather than a free
;; one: the map binds it whether or not markdown-ts-mode has been loaded.
(defvar markdown-ts-hide-markup)

(defun agent-river--markdown-ts-p ()
  "Return non-nil when this Emacs can render the map as Markdown.

Both halves have to be there: the mode ships with Emacs 31, the grammars
do not, and `markdown-ts-view-mode' in a buffer with no grammar installed
fails at the point the map is opened rather than at the point it is
configured.  Checked rather than assumed, so the map degrades to plain
text instead of erroring.

Loads the library to find out, because only `markdown-ts-mode' is
autoloaded: asking `fboundp' about the view mode before anything has
pulled the file in answers no on an Emacs that has it, and the map would
then quietly stay in the fallback for the whole session."
  (and (or (fboundp 'markdown-ts-view-mode)
           (require 'markdown-ts-mode nil t))
       (fboundp 'markdown-ts-view-mode)
       (fboundp 'treesit-language-available-p)
       (treesit-language-available-p 'markdown)
       (treesit-language-available-p 'markdown-inline)))

(defun agent-river--map-setup ()
  "Set the buffer-local state both map modes need."
  ;; A path is what the line is for, so it is never wrapped into a second
  ;; line the annotation column cannot survive.
  (setq-local truncate-lines t)
  (setq-local header-line-format nil)
  ;; Hiding the markup collapses the indentation the tree is drawn with --
  ;; see `agent-river--map-marker' -- and this must not depend on what the
  ;; user set the Markdown default to.
  (setq-local markdown-ts-hide-markup nil)
  ;; Outline's own cycling has to go, and not only because it puts a `keymap'
  ;; text property on every heading that wins over the mode map and swallows
  ;; TAB.  Its fold lives in overlays, and this buffer is erased and rebuilt
  ;; every few seconds -- so a heading folded that way springs open on the
  ;; next redraw.  `agent-river-map-toggle' folds the same headings by
  ;; deciding what gets drawn, which is the only kind of fold that survives
  ;; here.
  (setq-local outline-minor-mode-cycle nil)
  ;; Navigating by keyboard with nothing marking where you are is navigating
  ;; blind, and this view is read by eye far more than it is acted on.  The
  ;; heat overlays keep their own background over the top of it, so the
  ;; shading is still legible on the current line.  A mode hook is the way
  ;; out for anyone who does not want it.
  (when (fboundp 'hl-line-mode) (hl-line-mode 1))
  (buffer-disable-undo))

;; `markdown-ts-view-mode' rather than `markdown-ts-mode': it is the
;; read-only variant, it already has `special-mode' among its parents, and
;; the map is a view of a state that is written elsewhere -- an editable
;; buffer would offer edits that the next redraw silently throws away.
(define-derived-mode agent-river-map-mode markdown-ts-view-mode "Agent-Map"
  "Major mode for the project map, rendered as Markdown.

Dired-like on purpose: RET descends, `^' goes up, TAB opens what is under
a line.  The gestures are the ones the view is an answer to -- it exists
because a dired buffer can only ever show one directory at a time."
  (agent-river--map-setup))

(define-derived-mode agent-river-map-plain-mode special-mode "Agent-Map"
  "Major mode for the project map where Markdown cannot be rendered.

The same buffer, read as an outline instead.  The text is the same
Markdown either way; only the fontification is missing, which is what
makes this a degradation rather than a second view to keep in step."
  (setq-local outline-regexp "^\\(#+ \\|- \\)")
  (outline-minor-mode 1)
  (agent-river--map-setup))

(dolist (map (list agent-river-map-mode-map agent-river-map-plain-mode-map))
  ;; Set on both maps from one list rather than inherited, because the two
  ;; modes have different parents and neither can be the other's.  The
  ;; fallback has to carry the same keys or it stops being the same view
  ;; drawn plainer and becomes a second one to keep in step.
  (define-key map (kbd "TAB") #'agent-river-map-toggle)
  (define-key map (kbd "RET") #'agent-river-map-visit)
  (define-key map (kbd "^") #'agent-river-map-up)
  ;; `markdown-ts-view-mode' binds this to `ignore' to keep `revert-buffer'
  ;; off it; here there is something to revert to.
  (define-key map (kbd "g") #'agent-river-map-refresh)
  ;; n/p are outline's in `markdown-ts-view-mode' and unbound in the
  ;; fallback, so in one mode they skipped every file line and in the other
  ;; there was no entry motion at all.
  (define-key map (kbd "n") #'agent-river-map-next-line)
  (define-key map (kbd "p") #'agent-river-map-previous-line)
  (define-key map (kbd "SPC") #'agent-river-map-next-line)
  (define-key map (kbd "DEL") #'agent-river-map-previous-line)
  ;; Remapped rather than bound, the way dired does it, so the arrow keys
  ;; and C-n/C-p land on a name too.  Line motion that leaves point in
  ;; column zero puts the cursor on the Markdown marker, which reads as
  ;; though the markup were the content.
  (define-key map [remap next-line] #'agent-river-map-next-line)
  (define-key map [remap previous-line] #'agent-river-map-previous-line)
  (define-key map (kbd "M-n") #'agent-river-map-next-entry)
  (define-key map (kbd "M-p") #'agent-river-map-previous-entry)
  (define-key map (kbd ">") #'agent-river-map-next-active)
  (define-key map (kbd "<") #'agent-river-map-previous-active))

(defun agent-river--map-observe (_state _event)
  "Mark the map as needing a redraw, and make sure something will do it.

Deliberately does not draw.  This runs on every tool call, and rebuilding
a whole listing thousands of times a task would move point under whoever
is reading it -- so an event only says that the drawing is out of date and
the timer decides how often that is worth acting on."
  (setq agent-river--map-dirty t)
  (agent-river--ensure-map-timer))

(defvar agent-river--map-timer nil
  "Repeating timer redrawing the map, or nil while none runs.")

(defun agent-river--stop-map-timer ()
  "Stop the map redraw timer."
  (when (timerp agent-river--map-timer)
    (cancel-timer agent-river--map-timer))
  (setq agent-river--map-timer nil))

(defun agent-river--map-tick ()
  "Redraw the map, or stop the timer once there is nothing left to draw.
Cooling counts as something to draw: with a half-life set, a listing whose
agents have all stopped is still changing, and the weights would otherwise
sit frozen at whatever they were when the last event landed."
  (condition-case err
      (cond
       ((null (get-buffer agent-river-map-buffer-name))
        (agent-river--map-teardown))
       ((or agent-river--map-dirty
            (and agent-river-heat-half-life
                 (agent-river--heat-visible-p agent-river-map-scope)))
        (agent-river--map-draw))
       (t (agent-river--stop-map-timer)))
    ;; Same bargain as the other two timers: a redraw that throws every few
    ;; seconds would bury Emacs in messages, so it retires rather than
    ;; repeats -- and says so rather than going quiet.
    (error (agent-river--stop-map-timer)
           (message "agent-river: map refresh stopped (%s)"
                    (error-message-string err)))))

(defun agent-river--ensure-map-timer ()
  "Start the map redraw timer if the map is open and none runs."
  (when (and (null agent-river--map-timer)
             (get-buffer agent-river-map-buffer-name))
    (setq agent-river--map-timer
          (run-at-time agent-river-map-refresh-interval
                       agent-river-map-refresh-interval
                       #'agent-river--map-tick))))

(defun agent-river--map-teardown ()
  "Take the map off the event stream and stop its timer.
Run when the buffer is killed, and as the observer's retirement: the map
draws only into its own buffer, so closing that buffer is the whole of
turning it off."
  (remove-hook 'agent-river-observers #'agent-river--map-observe)
  (agent-river--stop-map-timer))

(put 'agent-river--map-observe 'agent-river-retire #'agent-river--map-teardown)

;;;###autoload
(defun agent-river-map (&optional ask)
  "Show where the agents are working across the whole project.

The lens over the dired heat: that shades the directory you are already
in, this lists one directory in full and says what has happened beneath
each entry, so several agents spread over a large repository are visible
at once.  With ASK (a prefix argument), prompts for the directory to
start from instead of deriving it from the sessions.

Needs no mode to be switched on: the buffer is the consent, and killing it
takes the map off the event stream."
  (interactive "P")
  (let ((root (if ask
                  (read-directory-name "Map: " nil nil t)
                (agent-river--map-default-root)))
        (buffer (get-buffer-create agent-river-map-buffer-name)))
    (with-current-buffer buffer
      ;; Set unconditionally rather than only on a fresh buffer: the answer
      ;; can change between two calls -- a grammar installed, or this file
      ;; reloaded -- and the mode is what decides how the buffer is read.
      (if (agent-river--markdown-ts-p)
          (agent-river-map-mode)
        (agent-river-map-plain-mode))
      (setq agent-river--map-root (directory-file-name (expand-file-name root))
            agent-river--map-folds nil)
      (add-hook 'kill-buffer-hook #'agent-river--map-teardown nil t))
    (add-hook 'agent-river-observers #'agent-river--map-observe)
    (agent-river--map-draw)
    (agent-river--ensure-map-timer)
    (pop-to-buffer buffer)))

;;; Foreign saves, noted from Emacs
;;
;; The flow runs the other way here.  Everything above turns hook events into
;; a state and then into views; this turns something only Emacs can see into
;; an event, via `agent-river-note'.  The two halves close the circle:
;;
;;   hooks       -> fold -> observers -> the outside world   (the dired heat)
;;   Emacs       -> note  -> fold -> observers               (this)
;;
;; So it does not hang off `agent-river-observers' -- that hook fires on the
;; agent's events, and this one has to fire on yours.
;;
;; What it is for: the agent is editing a file, you have it open and edit it
;; too.  Either its next edit fails on a string that moved, which is loud and
;; harmless, or it lands and quietly overwrites you.  Nothing in the hook
;; stream can see that coming -- the agent's staleness check knows the disk,
;; not your buffers -- so this is the case `agent-river-note' exists for: a
;; point-in-time fact that nothing could recompute once it has passed.
;;
;; Note what happened, never what to make of it.  "You saved a file the agent
;; is working in" is a fact; "its read is stale" is a conclusion, and drawing
;; conclusions here would put an opinion into the measured state.  Reading the
;; notes and deciding what, if anything, to tell the agent is a separate step
;; that is deliberately not built yet: first it has to be clear how often
;; these fire in real use.

(defcustom agent-river-foreign-save-scope 'task
  "Which artifact frame decides that a saved file is worth noting.

`task' notes a save only while the agent's current turn is in that file,
which is when a collision actually costs something.  `session' notes
anything it has been in at all this session, which is a wider net and a
noisier one."
  :type '(choice (const task) (const session)))

(defun agent-river--frame-touches (state name &optional scope)
  "Return how often STATE touched the file called NAME, or nil for never.

Matched on the bare name, the way `agent-river-touching' does it, so a
file reached from a worktree and from the main checkout is one file.
SCOPE is `session' for the whole session, `task' or nil for this turn."
  (let ((total 0))
    (maphash (lambda (path entry)
               (when (equal (file-name-nondirectory path) name)
                 (setq total (+ total (or (plist-get entry :touches) 0)))))
             (if (eq scope 'session)
                 (agent-river-state-artifacts state)
               (agent-river-state-task-artifacts state)))
    (and (> total 0) total)))

(defun agent-river--agent-in-flight-p (state name)
  "Return non-nil when STATE has a step running against the file called NAME.

The one case where a save is not evidence of anything: a tool call is open
on this very file, so the write may be the agent's own landing rather than
a human's.  Feeding that back as something observed about the agent would
launder its own action into an observation about it -- the closed loop the
`intent' slots are kept apart to prevent.

Deliberately narrow.  It suppresses nothing once the call has returned, so
a format-on-save firing a moment after the agent's write still produces a
note.  That is the right way round for now: the point of noting before
signalling is to find out how often these fire, and a filter tuned before
the evidence exists is tuned on a guess."
  (let ((step (agent-river-state-step state)))
    (and step
         (plist-get step :file)
         (equal (file-name-nondirectory (plist-get step :file)) name))))

(defun agent-river--frame-word (&optional scope)
  "Return the name SCOPE goes by in a sentence.
Said rather than assumed: the frame used to be written into the note as
\"this task\" whatever `agent-river-foreign-save-scope' was set to, so
one of the two settings put a number under the wrong heading."
  (if (eq (or scope agent-river-foreign-save-scope) 'session)
      "this session"
    "this task"))

(defun agent-river--touch-phrase (who touches)
  "Return TOUCHES by WHO as a phrase, WHO nil for the session itself."
  (format "%s%d touch%s"
          (if who (concat who " ") "")
          touches
          (if (= touches 1) "" "es")))

(defun agent-river--family-in-file (state name)
  "Return who in STATE's family is working in the file called NAME.

A list of plists -- the session itself first, its subagents after -- each
carrying `:who' (nil for the session, the agent type for a subagent),
`:touches' and `:in-flight'.

The family rather than the session alone, because a delegated file lands
in the *subagent's* task frame and never in its parent's.  Asking the root
only meant that a human saving a file a subagent was editing produced no
note whatsoever -- silence in the case with the least supervision in it.

Finished and stale subagents drop out: the question is who is in the file
now, and a child that has stopped cannot be about to overwrite anything."
  (let ((scope agent-river-foreign-save-scope)
        parties)
    (let ((own (agent-river--frame-touches state name scope)))
      (when own
        (push (list :who nil :touches own
                    :in-flight (agent-river--agent-in-flight-p state name))
              parties)))
    (dolist (child (agent-river-children (agent-river-state-id state)))
      (when (agent-river--active-p child)
        (let ((touches (agent-river--frame-touches child name scope)))
          (when touches
            (push (list :who (or (agent-river-state-agent-type child) "subagent")
                        :touches touches
                        :in-flight (agent-river--agent-in-flight-p child name))
                  parties)))))
    (nreverse parties)))

(defun agent-river-note-foreign-save (file)
  "Note FILE as saved outside any session, or subagent, working in it.

The note is addressed to the root session even when it is a subagent that
holds the file, because a root is the only thing that can be told
anything -- see `agent-river--answerable-p', where that is measured rather
than assumed.  Which is exactly why the note has to name who is in there:
addressed to the parent and silent about the child, it would read as a
statement about the parent's own work.

The file is carried as the note's `:path' as well as named in its text, so
an observer can reach it on disk -- the dired view pulses the entry a save
landed in.  It warms nothing: the agent did not touch this file, and a note
that shaded its entry would draw a claim the state cannot support.

Returns the ids noted, so the caller can tell silence from a miss.  Takes
the name rather than reading `buffer-file-name' itself: that makes the
whole decision testable without a buffer, a file on disk or a save."
  (let ((name (file-name-nondirectory file))
        noted)
    (maphash
     (lambda (id state)
       (when (and (null (agent-river-state-parent state))
                  (agent-river--active-p state))
         (let ((parties (agent-river--family-in-file state name)))
           ;; An open call on this file anywhere in the family makes the save
           ;; ambiguous -- it may be that agent's own write landing -- and the
           ;; family is the right scope for the guard now that it is the scope
           ;; for the question.
           (when (and parties
                      (not (seq-some (lambda (party) (plist-get party :in-flight))
                                     parties)))
             (agent-river-note
              (format "%s saved outside the session (%s: %s)"
                      name
                      (agent-river--frame-word)
                      (mapconcat (lambda (party)
                                   (agent-river--touch-phrase
                                    (plist-get party :who)
                                    (plist-get party :touches)))
                                 parties ", "))
              id file)
             (push id noted)))))
     agent-river-registry)
    noted))

(defun agent-river--after-save ()
  "Note the file this buffer just saved, if an agent is working in it."
  (when buffer-file-name
    ;; The same bargain the hook path makes, for the same reason: never break
    ;; the thing being observed over the observing.  An error raised inside
    ;; `after-save-hook' abandons the rest of the chain and lands in the
    ;; user's face on every single save, over what is only a log line.  So it
    ;; retires the mode instead, and says so rather than going quiet.
    (condition-case err
        (agent-river-note-foreign-save buffer-file-name)
      (error
       (agent-river-watch-saves-mode -1)
       (ignore-errors
         (agent-river-log "fail" (format "save watch stopped (%s)"
                                         (error-message-string err))))))))

;;;###autoload
(define-minor-mode agent-river-watch-saves-mode
  "Note when you save a file an agent is currently working in.

Off by default like every other side effect here, though this one only
writes into agent-river's own state and buffer -- the consent it needs is
for watching every save you make, not for what it does with them."
  :global t
  (if agent-river-watch-saves-mode
      (add-hook 'after-save-hook #'agent-river--after-save)
    (remove-hook 'after-save-hook #'agent-river--after-save)))

(provide 'agent-river)
;;; agent-river.el ends here
