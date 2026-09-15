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

(defcustom agent-river-max-entries 100
  "How many log lines to keep.
The buffer is newest-first, so the oldest lines sit at the bottom and are
dropped from there.  Zero or less keeps everything, which will grow
without bound."
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

(defcustom agent-river-spinner-frames
  '("✢" "✳" "✶" "✻" "✽" "✻" "✶" "✳")
  "Star-like glyphs the session marker cycles through while a turn runs.

Drawn over the `*' that makes a session line an outline heading, never in
place of it: `outline-regexp' matches the buffer text, so animating the
character itself would stop the block being a document the moment an
agent started working.  A `display' property changes what is shown and
leaves the text alone.

Nil turns the animation off and leaves the bare star -- which is also the
answer for a font without these glyphs, where the alternative is a row of
boxes.  Each frame should be one column wide, or the line will shift as
it spins."
  :type '(repeat string))

(defcustom agent-river-spinner-interval 0.6
  "Seconds between frames of the session marker's animation.
Separate from `agent-river-refresh-interval' because the two do different
amounts of work: a frame moves one text property, a refresh rebuilds the
whole block, and a block rebuilt at an animation's rate would fight
whoever is reading it.

It is also the phase's unit: a marker's frame is how long its own turn has
been running divided by this, so changing it re-times the animation
without anything having to be restarted -- though a timer already running
keeps the rate it was started at until the next turn.

Slow on purpose.  The marker says an agent is working, which is a fact
that holds for minutes; at a frame every 0.15 s it read as something
demanding attention, and with several sessions the block flickered.  It is
also what makes two markers being out of phase legible at all -- at speed
they are a blur either way."
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
  '(("exploring" . ("Read" "Grep" "Glob" "WebFetch" "WebSearch" "Agent" "LSP"
                    "read" "search" "fetch"))
    ("editing"   . ("Edit" "Write" "NotebookEdit"
                    "edit" "delete" "move")))
  "Tools that place a step in a phase, keyed by phase name.

Two dialects in one list, because a step is matched by name and the two
ways in do not name a tool alike.  The hooks report the host's own tool
name; an agent-shell session has none to report, so
`agent-river--shell-payload' stands the ACP call `kind' in for it --
lower-case and coarser.  Listing only the first left a hooks-less session
matching nothing at all: no phase ever, and -- since
`agent-river--writing-p' reads this table -- no write ever, so the map's
landed marker lost the half of its question only the fold can answer.

ACP `think' and `other' are deliberately absent.  The phase abstains
rather than guess, the same way a shell call does."
  :type '(alist :key-type string :value-type (repeat string)))

