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
;; sessions can fold side by side.  Nothing here reaches across sessions:
;; the map aggregates them per artifact record, and that is the whole of it.
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
  "Name of the buffer the folded state is drawn into."
  :type 'string)

(defcustom agent-river-log-buffer-name "*agent-river-log*"
  "Name of the buffer the event stream is logged to."
  :type 'string)

(defcustom agent-river-max-entries 100
  "How many log lines to keep.
The log runs oldest to newest, so the oldest sit at the top and are
dropped from there.  Zero or less keeps everything, which will grow
without bound."
  :type 'integer)

(defcustom agent-river-window-width 56
  "Width of the side windows the two views are opened in."
  :type 'integer)

(defcustom agent-river-block-max-height 12
  "Most lines the block\='s own side window is grown to.

The block is sized to what it holds after every redraw rather than once
when it is displayed, since a session may arrive at any time.  This limit
stops a morning\='s worth of sessions pushing the log off the screen; it is
a maximum rather than a height because the usual answer is one line."
  :type 'integer)

(defcustom agent-river-auto-display t
  "Whether the first event opens the state block, when nothing is showing it.

The first event, and only the first (`agent-river--block-shown').
Deleting that window is a reader saying what they want their screen to be,
and a view that came back on the next tool call would overrule that
decision several times a minute.  After the offer the window is the
reader's -- `agent-river-show' is how it comes back.

The log is never opened by an event at all; it is asked for
(`agent-river-show-log', or `l' in the block).  What that gives up is that
a line nobody is looking at is a line nobody sees -- the never-go-quiet
rule is about writing the line, not about seizing a window for it."
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
other event goes into a pipe nobody reads, while still being logged and
counted as though it had arrived.

The direction is deliberate: this list decides which events may answer,
and the hook wiring must then mark exactly those as not `async'.  The
config cannot be read from here, so the two are kept in step by the
invariant rather than by inspection.  Add a kind here only after making
its hook synchronous."
  :type '(repeat string))

(defcustom agent-river-label-width 8
  "Width of the session column shown when several sessions are active."
  :type 'integer)

(defcustom agent-river-tool-glyphs
  '(;; Three hosts' names for one thing.
    ("Bash" . "💻") ("BashOutput" . "💻") ("execute" . "💻")
    ;; Changing part of a file, and putting a whole one down.
    ("Edit" . "✏️") ("edit" . "✏️") ("Write" . "📄"))
  "What a log line draws in place of a tool's name, keyed by that name.

Usually the host's own word is the most specific thing the line can say.
What earns a glyph is a call made so often that its name is the part of
the line a reader has stopped seeing, while the argument beside it -- a
command, a path, clipped to `agent-river-detail-width' -- is what differs
between two of them.

Keyed by name and not by class: `Edit' and `Write' are not a class, they
are two tools that differ, and the glyph is how they differ.  Both
dialects are listed by hand, as in `agent-river-phase-buckets' -- the
hooks report the host's own tool name and an agent-shell session reports
the coarser ACP `kind'.

A tool absent from here keeps its name, which is also how a glyph is
turned off.  Not held to the one-column rule
`agent-river-spinner-frames' has: nothing is aligned after a tool name."
  :type '(alist :key-type string :value-type string))

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

Nil turns the animation off and leaves the bare star, which is also the
answer for a font without these glyphs.  Each frame should be one column
wide, or the line will shift as it spins."
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

Slow on purpose.  The marker says an agent is working, a fact that holds
for minutes; faster it reads as something demanding attention, and it is
what makes two markers being out of phase legible at all."
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
  '(("exploring" . ("Read" "Grep" "Glob" "WebFetch" "WebSearch" "Agent" "LSP"
                    "read" "search" "fetch"))
    ("editing"   . ("Edit" "Write" "NotebookEdit"
                    "edit" "delete" "move")))
  "Tools that place a step in a phase, keyed by phase name.

Two dialects in one list, because a step is matched by name and the two
ways in do not name a tool alike.  The hooks report the host's own tool
name; an agent-shell session has none to report, so
`agent-river--shell-payload' stands the ACP call `kind' in for it --
lower-case and coarser.  Listing only the first leaves a hooks-less
session matching nothing at all: no phase, and -- since
`agent-river--writing-p' reads this table -- no write either.

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

(defface agent-river-say '((t :inherit font-lock-keyword-face))
  "Face for what the agent said, at the end of a turn.

The prompt's colour without its weight, because the two are the halves of
one exchange; a colour of its own would file the answer with the tool
calls it is nothing like.  Distinct from `agent-river-reason\=', which is
the agent's words addressed to nobody -- thinking is not telling.")

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

(defface agent-river-ask '((t :inherit warning))
  "Face for a session holding a door open, waiting to be told whether to go on.

`warning' inherited rather than a shade of its own: it is what the user's
theme already means by \"this wants you\".  Distinct from
`agent-river-idle' deliberately -- an agent that has finished its turn is
waiting for whatever you want next, and an agent holding a permission
request is waiting for one particular word.")

(defface agent-river-subject '((t :inherit font-lock-variable-name-face))
  "Face for something that is not a session having happened.

Its own face because it is its own subject: every other kind on this list
is an agent doing something or being told something, and an artifact
appearing is true whether or not any agent ever looks at it.  Sharing a
colour with those would leave a reader unable to say whether a line was
about an agent or about the work.")

(defface agent-river-gone '((t :inherit agent-river-stale :strike-through t))
  "Face for a record whose subject is over -- an issue closed, a PR merged.

The line stays: it was worked on and it is over, which is history until
somebody says otherwise.

Struck through rather than merely greyed, because grey is the map's word
for several things at once -- stale, elided -- and \"this is over\" is
worth saying exactly.  A face and not Markdown `~~\': every face the map
wants travels as an overlay, since tree-sitter owns `face' in that buffer,
so this works in the plain fallback too.")

(defconst agent-river-kinds
  '(("prompt" "◆" agent-river-prompt)
    ("act"    "▸" agent-river-act)
    ("think"  "·" agent-river-think)
    ("reason" "◇" agent-river-reason)
    ("say"    "“" agent-river-say)
    ("intent" "◈" agent-river-intent)
    ("fail"   "✗" agent-river-fail)
    ("ask"    "?" agent-river-ask)
    ("note"   "◉" agent-river-note)
    ("artifact" "◎" agent-river-subject)
    ("signal" "!" agent-river-signal)
    ("done"   "□" agent-river-idle)
    ("idle"   "■" agent-river-idle))
  "Alist of (KIND GLYPH FACE) describing how each event kind renders.")


;;; The state

(defconst agent-river-said-width 200
  "How much of what the agent said the state keeps.

The same number the prompt is clipped to in `agent-river--event\=', matched
rather than shared: the two sit side by side in the export as the halves
of one exchange, and an answer four times the length of the question would
read as the whole of what happened rather than as the end of it.  Two
values because either may move without the other.  The event carries the
text unclipped.")

(cl-defstruct (agent-river-state (:constructor agent-river--state-create))
  id                ; registry key: "SESSION" or "SESSION/AGENT"
  label             ; human-readable: working directory, or the agent type
  ;; The absolute working directory the hook reported; the anchor
  ;; `artifacts' is keyed against.  Kept beside the keys rather than folded
  ;; into them, so a key stays relative and one file reached from a worktree
  ;; and from the main checkout is still one artifact.
  cwd
  ;; hash: artifact key -> the absolute directory it really sits in, for keys
  ;; `cwd' cannot place (a file outside the cwd degrades to a bare basename).
  ;; Only the strays are recorded: a key under the cwd is anchored by the cwd
  ;; already, and storing it twice would let the two disagree.
  anchors
  ;; hash: agent_id -> (:type TYPE :steps N :failures N :started T :last T
  ;; :done BOOL), for the work this session delegated.  A tally on the
  ;; session rather than a peer in the registry: a subagent has no prompt, no
  ;; working directory and nothing that can be told to it, so it fails the
  ;; definition of a session.
  subagents
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
  ;; Everything above is measured; the four below are a *claim* the agent
  ;; made about itself.  Kept apart so a claim can never be read back as an
  ;; observation and feed a signal.
  intent intent-at intent-step intent-hottest
  tasks             ; finished tasks, newest first
  signals           ; observations handed back, newest first
  ;; Observations made outside the hook stream, newest first -- see
  ;; `agent-river-note'.  Seen, but not by a hook, so it can't be recomputed
  ;; from the event stream and has to be carried rather than derived.
  notes
  ;; The end of the last turn, clipped to `agent-river-said-width' and stored
  ;; raw; escaped where rendered, like an intent, so the state carries no
  ;; rendering decision.
  ;;
  ;; In the *task* frame, cleared by `prompt' with the steps and the task
  ;; artifacts: it is the answer to the prompt above it, and after a new
  ;; prompt the old answer would be filed under a question it never heard.
  ;; The words themselves survive in the log.
  ;;
  ;; A measurement, not a claim: the stream witnessed the turn ending with
  ;; this being said.  Its *content* must never be read back as an
  ;; observation or feed a signal -- that would close the loop the intent
  ;; slots are kept apart to prevent.
  said)


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
;; agent-shell buffers run in this Emacs, and `agent-shell--state' carries
;; the ACP session id, which is verbatim the hooks' `session_id'.  That makes
;; liveness, labels and uniquifying exact rather than guessed.
;;
;; Falls back to the TTL-based estimates when agent-shell is absent.

;; Declared so the byte-compiler sees a special variable rather than a free
;; one: agent-shell owns it, and this sets it only while
;; `agent-river-approvals-mode' is on.
(defvar agent-shell-permission-responder-function)
(declare-function agent-shell-subscribe-to "agent-shell" (&rest args))
(declare-function agent-shell-unsubscribe "agent-shell" (&rest args))
(declare-function agent-shell--project-name "agent-shell-project" ())
(declare-function agent-shell--format-buffer-name "agent-shell" (agent-name project-name))

(defun agent-river--shell-buffer-p ()
  "Return non-nil when the current buffer hosts an agent-shell session."
  ;; The mode is the whole test: where agent-shell is not loaded there is no
  ;; such buffer, so no separate `featurep' check is needed.
  (derived-mode-p 'agent-shell-mode))

(defconst agent-river--shell-rescan 5
  "Seconds before a session with no agent-shell buffer is looked for again.
Long enough that a session nobody here hosts costs nothing to keep asking
about, short enough that one whose buffer arrives late is picked up while
it is still the same turn.")

(defvar agent-river--shell-sessions (make-hash-table :test 'equal)
  "What is known about who hosts each session, as id -> BUFFER or (none . TIME).

The index behind `agent-river--shell-buffer'.  A buffer recorded here is
one we have seen hosting that session, and it is kept after it dies: that
a session *had* a buffer and no longer does is what tells
`agent-river--active-p' it is over, and no snapshot of the buffers alive
now can say that.")

(defun agent-river--shell-scan (id)
  "Return the agent-shell buffer hosting session ID by looking for it.
The expensive half of `agent-river--shell-buffer': it walks every buffer
in Emacs."
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

Answered from `agent-river--shell-sessions' wherever it can be, because
every redraw asks this of every session several times over and a walk of
the buffer list each time is most of what drawing the block costs.

Three things can be known about an id, and the difference between the last
two is the point:

  - a buffer we have seen.  Live, it is the answer; dead, the session is
    over and nothing will host that id again -- `agent-shell-restart' kills
    the buffer and starts a *new* session -- so the answer is nil, and
    still without looking.
  - nothing at all: look, and remember what was found.
  - looked and found nothing, with the time.  Looked for again every
    `agent-river--shell-rescan' seconds, and never remembered
    permanently: a session whose first event beats agent-shell to setting
    its id would then be counted unhosted for the rest of the Emacs
    session -- no label, no reasoning lines, no RET -- with nothing saying
    so."
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

(defun agent-river-state (id &optional label)
  "Return the state keyed by ID, creating it if needed.
LABEL names it for a human and is refreshed on every call, so a session
that changes directory does not keep a stale name."
  (let ((state (or (gethash id agent-river-registry)
                   (puthash id
                            (agent-river--state-create
                             :id id
                             :subagents (make-hash-table :test 'equal)
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
    (let ((hosted (agent-river--shell-label id)))
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
not an estimate.  The TTL is what is left for everything else -- sessions
nobody here owns -- and is only ever a guess.

Asked of `agent-river--shell-hosted', which is per session: a global flag
would call every session run from a terminal inactive, since it has no
buffer here and never did."
  (cond
   ((agent-river--shell-hosted (agent-river-state-id state))
    (and (agent-river--shell-buffer (agent-river-state-id state)) t))
   (t (let ((seen (agent-river-state-last-seen state)))
        (and seen (< (float-time (time-subtract (current-time) seen))
                     agent-river-session-ttl))))))

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
  "Return how many sessions are currently live.

Sessions, and only sessions: a subagent is a tally on its parent, so a
session with three of them running counts once.  That is right for the one
thing this answers -- whether a second session exists, and the label
column is therefore worth drawing -- and wrong for anything asking how
many agents are at work, which has to add each session's running delegates
\(`agent-river-children') to this number."
  (let ((n 0))
    (maphash (lambda (_id state)
               (when (agent-river--active-p state) (setq n (1+ n))))
             agent-river-registry)
    n))

(defun agent-river-children (key)
  "Return what the session registered under KEY delegated, newest first.

A list of plists -- `:agent', `:type', `:steps', `:failures', `:status'
and `:elapsed'.  Read off the session's own tally rather than by walking
the registry for entries that name it as a parent: a subagent is not a
session, so it is not in the registry, so there is nothing there to walk.

`:status' distinguishes three things on purpose.  `done' comes from
`SubagentStop' and is a fact.  `stale' means nothing has been heard for
`agent-river-session-ttl' and no end event ever came -- something went
away without saying so.  Only `running' claims it is still working, and
inferring \"finished\" from silence is how a registry starts lying."
  (let ((state (gethash key agent-river-registry))
        kids)
    (when state
      (maphash
       (lambda (agent cell)
         (push (list :agent agent
                     :type (plist-get cell :type)
                     :steps (or (plist-get cell :steps) 0)
                     :failures (or (plist-get cell :failures) 0)
                     :last (plist-get cell :last)
                     :elapsed (and (plist-get cell :started)
                                   (agent-river--ago (plist-get cell :started)))
                     :status (cond
                              ((plist-get cell :done) "done")
                              ((agent-river--delegate-live-p cell) "running")
                              (t "stale")))
               kids))
       (agent-river-state-subagents state)))
    (sort kids (lambda (a b)
                 (agent-river--map-later (plist-get b :last) (plist-get a :last))))))

(defun agent-river--delegate-live-p (cell)
  "Return non-nil while subagent CELL has been heard from recently enough.
The TTL is all there is for a subagent -- it has no buffer of its own and
no process this Emacs can see -- which is why silence is reported as
`stale' rather than as finished."
  (let ((last (plist-get cell :last)))
    (and last (< (float-time (time-subtract (current-time) last))
                 agent-river-session-ttl))))


;;; The fold

(defun agent-river--delegated-p (event)
  "Return non-nil when EVENT reports a call a subagent made.

The payload says so: a subagent's hook call carries its parent's session
id and an agent_id of its own."
  (let ((agent (plist-get event :agent)))
    (and agent (not (string-empty-p agent)) t)))

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
it are different things to have done: forty reads and one rewrite weigh
the same as a touch count, and the map's party rows say which of the two
a name saw."
  (let ((entry (gethash path table)))
    (puthash path
             (list :touches (1+ (or (plist-get entry :touches) 0))
                   :writes (+ (or (plist-get entry :writes) 0) (if wrote 1 0))
                   :last (current-time))
             table)))

(defun agent-river--touch (state path &optional wrote)
  "Record that the session behind STATE touched PATH, writing it with WROTE.

Kept in two frames on purpose.  The session-wide tally has to survive a
change of task; the per-task one answers \"what is being worked on now\"
rather than \"what has been opened all afternoon\".  Reporting one while
labelling it the other is how a panel starts misleading people.

Both are counted for every path.  No view names a file: what still reads a
*file* entry is `agent-river--hottest', `agent-river--artifact-list' and
`agent-river--gone-artifacts'.  What reads a *declared* key is the map."
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

(defun agent-river--delegate (state agent type &optional step failed done)
  "Record what subagent AGENT of TYPE did, on STATE's own tally.

What this session set in motion, how far it has got, and whether it is
finished.  A plist rather than an `agent-river-state' because a subagent
has none of the things a state carries -- no prompt, no working directory,
no place, no intent, nothing that can be told to it."
  (let* ((table (agent-river-state-subagents state))
         (cell (and table agent (gethash agent table))))
    (when (and table agent (not (string-empty-p agent)))
      (puthash agent
               (list :type (or type (plist-get cell :type) "subagent")
                     :steps (+ (or (plist-get cell :steps) 0) (if step 1 0))
                     :failures (+ (or (plist-get cell :failures) 0) (if failed 1 0))
                     :started (or (plist-get cell :started) (current-time))
                     :last (current-time)
                     ;; Said by `SubagentStop', which is a fact rather than a
                     ;; guess -- the only thing here that is.
                     :done (or done (plist-get cell :done)))
               table))))

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
    ;; Folded rather than set where the state is addressed, so replaying the
    ;; events reproduces the anchor too.  Refreshed on every event that
    ;; carries a cwd; only the agent-shell path actually moves it, reading the
    ;; buffer's `default-directory' per event.  Events made inside Emacs --
    ;; a note, a signal -- carry none and leave it alone.
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
      ;; And so does it to the answer that ended the last one: the export
      ;; sits `said' under the prompt as one exchange, and a new prompt has
      ;; not been answered yet.
      (setf (agent-river-state-said state) nil)
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
      (agent-river--anchor state file path)
      ;; Counted on the session, not beside it: a delegated step is a step
      ;; this session took, and the file it touched lands in the session's
      ;; own frames.
      (agent-river--delegate state (plist-get event :agent)
                             (plist-get event :agent-type) t))

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
            (1+ (or (agent-river-state-task-failures state) 0)))
      (agent-river--delegate state (plist-get event :agent)
                             (plist-get event :agent-type) nil t)
      ;; The streak is the one measurement a delegated failure stays out of,
      ;; since it's what a signal is built from: three subagents failing once
      ;; each is not one line of work failing three times.  Everything else
      ;; about the failure is still counted: task tally, tool tally, and the
      ;; child's own tally.
      (unless (agent-river--delegated-p event)
        ;; A failure that follows a success opens a new run: the streak value
        ;; alone can't tell two runs apart, and an observation about the new
        ;; one must not be suppressed as a repeat of the first.  Never reset,
        ;; so the run id stays unique even after a prompt clears the streak.
        (when (zerop (agent-river-state-fail-streak state))
          (setf (agent-river-state-fail-runs state)
                (1+ (or (agent-river-state-fail-runs state) 0))))
        (setf (agent-river-state-fail-streak state)
              (1+ (agent-river-state-fail-streak state)))
        (let ((cell (assoc tool (agent-river-state-fail-tools state))))
          (if cell
              (setcdr cell (1+ (cdr cell)))
            (push (cons tool 1) (agent-river-state-fail-tools state))))))

     ;; The edge on its own: a session reached something without a tool call
     ;; this package could see -- see `agent-river-reach'.  Updates both
     ;; artifact frames and the anchor, nothing else.  No tool ran, so this
     ;; counts no step.
     ((equal kind "touch")
      (agent-river--touch state file (plist-get event :wrote))
      (agent-river--anchor state file path))

     ;; What the agent said, once the turn it said it in was over.  As narrow
     ;; as `touch' above: no tool ran, so no step is counted and no artifact
     ;; table is warmed.
     ;;
     ;; The event carries the whole text, for `agent-river-observers'; the
     ;; slot keeps an excerpt clipped to `agent-river-said-width', since
     ;; every reader of the slot is bounded (export, report, log line).
     ;;
     ;; `agent-river--excerpt' keeps both ends rather than the first WIDTH
     ;; characters: an answer opens by restating the question and closes
     ;; with the conclusion, while the middle narrates tool calls already
     ;; counted elsewhere.
     ;;
     ;; Not configurable -- a setting here would put policy inside the fold,
     ;; which this package keeps free of extension points, and would make
     ;; the replay promise depend on a variable's value at replay time.
     ((equal kind "say")
      (setf (agent-river-state-said state)
            (agent-river--excerpt (plist-get event :text)
                                  agent-river-said-width)))

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
      ;; The artifact tables emptied, nothing else: steps and failures still
      ;; count.  Folded rather than cleared where the command is written,
      ;; since the fold owns the state.
      ;;
      ;; The anchors go with them -- keyed on artifact keys, so without the
      ;; artifacts they address nothing.
      ;;
      ;; `:files' narrows the same transition to the keys it names, for
      ;; `agent-river-forget-gone-files': one branch rather than two, since
      ;; the state change is identical and only its subject differs.
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
      ;; `SubagentStop' carries an agent_id, so this retires the child it
      ;; names and never the session -- an event naming no child would
      ;; otherwise mark a live session finished.
      (agent-river--delegate state (plist-get event :agent)
                             (plist-get event :agent-type) nil nil t)))
    state))


;;; Artifacts -- the things worked on, as subjects of their own
;;
;; Everything above folds events onto a *session*.  `agent-river-fold' takes
;; an `agent-river-state', and the artifact tables inside it record which
;; files that session reached -- an artifact has no existence of its own,
;; just a key in somebody's table.
;;
;; That shape is right for a file, which only becomes interesting once an
;; agent opens it.  It is wrong for anything that arrives on its own -- an
;; incident routed to you, a review requested, a build that broke -- since
;; such a thing matters most when *no* agent is running, and there is no
;; session to fold it onto.
;;
;; So the implicit identity gets a table of its own.  What is true of the
;; artifact lives here; what is true of the *relationship* between a session
;; and an artifact stays in the session's two tables and is aggregated at
;; read time.  That split keeps the frames out of here: `artifacts' versus
;; `task-artifacts' is a property of the reaching, not of the thing reached.
;;
;; Deliberately not a mirror of those tables: a file an agent touched needs
;; no record here, since the session's table already says everything true
;; of it.  What belongs here is what the event stream could never produce --
;; something declared in from outside, the same rule `agent-river-note'
;; follows one subject over.
;;
;; A second table rather than widening `agent-river-registry' to hold
;; non-session keys: every walker of that registry would then have to ask
;; which kind of key it had, and a struct serving two meanings is a union
;; type either way it is spelled.  Two tables cost a second `clrhash' in
;; `agent-river-reset' and nothing else.

(cl-defstruct (agent-river-artifact
               (:constructor agent-river--artifact-create))
  ;; The identity, exactly as the session tables key it.  For a file that is
  ;; `agent-river--rel's answer; for anything else it is whatever the producer
  ;; chose, and it should carry its domain (`inc:INC-444') so that two
  ;; producers cannot collide on a bare number.
  key
  domain            ; symbol: who understands `key'.  Required; see the fold
  name              ; what a human calls it; `key' when nothing better was given
  ;; Whatever the producer carried in, an alist, opaque here.  This package
  ;; never reads a value out of it, which lets it hold a ticket body, a
  ;; severity or a URL without this file learning about any of them.
  context
  ;; When the key first entered this table.  The fact a dedup asks about, and
  ;; the reason it is a slot rather than derived: "have I seen this one" is not
  ;; answerable from an event stream that only carries the events you kept.
  appeared
  last              ; when something last happened *to* it
  ;; Closed, resolved, deleted.  Kept rather than removed: the ending is
  ;; itself a thing that happened.  `agent-river-drop-artifact' is the
  ;; gesture for when it has stopped being news.
  gone gone-at
  ;; Observations about the artifact itself, newest first -- not about any
  ;; session that reached it.  Same shape and same rule as the state's own
  ;; `notes': a measurement, never an opinion.
  notes)

(defvar agent-river-artifacts (make-hash-table :test 'equal)
  "Map of artifact key to `agent-river-artifact'.

The second folded table beside `agent-river-registry', and the only other
one: everything else this package keeps in a hash is a current-state fact
queried where it is read -- which buffer hosts a session, what a session
is waiting to be allowed.

Keyed the same way the session tables are, so that a key here and a key
there are the same artifact and a view can put the two readings together
without translating between them.")

(defun agent-river-artifact (key domain &optional name)
  "Return the artifact keyed by KEY, creating it with DOMAIN if needed.

DOMAIN and NAME are set once, when the record is created -- an artifact
does not change what kind of thing it is, and a later event that wants to
rename it says so through the fold (`name' on an `appear'), where it is
logged like every other transition.  This is addressing, not folding; it
writes no slot but the ones a record cannot exist without.

DOMAIN is required, and nil is refused **only where a record has to be
created**: `agent-river-ended' and `agent-river-note-artifact' name no
domain and must go on working, which they do because by then the key is
in the table.  Where it is not, the producer has said a thing is over or
has been noted before saying what it is, and there is nothing to make a
record out of.  There is no default domain: a record standing for \"nobody
declared this\" would be indistinguishable from no record at all."
  (or (gethash key agent-river-artifacts)
      (progn
        (unless domain
          (user-error "Artifact %s needs a domain" key))
        (puthash key
                 (agent-river--artifact-create
                  :key key
                  :domain domain
                  :name (or name key)
                  :appeared (current-time)
                  :last (current-time))
                 agent-river-artifacts))))

(defun agent-river-artifact-known-p (key)
  "Return non-nil when KEY is already in `agent-river-artifacts'.

The dedup question asked without folding anything, for a producer that
wants to decide before it builds an event.  `agent-river-observe-artifact'
answers the same question as its return value, which is the one to prefer:
asked separately, the answer is stale by the time the event is folded."
  (and (gethash key agent-river-artifacts) t))

(defun agent-river-fold-artifact (artifact event)
  "Fold EVENT into ARTIFACT and return ARTIFACT.

EVENT is a plist with :kind, and optionally :name, :context and :text.
Deterministic given the event order -- the same promise `agent-river-fold'
makes one subject over, and it has the same consequence: this is the only
writer.  Anything else that `setf's a slot here puts a transition into the
record that no event accounts for, and the promise stops being true
without anything failing.

Four kinds, and between them they are the whole vocabulary:

  appear   it exists, and here is what is known about it
  context  what is known about it has changed
  gone     it is closed, resolved or deleted
  note     something was observed about it

There is no kind for a session reaching it.  That is an edge rather than a
fact about the artifact, it is folded onto the session where the two
frames are (`agent-river-reach'), and duplicating it here would be the
second account this table exists to avoid."
  (let ((kind (plist-get event :kind)))
    ;; Every event is something happening to it, whatever else it does.
    (setf (agent-river-artifact-last artifact) (current-time))
    (cond
     ((equal kind "appear")
      ;; Idempotent on purpose: a producer that polls sees the same ticket
      ;; every pass, and the appearance is the *key* entering the table, not
      ;; this event arriving -- see `agent-river-observe-artifact'.
      (let ((name (plist-get event :name))
            (context (plist-get event :context)))
        (when name (setf (agent-river-artifact-name artifact) name))
        (when context
          (setf (agent-river-artifact-context artifact)
                (agent-river--artifact-merge
                 (agent-river-artifact-context artifact) context))))
      ;; Reappearing undoes an ending: a ticket resolved and then reopened is
      ;; open, and a record that kept saying otherwise would be wrong in the
      ;; direction that matters.
      (setf (agent-river-artifact-gone artifact) nil
            (agent-river-artifact-gone-at artifact) nil))

     ((equal kind "context")
      ;; Merged per key, not replaced wholesale: a producer that learned one
      ;; new thing shouldn't have to resend everything it knew before.
      (setf (agent-river-artifact-context artifact)
            (agent-river--artifact-merge
             (agent-river-artifact-context artifact)
             (plist-get event :context))))

     ((equal kind "gone")
      ;; Everything else is left standing.  What it was, who reached it and
      ;; what was noted about it are all still true of a thing that has
      ;; finished; only the present tense is withdrawn.
      (setf (agent-river-artifact-gone artifact) t
            (agent-river-artifact-gone-at artifact) (current-time)))

     ((equal kind "note")
      (push (cons (current-time) (plist-get event :text))
            (agent-river-artifact-notes artifact))))
    artifact))

(defun agent-river--artifact-merge (old new)
  "Return alist OLD with NEW\='s cells replacing or extending it.
NEW wins per key, and the order of OLD is kept so a context that is read
as a list does not reshuffle itself every time one field is updated.

Every cell is built fresh, and that is the whole of what this owes.
Copying the spine and updating in place shares the cells, so a context
handed out by `agent-river-artifacts-list\=' would change under a consumer
holding it with no event at that consumer\='s end accounting for it.  A
producer\='s own list is left alone for the same reason; it may well be a
quoted literal, and nothing here may write into one."
  (let (merged)
    (dolist (cell old)
      (let ((replacement (assq (car cell) new)))
        (push (cons (car cell) (cdr (or replacement cell))) merged)))
    (dolist (cell new)
      (unless (assq (car cell) old)
        (push (cons (car cell) (cdr cell)) merged)))
    (nreverse merged)))

(defvar agent-river-artifact-observers nil
  "Functions called with (ARTIFACT EVENT) after each artifact event is folded.

The artifact-side counterpart to `agent-river-observers', run by the same
runner and under the same three rules: its own guard, retired on the first
error, and torn down through the `agent-river-retire' symbol property.

The same runner, not a second one of its own: those three rules are the
whole of what a consumer inherits, and a second copy of the loop is a
second place for one of them to be quietly dropped.  That is why
`agent-river--run-observers' takes the hook symbol.

A separate hook rather than the same one, because the subject differs.
One hook carrying either an `agent-river-state' or an
`agent-river-artifact' would make every consumer begin by asking which it
had been handed, and a consumer that forgot to ask would be wrong only for
the events it saw least often.")

(defun agent-river--artifact-key (event)
  "Return EVENT\='s :key, or refuse to address a record with nothing.
A function rather than a guard inside `agent-river-observe-artifact\=', so
the check comes before `agent-river-artifact\=' has created the record the
check is about -- which is in the binding list, one line down."
  (let ((key (plist-get event :key)))
    (if (or (null key) (string-empty-p key))
        (user-error "No artifact key to record")
      key)))

(defun agent-river-observe-artifact (event)
  "Fold EVENT about an artifact, render it, and say whether the key was new.

EVENT is a plist: :key addresses the artifact, :kind selects the fold,
:domain and :name describe it when the record is created, :context carries
whatever the producer knows and :text is the line for the buffer.

Returns the artifact when this event was the key's first appearance here,
and nil when it was already known.  That is the dedup answer -- \"have I
seen this one?\" -- given by the table rather than by every producer
keeping a list of its own, and it is a return value rather than a query so
that asking and folding cannot come apart.

Nothing here can reach the agent.  Signals travel back through
`agent-river-observe' alone, and an artifact has no session to answer --
which is the whole case this table exists for.

An empty :key is refused, the way `agent-river-reach\=' refuses one: a
record under no key can be reached, found, ended or dropped by nobody."
  (let* ((key (agent-river--artifact-key event))
         (fresh (not (agent-river-artifact-known-p key)))
         (artifact (agent-river-artifact key
                                         (plist-get event :domain)
                                         (plist-get event :name))))
    ;; Guarded like the session fold: an error here must not become an error
    ;; in whatever producer called it -- on a webhook that's a dropped
    ;; ticket rather than a visible mistake.
    (condition-case err
        (agent-river-fold-artifact artifact event)
      (error
       (agent-river-log "fail" (format "artifact fold failed (%s) -- try M-x agent-river-reset"
                                       (error-message-string err)))))
    (agent-river--run-observers 'agent-river-artifact-observers artifact event)
    ;; Both halves are the producer's: the line and the name that tags it.
    (let ((text (plist-get event :text)))
      (unless (or (null text) (string-empty-p text))
        (agent-river-log "artifact" (agent-river--log-text text)
                         (agent-river--log-text
                          (agent-river-artifact-name artifact)))))
    (and fresh artifact)))

;;;###autoload
(defun agent-river-appeared (key &rest props)
  "Record that artifact KEY exists, and return it when that is news.

PROPS is a plist of :domain, :name, :context and :text.  The convenience
form of `agent-river-observe-artifact' for the case a producer has almost
always: something showed up, here is what I know about it, tell me whether
you had already heard.

Nil means the key was already in the table -- already reported, already
drawn, already whatever the producer did about it last time.  A producer
polling a queue can therefore act on the return value and keep no
bookkeeping of its own, which is the bookkeeping most likely to be the
thing that is wrong.

This is what says a key is declared at all, so it comes before
`agent-river-reach\=' rather than after it -- see there for what a reach on
a key nobody has declared is taken for."
  (agent-river-observe-artifact
   (append (list :kind "appear" :key key) props)))

;;;###autoload
(defun agent-river-ended (key &optional text)
  "Record that artifact KEY is closed, resolved or deleted.
TEXT is the line for the buffer.  The record is kept, struck out of the
present tense rather than removed: see `agent-river-drop-artifact' for
when it has stopped being worth showing at all."
  (agent-river-observe-artifact
   (list :kind "gone" :key key
         :text (or text (format "%s ended" key))))
  nil)

;;;###autoload
(defun agent-river-note-artifact (key text)
  "Fold TEXT as an observation about artifact KEY.

The artifact-side `agent-river-note', and it is kept apart from that one
for the reason the whole table is: a note on a session says something
about an agent, and a note here says something about the thing being
worked on, which is true whether or not any agent ever looks at it.

A measurement, not a claim.  An observer minting notes about its own
opinions closes the same loop the `intent' slots are kept apart to
prevent."
  (agent-river-observe-artifact
   (list :kind "note" :key key :text text))
  text)

;;;###autoload
(defun agent-river-reach (key &optional id wrote)
  "Record that session ID reached artifact KEY, writing it when WROTE.

The edge between a session and an artifact, for the case no tool call can
express it.  An agent dispatched to an incident has reached it in every
sense the artifact tables mean, but no tool argument names it and
`agent-river--tool-file' will never find it -- so without this the
association exists only in the head of whatever did the dispatching.

A measurement rather than a claim: whoever calls this performed the
dispatch and is reporting it -- a measurement made outside the hook
stream, the way `agent-river-note' is.  It is folded as an event like any
other and counted in both frames, so everything downstream -- the map's
parties and listing, `agent-river-reaching' -- sees it without being
taught anything.

What it deliberately does not do is count a step or move the phase.  No
tool ran, and a step count inflated here would be wrong in every reading
taken from it, to exactly the extent this is used.

ID defaults to the session that most recently acted.  That is a guess, and
it is the guess this table exists to avoid making -- name the session
where you can.

**Declare a key before you reach it.**  A domain is read off
`agent-river-artifacts\=', so a key reached before its record exists is
undeclared, and undeclared is a path: resolved against the session cwd,
`inc:INC-444\=' becomes `/repo/inc:INC-444\=', which
`agent-river-forget-gone-files\=' then offers to sweep as a name that is not
on disk.  The window closes by itself -- the domain is read at every draw,
so `agent-river-appeared\=' landing later repairs the placement -- but the
order is still wrong: nobody can say who is on a subject they have not
named yet.  Declaring is not done here because the table is not a mirror
of the session tables, and because two calls declaring a domain would be
two places it is decided."
  (let* ((key (or key ""))
         (session (or id agent-river--current))
         (state (and session (gethash session agent-river-registry))))
    (cond
     ((string-empty-p key) (user-error "No artifact to reach"))
     ((null state) (user-error "No session to attach a reach to"))
     (t
      (let ((event (list :kind "touch" :file key :wrote wrote :session session)))
        (agent-river-fold state event)
        (agent-river--update-panel state)
        (agent-river-log "artifact"
                         (agent-river--log-text
                          (format "%s reached %s"
                                  (agent-river-state-label state) key))
                         (agent-river-state-label state))
        (agent-river--run-observers 'agent-river-observers state event)
        key)))))

(defun agent-river-reaching (key &optional scope)
  "Return which sessions have reached artifact KEY, as a list of plists.

Matched on the key exactly: an artifact key *is* its own name and has no
other spelling.

SCOPE is `session' for the whole session, `task' or nil for this task."
  (let (hits)
    (maphash
     (lambda (id state)
       (let ((entry (gethash key (if (eq scope 'session)
                                     (agent-river-state-artifacts state)
                                   (agent-river-state-task-artifacts state)))))
         (when entry
           (push (list id
                       :label (agent-river-state-label state)
                       :touches (plist-get entry :touches)
                       :writes (or (plist-get entry :writes) 0)
                       :ago (agent-river--ago (plist-get entry :last)))
                 hits))))
     agent-river-registry)
    hits))

;; Linking by hand -- the user as the producer
;;
;; The edge between a session and an artifact can only be reported by
;; whoever performed the dispatch, and nothing in this package performs
;; one.  A user does -- so the gesture below is that report, made where
;; "which session" is not a guess.
;;
;; It calls `agent-river-appeared' and `agent-river-reach' as one
;; function, so a caller has no order to get wrong, and the session is
;; checked before either half runs.

(defun agent-river--read-session ()
  "Return the session a gesture is about, asked only where it is in doubt.

In an agent-shell buffer there is nothing to ask: `agent-shell--state'
carries the id the hooks use, so the buffer the command was typed in is
itself the answer -- which is the one context where \"which session am I\"
has an exact answer rather than an estimate.

Anywhere else this prompts, and deliberately does not fall back to
`agent-river--current' the way `agent-river-reach' does when handed no id.
That default is whichever session acted most recently, quite possibly not
the one meant, and a wrong edge in the artifact tables reads exactly like
a right one."
  (or (agent-river--shell-session)
      (let (cands)
        (maphash (lambda (id state)
                   ;; The id rides along because a label need not be
                   ;; unique -- agent-shell uniquifies the ones it hosts,
                   ;; nothing uniquifies the rest.
                   (push (cons (format "%s [%s]"
                                       (or (agent-river-state-label state) "?")
                                       id)
                               id)
                         cands))
                 agent-river-registry)
        (unless cands (user-error "No session to link to"))
        (setq cands (sort cands (lambda (a b) (string< (car a) (car b)))))
        (cdr (assoc (completing-read "Session: " cands nil t) cands)))))

(defun agent-river--read-artifact-key ()
  "Read an artifact key, offering the ones already on record.

The candidates are the keys themselves, never a \"KEY -- NAME\" display
string: the key is the identity `agent-river-reaching' matches on, so a
display string would have to be parsed back into one, and a parse is a
second account of what the user picked.  The name rides along as an
annotation, where nothing has to read it back.

No match is required.  Typing a key nothing answers to is how a new
artifact gets declared, which is the whole of what this reading is for."
  (let ((keys nil)
        (names (make-hash-table :test 'equal)))
    (maphash (lambda (key artifact)
               (push key keys)
               (puthash key (agent-river-artifact-name artifact) names))
             agent-river-artifacts)
    (let ((completion-extra-properties
           (list :annotation-function
                 (lambda (key)
                   (let ((name (gethash key names)))
                     (and name (not (equal name key)) (concat "  " name)))))))
      (string-trim (completing-read "Artifact key: " (sort keys #'string<))))))

(defun agent-river--read-domain ()
  "Read the domain a newly declared artifact key belongs to.

Asked every time rather than defaulted, because there is no default that
is right often enough to be worth the one time it is not, and because an
undeclared key is not a kind of thing -- it is a path relative to the
session cwd, which `agent-river--artifact-absolute' resolves and
`agent-river-forget-gone-files' may then sweep.  Reading the domain off
the key's own spelling instead is the prefix rule
`agent-river--key-domain' exists to refuse.

No match is required: a domain nothing here has heard of is still drawn,
and something that has arrived must not wait for configuration before it
can be seen.  An empty answer is refused, the same refusal
`agent-river-artifact' makes one layer down.

The candidates are `agent-river-domains', which is what the table has --
never a view's own list of domains, which would let a view's settings
decide what a producer may declare."
  (let ((answer (string-trim
                 (completing-read
                  "Domain: " (mapcar #'symbol-name (agent-river-domains))))))
    (if (string-empty-p answer)
        (user-error "A new artifact needs a domain")
      (intern answer))))

;;;###autoload
(defun agent-river-link-artifact (key session &optional domain name)
  "Record that SESSION is working on artifact KEY, declaring it when new.

The hand-made half of what a webhook does: KEY already on record is simply
reached, and KEY nothing answers to is declared with DOMAIN and NAME first
and reached after.  Called interactively from an agent-shell buffer the
session is that buffer's; anywhere else it is asked for.

DOMAIN is required for a key that is new and refused for one that is not:
a record already says what its key means, and a second answer here would
be a way for the two to disagree.

Everything is checked before anything is folded.  Declaring an artifact
and then failing to reach it would leave a record nobody asked for, which
only `agent-river-drop-artifact' takes back -- so the session is looked up
first, while there is still nothing to take back.

Returns KEY.  No step is counted and the phase does not move: no tool ran,
which is `agent-river-reach's rule and this only passes it on."
  (interactive
   (let* ((session (agent-river--read-session))
          (key (agent-river--read-artifact-key)))
     (if (agent-river-artifact-known-p key)
         (list key session)
       (list key session
             (agent-river--read-domain)
             (read-string (format "Name (%s): " key) nil nil key)))))
  (let* ((key (string-trim (or key "")))
         (fresh (not (agent-river-artifact-known-p key))))
    (cond
     ((string-empty-p key) (user-error "No artifact to link"))
     ((null (gethash session agent-river-registry))
      (user-error "No session %s to link to" session))
     ((and fresh (null domain))
      (user-error "A new artifact needs a domain"))
     (t
      (when fresh
        (agent-river-appeared key :domain domain :name name
                              :text (format "%s declared by hand" key)))
      (agent-river-reach key session)
      (when (called-interactively-p 'interactive)
        (message "agent-river: %s %s"
                 (if fresh "declared and linked" "linked") key))
      key))))

(defun agent-river-domains ()
  "Return every domain with a record in `agent-river-artifacts\=', in arrival order.

A domain is who knows what a key means.  It was declared by whoever put
the record here, and only that producer knows how to read the key back.

Derived from the table rather than declared in a variable: a declared list
of what has arrived is a second account of the table, right only for as
long as somebody keeps it in step."
  (let (domains)
    (maphash (lambda (_key artifact)
               (let ((domain (agent-river-artifact-domain artifact)))
                 (unless (memq domain domains) (push domain domains))))
             agent-river-artifacts)
    (nreverse domains)))

(defun agent-river--artifact-plist (artifact)
  "Return ARTIFACT as the plist a reader outside this file is handed.

One renderer, because there are two ways in: the whole table and a single
key.  Two would be two accounts of what an artifact looks like from
outside, right only for as long as somebody kept them in step."
  (list :key (agent-river-artifact-key artifact)
        :domain (agent-river-artifact-domain artifact)
        :name (agent-river-artifact-name artifact)
        :context (copy-alist (agent-river-artifact-context artifact))
        :gone (and (agent-river-artifact-gone artifact) t)
        :appeared (agent-river--ago (agent-river-artifact-appeared artifact))
        :ago (agent-river--ago (agent-river-artifact-last artifact))
        :notes (length (agent-river-artifact-notes artifact))
        :reached (length (agent-river-reaching
                          (agent-river-artifact-key artifact) 'session))))

;;;###autoload
(defun agent-river-artifact-at (key)
  "Return the artifact KEY names as a plist, or nil.

The cheap way to ask about one: a `gethash' and one rendering, where
`agent-river-artifacts-list' renders every record and walks the whole
session registry for each of them."
  (when-let* ((artifact (and key (gethash key agent-river-artifacts))))
    (agent-river--artifact-plist artifact)))

(defun agent-river-artifacts-list (&optional domain)
  "Return every known artifact as a plist, newest first.
DOMAIN narrows to one domain.  Ended artifacts are included and say so:
dropping them here would make this disagree with what the views draw, and
the ending is a thing that happened.

`agent-river-artifact-at' is the one to use for a single key.

The context comes back as a copy.  What is handed out here is a reading
taken at a moment, and a reading that goes on tracking its subject is not
one -- nor may a caller\='s `setcdr\=' reach into a record the fold is
supposed to own alone."
  (let (records out)
    (maphash (lambda (_key artifact)
               (when (or (null domain)
                         (eq (agent-river-artifact-domain artifact) domain))
                 (push artifact records)))
             agent-river-artifacts)
    ;; Sorted on the records and rendered afterwards, so the plist doesn't
    ;; need to carry a raw timestamp beside its formatted `:ago'.
    (dolist (artifact (sort records
                            (lambda (a b)
                              (time-less-p (agent-river-artifact-last b)
                                           (agent-river-artifact-last a)))))
      (push (agent-river--artifact-plist artifact) out))
    (setq out (nreverse out))
    out))

;;;###autoload
(defun agent-river-drop-artifact (key)
  "Forget artifact KEY entirely.

For when an ending has stopped being news -- the same moment
`agent-river-forget-gone-files' is for, one subject over.  Removing the
record is not a second writer to a state the fold owns: it removes the
subject rather than putting a transition in it, which is what
`agent-river-reset' does to every session and nobody calls that a write.

The sessions that reached it keep their tables.  Those are the edge, they
are true whatever became of the thing at the other end, and clearing them
from here would reach into a state this command is not about.

Returns KEY when a record was removed and nil when there was none of that
name.  No prompt: naming one record out of a completing list is already
the deliberate act a `y-or-n-p\=' would be asking for, which is what tells
this apart from `agent-river-artifacts-reset\=' below."
  (interactive
   (list (let (keys)
           (maphash (lambda (k _v) (push k keys)) agent-river-artifacts)
           (unless keys (user-error "No artifact records to forget"))
           (completing-read "Forget artifact: " keys nil t))))
  (if (not (gethash key agent-river-artifacts))
      ;; Nothing was removed, so nothing to log or redraw: a `forgotten\='
      ;; line here would record a thing that did not happen.
      (progn (message "agent-river: %s is not on record" key) nil)
    (remhash key agent-river-artifacts)
    (agent-river--forget-reported
     (agent-river--log-text (format "%s forgotten" key)) "artifact")
    key))

;;;###autoload
(defun agent-river-artifacts-reset ()
  "Forget every artifact, keeping the sessions.
The artifact-side `agent-river-forget-artifacts\=': what was being worked
on is dropped, and who was working is left alone.

Asks first, for the reason `agent-river-forget-gone-files\=' does and in the
same shape: nothing undoes this, and what it throws away is the half of
the state no event can rebuild.  A session folds again from its next hook
call; a record that arrived from a webhook an hour ago arrived once.

Always, rather than only when a person typed it: this is a gesture, and
`clrhash\=' on `agent-river-artifacts\=' is what code that means it should
say."
  (interactive)
  (let ((n (hash-table-count agent-river-artifacts)))
    (cond
     ((zerop n) (message "agent-river: no artifact records to forget"))
     ((not (y-or-n-p (format "Forget %d artifact record%s? "
                             n (if (= n 1) "" "s"))))
      (message "agent-river: kept"))
     (t
      (clrhash agent-river-artifacts)
      (agent-river--forget-reported
       (format "forgot %d artifact record%s" n (if (= n 1) "" "s"))
       "artifact")))))

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

(defun agent-river--answerable-p (event)
  "Return non-nil when an observation produced for EVENT can reach an agent.

A signal produced for a subagent reaches nobody -- its hook is
synchronous and `additionalContext' is written for it, but the text
arrives nowhere -- so it would be written into a pipe nobody reads, and
counting it in `signals' would make that tally report a conversation that
never happened.

Asked of EVENT rather than of a state: the payload says whether a subagent
made the call, so the session it belongs to is answerable either way.
Only known to hold on Claude Code; Codex and Gemini CLI are untested."
  (not (agent-river--delegated-p event)))

(defun agent-river--signalled-p (state id)
  "Return non-nil when ID has already been handed to the agent in STATE.

The signals list doubles as the delivery log, which is what makes
\"exactly once\" answerable without a second slot that would have to be
kept in step with it."
  (seq-find (lambda (entry) (equal (plist-get entry :id) id))
            (agent-river-state-signals state)))

(defvar agent-river-signal-functions (list #'agent-river--fail-streak-signal)
  "Functions called with STATE, each returning (:id ID :text TEXT) or nil.

The first non-nil answer wins, so order is precedence: a session gets one
observation per event however many things are true of it at once.

Unlike `agent-river-observers' a signal reaches the agent, which is why it
cannot simply be retired on its first error -- a retired signal is one the
agent silently never hears again. Each is guarded and a failure is reported
instead, leaving the next call to try again.

What belongs here is anything observed that the fold cannot derive from its
own stream. Anything it *can* derive belongs in the fold, where it is
replayable.")

(defun agent-river--fail-streak-signal (state)
  "Return the observation STATE has earned for its failure streak, or nil.

:text is kept to a single line with no control characters: the hook reads
it back through `emacsclient', whose printed representation of a plain
string is then parsed as JSON, and an embedded newline would break that.

:id names *what* is being reported rather than what was said about it, and
an id already in `signals' is not reported again.  The throttle alone
keys on the failure streak, a number that does not move when the agent
merely acts, so one run of failures would be re-delivered on every tool
call after it: the throttle decides which streaks are worth a word, the id
decides that each of them gets one."
  (let* ((streak (agent-river-state-fail-streak state))
         ;; Which run, and how deep into it: the run number distinguishes
         ;; separate streaks, the streak earns each of 3, 6, 9 its own word
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

(defun agent-river--signal (state)
  "Return the first observation any of `agent-river-signal-functions' offers."
  (seq-some
   (lambda (fn)
     (condition-case err
         (funcall fn state)
       (error
        (message "agent-river: signal %s failed -- %s" fn (error-message-string err))
        nil)))
   agent-river-signal-functions))


;;; Reading the hook payload
;;
;; The payload arrives as a file and is parsed here rather than assembled
;; as Elisp text by a shell script, so a tool argument is never read as
;; code and the derivation stays under test.

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

(defun agent-river--sentence-stops (text)
  "Return the offsets in TEXT just past every sentence that ends inside it.

A stop is a full stop, question or exclamation mark followed by a space or
by the end.  An abbreviation (\"e.g. \") makes a false one, and that is the
whole of what it costs: a cut in a slightly odd place."
  (let ((stops nil) (start 0))
    (while (string-match "[.!?][\"')]*\\(?: \\|\\'\\)" text start)
      (push (match-end 0) stops)
      (setq start (1+ (match-beginning 0))))
    (nreverse stops)))

(defun agent-river--clip-words (text width)
  "Return at most WIDTH characters of TEXT, ending at a word boundary.
Falls back to the hard cut where TEXT has no space to back off to, which
is what a path, a URL or a base64 blob is."
  (if (<= (length text) width)
      text
    (let ((cut (substring text 0 width)))
      (string-trim-right
       ;; Only where the cut landed inside a word -- backing off from one
       ;; on a boundary would throw away a whole word the budget paid for.
       (if (eq (aref text width) ?\s)
           cut
         (let ((space (string-match " [^ ]*\\'" cut)))
           (if space (substring cut 0 space) cut)))))))

(defun agent-river--clip-words-left (text width)
  "Return the last WIDTH characters of TEXT, beginning at a word boundary.
The mirror of `agent-river--clip-words\=', and it backs off by the same
rule: only where the cut fell inside a word, since one that fell on a
boundary already begins at a whole one."
  (if (<= (length text) width)
      text
    (let ((cut (substring text (- (length text) width))))
      (string-trim-left
       (if (eq (aref text (- (length text) width 1)) ?\s)
           cut
         (let ((space (string-match " " cut)))
           (if space (substring cut space) cut)))))))

(defun agent-river--excerpt-tail (text width)
  "Return how TEXT closes, in at most WIDTH characters, or nil.

The closing *line* first, and its last sentence where the line is too
long.  Lines rather than sentences because of how these messages are
written: a summary, a list of what was done, and then the ask or the
verdict on a line of its own.  Squished into one line the bullets and the
ask become a single sentence, so a last-sentence rule answers with the
whole tail of the message."
  (let* ((lines (seq-remove #'string-empty-p
                            (mapcar #'string-trim
                                    (split-string (or text "") "\n"))))
         (line (car (last lines))))
    (when line
      (let* ((one (agent-river--squish line))
             (opens (seq-filter (lambda (at) (< at (length one)))
                                (agent-river--sentence-stops one)))
             (sentence (when opens
                         (string-trim (substring one (car (last opens))))))
             ;; What to cut into where nothing whole fits.  A closing that
             ;; is the whole message isn't a closing -- a run-on with no end
             ;; distinguishable from its body -- so the head alone is the
             ;; honest answer there.
             (closing (or sentence (when (cdr lines) one)))
             (whole (seq-find (lambda (candidate)
                                (and candidate
                                     (<= (length candidate) width)
                                     ;; A closing `---' or a stray fence says
                                     ;; nothing and would spend the room the
                                     ;; head wants.
                                     (string-match-p "[[:alpha:]]" candidate)))
                              (list one sentence))))
        (or whole
            ;; Nothing whole fits.  Cut into the closing from the left
            ;; rather than give it up, since most answers end in one long
            ;; paragraph.  The gap is marked either way, so a tail starting
            ;; mid-clause can't be read as a quotation of the opening.
            (when (and closing (string-match-p "[[:alpha:]]" closing))
              (let ((cut (agent-river--clip-words-left closing width)))
                (and (string-match-p "[[:alpha:]]" cut) cut))))))))

(defun agent-river--excerpt-head (text width)
  "Return how TEXT opens, in at most WIDTH characters.
At a sentence boundary where one falls late enough to be worth taking --
a boundary in the first few words would spend the budget on an opening
like \"Done.\" and drop the whole of what followed -- and at a word
boundary otherwise."
  (let* ((stops (seq-filter (lambda (at) (<= at width))
                            (agent-river--sentence-stops text)))
         (stop (car (last stops))))
    (if (and stop (>= stop (/ width 2)))
        (string-trim (substring text 0 stop))
      (agent-river--clip-words text width))))

(defun agent-river--excerpt (text width)
  "Return TEXT as one line of about WIDTH characters, cut where it means something.

For the agent\\='s own prose, which is the one text here whose length and
shape it chooses.  Both ends are kept and the middle is the gap: an answer
opens by restating the question and closes on what it concluded or what it
wants from you, while the middle is a prose account of the tool calls,
which this state has already measured in steps, files and failures.

The gap is marked, because the result is then a quotation with a hole in
it rather than something the agent said, and the two must not look alike.
The closing is kept only while it is worth the room -- no more than half
the width, and never where the head would be left too short to say
anything -- since two fragments are worse than one sentence."
  (let ((one (agent-river--squish
              (replace-regexp-in-string "[[:cntrl:]]+" " " (or text "")))))
    (if (<= (length one) width)
        one
      (let* ((tail (agent-river--excerpt-tail text (/ width 2)))
             ;; Three for the ellipsis and the spaces that set it off.
             (budget (if tail (- width (length tail) 3) width))
             ;; Below this the head is a phrase rather than a statement, and
             ;; a pair of phrases says less than one clipped sentence.
             (tail (and tail (>= budget 24) tail))
             (head (agent-river--excerpt-head one (if tail budget width))))
        ;; The two ends meet in the middle of a short message: the head
        ;; already reaches into the closing, and a quotation that says a
        ;; thing twice with an ellipsis between the halves is worse than one
        ;; that simply stops.
        (if (and tail (<= (+ (length head) (length tail)) (length one)))
            (concat head " … " tail)
          (concat head "…"))))))

(defun agent-river--log-text (text)
  "Return TEXT as something one log line can hold.

The HUD is line-based: a newline does not make two log lines, it makes one
line and a remainder carrying none of the properties `n\=' and `>\=' read,
and `agent-river-max-entries\=' then trims by counting lines that are no
longer one entry each.

For producer text above all -- a ticket title or a note body arrives at
whatever length and shape its producer sent.  Control characters go first
and the whitespace collapse follows, so an escape sequence cannot survive
as a gap."
  (agent-river--clip
   (agent-river--squish (replace-regexp-in-string "[[:cntrl:]]+" " " (or text "")))
   agent-river-detail-width))

(defun agent-river--rel (path cwd)
  "Show PATH relative to CWD when under it, else as a bare name.
Never as a long absolute path: two agents touching one file from a
worktree and from the main checkout have to produce the same string, or
the view renders a collision as two unrelated files."
  (let ((dir (and cwd (not (string-empty-p cwd)) (file-name-as-directory cwd))))
    (if (and dir (string-prefix-p dir path))
        ;; Measured off the slash-terminated form, not off CWD plus one: a
        ;; cwd already ending in a slash would otherwise cut one character
        ;; too many and eat the first letter of the top component.
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
`path'.  An agent-shell session adds `filePath' and `filepath', the ACP
`rawInput' spellings, and `fileName' is what a Copilot-style diff names.
The artifact tables are keyed on this, so a name we did not know would not
fail -- it would quietly stop counting files."
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

Guarded with `consp' like `agent-river--failed-p': a tool response is not
always an alist.  An MCP tool answers with an *array* of content parts,
which the hook parses as a vector, and `alist-get' on one throws -- losing
the whole event."
  (let ((response (alist-get 'tool_response payload)))
    (and (consp response)
         (eq t (alist-get 'interrupted response)))))

(defun agent-river--unfinished-p (payload)
  "Return non-nil when PAYLOAD reports a turn that ended some other way.

`end_turn' is the only stop reason that says the agent finished saying
what it had to say; the rest -- `cancelled', `refusal', `max_tokens',
`max_turn_requests' -- mean the words on the line are as far as it got.
A missing reason answers nil: the hosts that report none would otherwise
have every turn marked."
  (let ((reason (alist-get 'stop_reason payload)))
    (and reason (not (equal reason "end_turn")) t)))

(defun agent-river--tool-label (tool)
  "Return what a log line calls TOOL.

Presentation only: the name itself is folded verbatim as `:tool', which
is what the tool tallies, `agent-river--bucket' and
`agent-river--writing-p' all match on.  Renaming it here and there alike
would mean a host's own word had stopped appearing anywhere, and the
next reader of the state would be matching against a glyph."
  (or (cdr (assoc tool agent-river-tool-glyphs)) tool))

(defun agent-river--detail (kind payload)
  "Return the line KIND should show for PAYLOAD."
  (let* ((tool (agent-river--tool-label
                (or (alist-get 'tool_name payload) "tool")))
         (input (alist-get 'tool_input payload))
         (ms (alist-get 'duration_ms payload))
         (took (if ms (concat "  " (agent-river--dur ms)) "")))
    (cond
     ((equal kind "prompt")
      (agent-river--clip
       (agent-river--squish (or (alist-get 'prompt payload) "new task")) 100))
     ((equal kind "idle") "waiting for you")
     ;; Through `agent-river--excerpt' rather than the clip beside it: this
     ;; is the agent's own prose, and a newline in it would make one entry
     ;; and a remainder carrying none of the properties the motions read.
     ;;
     ;; Marked where the turn did not finish, the way a `think' marks an
     ;; interrupted call: `turn-complete' fires whatever the stop reason, so
     ;; a cancelled or cut-off turn would otherwise read as an ordinary
     ;; answer.  Only a reason given and not `end_turn' marks; no reason at
     ;; all means "do not know" rather than "interrupted".
     ((equal kind "say")
      (concat (agent-river--excerpt (alist-get 'message payload)
                                    agent-river-detail-width)
              (if (agent-river--unfinished-p payload) " ✗" "")))
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
          ;; say where its keys are anchored -- the label is only its last
          ;; component and two checkouts of one project are labelled alike.
          :cwd cwd
          :agent (alist-get 'agent_id payload)
          :agent-type (alist-get 'agent_type payload)
          :tool (alist-get 'tool_name payload)
          :file (and file (agent-river--rel file cwd))
          ;; The absolute name, for views that have to reach the file on
          ;; disk.  Carried beside `:file' and never folded *into a key*:
          ;; the artifact tables key on the normalised form, so an absolute
          ;; path there would make a worktree and main-checkout file count
          ;; as two again -- see `agent-river--anchor'.
          :path file
          ;; Which tool call this is, so the line it opened can be completed
          ;; in place.  Paired with the session because call-id uniqueness
          ;; differs by host: Claude Code's `tool_use_id' is global, ACP's
          ;; only within its session.
          :call (let ((id (alist-get 'tool_use_id payload)))
                  (when (and id (not (string-empty-p (format "%s" id))))
                    (format "%s\0%s"
                            (or (alist-get 'session_id payload) "unknown") id)))
          :outcome (agent-river--outcome kind payload)
          :ms (alist-get 'duration_ms payload)
          ;; Why the turn ended, as the host said it.  On the event, not the
          ;; fold, like `:path': nothing here reads it, and a consumer that
          ;; wants to tell a finished answer from an interrupted one gets
          ;; the raw event.
          :stop-reason (alist-get 'stop_reason payload)
          :text (cond
                 ((equal kind "prompt")
                  (agent-river--clip
                   (agent-river--squish (or (alist-get 'prompt payload) "")) 200))
                 ;; Whole, where the prompt is clipped: a `◇' line shows only
                 ;; a thought's first sentence, but what the agent said is
                 ;; the answer, so the fold clips its own excerpt from this
                 ;; rather than being handed one already cut.
                 ((equal kind "say") (or (alist-get 'message payload) "")))
          :detail (agent-river--detail kind payload))))



;;; Live reasoning, from the ACP stream
;;
;; The reasoning rides the ACP stream that drives the shell:
;; `agent_thought_chunk' notifications carry it, read off the client
;; reachable from the buffer this file already locates by session id.
;; The one thing here agent-shell is required for rather than merely
;; better with -- the hooks carry no thinking text.
;;
;; A thought arrives in chunks rather than whole.  Only the first sentence
;; is shown, so a run is emitted the moment one is complete and the rest
;; is dropped; a run that ends without a sentence boundary is flushed by
;; the next non-thought notification.

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
a session that has ended.  What must not survive is the *view*: no event
ever addresses the old id again, so without this the line sits there
inviting a RET that can only fail.  The state is left to
`agent-river--active-p', which already calls a hosted session whose buffer
is gone by what it is.

Deferred by a tick, because `kill-buffer-hook' runs while the buffer is
still live: redrawn inline, `agent-river--shell-buffer' would still find
the dying buffer and draw the session straight back in.

Only the block.  A name the map drew stays on the lines that session
reached whatever becomes of the session, because it did reach them, so
there is nothing there a kill can change."
  (remhash buffer agent-river--teardown-hooked)
  (run-at-time 0 nil #'agent-river--redraw-block))

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
;; other agents agent-shell hosts do not, but agent-shell already reads
;; their ACP stream and publishes it through `agent-shell-subscribe-to'.
;; Three of its events carry what the fold wants: `input-submitted' the
;; prompt, `tool-call-update' a step with its status, `turn-complete' the
;; end of the turn.
;;
;; This path translates them into the payload shape the hooks report and
;; hands that to `agent-river--event' -- the same adapter, not a second
;; one -- so nothing downstream ever learns a second source exists.
;;
;; Two things it cannot do: talk back (no `additionalContext' on a stream
;; we only listen to), and represent a subagent (ACP has no such notion, so
;; a delegated task folds as one step of its parent).

(defvar agent-river--source (make-hash-table :test 'equal)
  "Session id -> the way in that owns it, `hooks' or `shell'.")

(defun agent-river--claim (session source)
  "Return non-nil when SOURCE may fold SESSION's steps, claiming it if free.

Both ways in describe the same session -- the hooks report what the CLI
did, agent-shell reports what its ACP stream said -- so folding both
would count every step twice.  That is not merely untidy: a doubled
failure streak states a fact that is false, to the agent itself.

The hooks win, because only they can carry an observation back.  A
watched session that turns out to have hooks is given up whole rather
than interleaved: what the stream folded is dropped, and the hooks build
it again from their first event.

What this decides is who folds the events *both* sources produce, which
is steps and the turn around them.  It is not a claim on the session as
such: a kind only one source can report has nothing to double, and so is
read wherever it can be got.  `agent-river--listen' reads what the agent
said, which no hook carries, and `agent-river--attend' the permission
requests, which none of them reports either -- both ungated, and both
serving sessions the hooks own."
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

(defvar-local agent-river--attending nil
  "This buffer's subscription token for permission requests, while it has one.
A second token rather than more work on the first: the two are turned on
by different gestures and for different reasons -- folding a session the
hooks cannot reach, and seeing what any session is waiting for -- and a
subscription shared between them would end when either did.")

(defvar-local agent-river--listening nil
  "This buffer's subscription token for what the session says, while it has one.
A third token, by the same rule as the second: the gesture that turns it
on is its own, and what it hears is wanted whether or not this session is
folded from the stream -- see `agent-river-listen-mode'.")

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


;;; What the agent said -- the other half of a turn
;;
;; What a session did and what it thought are folded from the events it
;; makes; what it *said* comes in here, as one `say' event carrying the
;; end of a turn.
;;
;; No hook carries the message text, so this follows the stream, like the
;; thought path: a session with no agent-shell buffer gets no `say' lines
;; at all.
;;
;; Not gated on `agent-river--claim': that gate is about who counts a
;; session's steps once, and no hook reports a message, so there is
;; nothing here to double.  The rule holds per *kind*, not per session, and
;; `agent-river--attending' has the same standing.
;;
;; Two chunks of mechanism.  The text arrives as `agent-message-chunk',
;; accumulated here since the shell does not.  The end of it is
;; `turn-complete', which exists on agent-shell's event stream and not on
;; the ACP notification stream the thought handler uses -- so this is a
;; subscription of its own, taking `:event' nil and filtering in the
;; handler since two events are wanted.
;;
;; Installed when the buffer appears, not on the session's first folded
;; event: a session that has folded nothing has no handler yet, and its
;; first turn is exactly the one worth hearing.
;;
;; One thing this cannot order: when `agent-river-watch-mode' also folds a
;; session, `turn-complete' reaches two subscriptions and which runs first
;; depends on which mode was turned on first, so the log may show the `“'
;; line above the `■' one.  Left alone -- for a hooked session `idle' comes
;; from an async hook in another process with no ordering available at
;; all, and the timestamps are a second apart at most, both true.

(defvar agent-river--say-runs (make-hash-table :test 'equal)
  "Session id -> the chunks of the message in flight, newest first.

Deliberately not a slot on `agent-river-state', for the reason
`agent-river--thought-runs' is not one: this is decoding state for one
ingestion path, nothing folds it and no query reads it, and putting it in
the struct would make every reload demand `agent-river-reset'.")

(defun agent-river--say-arrived (session chunk)
  "Add CHUNK to what SESSION is saying in the turn now running.

A chunk is nil for a block that is not text -- an image -- and there is
nothing to accumulate from one of those."
  (when (and (stringp chunk) (not (string-empty-p chunk)))
    (puthash session (cons chunk (gethash session agent-river--say-runs))
             agent-river--say-runs)))

(defun agent-river--say-ended (session reason)
  "Fold what SESSION said this turn, which ended for REASON.

Returns the text, or nil for a turn that said nothing -- which is an
ordinary turn rather than an edge case: an agent that answers with tool
calls alone has said nothing, and a `say' event carrying an empty string
would put a line in the log for the absence of one.

The whole of it goes on the event.  A dialogue act cannot be read off a
first sentence, which is where this parts company with the `◇' lines: what
they show is an aside, and clipping an aside loses an aside.

No cwd, deliberately, which puts this with the events made inside Emacs
rather than with the steps: the fold refreshes the anchor from every event
that carries one, and a `say' reached no file.  Carrying the shell
buffer\='s `default-directory' would have every turn end re-anchor a
session the hooks anchored, and the two spellings need not agree since
`expand-file-name' does not resolve a symlink and a host\='s reported cwd
may.  What that costs is a session folded from this path *alone* -- no
hooks, `agent-river-watch-mode' off -- which then has no cwd and so no
place in the block; it has no artifact keys either, which is the only
thing an anchor is for."
  (let ((chunks (gethash session agent-river--say-runs)))
    (remhash session agent-river--say-runs)
    (let ((text (apply #'concat (nreverse chunks))))
      (unless (string-empty-p (string-trim text))
        (agent-river-observe
         (agent-river--event "say" `((session_id . ,session)
                                     (message . ,text)
                                     (stop_reason . ,reason))))
        text))))

(defun agent-river--listen (event)
  "Fold what the current buffer's session says, from agent-shell's EVENT.

Like `agent-river--attend' and unlike `agent-river--shell-observe', not
gated on `agent-river--claim': see the section comment above -- the gate
is about who counts a session's steps, and nothing here counts one."
  (let ((session (agent-river--shell-session))
        (data (alist-get :data event)))
    (when session
      (pcase (alist-get :event event)
        ('agent-message-chunk
         (agent-river--say-arrived session (alist-get :text-chunk data)))
        ('turn-complete
         (agent-river--say-ended session (alist-get :stop-reason data)))
        ;; Three ways a run ends without being said, all dropped: chunks
        ;; left in the table would otherwise be flushed by a later turn,
        ;; glued onto the front of its text.
        ;;
        ;; `clean-up' is the buffer going mid-sentence.  `error' is the
        ;; `session/prompt' failing, which never emits `turn-complete'.
        ;; `session-restored' replays yesterday's chunks through the same
        ;; notification path live ones use, with no `turn-complete' behind
        ;; them -- what a session said last week is not something it said
        ;; today.
        ;;
        ;; An *interrupted* turn is not among them: cancelling resolves the
        ;; pending prompt with a stop reason, so it arrives as
        ;; `turn-complete' and is said, marked.
        ((or 'clean-up 'error 'session-restored)
         (remhash session agent-river--say-runs))))))

;;;###autoload
(defun agent-river-listen-shell (&optional buffer)
  "Fold what BUFFER's agent-shell session says at the end of each turn.
Idempotent, and a no-op outside an agent-shell buffer."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (when (and (agent-river--shell-buffer-p)
               (null agent-river--listening)
               (fboundp 'agent-shell-subscribe-to))
      (let ((shell (current-buffer)))
        (setq agent-river--listening
              (agent-shell-subscribe-to
               :shell-buffer shell
               :on-event
               (lambda (event)
                 ;; Never let the HUD break the shell it rides on -- but
                 ;; never go quiet either.
                 (condition-case err
                     (with-current-buffer shell
                       (agent-river--listen event))
                   (error
                    (ignore-errors
                      (agent-river-log
                       "fail" (format "message watch failed: %s"
                                      (error-message-string err)))))))))))))

(defun agent-river-unlisten-shell (&optional buffer)
  "Stop folding what BUFFER's agent-shell session says."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (when (and agent-river--listening (fboundp 'agent-shell-unsubscribe))
      (agent-shell-unsubscribe :subscription agent-river--listening)
      (setq agent-river--listening nil))))

;;;###autoload
(define-minor-mode agent-river-listen-mode
  "Fold what every agent-shell session says at the end of its turn.

Off by default and reversible by the gesture that turned it on, like the
other two: what it adds to the log is the agent's own prose, at the
length the agent chose, and a HUD that starts quoting paragraphs at
somebody who wanted a tool log is not something to do unasked.

Unlike `agent-river-watch-mode' this is not an alternative to the hooks
and does not compete with them -- a session they own still gets its
messages from here, because they carry none.  Turning it off drops the
turns in flight with the subscriptions: a message half-accumulated is not
something anyone can be told later."
  :global t
  :group 'agent-river
  (if agent-river-listen-mode
      (progn
        (add-hook 'agent-shell-mode-hook #'agent-river-listen-shell)
        (mapc #'agent-river-listen-shell (buffer-list)))
    (remove-hook 'agent-shell-mode-hook #'agent-river-listen-shell)
    (mapc #'agent-river-unlisten-shell (buffer-list))
    (clrhash agent-river--say-runs)))


;;; Approvals -- the one place this speaks, and whose words it uses
;;
;; agent-shell asks before a tool call the agent may not make on its own,
;; and renders the question in the session buffer.  With several sessions,
;; which is waiting and for what is exactly the question the HUD exists to
;; answer -- and the phase alone cannot say it, since a session holding a
;; door open reads as `waiting', which is only the end of a turn.
;;
;; The offer is read through `agent-shell-permission-responder-function', a
;; documented variable carrying the tool call, the options and a function
;; that answers.  It is a *slot* rather than a hook: returning non-nil means
;; "handled, skip the UI".  So this chains to whatever was there -- it
;; never claims the request, only watches one go past.
;;
;; A pending approval is a *current-state* fact: true now, false the
;; moment it is answered.  So it is not folded and there is no slot for
;; it -- it lives in a side table, queried where read, the way
;; `buffer-modified-p' is asked rather than noted.  The question being put
;; is point-in-time, though, and that gets a log line.
;;
;; Answering is this package speaking on a stream it otherwise only
;; listens to.  The rule against that is about agent-river's own
;; observations reaching the agent's context; a permission answer is the
;; user's own keystroke, relayed.  It still stays behind its own gesture: a
;; global mode, off by default, since installing yourself in another
;; package's decision path is not something a HUD does unasked.

(defvar agent-river--offers (make-hash-table :test 'equal)
  "Permission request id -> the choice a session is waiting to be given.

Each value is a plist: `:id' the request, `:session' whose it is,
`:tool-call-id' what it is about, `:title', `:kind', `:options' as
`agent-shell' enriched them, `:respond' the function that answers, and
`:at' when it arrived.

Two halves fill it, because neither source has both: the responder
function is handed the options and is not told whose session they belong
to, and the `permission-request' event is dispatched in the session's own
buffer but carries no options.  They share the request id, and the
responder runs first.

Deliberately not a struct slot and deliberately not folded.  A question
that is open right now stops being true the moment it is answered --
including by a button pressed in the shell buffer, which nothing here
would hear -- so it is kept where a stale entry costs a redraw rather
than a false state.")

(defvar agent-river--responder-before 'unset
  "What `agent-shell-permission-responder-function' held before this mode.
`unset' while the mode has never been on, so turning it off cannot install
a nil over somebody's function by mistake.")

(defun agent-river--offer (session)
  "Return the permission request SESSION is waiting on, or nil.
The newest, in the vanishing case where an agent has two open at once:
the panel has room for one, and the one just asked is the one on screen
in the session buffer."
  (let (found)
    (maphash (lambda (_id offer)
               (when (and (equal (plist-get offer :session) session)
                          (or (null found)
                              (time-less-p (plist-get found :at)
                                           (plist-get offer :at))))
                 (setq found offer)))
             agent-river--offers)
    found))

(defun agent-river--offer-live-p (offer)
  "Return non-nil while OFFER is still a question waiting for an answer.

Asked of agent-shell rather than remembered here.  It clears
`:permission-request-id' from the tool call when it answers and says so in
as many words -- \"so consumers can distinguish between a pending
permission request and one already answered\" -- whereas this package's
own table is a second account of that, and the one that cannot see a
button pressed in the session buffer."
  (when-let* ((session (plist-get offer :session))
              (call-id (plist-get offer :tool-call-id))
              (buffer (agent-river--shell-buffer session))
              (state (buffer-local-value 'agent-shell--state buffer))
              (call (alist-get call-id (alist-get :tool-calls state)
                               nil nil #'equal)))
    (and (alist-get :permission-request-id call) t)))

(defun agent-river--offer-text (offer)
  "Return OFFER as one line: what is being asked, and what may be answered.
The options are named where they are known and left out where they are
not -- the responder may never have run, and a question that can only be
answered in the session buffer is still worth saying out loud."
  (let ((options (plist-get offer :options)))
    (concat "asks: " (or (plist-get offer :title) "?")
            (if options
                (format " (%s)"
                        (mapconcat (lambda (option) (alist-get :option option))
                                   options " · "))
              ""))))

(defun agent-river--responder (permission)
  "Note what PERMISSION offers, and leave the answering to whoever asked.

Returns whatever the function this replaced returns, which is nil when
there was none: non-nil here means agent-shell skips its own dialog, and
watching a question go past must never be what swallows it.

Its own guard, for the same reason an observer has one: this runs inside
agent-shell's request handler, and a HUD that cannot note a permission
request must not be able to stop one being asked."
  (condition-case err
      (let* ((call (alist-get :tool-call permission))
             (id (alist-get :permission-request-id call)))
        (when id
          (puthash id (list :id id
                            :title (alist-get :title call)
                            :kind (alist-get :kind call)
                            ;; The arguments the agent proposes to run with.
                            ;; The title is agent-shell's summary, all the
                            ;; panel has room for; deciding needs the words
                            ;; themselves, which only this side carries --
                            ;; `permission-request' carries the session and
                            ;; no input.
                            :raw-input (alist-get :raw-input call)
                            :options (alist-get :options permission)
                            :respond (alist-get :respond permission)
                            :at (current-time))
                   agent-river--offers)))
    (error (message "agent-river: permission not noted (%s)"
                    (error-message-string err))))
  (and (functionp agent-river--responder-before)
       (funcall agent-river--responder-before permission)))

(defun agent-river--forget-offers (session)
  "Drop every permission request recorded for SESSION."
  (let (stale)
    (maphash (lambda (id offer)
               (when (equal (plist-get offer :session) session) (push id stale)))
             agent-river--offers)
    (dolist (id stale) (remhash id agent-river--offers))
    stale))

(defun agent-river--attend (event)
  "Track the permission requests of the current buffer's session from EVENT.

Separate from `agent-river--shell-observe' and deliberately not gated on
`agent-river--claim': that gate is about who *folds* a session, so that
one step is not counted twice, and a session whose hooks own it would
otherwise have its open questions go unseen -- which is the case with the
most sessions in it."
  (let ((data (alist-get :data event))
        (session (agent-river--shell-session)))
    (pcase (alist-get :event event)
      ('permission-request
       (when-let* ((id (alist-get :request-id data))
                   (session session))
         (let ((offer (or (gethash id agent-river--offers)
                          (list :id id :at (current-time)
                                :title (alist-get :title
                                                  (alist-get :tool-call data))))))
           (setq offer (plist-put offer :session session))
           (setq offer (plist-put offer :tool-call-id
                                  (alist-get :tool-call-id data)))
           (puthash id offer agent-river--offers)
           ;; That the question was put is point-in-time and belongs in the
           ;; log; that it is still open is not, and belongs in the panel,
           ;; which reads the table above.
           (agent-river-log "ask" (agent-river--offer-text offer)
                            (agent-river--shell-label session))
           ;; The block carries the open question ahead of everything
           ;; measured on the line, so it has to be redrawn for one.
           (agent-river--redraw-block)
           ;; Drawn rather than marked dirty, unlike the map: that observer
           ;; fires on every tool call, this fires when somebody is asked a
           ;; question, and showing it a second or two late is a queue
           ;; somebody is sitting in front of, waiting.
           (agent-river--approval-refresh))))
      ('permission-response
       (when-let* ((id (alist-get :request-id data)))
         (remhash id agent-river--offers)
         (agent-river--redraw-block)
         (agent-river--approval-refresh)))
      ('clean-up
       (when (and session (agent-river--forget-offers session))
         (agent-river--redraw-block)
         (agent-river--approval-refresh))))))

;;;###autoload
(defun agent-river-attend-shell (&optional buffer)
  "Watch BUFFER's agent-shell session for permission requests.
Idempotent, and a no-op outside an agent-shell buffer."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (when (and (agent-river--shell-buffer-p)
               (null agent-river--attending)
               (fboundp 'agent-shell-subscribe-to))
      (let ((shell (current-buffer)))
        (setq agent-river--attending
              (agent-shell-subscribe-to
               :shell-buffer shell
               :on-event
               (lambda (event)
                 ;; Never let the HUD break the shell it rides on -- but
                 ;; never go quiet either.
                 (condition-case err
                     (with-current-buffer shell
                       (agent-river--attend event))
                   (error
                    (ignore-errors
                      (agent-river-log
                       "fail" (format "permission watch failed: %s"
                                      (error-message-string err)))))))))))))

(defun agent-river-unattend-shell (&optional buffer)
  "Stop watching BUFFER's agent-shell session for permission requests."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (when (and agent-river--attending (fboundp 'agent-shell-unsubscribe))
      (agent-shell-unsubscribe :subscription agent-river--attending)
      (setq agent-river--attending nil))))

;;;###autoload
(define-minor-mode agent-river-approvals-mode
  "Show what each session is waiting to be allowed, and let you allow it.

Off by default, and the gesture that turns it on is what turns it off.
Two things happen here that nothing else in this package does: it
installs itself in agent-shell's permission path, and
\\[agent-river-answer] answers a question on the session's behalf --
writing to a session rather than reading one.

The slot it takes is restored on the way out, and only when it is still
ours: a responder installed while this was on belongs to whoever
installed it, and putting the old value back over it would be this mode
undoing somebody else's setting as it left."
  :global t
  :group 'agent-river
  (if agent-river-approvals-mode
      (progn
        (unless (eq agent-shell-permission-responder-function
                    #'agent-river--responder)
          (setq agent-river--responder-before
                agent-shell-permission-responder-function))
        (setq agent-shell-permission-responder-function #'agent-river--responder)
        (add-hook 'agent-shell-mode-hook #'agent-river-attend-shell)
        (mapc #'agent-river-attend-shell (buffer-list)))
    (when (eq agent-shell-permission-responder-function #'agent-river--responder)
      (setq agent-shell-permission-responder-function
            (and (not (eq agent-river--responder-before 'unset))
                 agent-river--responder-before)))
    (remove-hook 'agent-shell-mode-hook #'agent-river-attend-shell)
    (mapc #'agent-river-unattend-shell (buffer-list))
    (clrhash agent-river--offers)
    (agent-river--redraw-block)))

;;;###autoload
(defun agent-river-answer ()
  "Answer the permission request of the session on this line.

Deliberately a command with a prompt rather than a key per option.  The
HUD is a view; a single keystroke here that grants an agent
`allow_always' is the wrong place for a typo, and the options are the
agent's own words, which no fixed key could keep meaning."
  (interactive)
  (let* ((session (get-text-property (point) 'agent-river-session))
         (offer (and session (agent-river--offer session))))
    (cond
     ((null session) (user-error "No session on this line"))
     ;; Said rather than left to read as \"nothing is pending\": with the
     ;; mode off nothing is ever pending here, and that is a different fact.
     ((not agent-river-approvals-mode)
      (user-error "Permission requests are not watched; M-x agent-river-approvals-mode"))
     ((null offer) (user-error "This session is not waiting on a permission"))
     ((not (plist-get offer :options))
      (user-error "The options for this request were never seen; answer it in the session"))
     (t
      (let* ((options (plist-get offer :options))
             (labels (mapcar (lambda (option) (alist-get :option option)) options))
             (pick (completing-read (format "%s: " (plist-get offer :title))
                                    labels nil t))
             (chosen (seq-find (lambda (option)
                                 (equal (alist-get :option option) pick))
                               options)))
        (when chosen (agent-river--respond offer chosen)))))))

(defun agent-river--respond (offer option)
  "Relay OPTION to the session OFFER names, as the answer to its question.

The one place an answer is actually sent, so the prompt in the HUD and
the rows of the approval queue cannot come to different conclusions about
when a question may still be answered.  Which is the whole of what the
guards here are: this table is the second account of a state agent-shell
owns, and the one that can be behind -- a button pressed in the session
buffer never reaches it."
  (cond
   ((not (agent-river--offer-live-p offer))
    ;; Answered in the session buffer while this was on screen.  Dropped
    ;; rather than reported as still open: the table is behind, not the
    ;; session.
    (remhash (plist-get offer :id) agent-river--offers)
    (agent-river--redraw-block)
    (agent-river--approval-refresh)
    (user-error "That request has already been answered"))
   ((not (functionp (plist-get offer :respond)))
    (user-error "The options for this request were never seen; answer it in the session"))
   (t
    (funcall (plist-get offer :respond) (alist-get :option-id option))
    ;; The response event clears the table and redraws; this is only what
    ;; the person pressing the key is owed in the meantime.
    (message "agent-river: %s" (alist-get :option option)))))


;;; The approval queue -- the questions, on whatever screen is to hand
;;
;; The panel says which session is holding a door open; this is the buffer
;; the door is opened from, built for a phone in one hand, over
;; emacsclient in a terminal, in portrait.  Nothing about the HUD survives
;; that trip.
;;
;; So the shape is decided by the screen rather than by the state:
;;
;; - One question is a block, not a line: who is asking, what, the agent's
;;   own words, one line of context, then the answers.
;; - Every answer is a line of its own and the line is the target -- RET or
;;   a tap answers, which `agent-river-answer' deliberately does not: a
;;   prompt at a desk costs one keystroke, here it costs the screen.
;;   Friction stays only where it earns its place: the two `_always' kinds
;;   ask first, the rest do not.
;; - Wrapped, never measured: the width is the window's, so a rotation is
;;   just a resize.
;; - A row is propertised through its newline, so the whole row answers a
;;   tap, not just its glyphs.
;;
;; Not Markdown, for the reason the HUD is not: the title and raw input are
;; the agent's words and a tool's arguments, and rendering them as
;; structure hands that text the power to restructure the view.
;;
;; A view of `agent-river--offers', not folded and not an observer: drawn
;; when a question arrives or is answered, and on a slow timer of its own
;; for what moves with no event -- how long a question has waited, and
;; what the session has done since.

(defcustom agent-river-approval-queue-buffer-name "*agent-river-approvals*"
  "Name of the buffer `agent-river-approval-queue' draws into."
  :type 'string)

(defcustom agent-river-approval-queue-interval 2
  "Seconds between redraws of the approval queue.
Only the waiting times and the session context change between events, and
both are read rather than acted on: a second would be an animation, thirty
would leave `waiting 1m' on screen for a question asked half an hour ago."
  :type 'number)

(defcustom agent-river-approval-body-lines 4
  "How many lines of a request's own arguments an unopened block shows.
TAB shows the rest.  Four is about what fits above the options on a phone,
and the options staying on screen is the one thing this view cannot give
up -- a block whose answers are below the fold is a block nobody can
answer without scrolling first."
  :type 'integer)

(defcustom agent-river-approval-input-keys
  '(command file_path path absolute_path filePath url pattern query prompt)
  "Keys of a tool's raw input worth showing as the request's own words.

The first one present is what the block shows, because one of them is
almost always *the* argument -- the command for a shell call, the path for
an edit.  A tool none of them fit is rendered key by key instead, which is
verbose and never wrong; guessing which of an unknown tool's arguments
matters is how a view ends up hiding the dangerous half of a request."
  :type '(repeat symbol))

(defconst agent-river--approval-line-max 300
  "Longest a single line of a request's arguments is drawn.
A guard rather than a setting: an argument is occasionally a whole file,
and one line of that wrapped across a phone screen pushes the options off
the bottom -- which is the one failure this view cannot afford.")

(defvar agent-river--approval-timer nil
  "Repeating timer redrawing the approval queue, or nil while none runs.")

(defvar agent-river--approval-owns-mode nil
  "Non-nil when the queue is what turned `agent-river-approvals-mode' on.

Opening this buffer is a clear enough gesture to install the watcher --
there is nothing to queue otherwise, since the options and the means to
answer are only ever seen by the responder.  Turning it off again on the
way out is the other half of that, and it is conditional for the same
reason `agent-river--responder-before' is: a mode switched on by hand
while this buffer happened to be open belongs to whoever switched it on.")

(defvar-local agent-river--approval-expanded nil
  "Request ids whose block is showing all of its arguments.

Buffer-local and kept here rather than in overlays: the buffer is erased
and rebuilt on every question and every tick, so a fold that lived in the
text would spring open again a second later.")

(defun agent-river--offer-answered-p (offer)
  "Return non-nil when agent-shell's own account says OFFER is answered.

Not the complement of `agent-river--offer-live-p', and the difference is
the whole reason both exist.  That one answers \"still open\" and says no
where nothing can be seen, which is the right way round for a command
about to speak on a session's behalf.  This one answers \"agent-shell says
it is over\" and says no in the same unseeable case, which is the right
way round for a listing: a question dropped because its buffer could not
be reached is silence exactly where this view exists to say something.

`assoc' rather than `alist-get', because agent-shell leaves an answered
call in the table with its request id removed -- and a call that is absent
and a call that is present and empty are indistinguishable through a
lookup that returns nil for both."
  (when-let* ((session (plist-get offer :session))
              (call-id (plist-get offer :tool-call-id))
              (buffer (agent-river--shell-buffer session))
              (state (buffer-local-value 'agent-shell--state buffer))
              (cell (assoc call-id (alist-get :tool-calls state))))
    (null (alist-get :permission-request-id (cdr cell)))))

(defun agent-river--offers-waiting ()
  "Return every permission request still waiting, the oldest first.

Oldest first because this is a queue and the HUD is not: the log is
newest-first, where the newest line is the news, and here the question
that has been held longest is the one holding a session up."
  (let (waiting)
    (maphash (lambda (_id offer)
               (unless (agent-river--offer-answered-p offer)
                 (push offer waiting)))
             agent-river--offers)
    (sort waiting (lambda (a b) (time-less-p (plist-get a :at)
                                             (plist-get b :at))))))

(defun agent-river--offer-label (offer)
  "Return the name to put on OFFER's heading.
agent-shell's, where it hosts the session; the folded label where the
registry has one; and the session id only as a last resort, which is the
case where the queue is showing a question about a session nothing else
here has heard of."
  (let ((session (plist-get offer :session)))
    (or (and session (agent-river--shell-label session))
        (when-let* ((state (and session (gethash session agent-river-registry))))
          (agent-river-state-label state))
        session
        "?")))

(defun agent-river--approval-clean (text)
  "Return TEXT with control characters replaced by spaces, capped in length.
The buffer is line-based, so a stray control character makes one broken
row rather than the two it looks like it should."
  (let ((line (replace-regexp-in-string "[[:cntrl:]]" " " (or text ""))))
    (truncate-string-to-width line agent-river--approval-line-max nil nil "…")))

(defun agent-river--approval-value (value)
  "Return raw-input VALUE as text, whatever shape the host gave it.
A vector of words is how Codex passes a command, a nested alist is how a
structured argument arrives, and neither may reach a string function
unguarded -- see `agent-river--arg' for the same problem one layer down."
  (cond
   ((stringp value) value)
   ((null value) "")
   ((vectorp value) (mapconcat #'agent-river--approval-value value " "))
   ((and (consp value) (consp (car value)))
    (mapconcat (lambda (cell)
                 (format "%s: %s" (car cell)
                         (agent-river--approval-value (cdr cell))))
               value "\n"))
   (t (format "%s" value))))

(defun agent-river--offer-body (offer)
  "Return OFFER's arguments as lines -- the agent's own words for what it wants.

The title is agent-shell's summary and is what the panel has room for;
this is the thing a decision is actually made on, and the reason the queue
is a block rather than a line."
  (let* ((input (plist-get offer :raw-input))
         (named (seq-some (lambda (key)
                            (let ((value (and (consp input) (alist-get key input))))
                              (and value (not (equal value ""))
                                   (agent-river--approval-value value))))
                          agent-river-approval-input-keys))
         (text (or named (and input (agent-river--approval-value input)))))
    (when (and text (not (string-empty-p text)))
      (seq-remove #'string-empty-p
                  (mapcar #'agent-river--approval-clean
                          (split-string text "\n"))))))

(defun agent-river--approval-context (state)
  "Return one line of what STATE has been doing, or nil when it says nothing.

The fold, on the block that is asking to interrupt it.  Which is the whole
argument for putting it here: `Run rm -rf build` reads differently under
an agent that has been editing quietly for twenty steps and under one that
has failed three times running, and in the session buffer that context is
several screens up."
  (when state
    (let* ((phase (agent-river--phase state))
           (streak (agent-river-state-fail-streak state))
           (steps (agent-river-state-steps state))
           (parts (delq nil
                        (list
                         (when phase
                           (propertize phase 'face
                                       (cond ((equal phase "blocked") 'agent-river-fail)
                                             ((equal phase "waiting") 'agent-river-idle)
                                             (t 'agent-river-act))))
                         (when (> steps 0)
                           (propertize (format "%d step%s" steps
                                               (if (= steps 1) "" "s"))
                                       'face 'agent-river-time))
                         (when (> streak 0)
                           (propertize (format "%d failing" streak)
                                       'face 'agent-river-fail))
                         ;; The most-touched name, and no count beside it:
                         ;; what the session is about to be allowed to act
                         ;; on is most of what an allow-or-deny turns on,
                         ;; and how often it has been reached is the least
                         ;; of it.
                         (when-let* ((hot (car (agent-river--artifact-list state))))
                           (propertize (car hot) 'face 'agent-river-time))))))
      (when parts (mapconcat #'identity parts " · ")))))

(defvar agent-river-approval-option-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-river-approval-queue-answer)
    (define-key map [mouse-1] #'agent-river-approval-queue-answer)
    map)
  "Keymap active on one answer of a block in the approval queue.")

(defun agent-river--approval-row (text id &optional kind extra)
  "Return TEXT as one row of the block for request ID, newline included.

The newline is inside the propertised string on purpose.  A tap lands past
the end of a short row about as often as on it, and a row whose properties
stop at its last character is a target that has to be hit rather than one
that can be reached for.

KIND marks the row for the motions as `agent-river-line' does in the HUD;
rows without one are read and not stopped on.  EXTRA is any further
properties, which is where a row becomes a button."
  (apply #'propertize (concat text "\n")
         (append (list 'agent-river-approval id)
                 (when kind (list 'agent-river-line kind))
                 extra)))

(defun agent-river--approval-block (offer)
  "Return OFFER drawn as a block of rows: who, what, on what, and the answers."
  (let* ((id (plist-get offer :id))
         (session (plist-get offer :session))
         (state (and session (gethash session agent-river-registry)))
         (open (and (member id agent-river--approval-expanded) t))
         (body (agent-river--offer-body offer))
         (shown (if open body (seq-take body agent-river-approval-body-lines)))
         (hidden (- (length body) (length shown)))
         (options (plist-get offer :options))
         (rows nil))
    ;; Who, and for how long.  The heading also visits the session, for
    ;; the question this view cannot answer: what led here.  Made
    ;; visitable *around* the row so the keymap reaches the newline too,
    ;; and a tap past a short heading still opens the session.
    (push (agent-river--make-visitable
           (agent-river--approval-row
            (concat (propertize "? " 'face 'agent-river-ask)
                    (mapconcat
                     #'identity
                     (delq nil
                           (list (propertize (agent-river--offer-label offer)
                                             'face 'agent-river-session)
                                 (when-let* ((kind (plist-get offer :kind)))
                                   (propertize kind 'face 'agent-river-time))
                                 (propertize (concat "waiting "
                                                     (agent-river--ago
                                                      (plist-get offer :at)))
                                             'face 'agent-river-ask)))
                     " · "))
            id 'offer)
           session)
          rows)
    ;; What is being asked, in agent-shell's words for it.
    (push (agent-river--approval-row
           (concat "  " (agent-river--approval-clean
                         (or (plist-get offer :title) "?")))
           id)
          rows)
    ;; And in the agent's own.
    (dolist (line shown)
      (push (agent-river--approval-row
             (concat "  " (propertize line 'face 'agent-river-act))
             id)
            rows))
    (when (> hidden 0)
      (push (agent-river--approval-row
             (propertize (format "  … %d more line%s (TAB)" hidden
                                 (if (= hidden 1) "" "s"))
                         'face 'agent-river-stale)
             id)
            rows))
    (when-let* ((context (agent-river--approval-context state)))
      (push (agent-river--approval-row (concat "  " context) id) rows))
    (if options
        (dolist (option options)
          (push (agent-river--approval-row
                 (concat "  " (propertize
                               (concat "→ " (agent-river--approval-clean
                                             (alist-get :option option)))
                               'face 'agent-river-prompt))
                 id 'option
                 (list 'agent-river-approval-option (alist-get :option-id option)
                       'keymap agent-river-approval-option-map
                       'mouse-face 'highlight
                       'help-echo "RET or tap: answer with this"))
                rows))
      ;; The responder never ran, so the options and the means to answer
      ;; were never seen.  Said out loud rather than drawn as a block with
      ;; nothing under it: the question is real and the session is the
      ;; place it can still be answered.
      (push (agent-river--approval-row
             (propertize "  (answerable only in the session)"
                         'face 'agent-river-stale)
             id)
            rows))
    (apply #'concat (nreverse rows))))

(defun agent-river--approval-working ()
  "Return how many sessions are mid-turn right now."
  (let ((n 0))
    (maphash (lambda (_key state)
               (when (agent-river--state-working-p state) (setq n (1+ n))))
             agent-river-registry)
    n))

(defun agent-river--approval-header (offers)
  "Return the queue's header line, given the OFFERS it is about to draw.

A count and a count, in the map's sense: what moves and nothing else.  How
many questions are waiting is why the buffer is open, and how many agents
are working is what says whether an empty queue means quiet or means the
watcher is not running -- which is the third part, and only appears in the
case where it is true."
  (concat
   (propertize (if offers
                   (format "%d waiting" (length offers))
                 "nothing waiting")
               'face (if offers 'agent-river-ask 'agent-river-idle))
   (let ((working (agent-river--approval-working)))
     (when (> working 0)
       (propertize (format " · %d working" working) 'face 'agent-river-time)))
   (unless agent-river-approvals-mode
     (propertize " · not watching (M-x agent-river-approvals-mode)"
                 'face 'agent-river-fail))))

(defun agent-river--approval-here ()
  "Return what the line at point names, for a redraw to find again.
A cons of the request id and the answer on the line, or nil for either."
  (let ((id (get-text-property (line-beginning-position) 'agent-river-approval)))
    (when id
      (cons id (get-text-property (line-beginning-position)
                                  'agent-river-approval-option)))))

(defun agent-river--approval-find (id option)
  "Return the position of the row naming ID and OPTION, or nil."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (if (and (equal id (get-text-property (line-beginning-position)
                                              'agent-river-approval))
                 (equal option (get-text-property (line-beginning-position)
                                                  'agent-river-approval-option)))
            (setq found (line-beginning-position))
          (forward-line 1)))
      found)))

(defun agent-river--approval-goto (here)
  "Put point back on the row HERE named, or on the first row there is.

By name rather than by position, the way the HUD's block and the map's
listing both do it: the buffer is rebuilt under whoever is reading it, and
a question answered somewhere above would otherwise slide a different
question's `allow' under a finger already on its way down."
  (let ((pos (and here (or (agent-river--approval-find (car here) (cdr here))
                           ;; The answers are gone but the block is still
                           ;; there: its heading is where that reader was.
                           (agent-river--approval-find (car here) nil)))))
    (goto-char (or pos (point-min)))
    (unless pos
      (unless (agent-river--approval-line-p)
        (agent-river--approval-scan 1 #'agent-river--approval-line-p)))
    (agent-river--approval-beginning-of-row)))

(defun agent-river--approval-draw ()
  "Redraw the approval queue, if it is open."
  (when-let* ((buffer (get-buffer agent-river-approval-queue-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (here (agent-river--approval-here))
            (offers (agent-river--offers-waiting)))
        (erase-buffer)
        (insert (agent-river--approval-header offers) "\n\n")
        (dolist (offer offers)
          (insert (agent-river--approval-block offer) "\n"))
        (agent-river--approval-goto here)))))

(defun agent-river--approval-refresh ()
  "Draw the approval queue now and keep its timer running, if it is open.

Drawn inline rather than marked dirty, which is the opposite of what the
map's observer does and for the opposite reason: that one fires on every
tool call and would redraw a listing thousands of times a task, this one
fires when somebody has been asked a question and is waiting."
  (when (get-buffer agent-river-approval-queue-buffer-name)
    (agent-river--approval-draw)
    (agent-river--ensure-approval-timer)))

;;; Moving about the queue
;;
;; The same keys as the HUD and the map, for the same grains -- but here
;; the coarse grain and the attention grain are the same motion, since
;; every block in this buffer is a question waiting on somebody.  Bound all
;; the same so a reader arriving from either other buffer can press `>' and
;; get the next thing that wants them.

(defun agent-river--approval-line-p ()
  "Return non-nil on a row any motion may stop on."
  (and (get-text-property (line-beginning-position) 'agent-river-line) t))

(defun agent-river--approval-offer-line-p ()
  "Return non-nil on the heading row of a block."
  (eq (get-text-property (line-beginning-position) 'agent-river-line) 'offer))

(defun agent-river--approval-beginning-of-row ()
  "Put point on the first character of the row's own text.
Column zero is the indent and the marker, and a cursor parked there reads
as though the punctuation were the content."
  (goto-char (line-beginning-position))
  (skip-chars-forward " ")
  (when (looking-at "[?→] ")
    (goto-char (match-end 0))))

(defun agent-river--approval-scan (count test)
  "Move to the COUNTth row satisfying TEST, forward when COUNT is positive."
  (agent-river--scan count test #'agent-river--approval-beginning-of-row))

(defun agent-river-approval-queue-next-line (&optional n)
  "Move to the Nth next row worth stopping on."
  (interactive "p")
  (or (agent-river--approval-scan (or n 1) #'agent-river--approval-line-p)
      (user-error "No further row")))

(defun agent-river-approval-queue-previous-line (&optional n)
  "Move to the Nth previous row worth stopping on."
  (interactive "p")
  (agent-river-approval-queue-next-line (- (or n 1))))

(defun agent-river-approval-queue-next-offer (&optional n)
  "Move to the Nth next question, past the answers of this one."
  (interactive "p")
  (or (agent-river--approval-scan (or n 1) #'agent-river--approval-offer-line-p)
      (user-error "No further question")))

(defun agent-river-approval-queue-previous-offer (&optional n)
  "Move to the Nth previous question."
  (interactive "p")
  (agent-river-approval-queue-next-offer (- (or n 1))))

(defun agent-river--approval-at (&optional event)
  "Return the offer the row at point -- or at EVENT -- is part of, and its answer.
A cons of the offer and the option alist, either of which may be nil."
  (let* ((pos (if (and event (listp event))
                  (or (posn-point (event-end event)) (point))
                (point)))
         (start (save-excursion (goto-char pos) (line-beginning-position)))
         (id (get-text-property start 'agent-river-approval))
         (option-id (get-text-property start 'agent-river-approval-option))
         (offer (and id (gethash id agent-river--offers))))
    (cons offer
          (and offer option-id
               (seq-find (lambda (option)
                           (equal (alist-get :option-id option) option-id))
                         (plist-get offer :options))))))

(defun agent-river--approval-confirm-p (option)
  "Return non-nil when OPTION is one that should be asked about twice.

The `_always' kinds, and only those.  What `agent-river-answer' spends a
prompt on is stopping a slip from granting a standing permission, and that
much is worth keeping when the gesture becomes a single tap; making every
answer ask would put a second gesture between a reader and the
`reject_once' they came here to press."
  (member (alist-get :kind option) '("allow_always" "reject_always")))

(defun agent-river-approval-queue-answer (&optional event)
  "Answer the question on this row with the option it names.
EVENT is the mouse event, when invoked from one."
  (interactive (list last-nonmenu-event))
  (pcase-let ((`(,offer . ,option) (agent-river--approval-at event)))
    (cond
     ((null offer) (user-error "No question on this line"))
     ((null option)
      (user-error "Nothing to answer here; RET on one of the → rows"))
     ;; `y-or-n-p', not `yes-or-no-p': a standing permission shouldn't come
     ;; of one slip, and a second gesture serves that -- spelling out "yes"
     ;; on a soft keyboard would be a third.
     ((and (agent-river--approval-confirm-p option)
           (not (y-or-n-p (format "%s — %s? "
                                  (plist-get offer :title)
                                  (alist-get :option option)))))
      (message "agent-river: left unanswered"))
     (t (agent-river--respond offer option)))))

(defun agent-river-approval-queue-toggle ()
  "Show or hide the rest of this question's arguments."
  (interactive)
  (let ((id (get-text-property (line-beginning-position) 'agent-river-approval)))
    (unless id (user-error "No question on this line"))
    (setq agent-river--approval-expanded
          (if (member id agent-river--approval-expanded)
              (delete id agent-river--approval-expanded)
            (cons id agent-river--approval-expanded)))
    (agent-river--approval-draw)))

(defun agent-river-approval-queue-refresh ()
  "Redraw the queue now, and ask agent-shell again what is still open."
  (interactive)
  (agent-river--approval-draw))

(define-derived-mode agent-river-approval-queue-mode special-mode "Agent-Ask"
  "Major mode for the queue of questions the sessions are waiting on.

A view of a state written elsewhere, so read-only; and wrapped rather than
truncated, because the width here is whatever screen this was opened on
and the arguments are the thing being read."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; A wrapped argument reads as part of the row it came from rather than as
  ;; a row of its own, which on a narrow screen is most of them.
  (setq-local wrap-prefix "    ")
  (setq-local header-line-format nil)
  ;; Unlike the HUD, this buffer never pins its point anywhere: every row is
  ;; somewhere a reader chose to be, and on a touch screen the highlight is
  ;; the only thing saying which one a tap would act on.
  (when (fboundp 'hl-line-mode) (hl-line-mode 1))
  (buffer-disable-undo))

(let ((map agent-river-approval-queue-mode-map))
  (define-key map (kbd "RET") #'agent-river-approval-queue-answer)
  (define-key map (kbd "TAB") #'agent-river-approval-queue-toggle)
  (define-key map (kbd "g") #'agent-river-approval-queue-refresh)
  (define-key map (kbd "n") #'agent-river-approval-queue-next-line)
  (define-key map (kbd "p") #'agent-river-approval-queue-previous-line)
  (define-key map (kbd "SPC") #'agent-river-approval-queue-next-line)
  (define-key map (kbd "DEL") #'agent-river-approval-queue-previous-line)
  (define-key map [remap next-line] #'agent-river-approval-queue-next-line)
  (define-key map [remap previous-line] #'agent-river-approval-queue-previous-line)
  (define-key map (kbd "M-n") #'agent-river-approval-queue-next-offer)
  (define-key map (kbd "M-p") #'agent-river-approval-queue-previous-offer)
  ;; The same motion as M-n/M-p here, bound anyway: every block in this
  ;; buffer is a line that wants you, and a reader arriving from elsewhere
  ;; shouldn't have to learn this buffer is where `>' does nothing.
  (define-key map (kbd ">") #'agent-river-approval-queue-next-offer)
  (define-key map (kbd "<") #'agent-river-approval-queue-previous-offer))

(defun agent-river--stop-approval-timer ()
  "Stop the approval queue's redraw timer."
  (when (timerp agent-river--approval-timer)
    (cancel-timer agent-river--approval-timer))
  (setq agent-river--approval-timer nil))

(defun agent-river--approval-changing-p ()
  "Return non-nil while a redraw would still show something different.

Two things move without an event of their own: how long a question has
been waiting, and what the session asking has done since.  So a queue with
a question in it is always changing, and an empty one is changing while
any agent is still working -- because the next thing that happens may be
it asking."
  (or (agent-river--offers-waiting)
      (> (agent-river--approval-working) 0)))

(defun agent-river--approval-tick ()
  "Redraw the queue, or retire once nothing it shows can change."
  (condition-case err
      (cond
       ((null (get-buffer agent-river-approval-queue-buffer-name))
        (agent-river--approval-teardown))
       ((agent-river--approval-changing-p) (agent-river--approval-draw))
       (t
        ;; Drawn once on the way out, or the last question answered would
        ;; leave its own block on screen until somebody pressed `g'.
        (agent-river--approval-draw)
        (agent-river--stop-approval-timer)))
    ;; The same bargain the other timers make: a redraw that throws every
    ;; couple of seconds would bury Emacs in messages, so it retires rather
    ;; than repeats -- and says so rather than going quiet.
    (error (agent-river--stop-approval-timer)
           (message "agent-river: approval queue stopped (%s)"
                    (error-message-string err)))))

(defun agent-river--ensure-approval-timer ()
  "Start the queue's redraw timer if the queue is open and none runs."
  (when (and (null agent-river--approval-timer)
             (get-buffer agent-river-approval-queue-buffer-name))
    (setq agent-river--approval-timer
          (run-at-time agent-river-approval-queue-interval
                       agent-river-approval-queue-interval
                       #'agent-river--approval-tick))))

(defun agent-river--approval-teardown ()
  "Stop the queue's timer, and give back the mode if the queue took it."
  (agent-river--stop-approval-timer)
  (when (and agent-river--approval-owns-mode agent-river-approvals-mode)
    (agent-river-approvals-mode -1))
  (setq agent-river--approval-owns-mode nil))

;;;###autoload
(defun agent-river-approval-queue ()
  "Show every question the sessions are waiting on, and answer them here.

One block per question -- who is asking, what for, in whose words, and
what the session has been doing -- and one row per answer, which RET or a
tap gives.  Built for the screen it is most often needed on: a phone over
emacsclient, in portrait, answered with a thumb.

Turns `agent-river-approvals-mode' on if it is off, because there is
nothing to show otherwise: the options and the means to answer are only
ever seen by the responder that mode installs.  Killing this buffer turns
it back off again, unless it was already on when this was opened."
  (interactive)
  (let ((buffer (get-buffer-create agent-river-approval-queue-buffer-name)))
    (unless agent-river-approvals-mode
      (agent-river-approvals-mode 1)
      (setq agent-river--approval-owns-mode t))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-river-approval-queue-mode)
        (agent-river-approval-queue-mode))
      (add-hook 'kill-buffer-hook #'agent-river--approval-teardown nil t))
    (agent-river--approval-draw)
    (agent-river--ensure-approval-timer)
    ;; Reuse a window showing it, else take this one.  A phone has one
    ;; window and this is what it is for; a desktop has several and a view
    ;; that deletes them to make room is a view nobody opens twice.
    (pop-to-buffer buffer '((display-buffer-reuse-window
                             display-buffer-same-window)))))


;;; What a session is using -- two meters read from outside, one drawn
;;
;; agent-shell keeps two figures per session: how full the context window
;; is (`:context-used') and what it has cost (`:cost-amount'), both written
;; off the one `usage_update' notification.  What decides which of them the
;; graph is made of is which one the server actually *moves*: the context
;; fill climbs continuously, the cost moves once per turn.  A graph of cost
;; would draw a whole turn as one spike in the bar it happened to end in.
;;
;; A third figure, `:total-tokens', is not a way out either -- it exists
;; once a turn, on the `session/prompt' response, and the graph never
;; reads it.
;;
;; So the bars are the context: a bar holds how many tokens the window grew
;; by while it ran.  The cost is still read, totalled, and what
;; `agent-river-spend' answers with -- it just doesn't decide the shape.
;;
;; The two figures are kept under opposite rules, since a fall means
;; something different in each.  A context that drops has been compacted,
;; which is ordinary, so the reading is taken as it comes and growth is
;; measured from the new floor.  A cost that drops is somebody else's
;; arithmetic (a reconnect, a turn-scoped report), so `:cost' is a
;; high-water mark -- storing the dip would understate the session.
;;
;; Sampled on every event, never on a timer: a timer would run through the
;; quiet, which is when there is nothing to measure, where events arrive
;; thickly exactly while an agent works.
;;
;; Not a struct slot -- the exception to that rule, not an instance of it.
;; No hook payload carries either figure, so a slot would hold transitions
;; the event stream could never account for, and adding one would demand
;; `agent-river-reset' for a mere decoration.  A reload costs the shape of
;; the last hour, never the totals, which are re-read from agent-shell on
;; the next event.
;;
;; The hooks carry none of this, so a session run from a terminal has no
;; graph -- the same price the `◇' and `“' lines pay.

(defcustom agent-river-tokens-width 6
  "Characters of token graph drawn on a session line, or nil for none.

Braille is two dots wide, so a character is two bars and the default six
draws twelve of them.  The window the graph covers is therefore twice this
many `agent-river-tokens-interval's: an hour, by default.

Nil is the off switch, and the answer for a font with no braille in it.
So is 0, since a graph no characters wide is no graph -- which is why the
type is a natural number: a negative width is not a setting anybody meant,
and the customise buffer is the cheapest place to say so once."
  :type '(choice (const :tag "No graph" nil) natnum))

(defcustom agent-river-tokens-interval 300
  "Seconds of work one bar of the token graph covers.

Five minutes, so the default width spans an hour.  Shorter bars resolve a
burst into a spike, and shorten the window with it; longer ones reach
further back and flatten the same burst into its neighbours."
  :type 'number)

(defconst agent-river--usage-horizon 288
  "Bars kept per session, however wide the graph happens to be drawn.

A day at the default interval, and a few hundred conses a session, so the
table is bounded without the trimming having to know what the view is
showing.  A graph drawn wider than this leaves the bars beyond it blank
rather than empty: what was dropped is unknown, not idle.")

(defface agent-river-tokens '((t :inherit shadow))
  "Face for the token graph on a session line.

Faint on purpose.  The graph is a texture read at a glance beside the
numbers rather than a fact competing with them -- and inherited rather
than coloured, so how faint is the theme\\='s answer and not ours.")

(defvar agent-river--usage (make-hash-table :test 'equal)
  "Session id -> what it has used, as a plist.

`:used' is the last context reading, taken as it comes because a context
that falls has been compacted.  `:cost' is the high-water cost and
`:currency' what that is denominated in, which together are the whole of
what `agent-river-spend' answers with.  `:since' is when the context was
first *read*, which is not the same as when the session was first sampled
and is what an entry without a graph is missing.  `:bars' is an alist of
BAR -> TOKENS keyed by
`agent-river--usage-bar', holding only the bars the window grew in: a bar
inside the session\\='s life with no entry is one nothing arrived in, and
that is a different thing from a bar before the session was ever seen.")

(defun agent-river--usage-bar (&optional time)
  "Return which bar of the graph TIME falls in.

An integer count of `agent-river-tokens-interval's since the epoch, so two
sessions sampled at the same moment land in the same bar without anything
having to agree on where the graph starts.

An interval of zero is not an off switch -- `agent-river-tokens-width' nil
is -- so it falls back to a minute rather than dividing by it.  This is
reached from the block\\='s own redraw, and a setting nobody would defend is
still not allowed to take the HUD dark."
  (let ((interval (if (and (numberp agent-river-tokens-interval)
                           (> agent-river-tokens-interval 0))
                      agent-river-tokens-interval
                    60)))
    (floor (float-time (or time (current-time))) interval)))

(defun agent-river--usage-read (session)
  "Return what agent-shell reports for SESSION, or nil.

One buffer read for both meters, since they live in one alist and are
wanted on the same event: `:used' is the context fill, `:cost' what has
been spent, `:currency' what that is in.

Both are read past agent-shell\='s own starting values, 0 and 0.0, which by
type alone are indistinguishable from a reading.  A context of zero is a
server that does not report one rather than a session using nothing -- one
that has been prompted holds thousands of tokens before the agent says a
word -- so it counts only when positive.  A cost counts when it is
positive or when a currency was named beside it: the currency is the
evidence the figure is the server\='s, and this leaves a genuinely free run
its zero while keeping an unreported one out of `agent-river-spend'.

Nil, and nil fields within it, are the ordinary answer rather than a
failure -- a session nobody here hosts has no meter to read, and one whose
ACP server reports no cost never will have."
  (when-let* ((buffer (agent-river--shell-buffer session))
              (state (buffer-local-value 'agent-shell--state buffer))
              (usage (alist-get :usage state)))
    (let* ((used (alist-get :context-used usage))
           (cost (alist-get :cost-amount usage))
           (currency (alist-get :cost-currency usage))
           (named (and (stringp currency) currency)))
      (list :used (and (numberp used) (> used 0) used)
            :cost (and (numberp cost) (or (> cost 0) named) cost)
            :currency named))))

(defun agent-river--usage-record (session reading &optional now)
  "Record READING as what SESSION was using as of NOW.

The graph is made of the differences between readings, so the *first*
reading of a session adds nothing to it: a session this Emacs has just
adopted -- reloaded into, or started watching mid-task -- would otherwise
draw its whole context as one spike at the moment we first looked.  What
the first reading does establish is `:since', which is what tells a bar
nothing arrived in from a bar before there was anything to arrive.

`:since' is set by the first *context* reading and not by the first sample
of anything, which makes it the graph\='s own start: a session whose server
reports no context never gets one, and so is left without a graph rather
than with a row of bars asserting that nothing arrived.

A drop in the context is a compaction and is taken as it comes: it adds
nothing to the bar, and the growth after it is measured from the new
floor.  A drop in the cost is not taken as it comes; see
`agent-river--usage-cost'."
  (let* ((at (or now (current-time)))
         (entry (gethash session agent-river--usage))
         (used (plist-get reading :used))
         (last (plist-get entry :used))
         (grew (and last used (- used last)))
         (bars (plist-get entry :bars)))
    (when (and grew (> grew 0))
      (let* ((bar (agent-river--usage-bar at))
             (cell (assq bar bars)))
        (if cell
            (setcdr cell (+ (cdr cell) grew))
          (push (cons bar grew) bars))))
    (puthash session
             (list :used (or used last)
                   :cost (agent-river--usage-cost (plist-get entry :cost)
                                                  (plist-get reading :cost))
                   :currency (or (plist-get reading :currency)
                                 (plist-get entry :currency))
                   :since (or (plist-get entry :since) (and used at))
                   :bars bars)
             agent-river--usage)
    (agent-river--usage-trim at)))

(defun agent-river--usage-cost (kept reported)
  "Return the cost to keep, given what was KEPT and what was REPORTED.

The high-water mark, where the context beside it is simply the latest
reading.  The asymmetry is the point: a context that falls has been
compacted, which is a true thing that happened, where a cost that falls is
somebody else\\='s arithmetic -- a server reconnecting, an agent whose
`usage_update' reports the turn rather than the session.  Storing that dip
would make the one figure here that is shown as money wrong, in the one
place it is presented as a fact."
  (cond ((and kept reported) (max kept reported))
        (t (or reported kept))))

(defun agent-river--usage-trim (now)
  "Drop every session\\='s bars older than the horizon, as of NOW.

Swept over the whole table rather than over the session being written, so
a session that has stopped being sampled -- ended, or its shell buffer
killed -- does not hold its last bars for as long as this Emacs runs, and
`agent-river--usage-max' walks the sessions still working rather than
every one ever seen.

What is deliberately not dropped is the entry.  Its `:cost' is what lets
`agent-river-spend' answer for a session whose buffer is gone, which is
the one thing reading agent-shell directly cannot do, and an entry with no
bars left is a handful of values."
  (let ((floor (- (agent-river--usage-bar now) agent-river--usage-horizon)))
    (maphash (lambda (_session entry)
               (plist-put entry :bars
                          (seq-filter (lambda (cell) (> (car cell) floor))
                                      (plist-get entry :bars))))
             agent-river--usage)))

(defvar agent-river--usage-broken nil
  "Non-nil once reading the meters has thrown, which retires the sampling.
Cleared by `agent-river-reset'.  See `agent-river--usage-sample'.")

(defun agent-river--usage-sample (session)
  "Sample what SESSION is using, recording whatever of it is new.

Guarded like an observer, and for an observer\\='s three reasons: this runs
on every tool call, it reads another package\\='s internals, and it is extra
to the fold.  So it must not report itself as the fold having broken --
that sends somebody to `agent-river-reset' over a decoration -- must not
repeat a failure thousands of times, and must not go quiet either.  It
says so once and stops sampling."
  (unless agent-river--usage-broken
    (condition-case err
        (when-let* ((reading (agent-river--usage-read session)))
          (agent-river--usage-record session reading))
      (error
       (setq agent-river--usage-broken t)
       (agent-river-log "fail"
                        (format "usage read failed (%s) -- not sampling again"
                                (error-message-string err)))))))

(defconst agent-river--usage-left [0 #x40 #x44 #x46 #x47]
  "Braille bits for a bar of each height in a cell\\='s left column.
Filled from the bottom: dot 7, then 3, 2, 1.")

(defconst agent-river--usage-right [0 #x80 #xA0 #xB0 #xB8]
  "Braille bits for a bar of each height in a cell\\='s right column.
Dot 8, then 6, 5, 4 -- the same bars one column over, and not a shift of
the left ones, because braille numbers its dots down the columns.")

(defconst agent-river--usage-frame "│"
  "What closes the token graph at each end.

Box drawing rather than the ASCII pipe, because that is what the character
is for: it is a rule around a reading, and it reads as one at a glance
instead of as a character the log below would print literally.  Named once
because the graph and the blank column that stands in for it have to agree
-- two spellings of a frame are two widths, and the whole of what being a
column buys is that they do not differ.")

(defun agent-river--usage-cell (left right)
  "Return the braille character showing bars of height LEFT and RIGHT."
  (string (+ #x2800
             (aref agent-river--usage-left left)
             (aref agent-river--usage-right right))))

(defun agent-river--usage-height (amount max)
  "Return the height, 1 to 4, of a bar of AMOUNT against MAX.

Never 0: a blank bar is the graph\\='s decision about what it can see at all,
made from the range rather than from an amount.

AMOUNT nil is a bar that exists and nothing arrived in, and it draws one
dot rather than nothing at all: the bottom level is spent on that
distinction because it is the one that can mislead, \"the agent was here
and idle\" being a different statement from \"the agent was not here\".
That leaves three levels for the value, which is coarse and meant to be --
the graph answers when the work happened, and `agent-river-spend' answers
what it cost."
  (cond ((or (null amount) (<= amount 0)) 1)
        ((or (null max) (<= max 0)) 2)
        (t (min 4 (+ 1 (ceiling (* 3 (/ (float amount) max))))))))

(defun agent-river--usage-max (&optional now)
  "Return the largest bar any session has inside the window, or nil.

One scale for the whole block, so the graphs can be read against each
other.  Scaled per line instead, a dozing session\\='s trickle and a busy
one\\='s burst both draw a full bar, and two lines one above the other would
say the same thing about work an order of magnitude apart -- which is the
whole of what a stack of graphs is read for.

Recomputed per line rather than memoised for the draw: this is a handful
of sessions with a few dozen bars between them, which
`agent-river--usage-trim' keeps true by sweeping the whole table."
  (let ((window (* 2 (or agent-river-tokens-width 6)))
        (bar (agent-river--usage-bar now))
        (max nil))
    (maphash (lambda (_session entry)
               (dolist (cell (plist-get entry :bars))
                 (when (and (> (car cell) (- bar window))
                            (<= (car cell) bar)
                            (or (null max) (> (cdr cell) max)))
                   (setq max (cdr cell)))))
             agent-river--usage)
    max))

(defun agent-river--usage-graph (session scale &optional now)
  "Return SESSION\\='s token graph over the window as braille, or nil.

Oldest bar on the left, the one running now at the right.  SCALE is what
the bars are measured against, from `agent-river--usage-max' -- one scale
for every line, never this session\\='s own.  Nil when the graph is off or
this session has never been sampled, which is what leaves a hooks-only
session with a blank column rather than a made-up one."
  (when-let* ((width agent-river-tokens-width)
              ((> width 0))
              (entry (gethash session agent-river--usage))
              ;; An entry is not yet a meter: one with a cost and no
              ;; context has no `:since', and drawing it would wrongly
              ;; say "nothing arrived" instead of "nobody said".
              (since (plist-get entry :since)))
    (let* ((window (* 2 width))
           (bar (agent-river--usage-bar now))
           ;; Two floors, and both mean "we cannot say": before the context
           ;; was first read, and before the table stopped keeping bars.
           (first (max (agent-river--usage-bar since)
                       (- bar agent-river--usage-horizon -1)))
           (bars (plist-get entry :bars))
           (heights nil))
      (dotimes (i window)
        (let ((n (+ (- bar window) 1 i)))
          (push (if (>= n first)
                    (agent-river--usage-height (alist-get n bars) scale)
                  0)
                heights)))
      (setq heights (nreverse heights))
      (concat agent-river--usage-frame
              (mapconcat (lambda (i) (agent-river--usage-cell (nth (* 2 i) heights)
                                                              (nth (1+ (* 2 i)) heights)))
                         (number-sequence 0 (1- width))
                         "")
              agent-river--usage-frame))))

(defun agent-river--usage-measured-p ()
  "Return non-nil when a session the block is drawing has been sampled.

The question the column is reserved on, and pointedly not \"has anything
ever been sampled\": an entry outlives its session on purpose, so that
`agent-river-spend' can answer for one whose buffer is gone, and asking
the table whether it is empty would keep the column on every line of an
Emacs whose agent-shell sessions all ended hours ago.

`:since' is asked for the same reason one grain down: an entry made for a
cost alone has no graph in it, and reserving room across the block for a
column nothing can ever fill is the blank half of that mistake."
  (catch 'measured
    (maphash (lambda (session entry)
               (when-let* ((state (gethash session agent-river-registry)))
                 (when (and (plist-get entry :since)
                            (agent-river--active-p state))
                   (throw 'measured t))))
             agent-river--usage)
    nil))

(defun agent-river--usage-column (session &optional now)
  "Return SESSION\\='s graph padded to a fixed width, or nil.

Every graph is the same length and drawn first on the line, ahead of the
name: only the outline marker comes before it, so the graphs stack into a
strip that can be read straight down, which is what sharing one scale is
for.  It also squares up the field after it, the name being the one that
starts at a fixed place.

Padded with blank braille rather than spaces, so an empty column is
exactly as wide as a full one in whatever font is drawing them, and a
line\\='s own tail does not jump when its session is first sampled.

NOW is read once and handed to both readings below.  Left to each of them
to ask, a draw that straddled a bar boundary would scale the graph against
a window one bar from its own."
  (when (and agent-river-tokens-width (> agent-river-tokens-width 0)
             (agent-river--usage-measured-p))
    (let ((now (or now (current-time))))
      (propertize (or (agent-river--usage-graph session (agent-river--usage-max now) now)
                      (concat agent-river--usage-frame
                              (make-string agent-river-tokens-width #x2800)
                              agent-river--usage-frame))
                  'face 'agent-river-tokens))))

(defun agent-river--usage-money (row)
  "Return ROW\\='s `:cost' with its `:label' and `:currency' where it has them.

The currency is named where the meter named one and left out where it did
not, rather than defaulted to a dollar sign: this is the one place the
money itself is shown, and guessing what it is denominated in is worse
than saying nothing."
  (let ((label (plist-get row :label))
        (currency (plist-get row :currency)))
    (concat (and label (concat label " "))
            (and currency (concat currency " "))
            (format "%.2f" (plist-get row :cost)))))

;;;###autoload
(defun agent-river-spend ()
  "Report what each session has cost, and what they have cost together.

The figures are agent-shell\\='s, sampled as the sessions worked, and they
outlive the buffers they were read from: a session whose shell buffer has
been killed still has whatever it had cost when it was last seen, which is
the one thing reading `agent-shell--state' directly cannot say.  Summed
per currency, since this is the one place the money itself is shown and
two currencies added together are a number true of neither.

This is where the cost is answered for, and it is the only place: the
graph on the session line is the context window filling, because that
moves as the work happens where the cost moves once a turn.

Deliberately a query rather than a line in the HUD: a total across
sessions belongs to no session, so it would need a line or a header of its
own."
  (interactive)
  (let (rows totals)
    (maphash (lambda (session entry)
               ;; Only what somebody reported: a session with no `:cost'
               ;; has a server that never sent a figure, and a 0.00 row for
               ;; it would be this command inventing the thing it exists to
               ;; state.  A reported zero is kept -- that's a free run.
               (when-let* ((cost (plist-get entry :cost)))
                 (let* ((currency (plist-get entry :currency))
                        (state (gethash session agent-river-registry))
                        (sum (assoc currency totals)))
                   (push (list :label (or (and state (agent-river-state-label state))
                                          session)
                               :cost cost :currency currency)
                         rows)
                   (if sum
                       (setcdr sum (+ (cdr sum) cost))
                     (push (cons currency cost) totals)))))
             agent-river--usage)
    (setq rows (sort rows (lambda (a b) (> (plist-get a :cost)
                                           (plist-get b :cost)))))
    (message "%s"
             (if rows
                 ;; "total" leads the sums rather than trails them: after a
                 ;; list of sessions it would read as attached to whichever
                 ;; currency happened to be last.
                 (format "%s · total %s"
                         (mapconcat #'agent-river--usage-money rows " · ")
                         (mapconcat (lambda (sum)
                                      (agent-river--usage-money
                                       (list :cost (cdr sum) :currency (car sum))))
                                    totals ", "))
               "Nothing measured -- no session here reports what it costs"))
    (list :totals totals :sessions rows)))


;;; Entry points -- how state gets in
;;
;; Two ways: the hooks report what happened, and the agent can state what
;; it believes it is doing.  The second is a claim rather than a
;; measurement, kept apart everywhere downstream.

;; Side effects hang off `agent-river-observers' rather than being called
;; from `agent-river-observe' by name, since every consumer that reaches
;; outside this package needs the same three things:
;;
;; It must not run inside the fold, which is pure and driven by tests with
;; no frame, no buffers, no live session.  It must not share the fold's
;; guard, since an error there sends the user to `agent-river-reset' and
;; throws away every session's state over what may be one overlay.  And it
;; must retire on its first error, since this path runs on every tool call.
;;
;; The runner owns those three so a consumer is left with only its own job.

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

(defun agent-river--run-observers (hook subject event)
  "Run HOOK's functions over SUBJECT and EVENT, each in its own guard.

HOOK is the symbol of an abnormal hook -- `agent-river-observers', whose
subject is an `agent-river-state', or `agent-river-artifact-observers',
whose subject is an `agent-river-artifact'.  Taking the hook as an
argument rather than naming one is what keeps the three rules below in a
single implementation: they are the whole of what a consumer inherits, and
a second copy of them is a second place for one of them to be forgotten.

An observer that throws is removed rather than being allowed to fail on
every tool call for the rest of the session, and says so in the log --
going quiet is how this has broken before.  One that needs to tear
something down on the way out puts a function on its symbol's
`agent-river-retire' property; without it, removal is the whole
retirement."
  (dolist (observer (symbol-value hook))
    (condition-case err
        (funcall observer subject event)
      (error
       (set hook (delq observer (symbol-value hook)))
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
         ;; The session, whoever acted within it.  A subagent's hook call
         ;; carries its parent's session id and an agent_id of its own; a
         ;; subagent has no prompt, no directory and nothing that can be
         ;; told to it, so it is a tally on the session, folded by
         ;; `agent-river--delegate'.
         (id session)
         (state (agent-river-state id (plist-get event :label)))
         (kind (or (plist-get event :kind) "act"))
         (detail (or (plist-get event :detail) "")))
    ;; Before anything that can fail: where agent-shell hosts this session
    ;; the reasoning arrives on its ACP stream, so the subscription has to
    ;; exist before the first thought streams.  Its buffer dying is
    ;; likewise how a restart reaches us, with no hook event to say so.
    (agent-river--ensure-subscribed session)
    (agent-river--ensure-shell-teardown session)
    ;; The meters, read before the fold and outside its guard: a figure
    ;; that can't be read must not report itself as the fold having
    ;; broken, which sends somebody to `agent-river-reset'.  It carries its
    ;; own guard instead, and stops sampling once it has said so.
    (agent-river--usage-sample session)
    ;; The fold must not be able to take the HUD dark without saying so:
    ;; an error here must not abort `observe' before it renders anything.
    ;; Surface it and carry on; `agent-river-reset' is the fix.
    (condition-case err
        (progn (agent-river-fold state event)
               (agent-river--update-panel state))
      (error
       (agent-river-log "fail" (format "fold failed (%s) -- try M-x agent-river-reset"
                                       (error-message-string err)))))
    (agent-river--run-observers 'agent-river-observers state event)
    (let ((label (agent-river-state-label state))
          (call (plist-get event :call)))
      ;; A call that ends is written onto the line that began it, so one
      ;; tool call reads as one line.  Where that line is gone (trimmed, or
      ;; never written) the outcome falls back to a line of its own.
      (cond
       ((agent-river--log-outcome call (plist-get event :outcome) kind))
       ((not (string-empty-p detail))
        (agent-river-log kind detail label call)))
      ;; And the block.  Before the timers, since both read what this
      ;; draws: the refresh timer for the elapsed times, the animation for
      ;; the marks it paints here.
      (agent-river--update-block)
      (agent-river--ensure-timer)
      (agent-river--ensure-spinner)
      ;; Only ask for an observation on an event that can actually deliver
      ;; one: asked regardless, a streak still standing at `idle' (whose
      ;; hook is async) produces a signal that is logged and folded but
      ;; never read, overcounting `signals'.
      (let ((signal (and (member kind agent-river-answering-kinds)
                         (agent-river--answerable-p event)
                         (agent-river--signal state))))
        (when signal
          ;; Through the fold, not around it: a direct push onto the slot
          ;; would make `agent-river-observe' a second writer to a state
          ;; the fold is supposed to own alone.
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
                  ;; Explicit, since the answer is JSON for another process
                  ;; and the locale here isn't ours to assume -- a signal
                  ;; naming a non-ASCII file must not prompt for a coding
                  ;; system nobody is there to answer.
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
        (agent-river--update-block)
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
to reach the file on disk, without the note claiming the agent acted on
it.

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
        (agent-river--update-block)
        (agent-river--run-observers 'agent-river-observers state event)
        text)))))


;;; Queries -- the meta level

(defun agent-river--child-digest (child)
  "Return a compact summary of CHILD, one entry of `agent-river-children'.

No `:hottest': a delegated file lands in the session's own artifact
tables, and a per-child copy of that reading could only disagree with
them."
  (list (or (plist-get child :type) "agent")
        :steps (plist-get child :steps)
        :failures (plist-get child :failures)
        :status (plist-get child :status)))

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
         ;; Keys say which frame they are measured in: steps and the task
         ;; tally reset with every prompt, the session tally does not, and
         ;; unlabelled they'd read as comparable when they are not.
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
               :notes (length (agent-river-state-notes state))
               ;; The end of this task's last turn, cleared by a prompt
               ;; with the `task-' keys above it.  Unprefixed like
               ;; `:claimed-intent': the prefix is only for values that
               ;; exist in both frames, and this has no session-wide
               ;; reading to be confused with.
               :said (agent-river-state-said state))
         ;; Subagents fold separately so their failures stay theirs, but the
         ;; parent still has to be able to see what it set in motion.
         (when kids
           (list :subagents
                 (list :running (seq-count (lambda (c)
                                             (equal (plist-get c :status) "running"))
                                           kids)
                       :total (length kids)
                       :steps (apply #'+ (mapcar (lambda (c) (plist-get c :steps))
                                                 kids))
                       :each (mapcar #'agent-river--child-digest kids)))))))))

;;; Handing the state out -- Markdown, for where it is going to be read
;;
;; The one place Markdown belongs in this package.  The HUD stays plain
;; text since its log carries prompts, reasoning and tool arguments the
;; package does not control, and Markdown would hand that text the power
;; to restructure the view watching it.  Here the state is *leaving*, to
;; an issue, a pull request, a message, where Markdown is what gets read.
;;
;; A third derivation of the state, beside the panel and the report, built
;; on neither: the report's values are already formatted for a human
;; reading a plist, and re-formatting a formatted string is the
;; second-account problem in a different hat.  What the report gets free
;; from its key names -- `:task-hottest' against `:session-hottest' -- has
;; to be done by hand here, and tested, so the two frames don't read as
;; comparable when unlabelled.

(defun agent-river--md-escape (text)
  "Return TEXT with its Markdown-active punctuation neutralised.

For the values the agent wrote: a prompt, a stated intent, and the end of
a turn.  They do not stop being arbitrary text because the export is going
somewhere Markdown is read -- an intent containing an asterisk would
silently italicise the rest of the line, and one containing a bracket
would swallow it into a link.  This is the same hazard that keeps the HUD
out of Markdown; here it is small enough to escape, because only three
values are the agent's, and the third is clipped before it arrives
\(`agent-river-said-width')."
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

(defun agent-river--md-child (child)
  "Return one Markdown line for subagent CHILD, indented under its session.

CHILD is one entry of `agent-river-children'.  No hottest file: a
delegated file lands in the session's own tables and is already named
above, and a second reading of it here could only disagree."
  (let ((steps (plist-get child :steps))
         (failures (plist-get child :failures)))
    (format "    - %s — %s · %d step%s%s"
            (agent-river--md-code (or (plist-get child :type) "agent"))
            (plist-get child :status)
            steps (if (= steps 1) "" "s")
            (if (> failures 0) (format " · %d failed" failures) ""))))

(defun agent-river--md-session (state)
  "Return the Markdown for root STATE, its subagents folded in under it.

Subagents get no section of their own, exactly as they get no panel line:
their work is counted on the parent and aggregated on demand, so that the
two cannot drift."
  (let* ((kids (agent-river-children (agent-river-state-id state)))
         (task (agent-river-state-task state))
         (said (agent-river-state-said state))
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
    ;; Directly under the prompt: the two are one exchange, and the answer
    ;; filed below the tallies would read as another measurement rather
    ;; than the end of the thing above it.  Escaped here, not in the slot,
    ;; so the HUD (not Markdown) is never shown backslashes it never needed.
    (when (and said (not (string-empty-p said)))
      (push (format "- **said** — %s" (agent-river--md-escape said)) lines))
    ;; The frame is in the name of the bullet, not left to the reader.  The
    ;; task tally resets with every prompt and the session tally does not.
    (push (format "- **this task** — %d step%s · %d failure%s%s"
                  (agent-river-state-steps state)
                  (if (= (agent-river-state-steps state) 1) "" "s")
                  (or (agent-river-state-task-failures state) 0)
                  (if (= (or (agent-river-state-task-failures state) 0) 1) "" "s")
                  (let ((started (agent-river-state-task-started state)))
                    (if started (concat " · " (agent-river--ago started)) "")))
          lines)
    (push (format "- **this session** — %s"
                  (let ((started (agent-river-state-started state)))
                    (if started (agent-river--ago started) "just started")))
          lines)
    ;; A live failure run is the one thing a reader must not have to infer.
    (when (> streak 0)
      (push (format "- **failing** — %d in a row" streak) lines))
    ;; Last, and marked twice: the agent talking about itself, and a claim
    ;; taken for one of the measurements above it is exactly the confusion
    ;; the `intent' slots are kept apart to prevent.
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
      (let ((steps (apply #'+ (mapcar (lambda (c) (plist-get c :steps)) kids))))
        (push (format "- **subagents** — %d of %d running · %d step%s"
                      (seq-count (lambda (c) (equal (plist-get c :status) "running"))
                                 kids)
                      (length kids) steps (if (= steps 1) "" "s"))
              lines))
      (dolist (child (sort kids (lambda (a b)
                                  (string< (or (plist-get a :type) "")
                                           (or (plist-get b :type) "")))))
        (push (agent-river--md-child child) lines)))
    (string-join (nreverse lines) "\n")))

;;;###autoload
(defun agent-river-markdown (&optional id)
  "Return the state as Markdown, or nil when there is nothing to say.

Every live root session, in the order and by the rule the state block
shows them, so this is a snapshot of that block and not a second opinion
about which sessions count.  ID narrows it to one.

The order is the block's own, taken from `agent-river--panel-states'
rather than sorted again here: one function answers \"which sessions, in
what order\" for both readings, so the claim that this is a snapshot of
the block cannot quietly stop being true."
  (let ((states (agent-river--panel-states id)))
    (when states
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
  "Major mode for the state block.

One line per live session, redrawn on every fold, in a window sized to
exactly that.  Nothing here grows, so nothing here scrolls."
  ;; A session line carries a dozen fields and does not fit the side
  ;; window; truncating it would drop the numbers at the end of it.
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; Clear of the outline star, which is structure rather than content.
  (setq-local wrap-prefix "  ")
  ;; The session lines are outline headings, so outline navigation walks
  ;; the block as a document.  Matched against the buffer text, which is
  ;; why the star stays a literal `*' whatever is drawn over it.
  (setq-local outline-regexp "^\\*+ ")
  (outline-minor-mode 1)
  ;; Explicitly none: a value left behind by an older version of this file
  ;; would otherwise sit frozen at the top of the buffer.
  (setq-local header-line-format nil)
  (buffer-disable-undo))

(define-derived-mode agent-river-log-mode special-mode "Agent-Log"
  "Major mode for the event log.

Oldest to newest, the way every other log is read: the line that has just
arrived is at the bottom, the oldest are trimmed off the top, and a
window nobody has moved is kept on the end of it.  Deliberately
not Markdown, and this is the buffer that decides it for both -- what it
holds is prompts, reasoning and tool arguments, text this package does
not control, and Markdown would hand that text the power to restructure
the view watching it."
  ;; Tool lines fit the side window, but reasoning and signal lines are
  ;; prose and do not -- truncating them would hide most of what they say.
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; Clear of the timestamp.  Every line carries its own besides, because
  ;; whether it has a session column is decided per line.
  (setq-local wrap-prefix (make-string 11 ?\s))
  (setq-local header-line-format nil)
  (buffer-disable-undo))

(defun agent-river--artifact-list (state &optional scope)
  "Return STATE's artifacts as (NAME . TOUCHES), most-touched first.

NAME is the bare basename, and the touches of every path sharing one are
summed, so a file reached from a worktree and from the main checkout
counts once.  SCOPE is `session' for the whole session, nil for the
current task.

Read by the approval queue's context line, which takes the head of this
list and shows the name without its count."
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
different moments spin out of step -- which is what they are.  A row of
markers moving as one would read as a single animation about the block
rather than as one apiece.

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

Always literal stars -- `outline-regexp' is matched against the buffer
text, so the animation is a `display' property over one of them rather
than a different character in its place.  The star is marked with
`agent-river-spinner' where it is built, and the mark is that session's
phase: the frame timer finds the lines that are spinning and reads what
each should be showing off the mark itself, without re-deriving which
sessions are working or matching a regexp over the rendered text."
  (let* ((since (and (agent-river--state-working-p state)
                     (agent-river--spinning-since state)))
         (glyph (and since (agent-river--spinner-glyph since))))
    (concat (if glyph
                (propertize "*" 'agent-river-spinner since 'display glyph)
              "*")
            " ")))

(defun agent-river--panel (state)
  "Return the summary line of STATE, as a top-level outline heading.

The view of the *state*: a log shows activity, and only this line answers
what is being worked on right now, which is the question an onlooker
actually has."
  (let* ((kids (agent-river-children (agent-river-state-id state)))
         (running (seq-count (lambda (c) (equal (plist-get c :status) "running"))
                             kids))
         (task (agent-river-state-task state))
         (streak (agent-river-state-fail-streak state))
         (phase (agent-river--phase state))
         (parts
          (delq nil
                (list
                 ;; First on the line, ahead of the name: only the outline
                 ;; marker comes before it, so every graph starts in the
                 ;; same place and stacks into a strip read straight down,
                 ;; which is what sharing one scale is for.  It also
                 ;; squares up the name, the one field after it that
                 ;; starts at a fixed place.
                 ;;
                 ;; It is in neither frame: everything after it is this
                 ;; task's and resets on a prompt, where this covers a
                 ;; fixed window running straight through one -- reading it
                 ;; before the name says it is about the session, not the
                 ;; turn.
                 (agent-river--usage-column (agent-river-state-id state))
                 (propertize (or (agent-river-state-label state) "?")
                             'face 'agent-river-session)
                 ;; An open question outranks everything below it and
                 ;; comes first: it's the only thing on this line waiting
                 ;; on the reader rather than describing the agent.
                 ;; Queried, never folded, since it stops being true the
                 ;; moment it's answered -- including in the session
                 ;; buffer, where nothing here would hear.
                 (when-let* ((offer (agent-river--offer
                                     (agent-river-state-id state))))
                   (propertize (agent-river--offer-text offer)
                               'face 'agent-river-ask))
                 (when phase
                   (propertize phase 'face
                               (cond ((equal phase "blocked") 'agent-river-fail)
                                     ((equal phase "waiting") 'agent-river-idle)
                                     (t 'agent-river-act))))
                 ;; The stated intent replaces the prompt when it is
                 ;; fresh: a long task moves through several sub-goals
                 ;; while the prompt stays the same, and the finer one is
                 ;; what an onlooker wants.  Stale, it is shown greyed and
                 ;; marked rather than dropped -- the agent going quiet is
                 ;; itself worth seeing.
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
                 ;; A live failure run is the one thing an onlooker must not
                 ;; have to infer from scrollback.
                 (when (> streak 0)
                   (propertize (format "%d failing" streak)
                               'face 'agent-river-fail))
                 (when (> running 0)
                   (format "%d subagent%s" running (if (= running 1) "" "s")))))))
    ;; The `* ' at column zero makes the line an outline heading, so
    ;; outline navigation treats the block as a document.  It stays inside
    ;; the make-visitable call so the whole line, star included, is the
    ;; visitable region.
    ;;
    ;; `agent-river-line' is marked whether or not the session turned out
    ;; to be visitable: a line the motion can stop on and a line RET can
    ;; act on are different questions, and tying them together would make
    ;; `n' skip every session agent-shell does not host.
    ;;
    ;; `agent-river-block' is what a redraw finds the line by, a second
    ;; property rather than `agent-river-session' reused, since that one
    ;; is only set when the session is visitable -- point would come home
    ;; for hosted sessions and be dropped at the top for the rest.
    (propertize
     (agent-river--make-visitable
      (concat (agent-river--star state)
              (mapconcat #'identity parts " · "))
      (agent-river-state-id state))
     'agent-river-line 'session
     'agent-river-block (agent-river-state-id state))))

;;; Moving about the HUD
;;
;; The map's keys, for the grains these buffers hold: every line worth
;; stopping on, and in the log the lines that want attention.  A session
;; line here is a map entry; a log line is what neither other view has an
;; analogue for and rides the fine grain with the entries.
;;
;; Which lines those are is read off `agent-river-line', marked where the
;; line is built -- not matched by a regexp over the rendered text, which
;; is customisable and would let a rendering change what `n' stops on.

(defcustom agent-river-notable-kinds '("fail" "signal" "note" "artifact")
  "Event kinds `agent-river-next-notable\=' stops on.

The lines someone scanning a long log is looking for: what broke, what the
agent was told, and what was seen outside the hook stream.  Reasoning and
tool calls are the log\='s bulk rather than its landmarks, which is the whole
distinction this motion exists to make.

`artifact\=' is here for the last of those reasons and not as a fourth one.
A note is something Emacs saw that no hook could; a record arriving is
something *nobody* in the session saw, which is one step further out again
-- and it is most often the reason to look at the log at all, since it
arrives when nothing else is happening.  A producer noisy enough to make
this motion useless is a producer that has made the log useless, and the
answer is the same either way: take the kind out of this list, or send
less."
  :type '(repeat string))

(defun agent-river--entry-line-p ()
  "Return non-nil on a line any motion may stop on."
  (and (get-text-property (line-beginning-position) 'agent-river-line) t))

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

(defun agent-river--scan (count test &optional settle)
  "Move to the COUNTth line satisfying TEST, forward when COUNT is positive.
Returns nil and leaves point alone when there is none -- the same bargain
`agent-river--map-scan' makes, for the same reason: a motion that lands
somewhere near is one the next RET acts on by mistake.

SETTLE decides where on the line point comes to rest, and defaults to
`agent-river--beginning-of-entry'.  It is an argument rather than a third
copy of the loop above: the approval queue walks lines of its own, drawn
with its own marker, and what differs between the two buffers is only
where the text starts."
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
      (funcall (or settle #'agent-river--beginning-of-entry))
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

(defun agent-river--panel-states (&optional id)
  "Return the live root sessions the block draws, ordered by label.

One function answers \"which sessions, and in what order\" for both
readings of the state: the block itself and `agent-river-markdown', which
claims to be a snapshot of it.  Two orderings would be two accounts of
one question, and the export's claim would be true only for as long as
somebody kept them in step.

ID narrows it to one.  Ordered by label rather than by whichever session
acted last, so a line does not move under the eye because another agent
took a step."
  (let (states)
    (maphash (lambda (key state)
               (when (and (agent-river--active-p state)
                          (or (null id) (equal key id)))
                 (push state states)))
             agent-river-registry)
    (sort states (lambda (a b)
                   (string< (or (agent-river-state-label a) "")
                            (or (agent-river-state-label b) ""))))))

(defun agent-river--panel-block ()
  "Return one top-level panel line per live session.

A buffer of lines rather than a header line, which is structurally
single-line: with two sessions it could only show whichever acted last,
and the step count would jump between them with nothing to say they were
different agents."
  (let ((states (agent-river--panel-states)))
    (when states
      (mapconcat #'agent-river--panel states "\n"))))

(defun agent-river--update-panel (state)
  "Note STATE as the session that last acted, for `agent-river-set-intent'.
Nothing to resolve: a subagent folds onto the session it was spawned from,
so STATE is already a session."
  (setq agent-river--current (agent-river-state-id state)))

(defun agent-river--buffer ()
  "Return the block buffer, creating and initialising it if needed."
  (let ((buffer (get-buffer-create agent-river-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-river-mode)
        (agent-river-mode)))
    buffer))

(defun agent-river--log-buffer ()
  "Return the log buffer, creating and initialising it if needed."
  (let ((buffer (get-buffer-create agent-river-log-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-river-log-mode)
        (agent-river-log-mode)))
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

(defun agent-river--insert-block ()
  "Draw the state block into the current buffer, which holds nothing else.

No separator and no end marker: the block is the whole buffer, so
`point-max' answers where it stops."
  (let ((block (agent-river--panel-block)))
    (when block
      (goto-char (point-min))
      (insert block "\n"))))

(defun agent-river--trim ()
  "Drop the oldest lines past `agent-river-max-entries'.
The log buffer holds nothing but log lines, so the count is of entries.
Oldest is at the top, so this trims the head -- counted back from the end
rather than forward from the start, because what is kept is the newest N
and where those begin depends on how many there are.

Everything it deletes is above whoever is reading, so their marker rides
the text, the way it does for the insertion at the other end."
  (when (> agent-river-max-entries 0)
    (save-excursion
      (goto-char (point-max))
      (forward-line (- agent-river-max-entries))
      (delete-region (point-min) (point)))))

(defun agent-river--block-here ()
  "Return the id of the session whose line point is on, or nil for none.
This is the map\\='s `agent-river--map-here' at the block\\='s grain, for the
same reason: the block is torn down and rebuilt, so a place in it has to
be named rather than remembered as a position.  A plain id, the block
being one line per session."
  (get-text-property (line-beginning-position) 'agent-river-block))

;;;###autoload
(defun agent-river-session-at-point ()
  "Return the id of the session the place point is in names, or nil.

For a command that acts on the session somebody is looking at, and the
reason it is worth a function: `agent-river--current\=' is whichever session
acted most recently, which with several running is quite possibly not the
one on the line -- and a command that acts on the wrong session reads
exactly like one that acted on the right one.  That is the default
`agent-river-link-artifact\=' refuses to fall back on, for the same reason.

Three places name a session exactly and this is all of them.  A **block
line** carries the id the rebuild finds it by.  An **agent-shell buffer**
holds the ACP session id, which is the string the hooks key the registry
with -- so this answers there wherever point is, the buffer being the
subject.  And a **line of the approval queue** names the request, which
knows whose door it is holding open; nil there while the
`permission-request\=' event has not landed yet, since the responder that
fills the entry first is not told whose question it is.

A log line answers nothing: it names an event, and the session inside a
paired call id is there to match an outcome to the line that opened it,
not to say what the reader is looking at.  A map line names an artifact,
and the parties drawn on it are labels rather than ids.

The id, never a state.  It may name a session the registry has folded
nothing for yet -- an agent-shell buffer has its id from the handshake and
the first hook event lands some moments later, which is the window
`agent-river-launch--resolve-pending\=' exists to wait out."
  (or (and (derived-mode-p 'agent-river-mode) (agent-river--block-here))
      (agent-river--shell-session)
      (and (derived-mode-p 'agent-river-approval-queue-mode)
           (when-let* ((here (agent-river--approval-here))
                       (offer (gethash (car here) agent-river--offers)))
             (plist-get offer :session)))))

(defun agent-river--block-goto (here)
  "Put point back on the block line HERE names, if the rebuild still has it.
At `point-min' otherwise: the head is where a reader whose session has
gone from the block resumes.  Point lands past the outline stars, where a
motion would have left it."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (if (equal here (agent-river--block-here))
          (setq found t)
        (forward-line 1)))
    (if found
        (agent-river--beginning-of-entry)
      (goto-char (point-min)))))

(defmacro agent-river--keeping-block-place (&rest body)
  "Run BODY, which tears the block down and rebuilds it, and keep point.

`save-excursion' cannot do this on its own, and the failure is silent:
the marker it restores is inside the region the rebuild deletes, so it
collapses to `point-min' and the new block is inserted in front of it --
point at the top of the buffer on every refresh tick, which is the block
redrawing itself under whoever navigated into it.

So a block line is restored by what it names.  Point on no line of the
block is nobody\='s place and goes to the head, which is also where a line
that has gone sends it."
  (declare (indent 0) (debug t))
  `(let ((here (agent-river--block-here)))
     (unwind-protect
         (progn ,@body)
       (if here
           (agent-river--block-goto here)
         (goto-char (point-min))))))

(defmacro agent-river--keeping-place (&rest body)
  "Run BODY, which writes a line at the end of the log, and keep point.

A reader is above both edits -- the new line goes on at the bottom and
the trim comes off the top -- so their marker rides the text it was on
rather than the offset it was at.  `save-excursion' would manage that
much; what it cannot do is the other case, which is why this exists.

Point at `point-max' is nobody\\='s place: that is the tail, and a reader
who has not moved follows it onto the new line rather than being left
one line above it.  Without this the `goto-char' in the body moved buffer
point, and in the selected window buffer point *is* window point -- so
the one window most likely to be the one being read was dragged along by
every tool call, whatever `agent-river--following-windows' had decided."
  (declare (indent 0) (debug t))
  `(let ((place (and (< (point) (point-max)) (copy-marker (point)))))
     (unwind-protect
         (progn ,@body)
       (if place
           (progn (goto-char place) (set-marker place nil))
         (goto-char (point-max))))))

(defun agent-river--tail-start ()
  "Return where the log\\='s last line begins, which is as far as following goes.

A window is following while it shows the end of the buffer and has not
been navigated, and `agent-river--follow' pins one to `point-max', so the
last line is exactly the span that means \"nobody has moved this\".  The
line alone, never more: any wider a span and a reader who had navigated
would still count as following, and the next tool call would pull them
off the line they chose.

The trailing newline is why this steps back a line.  `point-max' sits at
the start of an empty line after the newest entry, and a reader on the
entry itself has not moved either."
  (save-excursion
    (goto-char (point-max))
    (when (and (bolp) (> (point) (point-min)))
      (forward-line -1))
    (line-beginning-position)))

(defun agent-river--following-windows (buffer)
  "Return the windows on log BUFFER that are still showing its tail.

Read before the buffer is touched, because the tail is about to move.
Only these get pinned back afterwards: a window someone has scrolled or
navigated away from is one they moved on purpose, and snapping it to the
end on the next tool call would make the buffer unreadable by hand."
  (with-current-buffer buffer
    (let ((tail (agent-river--tail-start)))
      (seq-filter (lambda (window) (>= (window-point window) tail))
                  (get-buffer-window-list buffer nil t)))))

(defun agent-river--follow (buffer windows)
  "Pin WINDOWS on log BUFFER back to the tail.

Oldest to newest, so this is an ordinary log and this is the ordinary
thing to do with one: the newest entry is at the bottom and a window
nobody has moved stays on it.

`window-start' is computed rather than left to redisplay, which would
find point below the window and recentre: the newest line would land in
the middle with half a window of nothing under it, once per tool call.
`vertical-motion' counts *screen* lines through the window it is given,
so the answer stays right in a buffer where the long lines wrap."
  (with-current-buffer buffer
    (save-excursion
      (dolist (window windows)
        (when (window-live-p window)
          (goto-char (point-max))
          (set-window-point window (point))
          (vertical-motion (- (1- (window-body-height window))) window)
          (set-window-start window (point)))))))

(defun agent-river--fit-block-windows (buffer)
  "Size the side windows this package opened on block BUFFER to what it holds.

Asked after every redraw rather than once when the window appears, because
the block is a line per live session and that number moves: a window
fitted while one agent was working hides the second the moment it starts.
`agent-river-block-max-height' is what stops a busy morning pushing the
log off the screen.

Only the windows `agent-river-show' opened, which is what the
`agent-river-fit' parameter says.  A window somebody put the block in
themselves is theirs to size, and the rule for writing into windows the
user did not point this at is the one the observers keep.  A
`display-buffer-alist' entry matching this buffer counts as somebody: it
takes precedence over the action `agent-river-show' passes and supplies
its own parameters, so a reader who has said where the block goes has
said how tall it is in the same breath, and this leaves them to it."
  (dolist (window (get-buffer-window-list buffer nil t))
    (when (window-parameter window 'agent-river-fit)
      (fit-window-to-buffer window agent-river-block-max-height 1))))

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
                     (get-buffer agent-river-log-buffer-name))))
    (when buffer
      (with-current-buffer buffer
        (save-excursion
          ;; Backwards from the end: the call being answered is nearly
          ;; always one of the last few lines, so the walk stops quickly
          ;; rather than reading a hundred lines of history.
          (goto-char (point-max))
          (let (found)
            (while (and (not found) (not (bobp)))
              (forward-line -1)
              (when (equal call (get-text-property (point) 'agent-river-call))
                (setq found t)))
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
                (insert (apply #'propertize (concat " " outcome) props))
                (put-text-property start (line-end-position)
                                   'agent-river-call nil)
                t))))))))

;;;###autoload
(defun agent-river-log (kind detail &optional label call)
  "Append DETAIL to the log as an event of KIND, tagged with session LABEL.
CALL names the tool call this line opens, so its outcome can later be
written onto this line instead of taking one of its own.
This is the view half, usable on its own; `agent-river-observe' is the
half that also folds, and the half that draws the block."
  (let* ((buffer (agent-river--log-buffer))
         ;; Asked before the edit, because the edit moves the head.
         (following (agent-river--following-windows buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        ;; Oldest to newest: the new line goes on at the bottom, the
        ;; oldest come off the top, and a reader keeps their place via
        ;; `agent-river--keeping-place'.
        (agent-river--keeping-place
          (goto-char (point-max))
          (insert (agent-river--render kind detail label call) "\n")
          (agent-river--trim))))
    ;; No window is opened here, whatever `agent-river-auto-display' says
    ;; -- that's the block's.  A log opening on every event would reopen
    ;; on the one right after a reader closed it.  The buffer is still
    ;; written and created; being there to be opened is all it owes.
    (agent-river--follow buffer following)
    kind))

(defvar agent-river--block-shown nil
  "Non-nil once the block has been on screen in this Emacs.

What `agent-river-auto-display' reads to open the block once and not
again.  A plain flag rather than anything derived, because the fact it
records is that the offer has been made -- a window deleted afterwards
leaves nothing behind to ask, so \"is one showing right now\" would
reopen the block on the event after every time the reader closed it.

Set three ways, all of them the block having been on screen: the event
that opens it, `agent-river-show' being asked, and an event that finds a
window already showing it.  The third is what keeps a reload honest -- a
reload clears the flag, and without it a block that has been up all
morning would be reopened once more the next time the reader closed it.

Never cleared, `agent-river-reset' included: forgetting what the sessions
did is not a request for a window.")

;;;###autoload
(defun agent-river-show ()
  "Display the state block in a side window on the right.

The `agent-river-fit' parameter is what marks this window as one to keep
sized to the block.  Only the windows opened here carry it: a window
somebody put the block in themselves is theirs, and resizing it under
them would be this package writing into a window it was never pointed
at."
  (interactive)
  (setq agent-river--block-shown t)
  (display-buffer (agent-river--buffer)
                  `((display-buffer-in-side-window)
                    (side . right)
                    (slot . 0)
                    (window-width . ,agent-river-window-width)
                    (window-parameters . ((no-delete-other-windows . t)
                                          (agent-river-fit . t)))))
  (agent-river--fit-block-windows (agent-river--buffer)))

;;;###autoload
(defun agent-river-show-log ()
  "Display the event log in a side window under the block.

The slot below the block\='s: the state on top, the stream beneath it.
This is the window that scrolls."
  (interactive)
  (display-buffer (agent-river--log-buffer)
                  `((display-buffer-in-side-window)
                    (side . right)
                    (slot . 1)
                    (window-width . ,agent-river-window-width)
                    (window-parameters . ((no-delete-other-windows . t))))))

;;;###autoload
(defun agent-river-clear ()
  "Empty the event log.  The folded state is left alone.

The block is left alone too, and there is nothing here for it: it is
derived, redrawn from the registry by the next event, and emptying it
would put a picture of the state on screen that is wrong until something
happens.  `agent-river-reset' is the one that forgets what it is drawn
from."
  (interactive)
  (with-current-buffer (agent-river--log-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer))))

;;;###autoload
(defun agent-river-reset ()
  "Forget all folded state.  The buffer is left alone."
  (interactive)
  (clrhash agent-river-registry)
  ;; The second folded table goes with the first, for the same reason: a
  ;; struct change can leave an artifact record short a slot too.  Kept
  ;; apart from `agent-river-forget-artifacts', which drops only where the
  ;; work was and keeps the subjects.
  (clrhash agent-river-artifacts)
  ;; Which way in owns a session, and which tool calls are in flight, are
  ;; state about the same sessions: left behind, they'd refer to states
  ;; that no longer exist.  The subscriptions themselves survive, since
  ;; they belong to buffers, not to what was folded out of them.
  (clrhash agent-river--source)
  (clrhash agent-river--tool-calls)
  (clrhash agent-river--shell-sessions)
  ;; The usage table goes too, keyed by the sessions being forgotten.
  ;; What it loses is the shape of the last hour, not the totals, which
  ;; come back with each session's next event.  A retired sampler is also
  ;; given another go here, since a reload may well have fixed it.
  (clrhash agent-river--usage)
  (setq agent-river--usage-broken nil)
  (agent-river--stop-timer)
  (agent-river--stop-spinner))


;;;###autoload
(defun agent-river-forget-artifacts ()
  "Forget which files the sessions have been in, keeping the sessions.

For the moment work lands -- a merge, a release -- after which the files
it was in are history rather than context.  Nothing drops out of the map
on its own, so this is the gesture that says the work is over: only you
know when that moment came.

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

(defun agent-river--forget-reported (text &optional kind)
  "Say TEXT happened as an event of KIND, and redraw the views it changed.

KIND defaults to `note', which is what a forget on a session is.  A
forget on an artifact passes `artifact', so the line is coloured by what
it was about rather than by which command wrote it.

Logged only into a log buffer that already exists.  `agent-river-log'
would otherwise create the buffer and `agent-river-auto-display' pop a
window for it, which is a lot of furniture to move in answer to a command
run from the map.  The block is redrawn unconditionally instead, since
that costs nothing where its buffer is gone and the numbers on it are
exactly what was just forgotten.

The map is drawn rather than marked dirty: its timer only runs while an
agent is working, so a flag set between turns would sit there until the
next one and the view would go on naming what was just forgotten.  Which
is why the artifact commands come through here too -- they remove a
subject rather than fold it, so no observer hook hears about them."
  (when (get-buffer agent-river-log-buffer-name)
    (agent-river-log (or kind "note") text))
  (agent-river--redraw-block)
  (agent-river--map-draw)
  (message "agent-river: %s" text))

(defun agent-river--artifact-gone-p (state key)
  "Return non-nil when STATE's artifact KEY names a file that is not there.

Placed the way every other view places a key -- through
`agent-river--artifact-absolute', so the anchor wins over the cwd for a file
that was reached from outside it, and so this cannot decide a file is
gone by looking for it in a directory no agent ever opened.

A key that cannot be placed at all is not gone but unplaceable, and is
kept: a state folded without a cwd would otherwise have every artifact it
ever recorded swept away by a command that never found any of them."
  (let ((abs (agent-river--artifact-absolute
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
struck-through lines are a list of files nobody is looking for, and only
you know when that moment has come.  So this is a command and not a
rule.

Measured against the disk, not against the strike-through.  An entry is
also drawn as missing when it was reached through an anchor the root
being listed has nothing to do with, and that file is not gone but
elsewhere -- sweeping it would throw away a measurement about a file that
still exists.  Such a line therefore stays struck through afterwards,
which looks like the command missing one and is the command refusing one.

It asks first, because nothing undoes it."
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
             (progn
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
  "Redraw the state block, if its buffer is still there.

The timer\='s way in, and the one that creates nothing: get-buffer rather
than `agent-river--buffer', because a tick must never resurrect a buffer
the user has killed.  `agent-river--update-block' is the event\='s way in,
which may."
  (let ((buffer (get-buffer agent-river-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (agent-river--keeping-block-place
            (erase-buffer)
            (agent-river--insert-block))))
      (agent-river--fit-block-windows buffer))))

(defun agent-river--update-block ()
  "Draw the block for something that has just been folded.

The event\='s way in, where `agent-river--redraw-block' is the timer\='s: this
creates the buffer when it has been killed and may open a window for it
under `agent-river-auto-display', and a tick must do neither.  A buffer
the user killed stays killed until something happens, and then it is the
something that brings it back.

A *window* the user closed is the other way round and stays closed: the
opening is offered once per Emacs, and `agent-river--block-shown' is what
remembers the offer was made.  Whether a window is showing it is still
asked, and answers a different question -- has it ever been on screen
versus is it on screen now -- which is why the branch where it is sets
the flag rather than doing nothing.

Called from each of the four places a state changes, not from wherever a
line is logged: an outcome written onto the line that opened its call
writes no line of its own."
  (let* ((buffer (agent-river--buffer))
         (shown (get-buffer-window buffer t)))
    (agent-river--redraw-block)
    (if shown
        ;; Finding it on screen is the offer having been made as surely as
        ;; making it is; recording that stops a reload -- which happens
        ;; several times an hour and re-arms the flag -- from reopening a
        ;; window the reader closes an hour later.
        (setq agent-river--block-shown t)
      (when (and agent-river-auto-display (not agent-river--block-shown))
        (agent-river-show)))))

;; The map's keys, on the same gestures, since the views are views of one
;; state and learning each separately buys nothing.  SPC and DEL give up
;; `special-mode's scrolling for line motion, the way dired's do.
;;
;; Which grains each buffer has is decided by what it holds.  The block has
;; the fine grain alone -- one line per live session and nothing under it,
;; no landmarks since nothing in it is a log line.  The log is the other
;; way round.  A key bound where its content is not is worse than an
;; unbound one: pressing it answers with an error about there being no
;; further anything, which reads as the state being empty rather than as
;; the question being the wrong one to ask here.
(define-key agent-river-mode-map (kbd "n") #'agent-river-next-line)
(define-key agent-river-mode-map (kbd "p") #'agent-river-previous-line)
(define-key agent-river-mode-map (kbd "SPC") #'agent-river-next-line)
(define-key agent-river-mode-map (kbd "DEL") #'agent-river-previous-line)
(define-key agent-river-mode-map [remap next-line] #'agent-river-next-line)
(define-key agent-river-mode-map [remap previous-line] #'agent-river-previous-line)
;; RET works on a session line through a keymap text property, which leaves
;; it doing nothing everywhere else.  Bound here it says why instead.
(define-key agent-river-mode-map (kbd "RET") #'agent-river-visit-session)
;; `special-mode' puts `revert-buffer' on g, which has nothing to revert to.
(define-key agent-river-mode-map (kbd "g") #'agent-river-refresh)
;; The one key here that writes to a session rather than reading one, and
;; it still asks which option: the block is a view, so a keystroke that
;; granted `allow_always' outright would be the wrong place for a typo.
;; Bound whether or not `agent-river-approvals-mode' is on, so pressing it
;; answers with a sentence rather than nothing happening.
(define-key agent-river-mode-map (kbd "a") #'agent-river-answer)
;; The log hangs off the block rather than the other way about: this is the
;; buffer that is opened first and the one a reader comes back to, so the
;; way to the other is here and there is none going back.  `q' is.
(define-key agent-river-mode-map (kbd "l") #'agent-river-show-log)

;; The log's own two grains: every line, and the landmarks among them.  No
;; `M-n', since a log line has no coarse structure over it to walk.
(define-key agent-river-log-mode-map (kbd "n") #'agent-river-next-line)
(define-key agent-river-log-mode-map (kbd "p") #'agent-river-previous-line)
(define-key agent-river-log-mode-map (kbd "SPC") #'agent-river-next-line)
(define-key agent-river-log-mode-map (kbd "DEL") #'agent-river-previous-line)
(define-key agent-river-log-mode-map [remap next-line] #'agent-river-next-line)
(define-key agent-river-log-mode-map [remap previous-line] #'agent-river-previous-line)
(define-key agent-river-log-mode-map (kbd ">") #'agent-river-next-notable)
(define-key agent-river-log-mode-map (kbd "<") #'agent-river-previous-notable)
;; Nothing here can be behind -- the log is written as it happens -- so `g'
;; redraws the other buffer instead, still better than `special-mode's
;; `revert-buffer', which would error about a file this buffer has not got.
(define-key agent-river-log-mode-map (kbd "g") #'agent-river-refresh)

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
;; whole block that often would cost far more than the animation is worth
;; and drag it out from under anybody reading it.  So this one writes a
;; `display' property onto the stars the panel already marked and derives
;; nothing else, which is what makes it safe to run several times a second.
;;
;; Whether to keep running is read off those marks rather than the
;; registry: the panel has already decided the same question when it drew
;; the stars, so asking again would only be an indexed lookup answering
;; what is already known.  The cost is a redraw from the refresh timer
;; before it retires, since the marks are also what has to be taken away
;; when a turn ends with no event to announce it.

(defvar agent-river--spinner-timer nil
  "Repeating timer animating the session markers, or nil while none runs.")

(defun agent-river--spinning-p (buffer)
  "Return non-nil while BUFFER's state block has a marker to animate.

The gate the animation runs on, and deliberately read off the rendering
rather than off the registry.  `agent-river--star' marks a star exactly
when `agent-river--state-working-p' holds for that session, so this is the
same question one step later and cannot answer differently -- and it
derives nothing, where asking the registry would ask
`agent-river--active-p' of every session several times a second."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (text-property-not-all (point-min) (point-max)
                                     'agent-river-spinner nil)
              t))))

(defun agent-river--spinner-paint (buffer &optional stop)
  "Show every spinning star in BUFFER the frame its own session is on.
With STOP, take the frames off and leave the bare stars instead.

Each star carries its session's phase as the value of its
`agent-river-spinner' property, so what to draw is read off the mark, and
the stars are found by that property rather than by looking for one in the
text: the property is also what says which session a star belongs to,
which no search of the text could answer.

`with-silent-modifications' because this is not an edit anyone should be
able to undo, and at this rate an undo list of frame changes would grow
without bound."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (with-silent-modifications
        (let ((end (point-max))
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
painting, and whether to carry on is `agent-river--spinning-p' -- an
answer the panel already reached when it drew the block."
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

;;; Reading the artifact tables
;;
;; One derivation, and every view of those tables is built on it rather
;; than walking the registry for itself: the map's domain sections and
;; the parties on its lines both answer from the same walk.
;;
;; Nothing here folds.  Readings are taken from the tables on every draw,
;; so no two readers can disagree about them and the fold stays pure.
;;
;; The keys deliberately cannot address a file on disk: `agent-river--rel'
;; normalises them relative to the session cwd, a bare basename outside
;; it, so one file reached from two checkouts is one key.
;; `agent-river--artifact-absolute' puts a key and its anchor back
;; together, and answers nil for a key nothing can place.

(defun agent-river--party-label (state)
  "Return the name STATE goes by in a view that shows several of them.

The session's label, and nothing else.  A delegated touch lands in the
session's own tables, so a party is a session and the map draws one name
per agent."
  (or (agent-river-state-label state) "?"))

(defvar agent-river--artifact-memo nil
  "A one-draw cache of `agent-river--artifact-entries', or nil when not caching.

Bound to a fresh box by `agent-river--map-draw' and thrown away with it,
which is why there is no invalidation here to get wrong: a draw is
synchronous Lisp, nothing on that path folds, and the binding cannot
outlive the walk it was made for.  A contributor's `:refresh' may start a
subprocess, but its sentinel runs later and under no binding of this.

Outside a draw this stays nil and every call walks the registry, which is
what every other reader wants -- a question asked a second later is
asking about a second later.")

(defun agent-river--artifact-entries (&optional scope)
  "Return one plist per artifact of every folded session.

Each carries `:party' (`agent-river--party-label'), `:cwd' (the anchor its
`:file' is relative to), `:file', the cumulative `:touches', `:writes'
and `:last'.  `:anchor' is the real directory for a `:file' the cwd cannot
place, and nil for everything under it -- see `agent-river--anchor'.
SCOPE is `session' for the whole session, `task' or nil for the current
task.

The one derivation every view of the artifact tables is built from,
rather than each walking the registry for itself: the map's roots, its
listing and its parties all have to answer from the same walk, and a
second walk is a second place for them to fall out of step.

`:touches' is the raw cumulative count, straight off the tables, which is
also what `agent-river--hottest' and `agent-river--artifact-list' render
as \"6 touches\".  Never aged or weighted: a number that changed with time
alone would disagree with itself between two redraws with nothing having
happened in between."
  (let ((key (or scope 'task)))
    (if (and agent-river--artifact-memo (eq (car agent-river--artifact-memo) key))
        (cdr agent-river--artifact-memo)
      (let ((entries (agent-river--artifact-walk scope)))
        (when agent-river--artifact-memo
          (setcar agent-river--artifact-memo key)
          (setcdr agent-river--artifact-memo entries))
        entries))))

(defun agent-river--artifact-walk (&optional scope)
  "Walk the registry for `agent-river--artifact-entries'.
Split out so the cache above and the walk cannot come apart.  The list is
shared between every reader within one draw, so nothing may mutate it --
each caller sorts a list of its own instead."
  (let (entries)
    (maphash
     (lambda (_id state)
       (let ((party (agent-river--party-label state))
             (cwd (agent-river-state-cwd state))
             (anchors (agent-river-state-anchors state)))
         (maphash (lambda (path entry)
                    ;; The cwd and the anchor ride along; no key is placed
                    ;; here.  What needs a key as a path on disk asks
                    ;; `agent-river--artifact-absolute' for one at a time
                    ;; (`agent-river--artifact-gone-p'), and the map lists
                    ;; records without placing them at all.
                    (push (list :party party
                                :cwd cwd
                                :anchor (and anchors (gethash path anchors))
                                :file path
                                :touches (or (plist-get entry :touches) 0)
                                :writes (or (plist-get entry :writes) 0)
                                :last (plist-get entry :last))
                          entries))
                  (if (eq scope 'session)
                      (agent-river-state-artifacts state)
                    (agent-river-state-task-artifacts state)))))
     agent-river-registry)
    entries))

(defun agent-river--artifact-absolute (entry)
  "Return ENTRY's file as an absolute name, or nil when nothing anchors it.

Nil for a state folded with no cwd -- one restored from before the slot
existed, or reported by a source that names none.  The answer is then
unknown, and guessing at it would place files in directories no agent
ever opened.

A key that is a bare name is resolved as a file sitting directly in the
cwd, which is what it almost always is.  `agent-river--rel' degrades a
file *outside* the cwd to the same shape, and resolving one of those
against the cwd would place it in a tree it has nothing to do with -- so
those carry an `:anchor', the directory they were really folded from, and
it wins over the cwd here."
  (let ((cwd (or (plist-get entry :anchor) (plist-get entry :cwd)))
        (file (plist-get entry :file)))
    (and cwd (not (string-empty-p cwd)) file (not (string-empty-p file))
         ;; A key somebody declared is not a path: resolving it here would
         ;; turn `inc:INC-444' into `/repo/inc:INC-444', a name in a tree
         ;; it has nothing to do with.  Nil is what the caller does the
         ;; right thing with -- a key that cannot be placed is left alone.
         ;; Undeclared is the only kind resolved, per
         ;; `agent-river--key-domain' answering nil.
         (null (agent-river--key-domain file))
         (expand-file-name file (file-name-as-directory cwd)))))

;;; The map -- what has arrived, and who is on it
;;
;; The view of `agent-river-artifacts': one section per domain, one line
;; per record, each annotated with whoever has reached it.  Derived from
;; the tables on every redraw, so it accumulates nothing of its own and
;; can say nothing the tables do not.
;;
;; **The listing is the artifact table.** There is no listing function to
;; write and nothing is read off disk: a record carries its own name,
;; whether it is over, and whatever context its producer put on it, and
;; the sessions' tables say who has reached it.
;;
;; What has *no* other answer is the thing that arrived on its own -- an
;; incident routed to you, a review requested, a build that broke --
;; which matters most when no agent is running, and which nothing in the
;; event stream could ever produce.  That is what this view is for, and
;; the queue of what nobody has picked up is the line it exists to carry.
;;
;; Nothing here is a path.  A section root is `inc:', an identity built
;; from the domain, and a line is the artifact key itself -- so there is
;; no placing, no anchor and no cwd on this side.  Zooming is by section:
;; RET on a heading goes in, `^' comes back out.

(defcustom agent-river-map-scope 'session
  "Which artifact frame the parties on a map line are read from.

`session' rather than `task', because the map is opened to find out who
has been on a record: a frame cleared by every prompt would drop half the
names each time an agent was given its next instruction."
  :type '(choice (const task) (const session)))

(defcustom agent-river-map-refresh-interval 3
  "Seconds between map redraws while anything is still moving.

The map is redrawn on a timer rather than on every event, and that is
deliberate.  Drawing a whole listing on each tool call means a redraw
thousands of times a task, and every one of them moves point in a buffer
someone is reading.  An event marks the map dirty; this decides how often
dirt is worth a redraw."
  :type 'number)

(defcustom agent-river-map-contended-marker "⇄"
  "Marker for a record more than one agent has reached.

A marker rather than a colour.  The listing already spends colour on what
is over, and encoding a second, unrelated fact the same way leaves a
reader unable to say which of them any given colour means.  This is also
the thing most worth being able to scan a whole listing for."
  :type 'string)

(defcustom agent-river-map-open-marker "▾"
  "Marker for a node whose contributed rows are shown beneath it.
In the same gutter as the other two, because \"there is more here\" is a
fact about the line and is scanned the same way."
  :type 'string)

(defcustom agent-river-map-closed-marker "…"
  "Marker for a node whose contributed rows are folded away.

Deliberately not a sideways triangle, which is what a folded outline
usually gets: the gutter is three columns of unrelated facts, each read
straight down the listing, and a shape that only means something once it
has been held against `agent-river-map-open-marker' a column over is one
a reader has to decode rather than scan.  An ellipsis says what a closed
node has to say on its own -- there is more here that you are not being
shown."
  :type 'string)

(defun agent-river--map-touches (parties)
  "Return the total touch count across PARTIES."
  (apply #'+ (mapcar (lambda (party) (plist-get party :touches)) parties)))

(defun agent-river--map-later (a b)
  "Return the later of times A and B, either of which may be nil."
  (cond ((null a) b)
        ((null b) a)
        ((time-less-p a b) b)
        (t a)))

(defun agent-river--map-by-last (cells)
  "Return CELLS -- each (NAME . TIME) -- most recent first.
A cell with no time sorts last, which is what a section whose subject has
never been touched is."
  (sort cells (lambda (a b)
                (let ((a-time (cdr a))
                      (b-time (cdr b)))
                  (if (and a-time b-time)
                      (time-less-p b-time a-time)
                    (and a-time (not b-time)))))))

;;; Domains -- what a section of the map is a section of
;;
;; A key an agent reached is a path: `agent-river--rel' made it relative to
;; the session cwd, and `agent-river--artifact-absolute' puts the two back
;; together -- against the anchor where the cwd cannot.
;;
;; An artifact declared from outside has no such answer.  `inc:INC-444' is
;; a perfectly good key, but resolved against a cwd it becomes
;; `/repo/inc:INC-444', a file that does not exist in a tree it has
;; nothing to do with -- the same mistake the anchors were folded to
;; stop, one domain over.
;;
;; So: a key is either **declared** -- it has a record, and therefore a
;; domain, read off the artifact table (`agent-river--key-domain') and
;; never parsed out of the key -- or it is not, and then it is a path and
;; nothing else.  A domain heads a section of its own, and the section's
;; listing is the artifact table itself, which is the whole reason there
;; is no per-domain listing function to write: a record already carries
;; its name, whether it has ended, and whatever context its producer put
;; on it.
;;
;; A domain is therefore declared by arriving and by nothing else: a
;; producer that passes `:domain' gets a section headed by that name,
;; because a thing that has arrived must not need configuration before it
;; can be seen.

(defun agent-river--key-domain (key)
  "Return the domain KEY was declared with, or nil when nobody declared it.

Read off `agent-river-artifacts' rather than parsed out of the key, which
matters more than it looks.  A prefix rule would have to decide what
`c:/tmp/x' means, and would answer for keys nobody ever declared -- where
this answers for what a producer actually said.  Which is the same line
the artifact table itself is drawn on.

**Nil is the whole of what an undeclared key is**, and the callers read it
that way: a key nothing declared is a path relative to the session cwd, so
it is the one kind `agent-river--artifact-absolute' will resolve and the
one kind that heads no section.  Never a pseudo-domain standing for the
absence of a record, which could itself be declared and would then mean
exactly what no record means.  A domain is what somebody said; nothing
said is nil."
  (let ((artifact (and key (not (string-empty-p key))
                       (gethash key agent-river-artifacts))))
    (and artifact (agent-river-artifact-domain artifact))))

(defun agent-river--domain-root (domain)
  "Return the section root standing for DOMAIN.
A string, because everything downstream of the draw compares roots with
`equal' and puts them on text properties; it is an identity and never a
path, and `agent-river--map-domain' is what tells the two apart."
  (format "%s:" domain))

(defvar agent-river--section-memo nil
  "A one-draw cache of `agent-river--domain-sections\=', or nil when not caching.

Bound to a fresh box by `agent-river--map-draw\=' and thrown away with it,
the way `agent-river--artifact-memo\=' is and for the same reason: a draw is
synchronous Lisp, nothing on that path declares an artifact, and the
binding cannot outlive the walk it was made for -- so there is no
invalidation here to get wrong.

Outside a draw this stays nil and every call reads the table, which is what
a caller outside a draw is asking about.")

(defun agent-river--domain-sections ()
  "Return an alist of section root to the domain it stands for.

The one derivation behind both readings below, and the one walk of
`agent-river-artifacts\=' that either of them costs.  `agent-river--map-domain\='
asks this question once per node per draw, so held as an alist the lookup
is an `assoc\=' and the roots are built once rather than per node."
  (let ((box agent-river--section-memo))
    (if (and box (car box))
        (cdr box)
      (let (sections)
        (dolist (domain (agent-river-domains))
          (push (cons (agent-river--domain-root domain) domain) sections))
        (setq sections (nreverse sections))
        (when box (setcar box t) (setcdr box sections))
        sections))))

(defun agent-river--map-domain (root)
  "Return the domain ROOT is the section of, or nil when ROOT is a directory.

The one predicate the rest of the draw dispatches on.  Asked rather than
inferred from the string's shape: a directory can be called anything, and
a listing that decided what to do by looking at a name would eventually
run git over somebody's incident queue."
  (cdr (assoc root (agent-river--domain-sections))))

(defun agent-river--domain-label (domain)
  "Return DOMAIN's section heading: the domain, as it was declared.

There is nothing to register a prettier name in, because a declared second
name for something the table already holds is right only while somebody
keeps the two in step.  The domain itself is what every key in the section
is prefixed with and what \\[agent-river-link-artifact] asks for, so it is
the one name a reader has already seen."
  (symbol-name domain))

(defun agent-river--map-domain-roots (&optional scope)
  "Return one (ROOT . LAST) per domain with something in it, newest first.

LAST is the most recent thing to have happened in the domain, taken from
the artifact records rather than from the sessions: a queue with nothing
assigned to it is still a queue that just received something, and ordered
by what agents did it would sink below every tree somebody is typing in --
which is precisely backwards for the case this exists for."
  (let ((seen (make-hash-table :test 'equal))
        (entries (agent-river--artifact-entries scope))
        result)
    ;; What the sessions have reached, so a domain somebody is working in
    ;; sorts by that rather than by when its records last changed.
    (dolist (entry entries)
      (let ((domain (agent-river--key-domain (plist-get entry :file))))
        (when domain
          (puthash domain
                   (agent-river--map-later (gethash domain seen)
                                           (plist-get entry :last))
                   seen))))
    (maphash (lambda (_key artifact)
               (let ((domain (agent-river-artifact-domain artifact)))
                 (puthash domain
                          (agent-river--map-later
                           (gethash domain seen)
                           (agent-river-artifact-last artifact))
                          seen)))
             agent-river-artifacts)
    (maphash (lambda (domain last)
               (push (cons (agent-river--domain-root domain) last) result))
             seen)
    (agent-river--map-by-last result)))

(defun agent-river--domain-parties (domain scope)
  "Return a hash of artifact key to the parties that reached it, in DOMAIN.

Heaviest first within a key, and the whole of the aggregation: an entry
counts under the key itself.

SCOPE is `session\' or `task\', which decides nothing here beyond which of
the two frames the entries were walked from."
  (let ((by-key (make-hash-table :test 'equal)))
    (dolist (entry (agent-river--artifact-entries scope))
      (let ((key (plist-get entry :file)))
        (when (and key (eq (agent-river--key-domain key) domain))
          (let* ((parties (or (gethash key by-key)
                              (puthash key (make-hash-table :test 'equal) by-key)))
                 (party (plist-get entry :party))
                 (cell (gethash party parties)))
            (puthash party
                     (list :touches (+ (or (plist-get cell :touches) 0)
                                       (plist-get entry :touches))
                           :writes (+ (or (plist-get cell :writes) 0)
                                      (or (plist-get entry :writes) 0))
                           :last (agent-river--map-later
                                  (plist-get cell :last) (plist-get entry :last)))
                     parties)))))
    (let ((out (make-hash-table :test 'equal)))
      (maphash
       (lambda (key parties)
         (let (plists)
           (maphash (lambda (party cell)
                      (push (list :party party
                                  :touches (plist-get cell :touches)
                                  :writes (plist-get cell :writes)
                                  :last (plist-get cell :last))
                            plists))
                    parties)
           (puthash key (sort plists (lambda (a b)
                                       (> (plist-get a :touches)
                                          (plist-get b :touches))))
                    out)))
       by-key)
      out)))

(defun agent-river--map-entries (root &optional scope)
  "Return the records ROOT's section lists, heaviest first.

One plist per record: `:name' the key, `:shown' what to call it, `:parties'
whoever has reached it, `:missing' whether it has ended, `:last' when
anything last happened to it.

**The listing is the artifact table itself**, which is why there is no
listing function beside this one: a record already carries its name,
whether it is over and whatever context its producer put on it.  Nothing
is read off disk -- what this view is for is the thing that arrived on its
own and has nobody on it yet.

Every record in the domain, whether or not any agent has reached it: an
unreached record is a thing nobody has picked up, which is the single most
important line this view can carry.

`:missing' is the record having ended, which draws it struck through: this
was worked on and is over, which is history and worth keeping on screen
until somebody says otherwise.

Ordered by touch count and then by recency, so the ones being worked on
rise and a queue with nothing happening in it is in the order things
arrived."
  (let* ((domain (agent-river--map-domain root))
         (parties (and domain (agent-river--domain-parties domain scope)))
         entries)
    (when domain
      (maphash
       (lambda (key artifact)
         (when (eq (agent-river-artifact-domain artifact) domain)
           (push (list :name key
                       :parties (gethash key parties)
                       :missing (and (agent-river-artifact-gone artifact) t)
                       ;; What the line shows, where the key is machinery and
                       ;; the name is what a human calls it.
                       :shown (agent-river-artifact-name artifact)
                       :last (agent-river-artifact-last artifact))
                 entries)))
       agent-river-artifacts))
    (sort entries
          (lambda (a b)
            (let ((wa (agent-river--map-touches (plist-get a :parties)))
                  (wb (agent-river--map-touches (plist-get b :parties))))
              (if (= wa wb)
                  (time-less-p (plist-get b :last) (plist-get a :last))
                (> wa wb)))))))

(defun agent-river--rows-artifact (_root nodes)
  "Return one row per thing known about the artifact each of NODES is.

The context a producer carried in, which this package has never read a
value out of and does not start here: the cells are rendered as they
arrived.  That is what lets a record hold a severity, a body and a URL
without this file having to learn about any of them -- and it is why the
rows are escaped like every other contributed row, since a context cell is
the least of our text there is.

Gated on the lookup rather than on the section being a domain's, which is
one special case fewer and strictly more use: a record declared against a
key the map already draws annotates that line too.  It is also what makes
this cheap -- the artifact table holds only what was declared into it, so
the lookup misses for every ordinary line on the map."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (node nodes)
      (let* ((key (plist-get node :path))
             (artifact (gethash key agent-river-artifacts))
             rows)
        (when artifact
          (dolist (cell (agent-river-artifact-context artifact))
            (push (list :key (format "context/%s" (car cell))
                        ;; Ahead of the parties: for a record that arrived on
                        ;; its own, what it *is* is the question, and who has
                        ;; since been near it is the follow-up.
                        :rank 0
                        :face 'agent-river-note
                        :text (format "%s: %s" (car cell) (cdr cell)))
                  rows))
          (let ((notes (agent-river-artifact-notes artifact)))
            (when notes
              (push (list :key "artifact/notes"
                          :rank 0
                          :face 'agent-river-stale
                          :text (format "%s · %s ago"
                                        (cdr (car notes))
                                        (agent-river--ago (car (car notes)))))
                    rows)))
          (when rows (puthash key (nreverse rows) table)))))
    table))

(defun agent-river--map-merge-parties (nodes)
  "Return the parties of NODES summed into one list, heaviest first.
How a section heading's reading is made: it is the aggregate of the
records listed under it and never a tally of its own, so the heading and
its records can never disagree about who has been where."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (node nodes)
      (dolist (party (plist-get node :parties))
        (let* ((cell (gethash (plist-get party :party) table))
               (last (agent-river--map-later (plist-get cell :last)
                                             (plist-get party :last))))
          (puthash (plist-get party :party)
                   (list :party (plist-get party :party)
                         :touches (+ (or (plist-get cell :touches) 0)
                                     (plist-get party :touches))
                         :writes (+ (or (plist-get cell :writes) 0)
                                    (or (plist-get party :writes) 0))
                         :last last)
                   table))))
    (let (out)
      (maphash (lambda (_party cell) (push cell out)) table)
      (sort out (lambda (a b) (> (plist-get a :touches) (plist-get b :touches)))))))

(defconst agent-river-map-buffer-name "*agent-river-map*"
  "Name of the artifact map buffer.")

(defvar-local agent-river--map-root nil
  "The directory the map buffer is currently showing.
When nil, the map shows all touched roots; when set, it shows only that root.")

(defvar-local agent-river--map-folds nil
  "Alist of absolute entry path to whether its rows are shown.
Only the entries that were toggled by hand: everything else draws closed,
because a row is detail and waits to be asked for.  A fold made by hand
survives the redraws, which is the whole reason this is data rather than
outline overlays -- the buffer is rebuilt every few seconds and an overlay
fold would spring open on each one.

Keyed on the path rather than the name, because the overview shows
several roots at once and `src' under one of them is not `src' under
another.  Being absolute, the keys also survive zooming into a section.")

(defvar agent-river--map-drawn nil
  "When the map was last drawn, or nil before the first time.
Read by `agent-river-map-contribute', which draws on an answer landing
unless one has just been drawn anyway.")

(defvar agent-river--map-dirty nil
  "Non-nil when an event has landed that the map has not yet drawn.")

;; The buffer is Markdown, and tree-sitter owns the `face' property: it
;; refontifies on redisplay, so a face written as a text property is
;; drawn once and then quietly gone.  Every face this view wants is
;; therefore marked with a property of its own and turned into an
;; overlay after the text is in (`agent-river--map-shade'), which sits
;; above the fontification rather than competing with it.

(defun agent-river--map-mark (text face)
  "Return TEXT marked to be drawn in FACE once it is in the buffer.
Unmarked when FACE is nil, which is what most of a listing is: a mark is
for a line that differs from the ones around it."
  (if face (propertize text 'agent-river-map-face face) text))

(defun agent-river--map-name (name)
  "Return NAME as one line of the map, marked as the name on that line.

Bare text, not a code span.  `markdown-ts-hide-markup' is nil here -- the
marker is the indentation, so nothing in this buffer is ever hidden -- and
with nothing hidden, inline markup can only put a face on a name, never
eat a character of one.  An underscore inside a word opens no emphasis in
CommonMark either, so `foo_bar_baz.el' draws plain unaided.

So what is left to prevent is structural, and the marker already prevents
it: a name never starts a line, so no name can become a heading, a rule or
a setext underline whatever it holds.  `## injected' in a record title
lands mid-line and stays text.  What that argument rests on is the line
staying one line (`agent-river--map-one-line', the same rule a contributed
row owes) -- a newline makes one entry and one stray, and the stray
carries none of the properties the motions and `agent-river--map-here'
read.

The `agent-river-map-point' property is what
`agent-river--map-beginning-of-name' lands on, and it is a property rather
than a search for the marker because this view reads what a line is off
its properties and never off its text: the prefix is a Markdown marker
followed by a gutter of glyphs the user can set, and a name may itself
begin with a dash or a hash.  Its own property rather than the line's
`agent-river-map-name', which carries the node's name across the whole
line and so cannot say where on that line the name begins."
  (propertize (agent-river--map-one-line name) 'agent-river-map-point t))

(defcustom agent-river-map-detail-rows nil
  "How many contributed rows a node shows before the rest are elided.
Nil, the default, elides nothing: a node draws closed, so rows are on
screen only where somebody opened that one node, and a cap there hides the
tail of the answer they opened it for.  Set a number where a contributor
has more to say than a node can hold."
  :type '(choice (const :tag "Elide nothing" nil) integer))

;; Rows under a node, and who may contribute them
;;
;; A map line carries what can be read straight down the listing --
;; contention as a marker, existence as a strike-through -- and that is
;; the whole of it.  Everything else is a row under the node.
;;
;; A row is detail and waits to be asked for: a node draws closed, with a
;; twisty saying there is something under it, and TAB opens it.  One
;; mechanism rather than two, reusing folds that already survive a redraw
;; because they are data rather than overlays.

(defvar agent-river-map-contributors
  (list (list :name 'parties :read #'agent-river--rows-parties)
        (list :name 'artifact :read #'agent-river--rows-artifact))
  "What may add rows under the map's nodes, in the order they are drawn.

Each entry is a plist:

  :name     a symbol, for attribution and for retiring a broken one
  :read     (ROOT NODES) -> hash of absolute path to a list of rows
  :refresh  (ROOT NODES) -> nil, optional, may take as long as it likes
  :ttl      seconds before `:refresh\=' is offered that root again

A row is a plist of `:text\=' (one line, which the map escapes), `:face\='
\(a symbol, never a face on the text -- tree-sitter owns `face\=' in this
buffer), `:key\=' (stable across redraws, or the point lands on the wrong
row after one) and an optional `:visit\=' thunk for RET.

One more says where it belongs rather than what it says.  `:rank\=' is a
number, low first, and it orders the rows of *all* the contributors
against each other -- ties keep this list's order, so a contributor that
sets none goes on being placed by where it was registered.  It is also
what `agent-river-map-detail-rows\=' cuts from where it is set at all: the
tail is the least worth keeping rather than whoever came last.

NODES are the lines about to be drawn, each `:path\=' -- the artifact key --
and `:parties\='.

Two functions rather than one because the redraw runs on a timer and must
never wait: `:read\=' is synchronous and answers from whatever the
contributor already has, `:refresh\=' is where waiting is allowed, and it
hands its answer back by calling `agent-river-map-contribute\=' -- an
answer landing after the redraw timer retired would otherwise reach a
cache and never the screen.

Editing this list is the off switch, the way it is for
`agent-river-observers\='.  The ones it starts with are built on the
same mechanism a foreign one would use, so there is no privileged path
through here for a contributor that happens to ship with the package.

A `defvar\=' holding its own defaults rather than a `setq\=' below them: a
reload must not quietly throw away a contributor somebody registered.")

(defconst agent-river--map-refresh-ttl 3
  "Seconds a contributor is left alone before it is offered a root again.
What a contributor that sets no `:ttl\=' gets.  Short, because a read is
asynchronous and nothing waits for it: this decides how stale an answer
may be, never how long a redraw takes.")

(defvar agent-river--map-refreshed (make-hash-table :test 'equal)
  "When each contributor was last offered a root, as NAME/ROOT -> time.
The map throttles how often it *asks*; whether a read is already in
flight is the contributor\='s own business, since only it knows what it
started.")

(defconst agent-river--map-contribution-delay 0.05
  "Seconds a contributor's answer waits for its siblings before being drawn.

Short enough to read as immediate and long enough to collect the answers
that arrive together -- a contributor that stores twice, a few
milliseconds apart, would otherwise draw the map twice for one read and
move the text under whoever is reading it.

A delay, never a floor on how recently the map was drawn: a read is
started by a draw and answers a few milliseconds later, so every answer
would fall inside such a floor and none would ever be drawn.")

(defvar agent-river--map-soon nil
  "One-shot timer for a draw a contributor's answer asked for.")

(defun agent-river-map-contribute ()
  "Say that a contributor has something new for the map to draw.

Draws it, shortly.  Leaving it to the redraw timer is most of how long an
asynchronous answer appears to take: the read is milliseconds and then
the answer sits in the contributor's cache for up to
`agent-river-map-refresh-interval' seconds before anybody draws it.  An
answer that has just landed is the moment the view is known to be out of
date, which is the one moment redrawing it is certainly worth doing.

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
             (ttl (or (plist-get contributor :ttl)
                      agent-river--map-refresh-ttl)))
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

(defun agent-river--map-shown-rows (contributed)
  "Return CONTRIBUTED as the rows to draw, most urgent first.

Ordered by `:rank', low first and stable, so a contributor\'s own order
survives inside its rank and the order between two contributors does not
rest on which of them somebody registered first.  It also decides what
`agent-river-map-detail-rows' cuts where it is set at all: the tail is
the least worth keeping, rather than whoever was registered last."
  (let (rows)
    (dolist (pair contributed)
      (setq rows (append rows (cdr pair))))
    (sort rows (lambda (a b) (< (or (plist-get a :rank) 0)
                                (or (plist-get b :rank) 0))))))

(defun agent-river--rows-parties (_root nodes)
  "Return one row per party on each of NODES: the names that left the line.

The line marks contention, because that is scannable down the listing; a
row adds what only makes sense once you are looking at this one node --
whose touches they were, how long ago, and how many of them changed the
file rather than read it.

Ordered by the parties themselves, which `agent-river--domain-parties\='
has already sorted heaviest first, so the row order is the same reading
the line is ordered by and cannot contradict it."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (node nodes)
      (let* ((parties (plist-get node :parties))
             (rows
              (mapcar
               (lambda (party)
                 (let ((writes (or (plist-get party :writes) 0))
                       (last (plist-get party :last)))
                   (list :key (concat "party/" (plist-get party :party))
                         ;; Behind the rows that say what the record is: who
                         ;; has been on it is the follow-up to that question,
                         ;; not the headline.
                         :rank 1
                         :face 'agent-river-stale
                         :text (concat
                                (plist-get party :party)
                                (if (> writes 0)
                                    (format " · %d write%s" writes
                                            (if (= writes 1) "" "s"))
                                  "")
                                (if last
                                    (format " · %s ago" (agent-river--ago last))
                                  "")))))
               parties)))
        (when rows (puthash (plist-get node :path) rows table))))
    table))

(defun agent-river--map-marker (level)
  "Return the Markdown that opens a map line at LEVEL.

A record is a heading, because it has something under it and folds: the
rows a contributor puts there.  A line with nothing under it ever passes
`leaf' rather than a number and comes out a list item -- the elision line
and the empty-map line, which must not be headings that swallow whatever
follows them.  The overview pushes the records down a level to make room
for the section headings, which is why a number is the wrong thing for a
line that is a leaf whatever level it is drawn at.

The markup is left visible.  Hiding it is `markdown-ts-view-mode's own
default and it looks better on prose, but here the marker is the
indentation -- hidden, a section and the records under it start in the
same column and the structure stops being one."
  (pcase level (1 "# ") (2 "## ") (3 "### ") (_ "- ")))

(defun agent-river--map-line (level name parties &optional missing rows)
  "Return one map line: NAME at LEVEL, annotated with PARTIES.
MISSING marks a name only the state knows about, and is the one thing
that faces this line: struck through, it cannot be mistaken for a place
an agent is still working in.

PARTIES are not named on the line, only counted and marked: their names
are rows beneath it (`agent-river--rows-parties'), where a row can also
say how long ago and how much of it was writing rather than reading.
Names on the line would be ragged, and nothing scannable could then
follow them.

ROWS is `open' or `closed' when this node has contributed rows, nil when
it has none -- so a folded node cannot look like a node with nothing
under it, which would make the fold a way of losing things quietly."
  (let* ((marker (agent-river--map-marker level))
         ;; The one thing a name is marked for.  Who is here is the gutter's
         ;; and the rows' to say.
         (face (and missing 'agent-river-gone))
         (shown (agent-river--map-name name))
         ;; The gutter: everything about this line, in one fixed-width
         ;; place before the name, so each marker sits next to what it
         ;; marks and the whole column reads straight down the listing.
         (gutter
          (concat (pcase rows ('open agent-river-map-open-marker)
                         ('closed agent-river-map-closed-marker)
                         (_ " "))
                  (if (> (length parties) 1) agent-river-map-contended-marker " ")
                  " ")))
    (string-trim-right
     (concat marker gutter (agent-river--map-mark shown face)))))

(defun agent-river--map-row-line (row)
  "Return contributed ROW as a line under its node.

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
    (concat "- " (if face (agent-river--map-mark text face) text))))

(defun agent-river--map-rows-insert (rows path)
  "Insert ROWS under PATH, marked for motion and capped where asked.

ROWS is what `agent-river--map-shown-rows' ordered, which is the same list
the fold marker on the line above was decided from -- so a twisty and what
it opens onto cannot disagree.

Each row carries its node\='s path, so RET on a row acts on the thing the
row is about; a row with a `:visit\=' of its own overrides that.  It carries
its `:key\=' as well, which is what keeps point on the right row across a
redraw -- `agent-river--map-goto\=' finds a line again by what it names, and
a row that named only its parent would inherit its parent\='s identity and
land point a line or two off after every draw."
  (let ((shown (if agent-river-map-detail-rows
                   (seq-take rows agent-river-map-detail-rows)
                 rows)))
    (dolist (row shown)
      (insert (propertize
               (concat (agent-river--map-row-line row) "\n")
               'agent-river-map-path path
               'agent-river-map-row (or (plist-get row :key)
                                        (plist-get row :text) "")
               'agent-river-map-visit (plist-get row :visit))))
    (when (> (length rows) (length shown))
      (insert (propertize "- …\n"
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

(defun agent-river--map-nodes (_root entries)
  "Return the lines ENTRIES will draw, as nodes for a contributor.

Each is `:path\=' -- the artifact key, which is its identity and never a
path to expand -- and `:parties\='.  Every line is included whether or not
it is open: a contributor is asked once per draw for the whole section,
and asking again per entry would put its work behind a keystroke."
  (mapcar (lambda (entry)
            (list :path (plist-get entry :name)
                  :parties (plist-get entry :parties)))
          entries))

(defun agent-river--map-header (root &optional sections)
  "Return the map's own heading for ROOT.

The name of what is being shown, and nothing else.  No legend -- which
frame the numbers come from belongs where the frame is decided
\(`agent-river-map-scope'), not redrawn every few seconds onto a line that
is read once -- and no count of the agents in view, which the listing
already gives per line through the contention marker, the party rows and
the `agent-river-map-active' property
`\\[agent-river-map-next-active]' walks by.

ROOT is nil in the overview, which spans SECTIONS domains and is named by
their number: no one of them may stand for the rest, or the heading would
read as though that one were the subject and the others were inside it."
  (concat (agent-river--map-marker 1)
          (agent-river--map-mark (if root
                                     ;; Through `agent-river--map-name' like
                                     ;; the lines below it: a label is a
                                     ;; name too, so it is held to one line
                                     ;; and carries the point the name
                                     ;; motions land on.
                                     (agent-river--map-name
                                      (agent-river--domain-label
                                       (agent-river--map-domain root)))
                                   (format "%d domain%s" (or sections 0)
                                           (if (= (or sections 0) 1) "" "s")))
                                 'agent-river-prompt)))

(defun agent-river--map-here ()
  "Return what identifies the line point is on, for a redraw to find again.

Two things name a line: the entry, and the contributed row under it.  A
row that named only its node would share its node\='s identity with every
other row there, and point would come back from a redraw one or two lines
off every time."
  (let ((beg (line-beginning-position)))
    (list (get-text-property beg 'agent-river-map-name)
          (get-text-property beg 'agent-river-map-row)
          (line-number-at-pos))))

(defun agent-river--map-goto (here)
  "Put point back where HERE was, by name if the line is still there.
By line number otherwise, rather than at the top: a line that has left
the listing should not send whoever was reading it back to the start of
the buffer."
  (goto-char (point-min))
  (let ((found nil))
    (when (nth 0 here)
      (while (and (not found) (not (eobp)))
        (if (and (equal (nth 0 here)
                        (get-text-property (line-beginning-position)
                                           'agent-river-map-name))
                 (equal (nth 1 here)
                        (get-text-property (line-beginning-position)
                                           'agent-river-map-row)))
            (setq found t)
          (forward-line 1))))
    (unless found
      (goto-char (point-min))
      (forward-line (1- (max 1 (or (nth 2 here) 1)))))))

(defun agent-river--map-draw ()
  "Redraw the map buffer from the state, if it is still alive.

With `agent-river--map-root' set the map is zoomed into that one section.
With it nil -- which is what the map opens on -- it shows every domain
with something in it, since no one of them may stand for the rest.

A single section is drawn without a heading of its own: the header
already names it, and a second line repeating it would indent the whole
listing to say nothing."
  (let ((buffer (get-buffer agent-river-map-buffer-name)))
    (when buffer
      (with-current-buffer buffer
        (let* ((here (agent-river--map-here))
               (inhibit-read-only t)
               ;; One walk of the registry for the whole draw.  Every
               ;; section is a reading of one set of artifacts; walking it
               ;; again per section would be as many chances for them to
               ;; disagree as it is extra work.
               (agent-river--artifact-memo (cons 'none nil))
               ;; And the reading taken *of* the artifact table on the same
               ;; terms: which domains are in play at all.
               (agent-river--section-memo (cons nil nil))
               (roots (or (and agent-river--map-root (list agent-river--map-root))
                          (mapcar #'car (agent-river--map-domain-roots
                                         agent-river-map-scope))))
               (sections (mapcar (lambda (root)
                                   (let ((entries (agent-river--map-entries
                                                   root agent-river-map-scope)))
                                     (list root
                                           entries
                                           (agent-river--map-rows
                                            root (agent-river--map-nodes
                                                  root entries)))))
                                 roots))
               (split (> (length sections) 1))
               (level (if split 3 2)))
          (erase-buffer)
          (insert (if split
                      (agent-river--map-header nil (length sections))
                    (agent-river--map-header (car (car sections))))
                  "\n")
          ;; Nothing has been declared.  Said outright rather than left as
          ;; a blank buffer, since the two read alike and only one of them
          ;; is this view working -- a reader with no producer wired up
          ;; needs to be told that, not shown an empty listing.
          (unless sections
            (insert (propertize
                     (concat (agent-river--map-marker 'leaf)
                             "*nothing has arrived yet*\n")
                     'agent-river-map-face 'agent-river-stale)))
          (dolist (section sections)
            (let ((root (car section))
                  (entries (nth 1 section))
                  (rows (nth 2 section)))
              (when split
                (let ((label (agent-river--domain-label
                              (agent-river--map-domain root))))
                  (insert (propertize
                           (concat (agent-river--map-line
                                    2 label
                                    (agent-river--map-merge-parties
                                     (mapcar (lambda (entry)
                                               (list :parties (plist-get entry :parties)))
                                             entries))
                                    ;; No twisty: a contributor is asked
                                    ;; about the nodes a section lists,
                                    ;; never about the section, so a root
                                    ;; has no rows to insert.
                                    )
                                   "\n")
                           ;; A section is a place like any other line's, so
                           ;; RET zooms into it and the motions stop on it.
                           ;; A thunk of its own since a domain is not a
                           ;; path: what the zoom stores is the section
                           ;; root, an identity.
                           'agent-river-map-name label
                           'agent-river-map-path root
                           'agent-river-map-visit
                           (lambda ()
                             (setq agent-river--map-root root)
                             (agent-river--map-draw))
                           'agent-river-map-section t
                           'agent-river-map-active (and entries t)))))
              (dolist (entry entries)
                (let* ((key (plist-get entry :name))
                       ;; What the line reads.  The key is machinery --
                       ;; `inc:INC-444' -- and the record carries what to
                       ;; call it; a record with no name is read by its
                       ;; key.
                       (label (or (plist-get entry :shown) key))
                       (shown (agent-river--map-shown-rows (gethash key rows)))
                       ;; Rows are detail and wait to be asked for, so a node
                       ;; draws closed until somebody says otherwise -- with a
                       ;; twisty saying there is something there.
                       (open (agent-river--map-folded-p key nil)))
                  (insert (propertize
                           (concat (agent-river--map-line
                                    level label
                                    (plist-get entry :parties)
                                    (plist-get entry :missing)
                                    (and shown (if open 'open 'closed)))
                                   "\n")
                           'agent-river-map-name key
                           'agent-river-map-path key
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
                    (agent-river--map-rows-insert shown key))))))
          (setq agent-river--map-drawn (current-time))
          (agent-river--map-shade)
          (agent-river--map-goto here)
          (agent-river--map-settle-point)
          (setq agent-river--map-dirty nil))))))

;;; Moving about the map
;;
;; Dired's gestures, since this is a listing and those are the keys a
;; listing is walked with.  Point belongs on the name, not column zero:
;; that's the Markdown
;; marker, and a cursor on `#' reads as though the markup were the content.
;;
;; Three motions, since the map has three grains of "next thing": every
;; entry is the fine one; the top-level entries alone skip an unfolded
;; node's rows; and the entries with agents on them are why the map was
;; opened at all -- the difference between reading the view and searching
;; it.

(defun agent-river--map-line-path ()
  "Return what this line names, or nil when it names nothing.
The root heading and the elision line carry no path, which is exactly what
makes them the lines no motion should ever stop on."
  (get-text-property (line-beginning-position) 'agent-river-map-path))

(defun agent-river--map-entry-line-p ()
  "Return non-nil on a line naming a record or a section."
  (and (agent-river--map-line-path) t))

(defun agent-river--map-row-line-p ()
  "Return non-nil on a row contributed under a node."
  (and (get-text-property (line-beginning-position) 'agent-river-map-row) t))

(defun agent-river--map-top-line-p ()
  "Return non-nil on one of the listing's own entries.
A contributed row carries `agent-river-map-row' and the entry itself does
not, which is the difference between the two grains of motion.  A row
inherits its node's path so that RET on it acts on the right thing, which
is exactly why it cannot be told apart by the path alone."
  (and (agent-river--map-entry-line-p)
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

The name carries `agent-river-map-point' (`agent-river--map-name'), which
is what is looked for -- the rule this view already lives by one grain up,
where which lines a motion may stop on is read off properties and never
off the rendered text.  Searching the text instead would have to know the
prefix, and the prefix is a Markdown marker followed by a gutter of glyphs
the user can set; worse, it would have no way to tell a gutter dash from a
name that begins with one.

A contributed row has no name -- its text is prose the map escaped -- so
there the marker is stepped over instead; landing in column zero would put
the cursor on the Markdown marker, which reads as though the markup were
the content.

Falls back to the start of the line, so this is safe to call anywhere."
  (goto-char (line-beginning-position))
  (let* ((end (line-end-position))
         (name (text-property-any (point) end 'agent-river-map-point t)))
    (if name
        (progn (goto-char name) t)
      (re-search-forward "^[-# ]+" end t))))

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
  "Move to the Nth next line of the map that names something."
  (interactive "p")
  (or (agent-river--map-scan (or n 1) #'agent-river--map-entry-line-p)
      (user-error "No further entry")))

(defun agent-river-map-previous-line (&optional n)
  "Move to the Nth previous line of the map that names something."
  (interactive "p")
  (agent-river-map-next-line (- (or n 1))))

(defun agent-river-map-next-entry (&optional n)
  "Move to the Nth next entry of the listing, past any rows under it."
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
  "Redraw the map now, and ask every contributor again while doing it.

Everything read from the state is recomputed on every draw anyway.  What
this adds is clearing the throttle: `agent-river--map-refreshed' decides
whether a contributor is even *offered* the root, so left standing it
would have `g' redraw without asking anybody anything.  Asking again is
what a refresh by hand means."
  (interactive)
  (clrhash agent-river--map-refreshed)
  (agent-river--map-draw))

(defun agent-river-map-toggle ()
  "Show or hide the contributed rows under the entry at point."
  (interactive)
  (let ((name (get-text-property (line-beginning-position) 'agent-river-map-name))
        (path (get-text-property (line-beginning-position) 'agent-river-map-path)))
    (when (get-text-property (line-beginning-position) 'agent-river-map-section)
      (user-error "A root heading holds the listing below it, not rows"))
    (unless (and name path) (user-error "No entry on this line"))
    (when (agent-river--map-row-line-p)
      (user-error "A row is what folds away, not what folds"))
    ;; Whether this line drew its rows is read off the line itself rather
    ;; than derived a second time, so the toggle cannot disagree with what
    ;; is on screen.
    (let ((open (get-text-property (line-beginning-position)
                                   'agent-river-map-open))
          (cell (assoc path agent-river--map-folds)))
      (if cell
          (setcdr cell (not open))
        (push (cons path (not open)) agent-river--map-folds)))
    (agent-river--map-draw)))

;;; What RET may do -- the actions a line offers
;;
;; Opening a thing is one of the things that can be done to it, not the
;; only one: an issue on the map is something to read *and* something to
;; start an agent on, and which is wanted is not a property of the
;; domain, it is a question for the person looking at the line.
;;
;; So a line is *asked* what it offers, by every function in
;; `agent-river-artifact-action-functions', and the answers are
;; collected.  Applicability is asked rather than declared: a function
;; with nothing to do with this subject answers nil, and a producer that
;; invents a domain gets whatever the registered functions offer without
;; registering anything itself.
;;
;; A domain declares nothing at all: one mechanism answers "what may RET
;; do here", and opening a file is an action like any other
;; (`agent-river--actions-file') rather than a branch of the command.
;; With one offer nothing is asked, so a plain file still opens on RET
;; with one keystroke.

(defun agent-river--actions-file (subject)
  "Offer to open the file SUBJECT names, when there is one on disk.

The default entry in `agent-river-artifact-action-functions' and the
smallest example of one: it reads `:path', which is set only where the
line names something absolute, and answers nil for everything else.
Opening a file is an action like any other rather than a branch of the
command."
  (let ((path (plist-get subject :path)))
    (when (and path (file-exists-p path))
      (list (list :name "Open file"
                  :act (lambda () (find-file path)))))))

(defvar agent-river-artifact-action-functions (list #'agent-river--actions-file)
  "Functions asked what RET on a line of the map may do.

Each is called with the subject the line names -- the plist
`agent-river-artifact-at' produces for a record (`:key', `:domain',
`:name', `:context' and the rest), plus `:path' where the line names
something absolute on disk -- and returns a list of

  (:name STRING :act THUNK)

or nil, which is how a function says it has nothing to do with this
subject.  Nil is the whole of the applicability rule: there is no
predicate to register and no domain to be listed under, so something that
has arrived is offered whatever these have for it without waiting to be
configured.

One offer is run without asking, so a line with a single action takes one
keystroke; several are offered by name.  A thunk that wants confirming
asks for it itself -- `agent-river-launch-artifact' does, because starting
a process is the one gesture here with nothing on the far side that can
take it back.

The order is this list's own, and nothing sorts it: the menu is a
`completing-read', where order decides what is read first and not what is
worth reading -- which is why a contributed row has a `:rank' and this
has not.  What a registration appends is therefore in load order, and
reordering is a `setq'.")

(defun agent-river--artifact-actions (subject)
  "Return everything offered for SUBJECT, in the order the functions are asked.

Each function is guarded on its own, and the difference from an
observer's guard is that this runs on a keystroke rather than on every
tool call: there is no runaway to retire, so a thrower is reported and
skipped rather than removed.  What the guard is for is the other half --
one function that throws must not take the offers beside it down with
it, which would leave a reader with a line that does nothing and no
account of why."
  (let (actions)
    (dolist (fn agent-river-artifact-action-functions)
      (condition-case err
          (dolist (action (funcall fn subject))
            (push action actions))
        (error
         (agent-river-log
          "fail" (agent-river--log-text
                  (format "action %s errored (%s)"
                          (if (symbolp fn) fn "function")
                          (error-message-string err)))))))
    (nreverse actions)))

(defvar agent-river-artifact-chosen nil
  "Non-nil while an action the user picked by name out of several is running.

Bound by `agent-river--artifact-act\=' around the thunk, and read by an
action that confirms for itself: a menu entry reading `Launch: Review\='
has already named what will happen, and a `y-or-n-p\=' after it is a second
question put to an answer just given.

Nil where the line had one offer and it was run outright, and that is the
case the whole variable exists to keep apart.  A line whose only action is
a launch starts a process on RET alone, so there the confirmation is the
only thing between a keystroke and a running agent -- which is why this
says a *choice was made* and never merely how the action was reached.  A
brief name handed to `agent-river-launch-artifact\=' proves nothing: the
same argument arrives from a line that offered no alternative.")

(defun agent-river--artifact-act (subject)
  "Run what SUBJECT offers, and return non-nil when something was offered.

Nothing is asked where there is nothing to choose: one offer is run, the
way RET on a file has always opened it, because a menu with one entry is
a question with no alternative.  Nil rather than an error where nothing
is offered, so the caller -- which is the one holding what the line names
-- says which kind of nothing it was."
  (let ((actions (agent-river--artifact-actions subject)))
    (when actions
      (let* ((alone (null (cdr actions)))
             (action
              (if alone
                  (car actions)
                ;; By name, and the first of a duplicated one wins.  Two
                ;; actions spelled alike are a configuration somebody wrote,
                ;; where uniquifying would answer it with a name nobody chose.
                (let ((by-name (mapcar (lambda (a) (cons (plist-get a :name) a))
                                       actions)))
                  (cdr (assoc (completing-read "Action: " by-name nil t)
                              by-name)))))
             ;; Only where there was something to choose between.  See the
             ;; variable: an action that confirms for itself reads this to
             ;; know whether the gesture that reached it already said so.
             (agent-river-artifact-chosen (not alone)))
        (funcall (plist-get action :act)))
      t)))

(defun agent-river--map-subject (key)
  "Return what the map line naming KEY is about, for an action function.

The artifact record, which is all a map line ever names: the listing *is*
the table, so there is no line whose key the table does not have.

`:path' is set only where KEY is itself an absolute name, which is the
producer\'s doing rather than ours: a record may be keyed by a path (a log,
a report on disk) and `agent-river--actions-file' offers to open that one.
It travels beside the key rather than inside it, which is the rule
`agent-river--artifact-absolute' states one subject over -- a key cannot
say where it is, and a non-file key resolved against a directory becomes a
file in a tree it has nothing to do with.  Nothing is resolved here; the
name is either already absolute or there is none."
  (append (and (file-name-absolute-p key) (list :path key))
          (agent-river-artifact-at key)))

(defun agent-river-map-visit ()
  "Do what the line at point offers, asking which when it offers more than one.

A section heading zooms the map into that one domain, through a thunk the
draw put on the line.  Anything else is asked what it offers -- see
`agent-river-artifact-action-functions' -- and a line with one offer runs
it without a second keystroke.

On a contributed row, whatever that row said RET means -- and where it
said nothing, the node the row is about.  Refusing would be the stricter
reading of \"a motion with nowhere to go refuses\", but that rule is about
landing *near* something the eye did not choose; the record a row is under
is the thing the eye chose."
  (interactive)
  (let ((path (get-text-property (line-beginning-position) 'agent-river-map-path))
        (visit (get-text-property (line-beginning-position) 'agent-river-map-visit)))
    (cond
     (visit (funcall visit))
     ((null path) (user-error "Nothing to visit on this line"))
     ((agent-river--artifact-act (agent-river--map-subject path)))
     (t (user-error "%s: nothing registered to open it with" path)))))

(defun agent-river-map-up ()
  "Show every domain again, from a map zoomed into one of them.

There is nothing above a section: a domain is an identity rather than a
path, so `^\' is the way back out and not a step towards a parent."
  (interactive)
  (if (null agent-river--map-root)
      (user-error "Already showing every domain")
    (setq agent-river--map-root nil)
    (agent-river--map-draw)))

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
  ;; One record, one screen line: the gutter and the name are read straight
  ;; down the listing, and a wrapped tail would break that column.
  (setq-local truncate-lines t)
  (setq-local header-line-format nil)
  ;; Hiding the markup collapses the indentation the listing is drawn with
  ;; -- see `agent-river--map-marker' -- and this must not depend on what the
  ;; user set the Markdown default to.
  (setq-local markdown-ts-hide-markup nil)
  ;; Outline's own cycling has to go: it puts a `keymap' property on every
  ;; heading that wins over the mode map and swallows TAB, and its fold
  ;; lives in overlays that spring open on the next redraw.
  ;; `agent-river-map-toggle' folds by deciding what gets drawn instead,
  ;; the only kind that survives here.
  (setq-local outline-minor-mode-cycle nil)
  ;; Navigating by keyboard with nothing marking where you are is navigating
  ;; blind, and this view is read by eye far more than it is acted on.  A
  ;; mode hook is the way out for anyone who does not want it.
  (when (fboundp 'hl-line-mode) (hl-line-mode 1))
  (buffer-disable-undo))

;; `markdown-ts-view-mode' rather than `markdown-ts-mode': it is the
;; read-only variant, it already has `special-mode' among its parents, and
;; the map is a view of a state that is written elsewhere -- an editable
;; buffer would offer edits that the next redraw silently throws away.
(define-derived-mode agent-river-map-mode markdown-ts-view-mode "Agent-Map"
  "Major mode for the artifact map, rendered as Markdown.

Dired-like on purpose: RET zooms into a section, `^' comes back out, TAB
opens what is under a line."
  (agent-river--map-setup))

(define-derived-mode agent-river-map-plain-mode special-mode "Agent-Map"
  "Major mode for the artifact map where Markdown cannot be rendered.

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
  ;; fallback, so left to the parents they would skip every row in one mode
  ;; and do nothing at all in the other.
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

(defun agent-river--map-observe (_subject _event)
  "Mark the map as needing a redraw after an event about SUBJECT.

On both observer hooks, which is the one shape that may do that.  The two
are kept apart because a consumer that reads its subject has to know
which kind it was handed -- and this one never reads it: the map is
redrawn from the tables either way, so the event is only ever news that
something moved.  A consumer that does look at SUBJECT belongs on one
hook or the other, and this is not the precedent for putting it on both.

Both hooks, because the timer retires once nothing is dirty: on the
session hook alone, an incident arriving while no agent was working would
sit in the table until somebody pressed `g' -- which is the case the
artifact table exists for."
  (agent-river--map-invalidate))

(defvar agent-river--map-timer nil
  "Repeating timer redrawing the map, or nil while none runs.")

(defun agent-river--stop-map-timer ()
  "Stop the map redraw timer."
  (when (timerp agent-river--map-timer)
    (cancel-timer agent-river--map-timer))
  (setq agent-river--map-timer nil))

(defun agent-river--map-tick ()
  "Redraw the map, or stop the timer once there is nothing left to draw.

Nothing on this map changes on its own, so the only thing worth a redraw
is dirt: an event marked it, a contributor answered, or a record
arrived.  The timer retires on the first tick that finds none,
which is also why the relative times in the rows stand still while
nothing is happening -- they move again on the next event, or on `g'.

What it cannot see is the disk.  A file that comes back while no agent is
working -- a branch switch, a build -- redraws on the next event or on
`g', the way a dired buffer does; watching the filesystem to catch it is a
lot of machinery for a view whose subject is the agents."
  (condition-case err
      (cond
       ((null (get-buffer agent-river-map-buffer-name))
        (agent-river--map-teardown))
       (agent-river--map-dirty
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
  "Take the map off both event streams and stop its timer.
Run when the buffer is killed, and as the observer's retirement: the map
draws only into its own buffer, so closing that buffer is the whole of
turning it off.

Both hooks, whichever of them retired it.  `agent-river--run-observers'
removes a thrower from the hook it threw on and leaves the other holding
a function that will throw again the moment an artifact arrives."
  (remove-hook 'agent-river-observers #'agent-river--map-observe)
  (remove-hook 'agent-river-artifact-observers #'agent-river--map-observe)
  (agent-river--stop-map-timer))

(put 'agent-river--map-observe 'agent-river-retire #'agent-river--map-teardown)

;;;###autoload
(defun agent-river-map (&optional ask)
  "Show what has arrived and who is on it.

One section per domain of `agent-river-artifacts', one line per record,
each annotated with whoever has reached it -- and the line this view is
for is the one nobody has.  No files: what an agent did to one is counted
in the session tables and named by no view.

Opens on every domain that has a record.  RET on a section zooms into it
and `^' comes back out.

With ASK (a prefix argument), prompt for one domain to show instead.

Needs no mode to be switched on: the buffer is the consent, and killing it
takes the map off the event stream."
  (interactive "P")
  (let* ((domains (agent-river-domains))
         (root (and ask domains
                    (agent-river--domain-root
                     (intern (completing-read "Map: "
                                              (mapcar #'symbol-name domains)
                                              nil t)))))
         (buffer (get-buffer-create agent-river-map-buffer-name)))
    (with-current-buffer buffer
      ;; Set unconditionally rather than only on a fresh buffer: the answer
      ;; can change between two calls -- a grammar installed, or this file
      ;; reloaded -- and the mode is what decides how the buffer is read.
      (if (agent-river--markdown-ts-p)
          (agent-river-map-mode)
        (agent-river-map-plain-mode))
      (setq agent-river--map-root root
            agent-river--map-folds nil)
      (add-hook 'kill-buffer-hook #'agent-river--map-teardown nil t))
    (add-hook 'agent-river-observers #'agent-river--map-observe)
    ;; And the artifact stream, which is where the whole listing comes
    ;; from: an incident arriving changes this map with no session event at
    ;; all, and without this hook the record would sit in the table, drawn
    ;; by nobody, until somebody pressed `g'.  Quiet is exactly when this
    ;; view has the most to say.
    (add-hook 'agent-river-artifact-observers #'agent-river--map-observe)
    (agent-river--map-draw)
    (agent-river--ensure-map-timer)
    (pop-to-buffer buffer)))

(provide 'agent-river)
;;; agent-river.el ends here