(defcustom agent-river-shell-tools '("Bash" "BashOutput" "execute")
  "Tools whose step text is searched for `agent-river-verify-regexp'.
`execute' is the ACP kind a shell call arrives as; see
`agent-river-phase-buckets' for why both dialects are listed."
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

(defface agent-river-gone '((t :inherit agent-river-stale :strike-through t))
  "Face for a name the state knows and the disk does not.

Struck through rather than merely greyed, because grey is the map's word
for several things at once -- stale, cold, elided -- and \"this file is
not there\" is worth saying exactly.  A face and not Markdown `~~\': the
names are code spans and inline markup does not apply inside one, and the
map's shading already travels as an overlay because tree-sitter owns
`face' in that buffer.  So this works in the plain fallback too.")

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
  ;; hash: artifact key -> the absolute directory it really sits in, for the
  ;; keys `cwd' cannot place.  `agent-river--rel' degrades a file outside the
  ;; cwd to a bare basename, so resolving it against the cwd puts it in a
  ;; directory no agent ever opened -- which is how a file edited under
  ;; ~/.claude showed up inside the project tree.  Only the strays are
  ;; recorded: a key that resolves under the cwd is anchored by the cwd
  ;; already, and storing it twice gives the two a way to disagree.
  anchors
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

(defconst agent-river--shell-rescan 5
  "Seconds before a session with no agent-shell buffer is looked for again.
Long enough that a session nobody here hosts costs nothing to keep asking
about, short enough that one whose buffer arrives late is picked up while
it is still the same turn.")

(defvar agent-river--shell-sessions (make-hash-table :test 'equal)
  "What is known about who hosts each session, as id -> BUFFER or (none . TIME).

The index behind `agent-river--shell-buffer', and the reason liveness is
cheap.  A buffer recorded here is one we have seen hosting that session,
and it is kept after it dies: that a session *had* a buffer and no longer
does is exactly what tells `agent-river--active-p' and
`agent-river--gone-p' that it is over, and it is the one thing a snapshot
of the buffers alive now can never say.")

(defun agent-river--shell-scan (id)
  "Return the agent-shell buffer hosting session ID by looking for it.
The expensive half of `agent-river--shell-buffer': this walks every buffer
in Emacs, which in a long-lived one is thousands of them."
  (seq-find
   (lambda (buffer)
     (with-current-buffer buffer
       (and (agent-river--shell-buffer-p)
            (equal id (alist-get :id (alist-get :session
                                                (bound-and-true-p
                                                 agent-shell--state)))))))
   (buffer-list)))

(defun agent-river--shell-buffer (id)
  "Return the agent-shell buffer hosting session ID, or nil.

Answered from `agent-river--shell-sessions' wherever it can be.  This is
asked of every session by every redraw -- for its label, for whether the
line can be jumped to, for whether it is still alive -- and a walk of the
buffer list each time was most of what drawing the block cost: measured at
1.4 ms a call in an Emacs with ten thousand buffers, against 13 ms for the
whole block.

Three things can be known about an id, and the difference between the last
two is the point:

  - a buffer we have seen.  Live, it is the answer; dead, the session is
    over and nothing will host that id again -- `agent-shell-restart' kills
    the buffer and starts a *new* session -- so the answer is nil, and
    still without looking.
  - nothing at all: look, and remember what was found.
  - looked and found nothing, with the time.  Looked for again every
    `agent-river--shell-rescan' seconds.  Remembering that permanently
    would be cheaper and is a trap: a session whose first event beats
    agent-shell to setting its id would be counted unhosted for the rest of
    the Emacs session -- no label from its buffer, no reasoning lines, no
    RET -- and nothing would ever say so."
  (let ((known (gethash id agent-river--shell-sessions)))
    (cond
     ((buffer-live-p known) known)
     ((bufferp known) nil)
     ((and (consp known)
           (< (float-time (time-since (cdr known))) agent-river--shell-rescan))
      nil)
     (t (let ((found (agent-river--shell-scan id)))
          (puthash id (or found (cons 'none (current-time)))
                   agent-river--shell-sessions)
          found)))))

(defun agent-river--shell-hosted (id)
  "Return the buffer we have seen hosting session ID, alive or dead.

Nil for a session nobody here has ever hosted, which is a different answer
from `agent-river--shell-buffer' returning nil and has to stay different:
one says the session has ended, the other that it was never ours to watch.
A session run from a terminal has no buffer to lose, and calling it dead
for that would be calling every CLI session dead."
  (let ((known (gethash id agent-river--shell-sessions)))
    (and (bufferp known) known)))

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
                             :anchors (make-hash-table :test 'equal)
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

For a root session we have seen agent-shell hosting, the buffer settles
it: the process runs in this Emacs, so whether it is alive is a fact and
not an estimate.  The TTL is what is left for everything else --
subagents, and sessions nobody here owns -- and it was only ever a way of
guessing at something we could not see.

Asked of `agent-river--shell-hosted', which is per session, where this
used to ask a flag that went sticky as soon as agent-shell had hosted
*anything* here.  The flag was a way of not forgetting a buffer that had
died, which the index does properly; what it cost was every session run
from a terminal, which has no buffer here and never did and was called
inactive for it."
  (cond
   ((agent-river-state-done state) nil)
   ((and (null (agent-river-state-parent state))
         (agent-river--shell-hosted (agent-river-state-id state)))
    (and (agent-river--shell-buffer (agent-river-state-id state)) t))
   (t (let ((seen (agent-river-state-last-seen state)))
        (and seen (< (float-time (time-subtract (current-time) seen))
                     agent-river-session-ttl))))))

(defun agent-river--gone-p (state)
  "Return non-nil when STATE's session is known to have ended.

Deliberately narrower than the negation of `agent-river--active-p': that
one falls back to the TTL, and a session that has merely gone quiet for
longer than the TTL is a guess at something we cannot see.  This is asked
where a view stops saying something -- the map's position markers, and
the names it keeps on a cold file -- so it answers from facts only: a
session we saw agent-shell hosting whose buffer has since been killed,
and a subagent whose own SubagentStop said it was finished.  A silent
session nobody here owns is not gone, it is silent, and withdrawing a
reading over that would be acting on an estimate.

Which is why the root branch is gated on `agent-river--shell-hosted' and
not merely on there being no buffer: a session run from a terminal with
hooks wired has no buffer here and never did, and calling that gone would
take its name and its marker off the map while it was still working.

A subagent goes with its root as well, since a child of a session that no
longer exists cannot still be running -- and the TTL, which is all a
subagent otherwise has, would take minutes to notice."
  (cond
   ((agent-river-state-parent state)
    (or (and (agent-river-state-done state) t)
        (let ((root (gethash (agent-river-state-parent state)
                             agent-river-registry)))
          (and root (agent-river--gone-p root)))))
   ((agent-river--shell-hosted (agent-river-state-id state))
    (not (agent-river--shell-buffer (agent-river-state-id state))))))

(defun agent-river--state-working-p (state)
  "Return non-nil while STATE is mid-turn, as opposed to merely alive.

Deliberately narrower than `agent-river--active-p': a session that has
ended its turn is still live, but nothing is happening in it, and a clock
ticking -- or a marker spinning -- over an idle agent claims work that is
not being done.

This is what both timers are gated on, so the animation and the elapsed
times agree about when a turn is over rather than each deciding for
itself."
  (and (agent-river--active-p state)
       (not (agent-river-state-idle state))))

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

(defun agent-river--writing-p (tool)
  "Return non-nil when TOOL is one that changes a file.

Read off the `editing' bucket of `agent-river-phase-buckets' rather than
from a list of its own: that bucket is already this package's answer to
\"did this step change something\", and a second list would be a second
place to teach it a host\='s dialect."
  (and tool
       (member tool (cdr (assoc "editing" agent-river-phase-buckets)))
       t))

(defun agent-river--touch-1 (table path &optional wrote)
  "Record one touch of PATH in TABLE, a writing one with WROTE.

Writes are counted apart from touches because reading a file and changing
it are different things to have done, and one view needs to tell them
apart: git can say a file is identical to the main branch, but not whether
that is because the work landed there or because nobody ever changed it.
Only what the agent did can answer that half."
  (let ((entry (gethash path table)))
    (puthash path
             (list :touches (1+ (or (plist-get entry :touches) 0))
                   :writes (+ (or (plist-get entry :writes) 0) (if wrote 1 0))
                   :last (current-time))
             table)))

(defun agent-river--touch (state path &optional wrote)
  "Record that the session behind STATE touched PATH, writing it with WROTE.

Kept in two frames on purpose.  The session-wide tally is what
`agent-river-touching' needs to spot two agents on one file, and it must
survive a change of task.  The per-task tally is what an observer wants:
\"what is being worked on now\", not \"what has been opened all
afternoon\".  Reporting one while labelling it the other is how a panel
starts misleading people."
  (when (and path (not (string-empty-p path)))
    (agent-river--touch-1 (agent-river-state-artifacts state) path wrote)
    (agent-river--touch-1 (agent-river-state-task-artifacts state) path wrote)))

(defun agent-river--anchor (state key path)
  "Record where KEY really sits, given the absolute PATH it was folded from.

Only for the keys the cwd cannot place.  `agent-river--rel' leaves a file
outside the session's cwd as a bare basename, which a view then resolves
against the cwd and draws inside a tree the file has nothing to do with.
The directory is kept here instead of in the key so the key stays
normalised -- one file reached from a worktree and from the main checkout
is still one artifact, and only the question of *where* consults this.

A key that has moved back under the cwd drops its anchor rather than
keeping the old one: the same basename can be reached both ways, and a
stale anchor would go on claiming the outside directory forever."
  (let ((table (agent-river-state-anchors state))
        (cwd (agent-river-state-cwd state)))
    (when (and table key (not (string-empty-p key))
               path (not (string-empty-p path)))
      (if (and cwd (not (string-empty-p cwd))
               (string-prefix-p (file-name-as-directory cwd) path))
          (remhash key table)
        (puthash key (directory-file-name (file-name-directory path)) table)))))

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
        (path (plist-get event :path))
        (ms   (plist-get event :ms)))
    ;; Folded rather than set where the state is addressed, so it keeps the
    ;; promise the docstring makes: replay the events and the anchor comes
    ;; back with them.  Refreshed on every event that carries one rather than
    ;; kept from the first, though measured on 2026-09-14 that moves nothing
    ;; on the hook path: a payload's cwd is the directory the agent was
    ;; started in, repeated identically on every event, and a `cd' inside a
    ;; Bash call is another process that never reaches it.  Only the
    ;; agent-shell path can move it -- it reads the buffer's
    ;; `default-directory' per event, so `M-x cd' there re-anchors the
    ;; session, and keys folded before that go on resolving against the new
    ;; cwd.  Left that way deliberately: a second account per key is a lot of
    ;; bookkeeping for a case only a hand gesture can provoke.  Events made
    ;; inside Emacs -- a note, a signal -- carry none and leave it alone.
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
      (agent-river--touch state file (agent-river--writing-p tool))
      (agent-river--anchor state file path))

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

     ((equal kind "forget")
      ;; The artifact tables emptied, and nothing else: the session goes on,
      ;; its steps and failures still count, and only the record of which
      ;; files it has been in is dropped.  Folded rather than cleared where
      ;; the command is written, because the fold owns the state -- a
      ;; `clrhash' from outside would be a transition no event accounts for,
      ;; and the replay promise in `agent-river-fold's docstring would stop
      ;; being true without anything failing.
      ;;
      ;; The anchors go with them.  They are keyed on artifact keys, so
      ;; without the artifacts they address nothing, and a later touch of
      ;; the same file re-folds the anchor from its `:path' anyway.
      ;;
      ;; `:files' narrows the same transition to the keys it names, which is
      ;; what `agent-river-forget-gone-files' folds.  One branch rather than
      ;; two: the state change is identical and only its subject differs, and
      ;; a second kind would be a second place for "what forgetting means"
      ;; to be decided.
      (let ((files (plist-get event :files)))
        (if files
            (dolist (file files)
              (remhash file (agent-river-state-artifacts state))
              (remhash file (agent-river-state-task-artifacts state))
              (remhash file (agent-river-state-anchors state)))
          (clrhash (agent-river-state-artifacts state))
          (clrhash (agent-river-state-task-artifacts state))
          (clrhash (agent-river-state-anchors state)))))

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

(defun agent-river--interrupted-p (payload)
  "Non-nil when PAYLOAD's tool response says the user stopped the call.

Guarded with `consp' like `agent-river--failed-p', and for a reason that
had already bitten: a tool response is not always an alist.  An MCP tool
answers with an *array* of content parts, and the hook parses arrays as
vectors, so `alist-get' threw on every one of them -- which cost the
whole event, leaving each MCP call unfolded and logged as `hook failed'
instead of counted."
  (let ((response (alist-get 'tool_response payload)))
    (and (consp response)
         (eq t (alist-get 'interrupted response)))))

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
      (concat tool (if (agent-river--interrupted-p payload) " ✗" " ✓") took))
     (t (let ((arg (agent-river--salient input (alist-get 'cwd payload))))
          (concat tool (if (string-empty-p arg) "" (concat "  " arg))))))))

(defun agent-river--outcome (kind payload)
  "Return how a call of KIND ended, for appending to the line that began it.
Nil for a kind that does not end one.

Only the verdict and the duration, without the tool name `agent-river--detail'
repeats: this is written onto the `act' line, which already names the tool."
  (let* ((ms (alist-get 'duration_ms payload))
         (took (if ms (concat "  " (agent-river--dur ms)) "")))
    (cond
     ((equal kind "fail") (concat "✗" took))
     ((equal kind "think")
      (concat (if (agent-river--interrupted-p payload) "✗" "✓") took)))))

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
          ;; folded *into a key*: the artifact tables are keyed on the
          ;; normalised form, and an absolute path in them would make one file
          ;; reached from a worktree and from the main checkout count as two
          ;; again.  Its directory alone is folded, and only for the keys the
          ;; cwd cannot place -- see `agent-river--anchor'.
          :path file
          ;; Which tool call this is, so the line a call opened can be
          ;; completed in place rather than answered by a second line.  Paired
          ;; with the session because the hosts do not agree on how wide a
          ;; call id is unique: Claude Code's `tool_use_id' is unique
          ;; everywhere, ACP's is unique only within its session.
          :call (let ((id (alist-get 'tool_use_id payload)))
                  (when (and id (not (string-empty-p (format "%s" id))))
                    (format "%s\0%s"
                            (or (alist-get 'session_id payload) "unknown") id)))
          :outcome (agent-river--outcome kind payload)
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
the dying buffer and draw the session straight back in.

The map is told as well, and it has to be told here.  Its names and its
position markers are the other view that reads a session as existing, and
nothing else will ever say otherwise: a killed session sends no further
events, so with no other agent running the map would have sat there
naming it until someone pressed `g'.  Marking it dirty is enough -- the
map's timer defers the redraw for us, past this buffer's death."
  (remhash buffer agent-river--teardown-hooked)
  (run-at-time 0 nil #'agent-river--redraw-block)
  (agent-river--map-invalidate))

(defun agent-river--ensure-shell-teardown (id)
  "Ensure BUFFER's session teardown is installed for session ID at most once.
Where agent-shell hosts ID, its buffer dying is how a restart or a kill
reaches us -- no hook event reports it, and a watched session sees only
`clean-up', which folds nothing.

The lookup is also what puts ID in `agent-river--shell-sessions', which is
where both liveness questions read it from afterwards.  Called from
`agent-river-observe' on every event, so a session is recorded as hosted
on its first one."
  (let ((buffer (agent-river--shell-buffer id)))
    (when buffer
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

(defun agent-river--shell-payload (call session cwd &optional ms id)
  "Return tool CALL of SESSION in the shape the hooks report, given CWD.
MS is how long the call took, where that is known.  ID is the call's own
identifier, reported as `tool_use_id' because that is what the hooks name
it -- the point of this shape is that `agent-river--event' need not know
which side it came from.

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
            (when ms `((duration_ms . ,ms)))
            (when id `((tool_use_id . ,id))))))

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
              (id (alist-get :tool-call-id data))
              (key (format "%s\0%s" session id))
              (started (gethash key agent-river--tool-calls))
              (ended (pcase (alist-get :status call)
                       ("completed" "think")
                       ("failed" "fail")))
              events)
         (unless started
           (setq started (current-time))
           (puthash key started agent-river--tool-calls)
           (push (agent-river--event
                  "act" (agent-river--shell-payload call session cwd nil id))
                 events))
         (when ended
           (remhash key agent-river--tool-calls)
           (push (agent-river--event
                  ended (agent-river--shell-payload
                         call session cwd
                         (round (* 1000 (float-time
                                         (time-subtract (current-time)
                                                        started))))
                         id))
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
    (let ((label (agent-river-state-label state))
          (call (plist-get event :call)))
      ;; A call that ends is written onto the line that began it, so one tool
      ;; call reads as one line and the log holds twice as much history at the
      ;; same `agent-river-max-entries'.  Where that line is gone -- trimmed,
      ;; or never written because this Emacs started mid-run -- the outcome
      ;; falls back to a line of its own rather than vanishing.
      (cond
       ((agent-river--log-outcome call (plist-get event :outcome) kind))
       ((not (string-empty-p detail))
        (agent-river-log kind detail label call)))
      (agent-river--ensure-timer)
      (agent-river--ensure-spinner)
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
                  ;; Explicit, because the answer is JSON for another process
                  ;; and the locale this runs under is not ours to assume.  A
                  ;; signal naming a file with a non-ASCII character used to
                  ;; stop here asking which coding system to use, which in a
                  ;; hook is an answer nobody is there to give.
                  (set-buffer-file-coding-system 'utf-8-unix)
                  (insert (json-serialize
                           `((hookSpecificOutput
                              . ((hookEventName . ,name)
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
  ;; The session lines are outline headings, so `outline-cycle' (TAB) can
  ;; fold each session's details.  The fold is for looking, not state: it
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

(defun agent-river--spinning-since (state)
  "Return when STATE's turn began, which is the phase its marker spins on.
The task's own clock, falling back to the session's where no prompt has
been seen -- never a clock of the animation's, so nothing has to be kept
in step with anything and a redraw cannot jog the marker."
  (or (agent-river-state-task-started state)
      (agent-river-state-started state)))

(defun agent-river--spinner-glyph (since)
  "Return the frame a marker whose turn began at SINCE is showing.

The phase is that session's own, so two agents given their prompts at
different moments spin out of step -- which is what they are.  A single
counter for the whole block put every marker on the same frame whatever
each session was doing, and a row of markers moving as one reads as one
animation about the block rather than as one apiece.

Derived from the clock rather than advanced by the timer, so the timer
below has no state to keep and a redraw mid-turn cannot reset the phase.

Nil when the animation is off, which is what leaves the bare star."
  (let ((frames agent-river-spinner-frames)
        (interval agent-river-spinner-interval))
    (when (and (consp frames) since (numberp interval) (> interval 0))
      (nth (mod (floor (float-time (time-since since)) interval) (length frames))
           frames))))

(defun agent-river--star (state)
  "Return the outline marker opening STATE's block line.

Always the literal `* ' -- `outline-regexp' is matched against the buffer
text, so the animation is a `display' property over the star rather than
a different character in its place.  The star is marked with
`agent-river-spinner' where it is built, and the mark is that session's
phase: the frame timer finds the lines that are spinning and reads what
each should be showing off the mark itself, without re-deriving which
sessions are working or matching a regexp over the rendered text."
  (let* ((since (and (agent-river--state-working-p state)
                     (agent-river--spinning-since state)))
         (glyph (and since (agent-river--spinner-glyph since))))
    (if glyph
        (concat (propertize "*" 'agent-river-spinner since 'display glyph) " ")
      "* ")))

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
                    (concat (agent-river--star state)
                            (mapconcat #'identity parts " · "))
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
  "Return one panel line per live session, and nothing else.

There is no heading closing the block off from the log below it.  One was
tried -- `* -- eventlog', so the log was an outline subtree TAB could fold
away -- and removed: a divider that exists only to be a fold handle earns
its line from nobody who is reading, and TAB now unfolds the session under
point instead.

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
                  "\n")))))

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

(defun agent-river--render (kind detail &optional label call)
  "Return the display line for DETAIL under event KIND, tagged with LABEL.
CALL is the tool call the line opens, which `agent-river--log-outcome'
later finds it by."
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
                'agent-river-kind kind
                'agent-river-call call)))

(defvar-local agent-river--block-end nil
  "Marker just past the state block, or nil while none is drawn.")

(defun agent-river--erase-block ()
  "Remove the state block from the head of the current buffer."
  (when (and (markerp agent-river--block-end)
             (marker-position agent-river--block-end))
    (delete-region (point-min) agent-river--block-end)
    (set-marker agent-river--block-end nil)))

(defun agent-river--insert-block ()
  "Draw the state block at the head of the current buffer.

The blank line closing it belongs to the block, not to the log: it is
erased and redrawn with it, so it cannot be left behind by a session
ending, and `agent-river--block-end' goes on meaning what everything
downstream reads it as -- the start of the newest log line, which is
where `agent-river--head-end' measures the head to and where
`agent-river--log-outcome' starts looking.

The separator is what a heading over the log used to be, at a line's
cost rather than a line plus a label.  Without it the block's last
session runs straight into the newest event, and the two halves of the
buffer -- the state, and the stream it was folded from -- read as one
list."
  (let ((block (agent-river--panel-block)))
    (when block
      (goto-char (point-min))
      (insert block "\n\n")
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

(defun agent-river--log-outcome (call outcome kind)
  "Write OUTCOME onto the logged line that opened tool CALL, if it is still here.
Return non-nil when one was found and amended.

Nil when there is none -- the line may have been trimmed away, the host
may name no call, or the run may have started before this Emacs did --
and the caller then logs an ordinary line, so an outcome is never
silently dropped on the way to being tidier.

KIND picks the face, so a failure still reads as one against the `act'
colouring of the line it is written onto.  The call is cleared from the
line afterwards: a second outcome for one call would otherwise append a
second verdict to a line that already carries its own."
  (let ((buffer (and call outcome (not (string-empty-p outcome))
                     (get-buffer agent-river-buffer-name))))
    (when buffer
      (with-current-buffer buffer
        (save-excursion
          ;; From the end of the block: everything above it is the state, and
          ;; only log lines ever carry a call.
          (goto-char (or (and (markerp agent-river--block-end)
                              (marker-position agent-river--block-end))
                         (point-min)))
          (let (found)
            (while (and (not found) (not (eobp)))
              (if (equal call (get-text-property (point) 'agent-river-call))
                  (setq found t)
                (forward-line 1)))
            (when found
              (let* ((inhibit-read-only t)
                     (face (nth 2 (or (assoc kind agent-river-kinds)
                                      (assoc "think" agent-river-kinds))))
                     ;; The line's own properties, so the appended text wraps
                     ;; and is walked over exactly as the rest of it is.
                     (props (plist-put (copy-sequence (text-properties-at (point)))
                                       'face face))
                     (start (line-beginning-position))
                     (end (line-end-position)))
                (goto-char end)
                (insert (apply #'propertize (concat " (" outcome ")") props))
                (put-text-property start (line-end-position)
                                   'agent-river-call nil)
                t))))))))

;;;###autoload
(defun agent-river-log (kind detail &optional label call)
  "Append DETAIL to the HUD as an event of KIND, tagged with session LABEL.
CALL names the tool call this line opens, so its outcome can later be
written onto this line instead of taking one of its own.
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
          (insert (agent-river--render kind detail label call) "\n")
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
  (clrhash agent-river--shell-sessions)
  (agent-river--stop-timer)
  (agent-river--stop-spinner))


;;;###autoload
(defun agent-river-forget-artifacts ()
  "Forget which files the sessions have been in, keeping the sessions.

For the moment work lands -- a merge, a release -- after which the files
it was in are history rather than context.  `agent-river-map-party-floor'
handles the everyday case on its own by letting a name fade, but cold is
not the same as done, and only you know which has just happened.

Not the same as `agent-river-reset', which forgets the sessions
themselves.  Here the steps, the failures and the task survive; only the
record of where the work was is dropped.

Deliberately left off the map's keymap.  It throws measurements away with
no way back, and a single keystroke in a view buffer is the wrong gesture
for that.  `agent-river-forget-gone-files' is the one that is bound
there, and the difference is its subject: it drops only what is about a
file that no longer exists."
  (interactive)
  (let ((n 0))
    (maphash (lambda (_key state)
               (setq n (+ n (hash-table-count (agent-river-state-artifacts state))))
               (agent-river-fold state '(:kind "forget")))
             agent-river-registry)
    (agent-river--forget-reported
     (format "forgot %d artifact%s" n (if (= n 1) "" "s")))))

(defun agent-river--forget-reported (text)
  "Say TEXT happened, and redraw the views a forget has just changed.

Logged only into a HUD that already exists.  `agent-river-log' would
otherwise create the buffer and `agent-river-auto-display' pop a window
for it, which is a lot of furniture to move in answer to a command run
from the map.

The map is drawn rather than marked dirty: its timer only runs while an
agent is working, so a flag set between turns would sit there until the
next one and the view would go on naming what was just forgotten."
  (if (get-buffer agent-river-buffer-name)
      (agent-river-log "note" text)
    (agent-river--redraw-block))
  (agent-river--map-draw)
  (message "agent-river: %s" text))

(defun agent-river--artifact-gone-p (state key)
  "Return non-nil when STATE's artifact KEY names a file that is not there.

Placed the way every other view places a key -- through
`agent-river--heat-absolute', so the anchor wins over the cwd for a file
that was reached from outside it, and so this cannot decide a file is
gone by looking for it in a directory no agent ever opened.

A key that cannot be placed at all is not gone but unplaceable, and is
kept: a state folded without a cwd would otherwise have every artifact it
ever recorded swept away by a command that never found any of them."
  (let ((abs (agent-river--heat-absolute
              (list :cwd (agent-river-state-cwd state)
                    :anchor (let ((anchors (agent-river-state-anchors state)))
                              (and anchors (gethash key anchors)))
                    :file key))))
    (and abs (not (file-exists-p abs)))))

(defun agent-river--gone-artifacts (state)
  "Return STATE's artifact keys whose files are no longer on disk.

Read from the session frame, which is the wider of the two: a file
deleted during an earlier task is just as gone, and sweeping only the
task frame would leave the session frame naming it -- and the map, which
reads the session frame by default, still drawing it."
  (let (gone)
    (maphash (lambda (key _entry)
               (when (agent-river--artifact-gone-p state key)
                 (push key gone)))
             (agent-river-state-artifacts state))
    gone))

;;;###autoload
(defun agent-river-forget-gone-files ()
  "Forget the artifacts naming files that are no longer on disk.

The map strikes those names through rather than dropping them, because a
deletion is a thing the agent did and losing it would make the view
flicker through every branch switch.  That is right while the deletion is
news and wrong once it is history -- after a merge or a cleanup the
struck-through lines are a list of what used to be there, and only you
know when that moment has come.  So this is a command and not a rule.

Measured against the disk, not against the strike-through.  An entry is
also drawn as missing when it was reached through an anchor the root
being listed has nothing to do with, and that file is not gone but
elsewhere -- sweeping it would throw away a measurement about a file that
still exists.  Such a line therefore stays struck through afterwards,
which looks like the command missing one and is the command refusing one.

Bound to \\<agent-river-map-mode-map>\\[agent-river-forget-gone-files] in the map, unlike
`agent-river-forget-artifacts': the subject here is already gone, so what
is lost is the record of an absence rather than the record of the work.
It still asks, because a keystroke in a view buffer is easy to hit and
nothing undoes this."
  (interactive)
  (let ((found nil) (n 0))
    (maphash (lambda (_key state)
               (let ((gone (agent-river--gone-artifacts state)))
                 (when gone
                   (push (cons state gone) found)
                   (setq n (+ n (length gone))))))
             agent-river-registry)
    (cond
     ((null found)
      (message "agent-river: no artifact names a file that is gone"))
     ((not (y-or-n-p (format "Forget %d artifact%s naming files that are gone? "
                             n (if (= n 1) "" "s"))))
      (message "agent-river: kept"))
     (t
      (dolist (cell found)
        (agent-river-fold (car cell) (list :kind "forget" :files (cdr cell))))
      (agent-river--forget-reported
       (format "forgot %d gone file%s" n (if (= n 1) "" "s")))))))

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

Per-session the question is `agent-river--state-working-p'; this asks it
of the registry, which is what makes both timers stop on their own
between turns instead of running for as long as Emacs does."
  (let (working)
    (maphash (lambda (_key state)
               (when (agent-river--state-working-p state)
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

On a session heading this unfolds that session's detail headings.  TAB is
for opening or closing the thing under the heading."
  (interactive)
  (agent-river-toggle-details))

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
  "Redraw the block, and stop the timer once no agent is working.

The redraw comes first even on the tick that retires the timer, and that
last one is load-bearing: it is what unmarks the stars of a session that
stopped working without an event to say so -- a killed agent-shell buffer
reports nothing -- and the animation reads those marks to know when to
stop.  It also leaves the elapsed times at what they finally were rather
than at whatever the previous tick drew."
  (condition-case err
      (progn
        (agent-river--redraw-block)
        (unless (agent-river--working-p)
          (agent-river--stop-timer)))
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

;; The marker animation is a second timer rather than a faster first one.
;; A frame has to land often enough to read as motion, and rebuilding the
;; whole block that often would both cost far more than the animation is
;; worth and drag the block out from under anybody reading it.  So this one
;; writes a `display' property onto the stars the panel already marked and
;; touches nothing else; it derives nothing, which is what would make it
;; safe to run many times a second.
;;
;; Nothing includes the question of whether to keep running.  Asking the
;; registry looked cheap and was not: `agent-river--active-p' used to find a
;; hosted session's buffer by walking every buffer in Emacs, which in a
;; long-lived one measured ~3 ms a tick, most of it consing a buffer list
;; for the garbage collector.  That lookup is indexed now, but the gate
;; stays where it was put: the panel has already decided the same question
;; when it marked the stars, so the marks are the gate and this loop
;; derives nothing at all.  What that costs is a redraw from the refresh
;; timer before it retires, since the marks are also what has to be taken
;; away when a turn ends with no event to announce it.

(defvar agent-river--spinner-timer nil
  "Repeating timer animating the session markers, or nil while none runs.")

(defun agent-river--block-limit ()
  "Return where the state block ends in the current buffer."
  (or (and (markerp agent-river--block-end)
           (marker-position agent-river--block-end))
      (point-min)))

(defun agent-river--spinning-p (buffer)
  "Return non-nil while BUFFER's state block has a marker to animate.

The gate the animation runs on, and deliberately read off the rendering
rather than off the registry.  `agent-river--star' marks a star exactly
when `agent-river--state-working-p' holds for that session, so this is the
same question one step later and cannot answer differently -- but asking
the registry meant asking `agent-river--active-p' of every session, which
for an agent-shell session walks every buffer in Emacs.  Six times a
second, that was most of what the animation cost."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (text-property-not-all (point-min) (agent-river--block-limit)
                                     'agent-river-spinner nil)
              t))))

(defun agent-river--spinner-paint (buffer &optional stop)
  "Show every spinning star in BUFFER the frame its own session is on.
With STOP, take the frames off and leave the bare stars instead.

Each star carries its session's phase as the value of its
`agent-river-spinner' property, so what to draw is read off the mark.
Scoped to the state block, which is the only place the marks are, and
found by the property rather than by looking for a star in the text --
the log below carries the agent's own words and a line of it may well
begin with one.

`with-silent-modifications' because this is not an edit anyone should be
able to undo, and at this rate an undo list of frame changes would grow
without bound."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (with-silent-modifications
        (let ((end (agent-river--block-limit))
              (pos (point-min)))
          (while (setq pos (text-property-not-all pos end 'agent-river-spinner nil))
            (let ((glyph (and (not stop)
                              (agent-river--spinner-glyph
                               (get-text-property pos 'agent-river-spinner)))))
              (if glyph
                  (put-text-property pos (1+ pos) 'display glyph)
                (remove-text-properties pos (1+ pos) '(display nil))))
            (setq pos (1+ pos))))))))

(defun agent-river--stop-spinner ()
  "Stop the animation and put the bare stars back.

Clearing is part of stopping: the last frame drawn is a `display'
property, so a timer that merely cancelled itself would leave every
finished session showing whichever glyph it happened to stop on, as
though it were still working."
  (when (timerp agent-river--spinner-timer)
    (cancel-timer agent-river--spinner-timer))
  (setq agent-river--spinner-timer nil)
  (agent-river--spinner-paint (get-buffer agent-river-buffer-name) t))

(defun agent-river--spin ()
  "Draw each session marker at its own phase, or stop once none is left.

Derives nothing: every frame it needs is written on the mark it is
painting, and whether to carry on is `agent-river--spinning-p'.  A tick
that asked the registry instead spent almost all of itself walking every
buffer in Emacs to decide whether anything was still working -- ~3 ms of
it, against 9 us for this -- an answer the panel had already reached when
it drew the block."
  (condition-case err
      (let ((buffer (get-buffer agent-river-buffer-name)))
        ;; get-buffer, not agent-river--buffer: a tick must never resurrect
        ;; a buffer the user has killed.
        (if (agent-river--spinning-p buffer)
            (agent-river--spinner-paint buffer)
          (agent-river--stop-spinner)))
    ;; Same bargain as the refresh timer: a tick that throws this often
    ;; would bury Emacs in messages, so it retires instead of repeating.
    (error (agent-river--stop-spinner)
           (message "agent-river: marker animation stopped (%s)"
                    (error-message-string err)))))

(defun agent-river--ensure-spinner ()
  "Start the marker animation if the block has a marker and none runs.
Asked of the block rather than of the registry, and it can be: the panel
is drawn before this is called, so the marks are already the answer."
  (when (and (null agent-river--spinner-timer)
             (agent-river--spinning-p (get-buffer agent-river-buffer-name)))
    (setq agent-river--spinner-timer
          (run-at-time agent-river-spinner-interval
                       agent-river-spinner-interval
                       #'agent-river--spin))))

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

(defun agent-river--gone-parties ()
  "Return a hash of party label to whether every session behind it has ended.

A party is a label, not a session, and two sessions can share one: two
`Explore' subagents of the same root are both `alpha/Explore'.  So the
answer is a fold over all of them rather than a lookup -- one live
sibling keeps the party alive, and asking per session would have buried
it with the finished one.

Kept apart from `agent-river--heat-entries': who still exists is a fact
about the registry and not about the artifact tables, and pushing a copy
of it onto every entry would be a second account of the same thing."
  (let ((gone (make-hash-table :test 'equal)))
    (maphash (lambda (_id state)
               (let ((party (agent-river--party-label state)))
                 (puthash party
                          (and (gethash party gone t)
                               (agent-river--gone-p state))
                          gone)))
             agent-river-registry)
    gone))

(defun agent-river--heat-entries (&optional scope)
  "Return one plist per artifact of every folded session.

Each carries `:party' (`agent-river--party-label'), `:cwd' (the anchor its
`:file' is relative to), `:file', the age-weighted `:weight' and `:last'.
`:anchor' is the real directory for a `:file' the cwd cannot place, and
nil for everything under it -- see `agent-river--anchor'.
SCOPE is `session' for the whole session, `task' or nil for the current
task.

The one derivation every *weighted* view of the artifact tables is built
from, rather than each walking the registry for itself: the basename table
below, the directory aggregate beside it and the project map all have to
answer with the same weighting, and a second walk is a second place for
them to drift.

Not every reading of those tables is a weighted one, and the panel's is
not: `agent-river--hottest' and `agent-river--artifact-list' take the raw
cumulative `:touches' straight off the tables.  That is deliberate and not
a view that got missed -- they answer \"how often\", and say so in the
words they render (\"6 touches\"), where this answers \"how hot\".  A tally
that aged would leave the panel's number disagreeing with itself between
two redraws with nothing having happened in between."
  (let (entries)
    (maphash
     (lambda (_id state)
       (let ((party (agent-river--party-label state))
             (cwd (agent-river-state-cwd state))
             (anchors (agent-river-state-anchors state)))
         (maphash (lambda (path entry)
                    (push (list :party party
                                :cwd cwd
                                :anchor (and anchors (gethash path anchors))
                                :file path
                                :weight (agent-river--heat-weight entry)
                                :writes (or (plist-get entry :writes) 0)
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
cwd, which is what it almost always is.  `agent-river--rel' degrades a
file *outside* the cwd to the same shape, and resolving those against the
cwd used to draw them inside a tree they have nothing to do with; they
carry an `:anchor' instead, the directory they were really folded from,
and it wins over the cwd here."
  (let ((cwd (or (plist-get entry :anchor) (plist-get entry :cwd)))
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

(defcustom agent-river-map-untouched nil
  "Whether the map lists entries no agent has reached.

Nil -- the default -- lists only what has been touched.  Agents spread
over several roots turn the full listing into mostly context: every
sibling directory of every tree anyone started a session in, with the
handful of lines that carry an agent somewhere among them.  Filtered, the
map is a list of where the work is, which is the question it is opened
with.

This never hides activity, which is the one thing the map exists not to
do: an entry is dropped only when nothing has been reached beneath it, so
a `:missing' entry -- known to the state and not to the disk -- always
stays.  What is lost is the context around the work: which siblings a
touched directory has, and how much of a tree nobody is in.  Set non-nil
to get that back, or press \\[agent-river-map-toggle-untouched] in the map,
which sets it for that buffer alone."
  :type 'boolean)

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
  "Marker for the entry holding an agent's most recent touch.
Drawn only while that agent still exists: the marker is the map's one
present-tense reading, and over a session that has ended it points at
where nobody is.

It sits in the gutter immediately before the name, which is where a
marker about *this line* belongs: read down the listing it is the answer
to \"where is the work\", and at the end of a line it was separated from
the thing it is about by however wide the name happened to be."
  :type 'string)

(defcustom agent-river-map-open-marker "▾"
  "Marker for a node whose contributed rows are shown beneath it.
In the same gutter as the other two, because \"there is more here\" is a
fact about the line and is scanned the same way."
  :type 'string)

(defcustom agent-river-map-closed-marker "…"
  "Marker for a node whose contributed rows are folded away.

Deliberately not a sideways triangle, which is what a folded outline
usually gets: `agent-river-map-here-marker' is already one, in the same
gutter, and two triangles a column apart meaning unrelated things is how
a reader stops trusting either.  An ellipsis says what a closed node has
to say anyway -- there is more here that you are not being shown."
  :type 'string)

(defcustom agent-river-map-vc t
  "Whether map lines carry a diffstat of the tree beneath them.

Answers what no reading of the event stream can: an agent that read a
file forty times and an agent that rewrote it once weigh the same, and
\"what is different from HEAD\" is the question a map of the work is most
often opened next to.  Nil leaves the column out entirely and runs no
commands at all."
  :type 'boolean)

(defcustom agent-river-vc-program "git"
  "The git executable the diffstat column is read with.
Missing or unreadable, the column is simply absent -- like every other
part of this package, a view that cannot be drawn must not take anything
else down with it."
  :type 'string)

(defcustom agent-river-map-vc-ttl 3
  "Seconds a root's diffstat is reused before it is read again.

This is the map's staleness, and it used to be most of it: at ten seconds
a file could be changed, drawn twice and still annotated with what it had
looked like before.  It was set that high against a guess at what a read
costs -- \"two subprocesses per root\" sounds expensive.  Measured, a read
is about 8 ms of which the commands are 2, so once per redraw is a third
of a percent of the interval between redraws, and the guess was simply
wrong.

The read is asynchronous either way, so this sets how stale the column may
be, never how long a redraw waits: nothing waits.  \\[agent-river-map-refresh]
drops the cache, so the reading someone asked for by hand is fresh."
  :type 'number)

(defcustom agent-river-map-new-marker "?"
  "Marker for a name git has never seen, beside its neighbours' line counts.

Git's own word for untracked, and it says the one thing the counts
cannot: there is no HEAD version to have differed from.  A file the agent
has just written is untracked, which makes this exactly the line a map of
the work most wants annotated -- reading only the diff would leave the
newest work as the one thing the column said nothing about."
  :type 'string)

(defcustom agent-river-map-landed-marker "✓"
  "Marker for a file whose work has reached the main branch.

The third thing the diffstat column can say, and the three are one
question: what state is the work on this line in.  `+12 -3\=' is work that
is still here, `?\=' work git has never seen, and this is work that is no
longer anywhere but the main branch -- merged or rebased in, which look
the same from the file\='s side and are the same fact about it."
  :type 'string)

(defcustom agent-river-map-main-branch nil
  "The branch a file counts as landed in, or nil to work it out.

Nil tries `origin/HEAD\=', `main\=', `master\=' and `origin/main\=' in that
order and takes the first that resolves -- `origin/HEAD\=' first because it
is what the remote itself says its main branch is, rather than a guess
from a list of popular names.  Set it to a string for a project that
calls it something else; a name that does not resolve is the same as
having no main branch, which costs the marker and nothing else."
  :type '(choice (const :tag "Work it out" nil) string))

(defun agent-river--map-weight (parties)
  "Return the total weight across PARTIES."
  (apply #'+ (mapcar (lambda (party) (plist-get party :weight)) parties)))

(defun agent-river--map-writes (parties)
  "Return how many of PARTIES\=' touches changed the file rather than read it.
Unweighted, where the heat is weighted: this is not a reading about how
recent the work was but about whether there was any, and a write does not
stop having happened because it was a while ago."
  (apply #'+ (mapcar (lambda (party) (or (plist-get party :writes) 0)) parties)))

(defun agent-river--map-later (a b)
  "Return the later of times A and B, either of which may be nil."
  (cond ((null a) b)
        ((null b) a)
        ((time-less-p a b) b)
        (t a)))

(defcustom agent-river-map-party-floor 0.25
  "The weight below which an agent stops being named on a map line.

The shading has had a floor all along -- `agent-river-heat-levels' runs
out at 1, and below it a file gets no face and no overlay.  The name in
the brackets had none, and the weights decay exponentially, so they
approach zero without reaching it: after an hour in a small repository
every file carried a name, every line read alike, and a view where
everything is marked marks nothing.

At the default half-life a single touch falls under this in about four
minutes and a file touched ten times in about eleven, so what is left is
where the work has been recently rather than everywhere it has ever been.

A party that still exists is never dropped from the one file it reached
most recently, whatever that weighs.  Cold is not the same as gone: that
file is the answer to \"where is this agent now\", which is the map's most
useful single fact, and an idle agent is exactly when it is asked.  So a
quiet map settles at one line per agent rather than at none.

A party that has *gone* -- an agent-shell buffer killed, a subagent
finished -- keeps no such file, because there is no longer anyone for
\"now\" to be about.  Its name fades through this floor like any other and
its position marker is dropped at once; see `agent-river--map-newest'.

Nil turns the floor off and restores the old behaviour, where a touch is
named for as long as the session is folded."
  :type '(choice (const :tag "Never drop a name" nil) number))

(defun agent-river--map-newest (entries)
  "Return a hash of party to the file it reached most recently.

Computed across every entry, not just the ones under some root: taken per
root, descending into a subdirectory would invent a second \"most recent\"
file that only looks like one because the real one is out of view.

A party `agent-river--gone-parties' calls finished is left out of the
hash altogether, and that is what cleans it off the map.  Both readings
taken from here are present tense -- the position marker says where an
agent *is*, and the floor exemption below keeps its name on that file for
as long as there is an agent to ask about -- so for a session whose
agent-shell buffer has been killed the two together pinned a name and an
arrow to a file forever, on behalf of nobody.  Absent from the hash, the
marker is not drawn and the name is left to fade at the floor like any
other: the file was still touched, which is history and stays, and it is
only the present tense that is withdrawn."
  (let ((newest (make-hash-table :test 'equal))
        (gone (agent-river--gone-parties)))
    (dolist (entry entries)
      (let ((abs (agent-river--heat-absolute entry))
            (party (plist-get entry :party))
            (last (plist-get entry :last)))
        (when (and abs (not (gethash party gone)))
          (let ((seen (gethash party newest)))
            (when (or (null seen)
                      (eq last (agent-river--map-later (plist-get seen :last) last)))
              (puthash party (list :abs abs :last last) newest))))))
    newest))

(defun agent-river--map-live-p (entry newest)
  "Return non-nil while ENTRY still earns its party a name on the map.

Above `agent-river-map-party-floor', or the one file NEWEST says that
party reached last -- which a party whose sessions have all ended does
not have, so its names fade rather than being pinned for as long as the
registry holds it.  Asked in both places that read the artifact tables
for the map -- which trees to draw, and what to draw in them -- because a
root kept alive by a touch too cold to name would head a section with
nothing under it.

The exemption is granted to a deleted file too, which it was not for a
while.  The worry was that `:current' would then read as \"the agent is
here\" over a file that is not there -- but that was a rendering problem,
and `agent-river-gone' fixes it where it was: struck through, the line
says the agent's last move was into a file that has since gone, which is
both true and worth knowing.  Refusing the exemption instead left an
agent whose last act was a deletion named nowhere at all, and losing a
party off the map entirely is the worse of the two readings."
  (let ((abs (agent-river--heat-absolute entry)))
    (and abs
         (or (null agent-river-map-party-floor)
             (>= (plist-get entry :weight) agent-river-map-party-floor)
             (equal abs (plist-get (gethash (plist-get entry :party) newest) :abs))))))

(defun agent-river--map-all-roots (&optional scope)
  "Return every directory tree the agents have touched, newest first.

A root is a session's cwd, or -- for a file outside it -- the `:anchor'
that says where the file really is.  Taking the cwd alone put every stray
under whichever project happened to be current, which is the whole reason
the anchor is folded: a session editing one file under ~/.claude has two
roots, not one, and a view that shows a single root is hiding the second.
Roots are sorted by the most recent touch within them."
  (let* ((roots (make-hash-table :test 'equal))
         (entries (agent-river--heat-entries scope))
         (newest (agent-river--map-newest entries)))
    (dolist (entry entries)
      (let ((root (or (plist-get entry :anchor) (plist-get entry :cwd))))
        (when (and root (not (string-empty-p root))
                   (agent-river--map-live-p entry newest))
          (puthash root
                   (agent-river--map-later
                    (gethash root roots)
                    (plist-get entry :last))
                   roots))))
    ;; Convert to a sorted list: most recent first
    (let (result)
      (maphash (lambda (root last-time)
                 (push (cons root last-time) result))
               roots)
      (sort result (lambda (a b)
                     (let ((a-time (cdr a))
                           (b-time (cdr b)))
                       (if (and a-time b-time)
                           (time-less-p b-time a-time)
                         (and a-time (not b-time)))))))))

(defun agent-river--map-reach (root &optional scope)
  "Return what the agents have reached inside ROOT, deepest detail kept.

A list of plists, heaviest first, each carrying `:rel' -- the file's path
relative to ROOT -- and `:parties', an alist-like list of plists with
`:party', `:weight', `:last' and `:current'.

`:current' marks the one file a party touched most recently, which is the
only thing here that says where an agent is now rather than where it has
been -- and is therefore nil throughout for a party that no longer
exists.  Computed across everything the party reached, not just what fell
inside ROOT, so descending into a subdirectory cannot invent a second
\"most recent\" file that only looks like one because the real one was out
of view."
  (let* ((prefix (file-name-as-directory (expand-file-name root)))
         (by-rel (make-hash-table :test 'equal))
         (entries (agent-river--heat-entries scope))
         (newest (agent-river--map-newest entries)))
    (dolist (entry entries)
      (let ((abs (agent-river--heat-absolute entry))
            (party (plist-get entry :party))
            (last (plist-get entry :last)))
        ;; A touch too cold to name is not reached any more, so the node it
        ;; would have made is never built: an entry left with no parties
        ;; would otherwise be listed with an empty annotation, which reads
        ;; as an agent whose name failed to render.
        (when (and abs (string-prefix-p prefix abs)
                   (agent-river--map-live-p entry newest))
          (let* ((rel (substring abs (length prefix)))
                 (parties (or (gethash rel by-rel)
                              (puthash rel (make-hash-table :test 'equal) by-rel)))
                 (cell (gethash party parties)))
            (puthash party
                     (list :weight (+ (or (plist-get cell :weight) 0)
                                      (plist-get entry :weight))
                           :writes (+ (or (plist-get cell :writes) 0)
                                      (or (plist-get entry :writes) 0))
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
                                  :writes (plist-get cell :writes)
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
                         :writes (+ (or (plist-get cell :writes) 0)
                                    (or (plist-get party :writes) 0))
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

The listing is the union of what is on disk and what has been reached,
filtered to the reached half unless `agent-river-map-untouched' says
otherwise.  `:missing' marks an entry only the state knows about --
deleted, renamed, or reached through an anchor this root has nothing to do
with.  Showing it anyway is the point: an artifact whose top component is
gone would otherwise be activity the map silently drops, and that is also
why the filter is written as \"has no parties\" rather than \"is not on
disk\" -- the two coincide for an inert entry and come apart for exactly
the entries that matter."
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
      (let ((all (append (nreverse entries)
                         (sort orphans (lambda (a b)
                                         (string< (plist-get a :name)
                                                  (plist-get b :name)))))))
        (if agent-river-map-untouched
            all
          (seq-filter (lambda (entry) (plist-get entry :parties)) all))))))

(defcustom agent-river-map-detail-files 8
  "How many reached files an unfolded map entry lists.
Ordered by weight, so the tail is the least interesting; an ellipsis
marks what was left off."
  :type 'integer)

(defconst agent-river-map-buffer-name "*agent-river-map*"
  "Name of the project map buffer.")

(defvar-local agent-river--map-root nil
  "The directory the map buffer is currently showing.
When nil, the map shows all touched roots; when set, it shows only that root.")

(defvar-local agent-river--map-folds nil
  "Alist of absolute entry path to whether its files are shown.
Only where the user said so.

Only the entries that were toggled by hand.  Everything else falls back to
the default in `agent-river--map-open-p', so a new directory an agent has
just moved into opens without needing an entry here -- and a fold made by
hand survives the redraws, which is the whole reason this is data rather
than outline overlays.  The block is rebuilt every few seconds and an
overlay fold would spring open on each one.

Keyed on the path rather than the name, because the overview shows
several roots at once and `src' under one of them is not `src' under
another.  Being absolute, the keys also survive descending, where a
name-keyed fold had to be thrown away on the way in or it would have
folded whatever entry in the new listing happened to share a name.")

(defvar agent-river--map-drawn nil
  "When the map was last drawn, or nil before the first time.
Read by `agent-river-map-contribute', which draws on an answer landing
unless one has just been drawn anyway.")

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

;;; What the disk says, beside what the agents did
;;
;; The map's four facts are all readings of the event stream: how heavily a
;; name was reached, by whom, by how many at once, and whether it is still
;; on disk.  None of them can say whether anything actually changed, so a
;; fifth fact is read straight off the working tree -- and it earns its
;; place exactly because no fold of the stream could produce it.
;;
;; It is neither folded nor observed.  A diffstat is a current-state fact
;; in the sense of the producer rules: true of the disk right now,
;; recomputable at any moment, and wrong again by the next write.  So it is
;; queried where it is read, the way `buffer-modified-p' is, and nothing
;; downstream of the fold knows it exists.  Putting it in the state would
;; be a second account of something the disk already holds, kept in step by
;; hope.
;;
;; What it is not is an attribution.  Git cannot say who changed a file, so
;; a line's stat is a statement about the tree beneath that name and
;; nothing more -- deliberately not intersected with what the agents
;; reached, which would read as "the agent changed this much" and become a
;; lie the moment a human edited a file the agent only read.  The brackets
;; say who has been here and the column says what is different; two facts
;; side by side, neither dressed as the other.

(defface agent-river-added '((t :inherit success :weight normal))
  "Face for the added half of a diffstat.

Inherited rather than coloured here, so the shade is the one the user's
theme already means \"good\" by -- the same reason nearly every face in
this package inherits.  Only the weight is overridden: `success' is bold
in most themes, and a column that is bold down its whole length stops
being scannable for the lines that matter.")

(defface agent-river-removed '((t :inherit error :weight normal))
  "Face for the removed half of a diffstat.

Red is `agent-river-fail's channel in the HUD, and free here: nothing in
the map means failure, and removed-is-red is the one convention a reader
arrives with.")

(defface agent-river-landed '((t :inherit shadow))
  "Face for the marker on a file whose work has reached the main branch.

Quiet on purpose, where the counts beside it are not.  The column is
scanned for work that is still to be dealt with; a landed file is the
answer \"nothing here\", and printing that in a colour that catches the eye
would make the finished lines compete with the unfinished ones.  Grey
means several things elsewhere in this package -- stale, cold, elided --
and nothing else in this column, which is what makes it free here.")

(defvar agent-river--vc-cache (make-hash-table :test 'equal)
  "Absolute root to what the last git read found there.

Each value is a plist: `:at' when the read finished, `:table' its result,
`:ahead' the paths this branch has changed against the main branch,
`:main' the revision that branch resolved to (or `none'), and `:out' how
many reads are still running.  A `:table' of nil is a real answer -- not
a repository, or no git -- and is stored like any other so a failure is
throttled by the TTL rather than retried on every redraw.

`:ahead' is nil for \"not asked, or could not be asked\", which is a
different answer from an empty table: empty says every path this branch
touched is in the main branch, nil says we do not know, and nothing is
marked landed on a nil.")

(defun agent-river--vc-claim (root process)
  "Count one more read in flight for ROOT, or one fewer when PROCESS is nil.

A count rather than the process itself, since the reads run beside each
other now: holding the last one started would let the first to finish
clear the flag while its sibling was still running, and the next redraw
would start the whole thing again underneath it."
  (let* ((cell (gethash root agent-river--vc-cache))
         (out (max 0 (+ (or (plist-get cell :out) 0) (if process 1 -1)))))
    (puthash root (list :at (or (plist-get cell :at) 0)
                        :table (plist-get cell :table)
                        :ahead (plist-get cell :ahead)
                        :main (plist-get cell :main)
                        :out out)
             agent-river--vc-cache)))

(defun agent-river--vc-store (root table &optional ahead main)
  "Record TABLE as ROOT's diffstat and ask the map to draw it.

AHEAD is the paths still outside the main branch and MAIN the revision it
resolved to; both are remembered across a read that does not mention them,
so the cheap half of a refresh can store what it has without throwing away
the expensive half.

The map is marked dirty rather than redrawn, and its timer started if it
had retired: the answer arrives while nothing else is happening, and a
column that landed in the cache but never on screen would be the same as
not having read it."
  (let ((cell (gethash root agent-river--vc-cache)))
    (puthash root (list :at (current-time)
                        :table table
                        :ahead (or ahead (plist-get cell :ahead))
                        :main (or main (plist-get cell :main))
                        :out (or (plist-get cell :out) 0))
             agent-river--vc-cache))
  (agent-river-map-contribute))

(defun agent-river--vc-run (root args callback &optional on-fail)
  "Run git with ARGS in ROOT and pass its output to CALLBACK.

Asynchronous, and that is the whole point.  The map redraws every few
seconds while an agent works, and a diff on a large repository takes long
enough that reading it inline would stop Emacs on a timer.  Nothing ever
waits: a draw shows whatever the last read left behind, so the column is
at worst one redraw behind the disk -- the same bargain the weights above
it already make.

A non-zero exit is not an error to report but an answer to record: a
directory that is not a repository is an ordinary thing for the map to be
pointed at, and it must cost a line its column and nothing else.  ON-FAIL
says what recording it means for this command; without it the root is
stored as no repository, which is right for the read that decides that and
wrong for every read chained after it -- one of those failing must not
take the answers already in hand down with it."
  (let* ((buffer (generate-new-buffer " *agent-river-vc*" t))
         (process
          (make-process
           :name "agent-river-vc"
           :buffer buffer
           :noquery t
           :connection-type 'pipe
           :coding 'utf-8-unix
           :command (append (list agent-river-vc-program "-C" root) args)
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (let ((output (with-current-buffer buffer (buffer-string)))
                     (ok (eq (process-exit-status process) 0)))
                 (kill-buffer buffer)
                 ;; Released before the callback runs, because a callback
                 ;; that starts the next command claims the slot again.
                 (agent-river--vc-claim root nil)
                 (condition-case nil
                     (if ok
                         (funcall callback output)
                       (funcall (or on-fail
                                    (lambda () (agent-river--vc-store root nil)))))
                   (error (funcall (or on-fail
                                       (lambda ()
                                         (agent-river--vc-store root nil))))))))))))
    (agent-river--vc-claim root process)))

(defun agent-river--vc-parse (output root table)
  "Fold git's NUL-separated numstat OUTPUT into TABLE, keyed under ROOT.

One record per changed file, `ADDED\\tREMOVED\\tNAME', except for a rename:
there the name is empty and the two records after it are the old name and
the new one.  The new one is what the listing can have a line for.

Binary files come back with `-' for both counts, which `string-to-number'
reads as zero -- recorded all the same, so the file still counts as
differing from HEAD even though there are no lines to say by how much."
  (let ((fields (split-string output "\0")))
    (while fields
      (let ((record (pop fields)))
        (when (string-match "\\`\\([0-9]+\\|-\\)\t\\([0-9]+\\|-\\)\t" record)
          (let ((added (string-to-number (match-string 1 record)))
                (removed (string-to-number (match-string 2 record)))
                (name (substring record (match-end 0))))
            (when (string-empty-p name)
              (pop fields)
              (setq name (or (pop fields) "")))
            (unless (string-empty-p name)
              (puthash (expand-file-name name root) (cons added removed)
                       table))))))
    table))

(defconst agent-river--vc-main-candidates
  '(("refs/remotes/origin/HEAD" . "origin/HEAD")
    ("refs/heads/main" . "main")
    ("refs/heads/master" . "master")
    ("refs/remotes/origin/main" . "origin/main"))
  "Refs tried as the main branch, best first, as (REFNAME . REVISION).
`origin/HEAD' leads because it is what the remote says its main branch is,
where the rest are guesses from a list of popular names.")

(defun agent-river--vc-main-rev (refnames)
  "Return the best main-branch revision among the REFNAMES that exist.
Ordered by `agent-river--vc-main-candidates' rather than by the order git
listed them in: `for-each-ref' sorts by refname, which would make the
answer alphabetical and put `master' ahead of `origin/HEAD'."
  (or agent-river-map-main-branch
      (cdr (seq-find (lambda (pair) (member (car pair) refnames))
                     agent-river--vc-main-candidates))))

(defun agent-river--vc-refresh (root)
  "Start reading ROOT's diffstat in the background.

Chained rather than raced, so a later read cannot land in a table an
earlier one has not filled yet.  `diff' reports the tracked files that
differ from HEAD; `ls-files --others' the ones git has never seen, which
is what a file an agent has just written is.  Those two are the column,
and they are stored as soon as they are in -- what follows is a separate
question that must not hold them up or take them down with it.

What follows is which paths this branch has changed against the main
branch: `for-each-ref' to find out what that branch is called here, then
`diff --name-only MAIN...HEAD' for the paths still outside it.  Three dots,
not two: the question is what *this branch* did since it diverged, so a
main branch that has moved on since does not read as this branch's work.
Everything it does not name has nothing of ours left outside main, which
is half of what the landed marker needs -- the other half is that an agent
wrote the file at all, which only the fold can say.

All of it is read with ROOT as the working directory and scoped to it --
`--relative' for the diffs, which is also what makes their paths relative
to ROOT rather than to the top of the checkout.  A session started in a
subdirectory of a repository is therefore annotated with its own subtree,
not with every change in a tree it has nothing to do with."
  (let* ((table (make-hash-table :test 'equal))
         (left 2)
         (done (lambda ()
                 ;; The barrier is what chaining used to buy: a half-filled
                 ;; table stored would draw the column one file at a time.
                 ;; Bought explicitly now, because the two reads answer
                 ;; different questions and waiting for the first to come
                 ;; back before asking the second cost a round trip through
                 ;; the event loop for nothing.
                 (setq left (1- left))
                 (when (zerop left)
                   (agent-river--vc-store root table)
                   (agent-river--vc-ahead root table)))))
    (condition-case nil
        (progn
          (agent-river--vc-run
           root '("diff" "--numstat" "--relative" "-z" "HEAD" "--")
           (lambda (output)
             (agent-river--vc-parse output root table)
             (funcall done))
           (lambda () (agent-river--vc-store root nil)))
          (agent-river--vc-run
           root '("ls-files" "--others" "--exclude-standard" "-z")
           (lambda (others)
             (dolist (name (split-string others "\0" t))
               (puthash (expand-file-name name root) 'new table))
             (funcall done))
           (lambda () (agent-river--vc-store root nil))))
      ;; No git on PATH at all.  Stored like any other answer, so the map
      ;; loses its column rather than throwing once every redraw.
      (error (agent-river--vc-store root nil)))))

(defun agent-river--vc-ahead (root table)
  "Read which of ROOT's paths this branch still has outside the main branch.

Stored beside TABLE, which is already in the cache: everything here is an
extra reading and a failure at any step leaves the column exactly as the
diffstat left it, with `:ahead' unset, which the marker reads as \"do not
know\" rather than as \"landed\".  Claiming a landing we could not check
would be the one mistake worth avoiding here -- it says work is safely in
the main branch."
  (let ((known (let ((main (plist-get (gethash root agent-river--vc-cache) :main)))
                 (and (stringp main) main)))
        (patterns (mapcar #'car agent-river--vc-main-candidates)))
    (condition-case nil
        (if known
            ;; Which branch is the main one changes about as often as the
            ;; checkout does, and every read of it is a round trip through
            ;; the event loop.  Remembered, it costs one command the first
            ;; time and none after that; `g' drops the cache, which is where
            ;; a branch that has been renamed is noticed.
            (agent-river--vc-ahead-diff root table known)
          (agent-river--vc-run
           root (append '("for-each-ref" "--format=%(refname)") patterns)
           (lambda (refs)
             (let ((rev (agent-river--vc-main-rev (split-string refs "\n" t))))
               (if rev
                   (agent-river--vc-ahead-diff root table rev)
                 (agent-river--vc-store root table nil 'none))))
           (lambda () (agent-river--vc-store root table nil 'none))))
      (error (agent-river--vc-store root table nil 'none)))))

(defun agent-river--vc-ahead-diff (root table rev)
  "Read which of ROOT's paths this branch has outside REV, beside TABLE."
  (agent-river--vc-run
   root (list "diff" "--name-only" "--relative" "-z" (concat rev "...HEAD") "--")
   (lambda (output)
     (let ((ahead (make-hash-table :test 'equal)))
       (dolist (name (split-string output "\0" t))
         (puthash (expand-file-name name root) t ahead))
       (agent-river--vc-store root table ahead rev)))
   ;; A revision that resolves but cannot be diffed against -- an empty
   ;; repository, a shallow clone with no merge base.  The column stays;
   ;; only the marker goes unanswered.
   (lambda () (agent-river--vc-store root table nil 'none))))

(defun agent-river--vc-stats (root)
  "Return ROOT's diffstat table, starting a fresh read when this one is old.

Returns what is cached, including nil, and never waits for the read it
starts: the caller is a redraw."
  (when agent-river-map-vc
    (let ((cell (gethash root agent-river--vc-cache)))
      (when (and (zerop (or (plist-get cell :out) 0))
                 (or (null cell)
                     (> (float-time (time-since (plist-get cell :at)))
                        agent-river-map-vc-ttl)))
        (agent-river--vc-refresh root))
      (plist-get cell :table))))

(defun agent-river--vc-forget ()
  "Drop every cached diffstat, so the next draw reads the disk again."
  (clrhash agent-river--vc-cache))

(defun agent-river--vc-under (table path)
  "Return (ADDED REMOVED NEW) for PATH and all of TABLE beneath it, or nil.

The same grain as the parties: a directory line reports the whole subtree
under it, because that is what the listing gives it a line for.  Nil says
nothing there differs from HEAD, which is a different answer from a nil
TABLE -- that one says nobody asked git."
  (when table
    (let ((prefix (file-name-as-directory path))
          (added 0) (removed 0) (files 0) new found)
      (maphash (lambda (key value)
                 (when (or (equal key path) (string-prefix-p prefix key))
                   (setq found t files (1+ files))
                   (if (eq value 'new)
                       (setq new t)
                     (setq added (+ added (car value))
                           removed (+ removed (cdr value))))))
               table)
      ;; The count is the fourth element and not the column's business: a
      ;; column of fixed width has no room for it, and it is the one thing
      ;; a directory's row can say that its own summary cannot -- `+40 -12'
      ;; over four files and over one are different pieces of news.
      (and found (list added removed new files)))))

(defun agent-river--vc-column (stat)
  "Return STAT as the reading a map line's diffstat column shows, or nil.

Only what is non-zero: a file with additions and no deletions says `+12'
rather than `+12 -0', because the second half of that is a number a
reader has to look at to find out it means nothing.  Nil when there is
nothing at all to say, which the caller turns into an empty column."
  (when stat
    (let ((parts (delq nil
                       (list (and (> (nth 0 stat) 0)
                                  (agent-river--map-mark
                                   (format "+%d" (nth 0 stat)) 'agent-river-added))
                             (and (> (nth 1 stat) 0)
                                  (agent-river--map-mark
                                   (format "-%d" (nth 1 stat)) 'agent-river-removed))
                             (and (nth 2 stat)
                                  (agent-river--map-mark
                                   agent-river-map-new-marker 'agent-river-added))))))
      (and parts (mapconcat #'identity parts " ")))))

(defun agent-river--vc-landed-p (root path)
  "Return non-nil when nothing under PATH is still outside ROOT's main branch.

Nil when nobody could ask -- no main branch here, or the read has not come
back yet -- because `:ahead' unset means \"do not know\", and the one thing
this marker must never do is say work is safely in the main branch on a
guess.  An empty `:ahead' is the opposite: every path this branch changed
is in there now."
  (let ((ahead (plist-get (gethash root agent-river--vc-cache) :ahead)))
    (and (hash-table-p ahead)
         (let ((prefix (file-name-as-directory path))
               (outside nil))
           (maphash (lambda (key _value)
                      (when (or (equal key path) (string-prefix-p prefix key))
                        (setq outside t)))
                    ahead)
           (not outside)))))

(defun agent-river--refresh-vc (root _nodes)
  "Ask git about ROOT, if the last answer is old enough.
The throttle is `agent-river--vc-stats\=' own -- the map offers a refresh on
the contributor\='s `:ttl\=', and this one keeps the TTL it always had, so a
map redraw and a dired shading cannot start two reads of the same tree."
  (agent-river--vc-stats root))

(defun agent-river--rows-vc (root nodes)
  "Return what git has to say about each of NODES under ROOT.

The diffstat as an ordinary contributor, which is the test of whether the
contributor protocol is one: it is the asynchronous case, the batched
case and the aggregating case at once, and it fits without an exception.
It reads its own cache, starts nothing here -- `:refresh\=' does that -- and
answers for a directory by summing the subtree beneath it, because it is
the contributor that knows whether its readings aggregate.

The row spells out what the column abbreviates.  That is the relation the
whole design rests on: the line is a projection of the rows, so the two
cannot disagree about what git said."
  (let ((table (and agent-river-map-vc
                    (plist-get (gethash root agent-river--vc-cache) :table)))
        (out (make-hash-table :test 'equal)))
    (dolist (node nodes)
      (let* ((path (plist-get node :path))
             (stat (agent-river--vc-under table path))
             (writes (agent-river--map-writes (plist-get node :parties)))
             (landed (and (> writes 0) (agent-river--vc-landed-p root path))))
        (cond
         (stat
          (puthash path
                   (list (list :key "vc"
                               :column (agent-river--vc-column stat)
                               :text (concat
                                      (or (agent-river--vc-column-plain stat)
                                          "changed")
                                      " vs HEAD"
                                      (if (and (plist-get node :dir)
                                               (> (nth 3 stat) 1))
                                          (format " in %d files" (nth 3 stat))
                                        "")
                                      (if (nth 2 stat)
                                          ", untracked by git" ""))))
                   out))
         (landed
          (puthash path
                   (list (list :key "vc"
                               :face 'agent-river-landed
                               :column (agent-river--map-mark
                                        agent-river-map-landed-marker
                                        'agent-river-landed)
                               :text "in the main branch"))
                   out)))))
    out))

(defun agent-river--vc-summary (rows)
  "Return the column reading for the vc ROWS of one node.

Carried on the row rather than computed again from the tables, so the
column and the row it summarises cannot come to different conclusions --
which is the whole claim the line makes about the rows beneath it.  A
contributor may keep its own keys on a row; the map reads the ones it
knows and leaves the rest alone."
  (plist-get (car rows) :column))

(defun agent-river--vc-column-plain (stat)
  "Return STAT as unmarked text, for a row rather than for the column.
The column carries its own faces; a row is escaped where it is inserted,
and escaping marked-up text would leave the marks pointing at the wrong
characters."
  (let ((parts (delq nil (list (and (> (nth 0 stat) 0) (format "+%d" (nth 0 stat)))
                               (and (> (nth 1 stat) 0) (format "-%d" (nth 1 stat)))))))
    (and parts (mapconcat #'identity parts " "))))

(defcustom agent-river-map-detail-rows 6
  "How many contributed rows a node shows before the rest are elided.
The same wall `agent-river-map-detail-files' puts in front of a directory
with a hundred reached files, and for the same reason: a listing that can
be arbitrarily long is not a listing.  A contributor with more to say than
this says the rest somewhere else."
  :type 'integer)

;; Rows under a node, and who may contribute them
;;
;; A map line carries five facts already -- weight as shading, position and
;; contention as markers, existence as a strike-through, the state of the
;; work as a column -- and that is the ceiling.  The party names used to be
;; a sixth, and they were the one ragged thing on the line, which is why
;; nothing scannable could ever follow them.  They are rows now, and the
;; room they left is what anything new gets to compete for.
;;
;; A row is detail and enrichment at once, which is the whole reason this
;; shape was chosen: rows are drawn by default where there are any, and TAB
;; hides them.  Visible by default is the enrichment; collapsible is the
;; detail; and it is one mechanism rather than two, reusing the folds that
;; already survive a redraw because they are data rather than overlays.
;;
;; The line stays a projection of the rows and never a second account of
;; them -- the same rule the listing already follows one grain up, where a
;; directory's reading is the aggregate of what lies beneath it so the two
;; cannot disagree.

(defvar agent-river-map-contributors
  (list (list :name 'vc
              :read #'agent-river--rows-vc
              :refresh #'agent-river--refresh-vc
              :summary #'agent-river--vc-summary)
        (list :name 'parties :read #'agent-river--rows-parties)
        (list :name 'step :read #'agent-river--rows-step))
  "What may add rows under the map's nodes, in the order they are drawn.

Each entry is a plist:

  :name     a symbol, for attribution and for retiring a broken one
  :read     (ROOT NODES) -> hash of absolute path to a list of rows
  :refresh  (ROOT NODES) -> nil, optional, may take as long as it likes
  :ttl      seconds before `:refresh\=' is offered that root again
  :summary  (ROWS) -> a short string for the line, or nil

`:summary\=' is how a contributor gets onto the line itself, and it is
rationed rather than offered: the line is a column of fixed width, so a
summary must be short and shaped the same on every line, and it must be a
reading *of the rows* -- the same data smaller, never a second account of
it.  A contributor with nothing that shape says nil and lives under the
node, which is where most of them belong.

A row is a plist of `:text\=' (one line, which the map escapes), `:face\='
\(a symbol, never a face on the text -- tree-sitter owns `face\=' in this
buffer), `:key\=' (stable across redraws, or the point lands on the wrong
row after one) and an optional `:visit\=' thunk for RET.

NODES are the lines about to be drawn, each `:path\=', `:dir\=' and
`:parties\=', so a contributor can answer for a directory as well as a file
and can decide for itself whether its rows aggregate -- the parties\=' do,
a list of diagnostics does not.

Two functions rather than one because the redraw runs on a timer and must
never wait: `:read\=' is synchronous and answers from whatever the
contributor already has, `:refresh\=' is where waiting is allowed, and it
hands its answer back by calling `agent-river-map-contribute\='.  The
diffstat below is the worked example.

Editing this list is the off switch, the way it is for
`agent-river-observers\='.  The two sorts it starts with are built on the
same mechanism a foreign one would use, so there is no privileged path
through here for a contributor that happens to ship with the package.

A `defvar\=' holding its own defaults rather than a `setq\=' below them: a
reload must not quietly throw away a contributor somebody registered.")

(defvar agent-river--map-refreshed (make-hash-table :test 'equal)
  "When each contributor was last offered a root, as NAME/ROOT -> time.
The map throttles how often it *asks*; whether a read is already in
flight is the contributor\='s own business, since only it knows what it
started.")

(defconst agent-river--map-contribution-delay 0.05
  "Seconds a contributor's answer waits for its siblings before being drawn.

Short enough to read as immediate and long enough to collect the answers
that arrive together -- a diffstat read stores twice, a few milliseconds
apart, and two draws for one read would be two chances to move the text
under whoever is reading it.

A floor on how *recently* the map was drawn was tried first and was
exactly backwards: a read is started by a draw and answers about ten
milliseconds later, so every answer there has ever been arrives inside the
floor and none of them drew.")

(defvar agent-river--map-soon nil
  "One-shot timer for a draw a contributor's answer asked for.")

(defun agent-river-map-contribute ()
  "Say that a contributor has something new for the map to draw.

Draws it, shortly.  Leaving it to the redraw timer was the larger half of
how long the diffstat appeared to take: the read itself is about 8 ms and
then the answer sat in the cache for up to
`agent-river-map-refresh-interval' seconds before anybody drew it -- ten
seconds, end to end, once the TTL had had its say.  An answer that has
just landed is the moment the view is known to be out of date, which is
the one moment redrawing it is certainly worth doing.

Deliberately takes no arguments -- the draw asks every contributor what it
has, so there is one path in and no way for an answer to arrive around the
side of it."
  (when (get-buffer agent-river-map-buffer-name)
    (setq agent-river--map-dirty t)
    (agent-river--ensure-map-timer)
    (unless (timerp agent-river--map-soon)
      (setq agent-river--map-soon
            (run-at-time
             agent-river--map-contribution-delay nil
             (lambda ()
               (setq agent-river--map-soon nil)
               (condition-case err
                   (when (get-buffer agent-river-map-buffer-name)
                     (agent-river--map-draw))
                 ;; The periodic tick retires itself on an error; this one
                 ;; is over already, so it only has to say so rather than
                 ;; go quiet about a draw that did not happen.
                 (error (message "agent-river: map draw failed (%s)"
                                 (error-message-string err))))))))))

(defun agent-river--map-one-line (text)
  "Return TEXT as something that can be one line of the map.

The buffer is line-based: positions, text properties and every motion
assume one node per line, so a newline in a contributed row would not make
two rows, it would make one broken one.  The same reason a signal is held
to a single line."
  (string-trim (replace-regexp-in-string "[[:cntrl:]]+" " " (or text ""))))

(defun agent-river--map-offer-refresh (contributor root nodes)
  "Let CONTRIBUTOR start reading ROOT for NODES, if it is due."
  (let ((refresh (plist-get contributor :refresh)))
    (when refresh
      (let* ((key (format "%s\0%s" (plist-get contributor :name) root))
             (last (gethash key agent-river--map-refreshed))
             (ttl (or (plist-get contributor :ttl) agent-river-map-vc-ttl)))
        (when (or (null last) (> (float-time (time-since last)) ttl))
          (puthash key (current-time) agent-river--map-refreshed)
          (funcall refresh root nodes))))))

(defun agent-river--map-rows (root nodes)
  "Return what every contributor has to say about NODES under ROOT.

A hash of absolute path to a list of (CONTRIBUTOR . ROWS), in the order
the contributors are registered -- deterministic, because anything else
reorders itself between two redraws with nothing having happened.

A contributor that throws is retired on the spot, once, with a message:
this runs on every redraw, so a broken one is broken thousands of times,
and a view that dies with it is the worse outcome.  The same bargain
`agent-river--run-observers\=' makes."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (contributor agent-river-map-contributors)
      (condition-case err
          (progn
            (agent-river--map-offer-refresh contributor root nodes)
            (let ((answer (funcall (plist-get contributor :read) root nodes)))
              (when (hash-table-p answer)
                (maphash (lambda (path rows)
                           (when rows
                             (puthash path
                                      (append (gethash path table)
                                              (list (cons contributor rows)))
                                      table)))
                         answer))))
        (error
         (setq agent-river-map-contributors
               (delq contributor agent-river-map-contributors))
         (message "agent-river: map contributor %s retired (%s)"
                  (plist-get contributor :name)
                  (error-message-string err)))))
    table))

(defun agent-river--map-row-list (contributed)
  "Return the rows of CONTRIBUTED, flattened in contributor order."
  (apply #'append (mapcar #'cdr contributed)))

(defun agent-river--map-summarised-p (rows)
  "Return non-nil when anything in ROWS would put a reading on a line."
  (let (found)
    (maphash (lambda (_path contributed)
               (dolist (pair contributed)
                 (when (and (plist-get (car pair) :summary)
                            (funcall (plist-get (car pair) :summary) (cdr pair)))
                   (setq found t))))
             rows)
    found))

(defun agent-river--map-summary (contributed column)
  "Return the line reading CONTRIBUTED earns, given COLUMN is being shown.

COLUMN says whether the buffer reserves the width at all -- nil when no
contributor under this map has anything to summarise, in which case no
line holds it open and the markers move left.  With it on, a node with
nothing to say still returns the empty string, so the column stays where
it was on the line above and can be read downward, which is the only
reason it is a column."
  (and column
       (mapconcat #'identity
                  (delq nil (mapcar (lambda (pair)
                                      (let ((summary (plist-get (car pair) :summary)))
                                        (and summary (funcall summary (cdr pair)))))
                                    contributed))
                  " ")))

(defun agent-river--rows-parties (_root nodes)
  "Return one row per party on each of NODES: the names that left the line.

What a bracket could never say.  The line still shades by weight and
still marks contention and position, because those are scannable down the
listing; the row adds what only makes sense once you are looking at this
one node -- whose touches they were, how long ago, and how many of them
changed the file rather than read it.

Ordered by the parties themselves, which `agent-river--map-reach\=' has
already sorted heaviest first, so the row order is the same reading as the
shading and cannot contradict it."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (node nodes)
      (let ((rows
             (mapcar
              (lambda (party)
                (let ((writes (or (plist-get party :writes) 0))
                      (last (plist-get party :last)))
                  (list :key (concat "party/" (plist-get party :party))
                        :face (if (plist-get party :current)
                                  'agent-river-prompt
                                'agent-river-stale)
                        :text (concat
                               (plist-get party :party)
                               (if (plist-get party :current)
                                   (concat " " agent-river-map-here-marker) "")
                               (if (> writes 0)
                                   (format " · %d write%s" writes
                                           (if (= writes 1) "" "s"))
                                 "")
                               (if last
                                   (format " · %s ago" (agent-river--ago last))
                                 "")))))
              (plist-get node :parties))))
        (when rows (puthash (plist-get node :path) rows table))))
    table))

(defun agent-river--rows-step (_root nodes)
  "Return a row for any of NODES a session has a tool call open on.

The one row here that is present tense, which is why it is a second sort
rather than more of the first: the parties above it say where an agent has
*been*, this says what is happening in the file right now, and after a
long task those are different statements about different moments.

Read from the sessions rather than from the node, because a step in
flight is not in the artifact tables at all -- it is the call that has not
come back yet."
  (let ((table (make-hash-table :test 'equal)))
    (maphash
     (lambda (_id state)
       (let ((step (agent-river-state-step state)))
         (when (and step (plist-get step :file)
                    (agent-river--state-working-p state))
           (let ((abs (agent-river--heat-absolute
                       (list :cwd (agent-river-state-cwd state)
                             :file (plist-get step :file)))))
             (when (and abs (seq-find (lambda (node)
                                        (equal (plist-get node :path) abs))
                                      nodes))
               (puthash abs
                        (append (gethash abs table)
                                (list (list :key (concat "step/" (agent-river-state-id state))
                                            :face 'agent-river-act
                                            :text (format "%s: %s since %s"
                                                          (agent-river--party-label state)
                                                          (or (plist-get step :tool) "?")
                                                          (agent-river--ago
                                                           (plist-get step :at))))))
                        table))))))
     agent-river-registry)
    table))

(defun agent-river--map-marker (level)
  "Return the Markdown that opens a map line at LEVEL.

Directories are headings and files are list items, which is what each of
them is: a heading has something under it and folds, a leaf does not.
Making every file a level-3 heading instead would set the whole listing in
the heading face and leave the structure saying that a file contains the
lines after it.  So a file passes `file' rather than a number: the
overview pushes the entries down a level to make room for the root
headings, and a file that took its level from its entry would have
followed them into being a heading.

The markup is left visible.  Hiding it is `markdown-ts-view-mode's own
default and it looks better on prose, but here the marker is the
indentation -- hidden, a directory and the files under it start in the
same column and the tree stops being one."
  (pcase level (1 "# ") (2 "## ") (3 "### ") (_ "- ")))

(defun agent-river--map-line (level name parties &optional missing stat rows)
  "Return one map line: NAME at LEVEL, annotated with PARTIES.
MISSING marks a name only the state knows about, which is struck through
rather than shaded -- there is no file on disk for the shading to be
about, and a line that reads as gone cannot be mistaken for a place an
agent is still working in.

PARTIES are no longer named on the line, only shaded and marked: their
names are rows beneath it now (`agent-river--rows-parties').  The brackets
were the one ragged thing here, which is why nothing scannable could ever
be put after them -- moving them down is what freed the tail of the line,
and a row says what a bracket never could: how long ago, and how much of
it was writing rather than reading.

STAT is the reading a contributor earned on this line, from
`agent-river--map-summary'.  Nil leaves the column out for every line in
the buffer, which is what happens when no contributor under this map has
anything to put in it.

ROWS is `open' or `closed' when this node has contributed rows, nil when
it has none.  A folded node used to look exactly like a node with nothing
under it, which made the fold a way of losing things quietly."
  (let* ((marker (agent-river--map-marker level))
         (face (if missing
                   'agent-river-gone
                 (agent-river--heat-face (agent-river--map-weight parties))))
         (shown (agent-river--map-name name))
         ;; The gutter: everything that is about this line rather than about
         ;; the tree, in one fixed-width place before the name.  At the end
         ;; of the line these were held away from what they mark by however
         ;; wide the name happened to be, which is the opposite of what a
         ;; marker is for.
         (gutter
          (concat (pcase rows ('open agent-river-map-open-marker)
                         ('closed agent-river-map-closed-marker)
                         (_ " "))
                  (if (> (length parties) 1) agent-river-map-contended-marker " ")
                  (if (seq-some (lambda (party) (plist-get party :current)) parties)
                      agent-river-map-here-marker " ")
                  " "))
         (pad (max 1 (- agent-river-map-name-width
                        (length marker) (string-width gutter)
                        (string-width shown)))))
    (string-trim-right
     (concat marker
             gutter
             (agent-river--map-mark shown face)
             (make-string pad ?\s)
             (or stat "")))))

(defun agent-river--map-row-line (row &optional nested)
  "Return contributed ROW as a line, one level deeper again when NESTED.

The text is escaped, and that is not politeness.  The map is Markdown on
the condition that every token in it is ours; a contributor\='s text is the
first text here that is not, and a row beginning with a `#\=' or carrying a
stray asterisk would restructure the view that is showing it -- which is
exactly why the HUD is not Markdown at all.  The condition holds by force
here instead of by luck.

The face is applied the map\='s way, as `agent-river-map-face\=' turned into
an overlay after the text is in: tree-sitter owns `face\=' in this buffer
and refontifies on redisplay, so a face written as a text property is
drawn once and then quietly gone."
  (let ((text (agent-river--md-escape
               (agent-river--map-one-line (plist-get row :text))))
        (face (plist-get row :face)))
    (concat (if nested "  - " "- ")
            (if face (agent-river--map-mark text face) text))))

(defun agent-river--map-rows-insert (contributed path &optional nested)
  "Insert CONTRIBUTED rows for PATH, capped and marked for motion.

Each row carries its node\='s path, so RET on a row acts on the thing the
row is about; a row with a `:visit\=' of its own overrides that.  It carries
its `:key\=' as well, which is what keeps point on the right row across a
redraw -- `agent-river--map-goto\=' finds a line again by what it names, and
a row that named only its parent would inherit its parent\='s identity and
land point a line or two off after every draw."
  (let* ((rows (agent-river--map-row-list contributed))
         (shown (seq-take rows agent-river-map-detail-rows)))
    (dolist (row shown)
      (insert (propertize
               (concat (agent-river--map-row-line row nested) "\n")
               'agent-river-map-path path
               'agent-river-map-row (or (plist-get row :key)
                                        (plist-get row :text) "")
               'agent-river-map-visit (plist-get row :visit))))
    (when (> (length rows) (length shown))
      (insert (propertize (concat (if nested "  - " "- ") "…\n")
                          'agent-river-map-face 'agent-river-stale)))))

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

(defun agent-river--map-folded-p (path default)
  "Return whether PATH's children are drawn, DEFAULT when nobody has said.

The fold is data rather than an overlay, which is what lets it survive a
buffer rebuilt every few seconds -- an overlay fold springs open on the
next redraw, which is not a fold."
  (let ((cell (assoc path agent-river--map-folds)))
    (if cell (cdr cell) default)))

(defun agent-river--map-open-p (entry root &optional rows)
  "Return non-nil when ENTRY's children are shown beneath it, under ROOT.

An entry with something under it opens by default -- the files, and now
the contributed ROWS, are the reason the entry is annotated at all -- and a
toggle by hand wins from then on.  Rows counting here is what makes them
enrichment and detail at once: drawn where there are any, hidden by the
same TAB that hides the files."
  (agent-river--map-folded-p (expand-file-name (plist-get entry :name) root)
                             (and (or (plist-get entry :files) rows) t)))

(defun agent-river--map-nodes (root entries)
  "Return the lines ENTRIES will draw under ROOT, as nodes for a contributor.

Each is `:path\=', `:dir\=' and `:parties\='.  Files are included whether or
not their entry is open: a contributor is asked once per draw for the whole
root, and asking again for each entry that turns out to be unfolded would
put a subprocess behind a keystroke."
  (let (nodes)
    (dolist (entry entries)
      (let ((path (expand-file-name (plist-get entry :name) root)))
        (push (list :path path
                    :dir (plist-get entry :dir)
                    :parties (plist-get entry :parties))
              nodes)
        (dolist (file (plist-get entry :files))
          (push (list :path (expand-file-name (plist-get file :rel) path)
                      :dir nil
                      :parties (plist-get file :parties))
                nodes))))
    (nreverse nodes)))

(defun agent-river--map-header (root entries &optional roots)
  "Return the map's own heading for ROOT, given its ENTRIES.

The name of what is being shown, and how many agents are in it.  It used
to caption the view as well -- which frame the numbers came from, and
that the diffstat came from HEAD instead of a frame -- and that was a
legend for a listing, carried on every redraw by a line that is read once.
Both facts still hold and are documented where they are decided
\(`agent-river-map-scope', `agent-river--map-stats'); the heading is not
where a reader goes to look them up.

The count is of agents that still exist, not of names on the map.  A name
outlives its session on purpose -- it fades through
`agent-river-map-party-floor' rather than vanishing, because the file was
still touched -- so counting names would report an audience that has left
as though it were still there, which is the one thing this number is for.

ROOT is nil in the overview, which spans ROOTS trees and has no one path
to be named after.  Titling it with any of them -- the most recent, say --
is what this replaced: the heading then read as though that tree were the
project and the others were somewhere inside it."
  (let* ((gone (agent-river--gone-parties))
         (parties (seq-remove
                   (lambda (party) (gethash (plist-get party :party) gone))
                   (agent-river--map-merge-parties
                    (mapcar (lambda (entry)
                              (list :parties (plist-get entry :parties)))
                            entries)))))
    (concat (agent-river--map-marker 1)
            (agent-river--map-mark (if root
                                       (agent-river--map-name
                                        (abbreviate-file-name root))
                                     (format "%d roots" (or roots 0)))
                                   'agent-river-prompt)
            (if parties
                (format "  ·  %d agent%s" (length parties)
                        (if (= (length parties) 1) "" "s"))
              "  ·  quiet"))))

(defun agent-river--map-here ()
  "Return what identifies the line point is on, for a redraw to find again.

Three things name a line, not two: the entry, the file under it, and the
contributed row under that.  A row that named only its node would share
its node\='s identity with every other row there, and point would come back
from a redraw one or two lines off every time."
  (let ((beg (line-beginning-position)))
    (list (get-text-property beg 'agent-river-map-name)
          (get-text-property beg 'agent-river-map-rel)
          (get-text-property beg 'agent-river-map-row)
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
                                           'agent-river-map-rel))
                 (equal (nth 2 here)
                        (get-text-property (line-beginning-position)
                                           'agent-river-map-row)))
            (setq found t)
          (forward-line 1))))
    (unless found
      (goto-char (point-min))
      (forward-line (1- (max 1 (or (nth 3 here) 1)))))))

(defun agent-river--map-draw ()
  "Redraw the map buffer from the state, if it is still alive.

With `agent-river--map-root' set the map is zoomed into that one tree.
With it nil -- which is what the map opens on -- it shows every tree the
agents have touched.  The state spans whatever directories the sessions
were started in and there is no reference project among them, so naming
one of them as the root and hiding the rest was a view of the state that
the state does not have.

One tree is drawn without a heading of its own: the header already names
it, and a second line repeating it would indent the whole listing to say
nothing."
  (let ((buffer (get-buffer agent-river-map-buffer-name)))
    (when buffer
      (with-current-buffer buffer
        (let* ((here (agent-river--map-here))
               (inhibit-read-only t)
               (roots (or (and agent-river--map-root (list agent-river--map-root))
                          (mapcar #'car (agent-river--map-all-roots
                                         agent-river-map-scope))
                          ;; Nothing folded yet.  Showing where this Emacs
                          ;; happens to be beats an empty buffer: the listing
                          ;; is still a listing before any agent has reached
                          ;; into it.
                          (list (agent-river--map-default-root))))
               (sections (mapcar (lambda (root)
                                   (let ((entries (agent-river--map-entries
                                                   root agent-river-map-scope)))
                                     (list root
                                           entries
                                           (agent-river--map-rows
                                            root (agent-river--map-nodes
                                                  root entries)))))
                                 roots))
               ;; One decision for the whole buffer: a column reserved on
               ;; some lines and not others would sit in a different place
               ;; per section, which is the column's whole purpose spent on
               ;; nothing.  Decided from what the contributors have rather
               ;; than from git in particular -- the column belongs to
               ;; whoever can summarise, and today that is only the diffstat.
               (column (and (seq-some (lambda (section)
                                        (agent-river--map-summarised-p (nth 2 section)))
                                      sections)
                            t))
               (split (> (length sections) 1))
               (level (if split 3 2)))
          (erase-buffer)
          (insert (if split
                      (agent-river--map-header
                       nil (apply #'append (mapcar #'cadr sections))
                       (length sections))
                    (agent-river--map-header (car (car sections))
                                             (nth 1 (car sections))))
                  "\n")
          (dolist (section sections)
            (let ((root (car section))
                  (entries (nth 1 section))
                  (rows (nth 2 section)))
              (when split
                (insert (propertize
                         (concat (agent-river--map-line
                                  2 (abbreviate-file-name root)
                                  (agent-river--map-merge-parties
                                   (mapcar (lambda (entry)
                                             (list :parties (plist-get entry :parties)))
                                           entries))
                                  nil
                                  (agent-river--map-summary (gethash root rows) column)
                                  (and (gethash root rows) 'open))
                                 "\n")
                         ;; A root is a place like any other line's, so RET
                         ;; zooms into it and the motions stop on it.
                         'agent-river-map-name (abbreviate-file-name root)
                         'agent-river-map-path root
                         'agent-river-map-dir t
                         'agent-river-map-section t
                         'agent-river-map-active (and entries t))))
              (progn
               (dolist (entry entries)
                (let* ((name (plist-get entry :name))
                       (dir (plist-get entry :dir))
                       (path (expand-file-name name root))
                       (mine (gethash path rows))
                       (open (agent-river--map-open-p entry root mine)))
                  (insert (propertize
                           (concat (agent-river--map-line
                                    level (concat name (if dir "/" ""))
                                    (plist-get entry :parties)
                                    (plist-get entry :missing)
                                    (agent-river--map-summary mine column)
                                    (and mine (if open 'open 'closed)))
                                   "\n")
                           'agent-river-map-name name
                           'agent-river-map-path path
                           'agent-river-map-dir dir
                           ;; Whether its children were drawn, read back by TAB.
                           ;; Off the rendering rather than derived again, so
                           ;; the toggle cannot disagree with what is on screen.
                           'agent-river-map-open open
                           ;; What `agent-river-map-next-active' stops on.  Read
                           ;; off the parties rather than off the annotation
                           ;; text, so the motion and the reading cannot come
                           ;; apart if the line is ever formatted differently.
                           'agent-river-map-active (and (plist-get entry :parties) t)))
                  (when open
                    (agent-river--map-rows-insert mine path)
                    (let* ((files (plist-get entry :files))
                           (shown (seq-take files agent-river-map-detail-files)))
                      (dolist (file shown)
                        (let* ((fpath (expand-file-name (plist-get file :rel) path))
                               (frows (gethash fpath rows))
                               (fopen (agent-river--map-folded-p fpath (and frows t))))
                        (insert (propertize
                                 (concat (agent-river--map-line
                                          'file (plist-get file :rel)
                                          (plist-get file :parties)
                                          nil
                                          (agent-river--map-summary frows column)
                                          (and frows (if fopen 'open 'closed)))
                                         "\n")
                                 'agent-river-map-name name
                                 'agent-river-map-rel (plist-get file :rel)
                                 'agent-river-map-path fpath
                                 'agent-river-map-open fopen
                                 'agent-river-map-active
                                 (and (plist-get file :parties) t)))
                        (when fopen
                          (agent-river--map-rows-insert frows fpath t))))
                      (when (> (length files) (length shown))
                        (insert (propertize
                                 (concat (agent-river--map-marker 'file) "…\n")
                                 'agent-river-map-face 'agent-river-stale
                                 'agent-river-map-name name))))))))
              ;; An empty listing has to say which kind of empty it is.
              ;; Filtered, the tree may be full of files nobody has been
              ;; near, and a blank section then reads as though the map had
              ;; lost them.  No `agent-river-map-path', so the motions pass
              ;; over it the way they pass over the elision line.
              (unless entries
                (insert (propertize
                         (concat (agent-river--map-marker 'file)
                                 (if agent-river-map-untouched
                                     "*empty*"
                                   "*nothing reached here — `a` lists everything*")
                                 "\n")
                         'agent-river-map-face 'agent-river-stale)))))
          (setq agent-river--map-drawn (current-time))
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

(defun agent-river--map-row-line-p ()
  "Return non-nil on a row contributed under a node."
  (and (get-text-property (line-beginning-position) 'agent-river-map-row) t))

(defun agent-river--map-top-line-p ()
  "Return non-nil on one of the listing's own entries.
A file shown under an unfolded directory carries `agent-river-map-rel' and
a contributed row carries `agent-river-map-row'; the entry itself carries
neither, which is the difference between the two grains of motion.  A row
inherits its node's path so that RET on it acts on the right thing, which
is exactly why it cannot be told apart by the path alone."
  (and (agent-river--map-entry-line-p)
       (null (get-text-property (line-beginning-position) 'agent-river-map-rel))
       (not (agent-river--map-row-line-p))))

(defun agent-river--map-active-line-p ()
  "Return non-nil on a line some agent has been working under.
Contributed rows carry no `agent-river-map-active\=' and are passed over:
`>\=' is the motion for finding the agents, and a contributor that could
put itself on it would be competing for the one gesture that is about
them."
  (and (agent-river--map-entry-line-p)
       (get-text-property (line-beginning-position) 'agent-river-map-active)))

(defun agent-river--map-beginning-of-name ()
  "Put point on the first character of the name on this line.

The names are code spans, so the backtick finds them.  A contributed row
has no code span -- its text is prose the map escaped -- so the marker is
stepped over instead; landing in column zero would put the cursor on the
Markdown marker, which reads as though the markup were the content.

Falls back to the start of the line, so this is safe to call anywhere."
  (goto-char (line-beginning-position))
  (or (re-search-forward "`" (line-end-position) t)
      (re-search-forward "^[-# ]+" (line-end-position) t)))

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
  "Redraw the map now, and read the disk again while doing it.

The weights are recomputed on every draw anyway; the diffstat is cached
for `agent-river-map-vc-ttl' seconds, so dropping it here is what makes
this the authoritative reading.  Someone who asks for a refresh by hand
is asking about now.  The read is still asynchronous, so the numbers land
on the redraw after this one."
  (interactive)
  (agent-river--vc-forget)
  (agent-river--map-draw))

(defun agent-river-map-toggle ()
  "Show or hide the reached files under the entry at point."
  (interactive)
  (let ((name (get-text-property (line-beginning-position) 'agent-river-map-name))
        (path (get-text-property (line-beginning-position) 'agent-river-map-path)))
    (when (get-text-property (line-beginning-position) 'agent-river-map-section)
      (user-error "A root heading holds the listing below it, not files"))
    (unless (and name path) (user-error "No entry on this line"))
    (when (agent-river--map-row-line-p)
      (user-error "A row is what folds away, not what folds"))
    ;; Whether this line drew its children is read off the line itself
    ;; rather than derived a second time.  Deriving it meant finding the
    ;; entry again by name in a freshly built listing, which only worked for
    ;; the listing's own entries -- a file line, which can now have rows of
    ;; its own under it, was not in there at all and toggled nothing.
    (let ((open (get-text-property (line-beginning-position)
                                   'agent-river-map-open))
          (cell (assoc path agent-river--map-folds)))
      (if cell
          (setcdr cell (not open))
        (push (cons path (not open)) agent-river--map-folds)))
    (agent-river--map-draw)))

(defun agent-river-map-toggle-untouched ()
  "Show or hide the entries no agent has reached, in this map buffer.

Buffer-local, so the gesture is undone by the same gesture and never
edits the user's setting behind their back: `agent-river-map-untouched'
goes on being what a fresh map opens with."
  (interactive)
  (setq-local agent-river-map-untouched (not agent-river-map-untouched))
  (agent-river--map-draw)
  (message "map: %s"
           (if agent-river-map-untouched
               "listing everything"
             "listing only what agents have reached")))

(defun agent-river-map-visit ()
  "Descend into the directory at point, or open the file at point.
The lens is moved rather than widened: one directory is always listed in
full, and going deeper means looking somewhere else.

On a contributed row, whatever that row said RET means -- and where it
said nothing, the node the row is about.  Refusing would be the stricter
reading of \"a motion with nowhere to go refuses\", but that rule is about
landing *near* something the eye did not choose; the file a row is under
is the thing the eye chose."
  (interactive)
  (let ((path (get-text-property (line-beginning-position) 'agent-river-map-path))
        (dir (get-text-property (line-beginning-position) 'agent-river-map-dir))
        (visit (get-text-property (line-beginning-position) 'agent-river-map-visit)))
    (cond
     (visit (funcall visit))
     ((null path) (user-error "Nothing to visit on this line"))
     (dir (agent-river-map-descend path))
     ((file-exists-p path) (find-file path))
     (t (user-error "%s is not on disk" (abbreviate-file-name path))))))

(defun agent-river-map-descend (dir)
  "Point the map at DIR.
The hand-made folds are kept: they are keyed on absolute paths, so none
of them can mean an entry of the listing being entered."
  (setq agent-river--map-root (directory-file-name (expand-file-name dir)))
  (agent-river--map-draw))

(defun agent-river-map-up ()
  "Point the map at the parent of the directory it is showing.

A touched root goes back to the overview rather than to its parent.  Those
are the tops of the trees the state knows about, and climbing past one
leads into directories no agent has been near -- a listing that gets
emptier the further up it goes, with the other trees still out of view."
  (interactive)
  (let ((root agent-river--map-root))
    (cond
     ((null root) (user-error "Already showing every root"))
     ((member root (mapcar #'car (agent-river--map-all-roots agent-river-map-scope)))
      (setq agent-river--map-root nil)
      (agent-river--map-draw))
     (t
      (let ((up (file-name-directory (directory-file-name root))))
        (if (or (null up) (equal (directory-file-name up) root))
            (user-error "Already at the root")
          (agent-river-map-descend up)))))))

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
  (define-key map (kbd "a") #'agent-river-map-toggle-untouched)
  ;; The one forgetting command that belongs on a key here: it drops only
  ;; what is about a file that is already gone, where
  ;; `agent-river-forget-artifacts' drops the record of the work itself and
  ;; is deliberately left to `M-x'.
  (define-key map (kbd "C") #'agent-river-forget-gone-files)
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

(defun agent-river--map-invalidate ()
  "Say the map is out of date and make sure something will redraw it.

Deliberately does not draw.  The event path below runs on every tool
call, and rebuilding a whole listing thousands of times a task would move
point under whoever is reading it -- so a caller only says that the
drawing is out of date and the timer decides how often that is worth
acting on.  Which also makes this safe to call from a `kill-buffer-hook',
where drawing inline would read a buffer that is still live."
  (setq agent-river--map-dirty t)
  (agent-river--ensure-map-timer))

(defun agent-river--map-observe (_state _event)
  "Mark the map as needing a redraw after an event."
  (agent-river--map-invalidate))

(defvar agent-river--map-timer nil
  "Repeating timer redrawing the map, or nil while none runs.")

(defun agent-river--stop-map-timer ()
  "Stop the map redraw timer."
  (when (timerp agent-river--map-timer)
    (cancel-timer agent-river--map-timer))
  (setq agent-river--map-timer nil))

(defun agent-river--map-cooling-p ()
  "Return non-nil while cooling alone will still change the map.

Two thresholds, because two things fade at different depths.  The
shading runs out at the bottom of `agent-river-heat-levels', and asking
only that retired the timer while names were still on screen waiting to
cross `agent-river-map-party-floor' -- which sits below it, so the map
froze mid-fade and the names sat there until the next event.

A name held by the `:current' exemption is not cooling: it never crosses
anything, so it is not something left to draw and must not keep the timer
alive for as long as Emacs runs."
  (and agent-river-heat-half-life
       (or (agent-river--heat-visible-p agent-river-map-scope)
           (and agent-river-map-party-floor
                (seq-some (lambda (entry)
                            (>= (plist-get entry :weight)
                                agent-river-map-party-floor))
                          (agent-river--heat-entries agent-river-map-scope))))))

(defun agent-river--map-tick ()
  "Redraw the map, or stop the timer once there is nothing left to draw.
Cooling counts as something to draw: with a half-life set, a listing whose
agents have all stopped is still changing, and the weights would otherwise
sit frozen at whatever they were when the last event landed.

What it cannot see is the disk.  A file that comes back while no agent is
working -- a branch switch, a build -- redraws on the next event or on
`g', the way a dired buffer does; watching the filesystem to catch it is a
lot of machinery for a view whose subject is the agents."
  (condition-case err
      (cond
       ((null (get-buffer agent-river-map-buffer-name))
        (agent-river--map-teardown))
       ((or agent-river--map-dirty (agent-river--map-cooling-p))
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
at once.

Opens on every tree the agents have touched.  There is no reference
project to open on instead: the state spans whatever directories the
sessions were started in, and picking one of them would hide the others
behind a heading claiming to be the root of all of them.  RET zooms into
a tree from there, and `^' comes back out.

With ASK (a prefix argument), prompt for one directory to show instead.

Needs no mode to be switched on: the buffer is the consent, and killing it
takes the map off the event stream."
  (interactive "P")
  (let* ((root (and ask (read-directory-name "Map: " nil nil t)))
         (buffer (get-buffer-create agent-river-map-buffer-name)))
    (with-current-buffer buffer
      ;; Set unconditionally rather than only on a fresh buffer: the answer
      ;; can change between two calls -- a grammar installed, or this file
      ;; reloaded -- and the mode is what decides how the buffer is read.
      (if (agent-river--markdown-ts-p)
          (agent-river-map-mode)
        (agent-river-map-plain-mode))
      (setq agent-river--map-root (and root (directory-file-name
                                             (expand-file-name root)))
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
