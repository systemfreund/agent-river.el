;;; agent-river-launch.el --- Starting a session from an event -*- lexical-binding: t; -*-

;; Author: systemfreund <github@o9z.de>
;; Keywords: tools

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The third direction.  `agent-river.el' listens: hooks report, the fold
;; folds, observers carry state outward, producers add events about a session
;; that already exists.  Nothing there acts.  This file is where an event
;; from outside becomes a *new* session -- an issue is opened and an agent
;; goes to work on it.
;;
;; Five roles, and three of them are pure functions over a candidate and the
;; registry, which is what makes them testable the way the fold is:
;;
;;   source   -> candidate   an issue was opened; a session handed off
;;   rule     -> decision    does this match, may it run now, with what prompt
;;   ledger   -> dedupe      has this occasion already been acted on
;;   launcher -> session     start it
;;   queue                   what has been decided and not yet started
;;
;; All five roles exist.  What does not exist is a reason for the last one to
;; fire: three switches stand in front of it and all three are off, so out of
;; the box a candidate arrives, is deduplicated, is matched against a rule, is
;; held until its gate opens, and is then decided `ready' -- the whole
;; pipeline, with a no-op where the process would go.
;;
;; That is deliberate rather than unfinished.  The path from "watch it decide"
;; to "let it run overnight" is paved with a fortnight of decisions, and
;; decisions only accrue in wall-clock time, so the log has to be running long
;; before anything is armed.  `agent-river-launch-launcher' says whether
;; anything can launch, a rule's `:prompt' whether that rule may, and
;; `agent-river-launch-auto' whether it happens without being asked.
;;
;; See the README section "A third direction: starting a session from an
;; event" for the reasoning behind all of it, including the parts deliberately
;; not written yet.
;;
;;   (agent-river-launch-mode 1)
;;   M-x agent-river-queue
;;
;; Delivering one by hand, which is also how a poller does it -- built
;; elsewhere, renamed in:
;;
;;   d=~/.local/state/agent-river/spool
;;   printf '%s' '{"source":"river","id":"1@t1","title":"hello"}' > $d/x.tmp
;;   mv $d/x.tmp $d/x.json
;;
;; An agent says it has reached a point the same way, and needs no tool and
;; no hook to do it -- writing the file *is* the handoff:
;;
;;   {"source":  "handoff",
;;    "occasion": "review",          the token a rule may match
;;    "session":  "<its session id>",   optional: who, and where to note it
;;    "cwd":      "/path/to/tree",
;;    "text":     "the gate ordering is worth a second pair of eyes"}
;;
;; `text' is the agent's own words and goes to `:claim', which nothing
;; matches on and nothing turns into a prompt.  See the field list below.

;;; Code:

(require 'seq)
(require 'iso8601)
(require 'filenotify)
(require 'agent-river)

(defgroup agent-river-launch nil
  "Starting a coding-agent session from an event."
  :group 'agent-river
  :prefix "agent-river-launch-")


;;; Customisation

(defcustom agent-river-launch-spool
  (expand-file-name "agent-river/spool/" (or (getenv "XDG_STATE_HOME")
                                             "~/.local/state/"))
  "Directory candidates are delivered to.

The only door.  A GitHub poller, an observer on this package's own event
stream, an agent handing off, and you with `echo' all write the same
shape to the same place -- so a new kind of source is a new writer and
never a new mechanism.

Deliberately not under `user-emacs-directory', which is where a package's
data would otherwise go.  Everything else this package writes is written
by Emacs; this is written *to* Emacs, by processes that should not have to
know how an Emacs configuration is laid out -- and it is a working
directory rather than state anyone would keep.  It is also somewhere
people symlink package checkouts into, which on the first run of this put
a spool full of JSON inside a git repository.

Three subdirectories underneath carry the state, because the state *is*
the filesystem: there is then no second account of what has been handled
that can disagree with the first, it survives an Emacs restart, and it
can be read and repaired by hand.

  <spool>/            the inbox: delivered, not yet taken in
  <spool>/queued/     taken in and waiting, the queue's durable form
  <spool>/done/       decided -- launched, or refused with a reason
  <spool>/failed/     unreadable, kept for you to look at

A writer must build the file elsewhere and `rename' it in.  The watcher
sees a file the moment it appears, and a half-written one would be read
as malformed and filed away as such; a rename within a filesystem is
atomic, so the file is never visible incomplete.  Only names ending in
\".json\" are taken in, which is what leaves \".tmp\" free for the
writing half."
  :type 'directory)

(defcustom agent-river-launch-poll-interval 60
  "Seconds between safety-net scans of the spool, or nil for none.

`file-notify' is the primary way a delivery is noticed and is far
quicker.  It is also not guaranteed: watches are lost when a directory is
recreated, the kernel runs out of them, and nothing over TRAMP has them
at all.  A candidate that is silently never noticed is the failure this
prevents, and at a minute the cost of preventing it is a `directory-files'
on a directory that is almost always empty."
  :type '(choice (const :tag "No safety net" nil) integer))

(defcustom agent-river-launch-settle 2
  "Seconds a file that will not parse is given before it is called broken.

The contract is write-then-rename, and a poller can be held to it.  An
agent handing off cannot: it reaches for `Write', which creates the file
where the watch can already see it, so its JSON is briefly half there.
Filing that under `failed/' would lose a handoff over a contract nobody
told the agent about, and losing it *quietly* -- the agent has no way to
find out that what it wrote was thrown away.

So a file too young to be trusted is simply left for the next scan.  The
cost is that a genuinely broken file is filed a couple of seconds late."
  :type 'number)

(defcustom agent-river-launch-queue-limit 200
  "How many candidates may wait in the queue at once.

A source that loses its own memory -- a poller restarted, a watch
re-delivering -- can produce candidates faster than anything drains them,
and an unbounded queue in an Emacs that runs for weeks is a leak with a
view attached.

On reaching the limit intake *stops* rather than dropping anything: the
files stay in the inbox and are taken in once there is room.  Dropping the
oldest would throw away the candidate most likely to still matter, and
refusing the newest silently would make the spool lie about what it holds."
  :type 'integer)

(defcustom agent-river-launch-decision-limit 200
  "How many recent decisions `*agent-river-queue*' keeps to show.

The durable record is the filesystem -- which directory a candidate ended
up in.  This is the readable form of it, and it is capped because it is a
display, not the account."
  :type 'integer)

(defcustom agent-river-launch-queue-buffer-name "*agent-river-queue*"
  "Name of the buffer the queue and its decisions are shown in."
  :type 'string)


;;; The candidate
;;
;; One occasion, normalised.  Everything downstream -- rules, the ledger, the
;; launcher -- sees this shape and nothing else, the same way everything below
;; `agent-river--event' sees one event shape however many hosts feed it.
;;
;;   :key      the occasion's identity, and the ledger's key
;;   :source    which adapter read it, and which dialect :payload is in
;;   :at        when the occasion happened
;;   :occasion  what kind of occasion, from the source's own small vocabulary
;;   :title     one line, for a human reading the queue
;;   :actor     who caused it -- the provenance guard's input, later
;;   :labels    tags the source classifies it with, comma-joined and wrapped
;;   :session   the agent-river session it came from, where one did
;;   :cwd       where a session for this would be started
;;   :claim     what the subject said about itself.  Never matched on
;;   :payload   the source's own data, unread by anything generic
;;   :file      where the candidate currently lives on disk
;;
;; `:claim' is the one field kept deliberately out of reach, and it is the
;; same separation the `intent*' slots have in the state: a claim is the agent
;; talking about itself, and the moment it is read as a measurement the loop
;; closes.  It is shown, marked as the agent's words, and that is all -- see
;; `agent-river-launch--field', which refuses it, so a rule cannot be steered
;; by the words of the thing it is deciding about.

(defun agent-river-launch--time (value fallback)
  "Read VALUE as a time, falling back to FALLBACK.
Accepts epoch seconds or an ISO 8601 string, which is what every source
worth reading emits; anything else is not worth a parser of its own."
  (cond
   ((numberp value) (time-convert value 'list))
   ((and (stringp value)
         (ignore-errors (encode-time (iso8601-parse value)))))
   (t fallback)))

(defun agent-river-launch--string (value)
  "Return VALUE if it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun agent-river-launch--read-river (source data)
  "Read DATA, already in the normalised shape, as a candidate of SOURCE.

The built-in reader, and the fallback for a source with no adapter
registered -- which is why the adapter protocol below is not speculative.
A source that can write this shape directly needs no adapter at all, and
one that cannot has exactly one place to be taught.

`id' names the *occasion*, not the object it is about.  `issue-42' alone
is wrong: an issue reopened two weeks later is a new reason to act, and
the same mistake has been made here once before -- `(streak N)' silently
suppressed a genuinely new run of failures because it named the number
rather than the run.  So a poller pairs the object with whatever moved:
\"42@2026-09-14T10:11:12Z\"."
  (let ((id (agent-river-launch--string (alist-get 'id data))))
    (unless id
      (error "No `id': nothing to identify the occasion by"))
    (list :key (format "%s/%s" source id)
          :source source
          :at (agent-river-launch--time (alist-get 'at data) nil)
          :occasion (agent-river-launch--string (alist-get 'occasion data))
          :title (or (agent-river-launch--string (alist-get 'title data)) id)
          :actor (agent-river-launch--string (alist-get 'actor data))
          :cwd (agent-river-launch--dir-value (alist-get 'cwd data))
          :payload (alist-get 'payload data))))

(defun agent-river-launch--dir-value (value)
  "Return VALUE as an absolute directory name, or nil."
  (let ((dir (agent-river-launch--string value)))
    (and dir (expand-file-name dir))))

(defun agent-river-launch--mint ()
  "Return an id for an occasion that is its own, and happens once."
  (format "%s-%04x" (format-time-string "%Y%m%dT%H%M%S") (random 65536)))

(defun agent-river-launch--read-handoff (source data)
  "Read DATA as an agent saying it has reached a point, from SOURCE.

The agent needs no tool for this and no hook: it writes a file into the
spool with an ordinary `Write' or `Bash' call, the source reads it like
any other, and nothing in the fold changes.

It is the better anchor than a turn ending, because it carries arguments
-- review this, it is blocked on that -- and because it fires *during* a
session, which is the only way a session that goes on working can be the
occasion for more than one thing.

The key is minted here rather than taken from the data, and that is the
one place this parts company with a poller.  A pull source re-sees the
same object on every tick, so its key has to say which *visit* this is or
one issue becomes an agent an hour.  A push source is delivered once and
consumed once: there is nothing to re-see, so every write is its own
occasion and minting says exactly that.  An `id' may still be given, for
a writer that retries and wants the second attempt to be recognised as
the first.

`text' is the agent's own words and lands in `:claim', which nothing
matches on.  `occasion' is the short token a rule may match -- keep the
vocabulary small, since a rule author has to know what to write."
  (let ((id (or (agent-river-launch--string (alist-get 'id data))
                (agent-river-launch--mint)))
        (occasion (or (agent-river-launch--string (alist-get 'occasion data))
                      "done"))
        (session (agent-river-launch--string (alist-get 'session data))))
    (list :key (format "%s/%s" source id)
          :source source
          :at (agent-river-launch--time (alist-get 'at data) nil)
          :occasion occasion
          :title (format "handoff: %s" occasion)
          :session session
          :actor (or session "an agent")
          :cwd (agent-river-launch--dir-value (alist-get 'cwd data))
          :claim (agent-river-launch--string (alist-get 'text data))
          :payload data)))

(defvar agent-river-launch-sources
  (list (cons "river" #'agent-river-launch--read-river)
        (cons "handoff" #'agent-river-launch--read-handoff))
  "Alist of (SOURCE . READER) turning a delivered file into a candidate.

READER is called with the source name and the parsed JSON as an alist,
and returns a candidate plist or signals.  It is the one place that knows
a source's dialect -- exactly the role `agent-river--event' plays for the
hosts, and for the same reason: a poller should move bytes and understand
nothing, so `gh's raw JSON is what lands in the spool and the knowledge of
what `gh' calls things lives here, in Elisp, under test.

A reader that throws costs its own file and nothing else: that file is
filed under `failed/' and never read again, so there is no runaway to
retire it from.  Unlike an observer, it cannot fail repeatedly.")

(defun agent-river-launch--candidate (file)
  "Read FILE as a candidate, or signal saying why it is not one."
  (let* ((data (with-temp-buffer
                 (insert-file-contents file)
                 (json-parse-buffer :object-type 'alist
                                    :null-object nil
                                    :false-object nil)))
         (source (or (agent-river-launch--string (alist-get 'source data))
                     (error "No `source': nothing says how to read this")))
         (reader (or (alist-get source agent-river-launch-sources
                                nil nil #'equal)
                     #'agent-river-launch--read-river))
         (candidate (funcall reader source data)))
    (unless (agent-river-launch--string (plist-get candidate :key))
      (error "Reader for `%s' produced no key" source))
    ;; The time falls back to the file's own, which is the closest thing to
    ;; the occasion that is left when the source did not say -- and it keeps
    ;; every candidate orderable, which the queue needs.
    (unless (plist-get candidate :at)
      (setq candidate (plist-put candidate :at
                                 (file-attribute-modification-time
                                  (file-attributes file)))))
    (plist-put candidate :file file)))


;;; The ledger -- which is the filesystem
;;
;; A poller sees the same issue on every tick, and a watch can re-deliver.
;; So an occasion is acted on once, and the record of that has to outlive
;; Emacs: a lost signal is a sentence nobody heard, but a lost launch record
;; is a second agent on the same issue.
;;
;; The record is a file's presence, under a name derived from the key.  Hence
;; the hash: the sanitised name alone would map `a/b' and `a_b' onto one
;; file, and a false match in a dedupe ledger is a launch that never happens
;; and says nothing about why.

(defun agent-river-launch--filename (key)
  "Return the file name KEY is recorded under."
  (let ((safe (replace-regexp-in-string "[^A-Za-z0-9._-]+" "_" key)))
    (format "%s-%s.json"
            (substring safe 0 (min 60 (length safe)))
            (substring (secure-hash 'sha1 key) 0 10))))

(defun agent-river-launch--dir (name)
  "Return the spool subdirectory NAME, or the inbox for nil."
  (let ((dir (if name
                 (expand-file-name name agent-river-launch-spool)
               agent-river-launch-spool)))
    (file-name-as-directory (expand-file-name dir))))

(defun agent-river-launch--ensure-dirs ()
  "Create the spool and its subdirectories if they are not there."
  (dolist (name '(nil "queued" "done" "failed"))
    (make-directory (agent-river-launch--dir name) t)))

(defun agent-river-launch--path (name key)
  "Return where KEY lives under spool subdirectory NAME."
  (expand-file-name (agent-river-launch--filename key)
                    (agent-river-launch--dir name)))

(defun agent-river-launch--seen-p (key)
  "Return non-nil if KEY has already been taken in.

Both `queued/' and `done/' count.  Asking only `done/' would re-take a
candidate that is waiting, which is how one occasion becomes two agents."
  (or (file-exists-p (agent-river-launch--path "queued" key))
      (file-exists-p (agent-river-launch--path "done" key))))


;;; Decisions
;;
;; The evidence rung 3 is armed on.  What matters is that *refusals* are
;; recorded and not only launches: after a fortnight this log says which rule
;; would have been wrong how often, and one rule is armed on that rather than
;; on a feeling.  It is the same move notes make -- visible and counted first,
;; fed back only once the rate is known.
;;
;; Durably, a decision is which directory a candidate ended up in.  That is
;; enough while the only decisions are the three below; once a rule can refuse
;; one, the reason has to become durable too, because "refused" and "refused
;; because the budget was spent" are different pieces of evidence.

(defvar agent-river-launch--decisions nil
  "Recent decisions, newest first.  A display, not the account.")

(defvar agent-river-launch--decided 0
  "How many decisions have ever been recorded.

What `:n' is taken from, so that a line of the decision log can be found
again after the buffer is rebuilt under whoever is reading it.  Never
reset, for `fail-runs\=' reason one subject over: a counter that starts
again lets a new row take the name an old row was found by, and the
reader is then put back on the wrong line by the mechanism that exists
to stop exactly that.")

(defun agent-river-launch--decide (decision candidate reason)
  "Record DECISION about CANDIDATE, because of REASON.
CANDIDATE may be a plist or, where reading failed, a file name."
  (setq agent-river-launch--decided (1+ agent-river-launch--decided))
  (let ((entry (list :at (current-time)
                     :n agent-river-launch--decided
                     :decision decision
                     :reason reason
                     :key (if (stringp candidate)
                              (file-name-nondirectory candidate)
                            (plist-get candidate :key))
                     :title (and (not (stringp candidate))
                                 (plist-get candidate :title)))))
    (push entry agent-river-launch--decisions)
    (when (> (length agent-river-launch--decisions)
             agent-river-launch-decision-limit)
      (setcdr (nthcdr (1- agent-river-launch-decision-limit)
                      agent-river-launch--decisions)
              nil))
    entry))


;;; The queue
;;
;; A store and, later, a drainer; the buffer is a view of it.  It cannot be a
;; feature of the buffer, because the end state drains without anyone looking
;; -- `RET' and "automatically" have to be two modes of one drainer rather
;; than two mechanisms.
;;
;; Deliberately not in `agent-river-registry': the fold's docstring promises a
;; state can be rebuilt by replaying its events, and a candidate that has not
;; started is none of its events.

(defvar agent-river-launch--queue nil
  "Candidates taken in and not yet decided, oldest first.")

(defun agent-river-launch--queued-p (key)
  "Return non-nil if KEY is already in the in-memory queue."
  (seq-find (lambda (c) (equal (plist-get c :key) key))
            agent-river-launch--queue))

(defun agent-river-launch--enqueue (candidate)
  "Append CANDIDATE to the queue."
  (setq agent-river-launch--queue
        (append agent-river-launch--queue (list candidate))))

(defun agent-river-launch--full-p ()
  "Return non-nil while the queue is at `agent-river-launch-queue-limit'."
  (>= (length agent-river-launch--queue) agent-river-launch-queue-limit))


;;; Rules -- which candidates are worth acting on, and when
;;
;; A rule is data with functions as the way out, rather than a function with
;; data as a special case.  The reason is the first rung: calibrating means
;; *reading*, and a declarative rule can be explained in the queue -- matched
;; on source `gh', held because two sessions are already running -- where a
;; function can only be named.  What holds either way is that the decision log
;; records the outcome, so a function rule is still answerable for afterwards;
;; it just cannot explain itself in advance.
;;
;; Two halves, and the split is not cosmetic: `:match' asks whether this is the
;; kind of thing the rule is about, which is a property of the candidate alone
;; and never changes; `:gate' asks whether now is the moment, which is a
;; property of the world and changes every minute.  So a candidate no rule
;; matches is finished -- nothing will ever match it -- and a candidate a gate
;; refuses stays in the queue and is asked again.  Collapsing the two would
;; throw away work for having arrived while an agent happened to be busy.

(defcustom agent-river-launch-rules
  '((:name "everything" :match t))
  "Rules deciding which candidates are acted on, and when.

Each rule is a plist:

  :name    what the decision log calls it.
  :match   t, an alist of (FIELD . SPEC), or a function of the candidate.
  :gate    nil, an alist of (CHECK . VALUE), or a function of the candidate
           returning nil to allow or a string saying why not.

In a `:match' alist FIELD is one of :source :occasion :title :actor
:labels :session :key :cwd, and SPEC is a regexp, or a list of regexps of which
one must match.  All pairs must hold.  A regexp rather than a comparison
because several of these are prose; anchor it (\"\\\\`gh\\\\'\") where you
mean the whole value.

`:claim' is not among them and cannot be added: it holds what the subject
of the candidate said about itself, and a rule matching it would let an
agent choose the words that arm the rule it wanted.  `:occasion' is the
field a source is meant to steer -- a short token from a small vocabulary,
which is a choice a rule author can anticipate where a sentence is not.

In a `:gate' alist CHECK is one of:

  :max-concurrent N       refuse while N or more agents are working.
  :idle t                 refuse while any agent is mid-turn.
  :no-failures t          refuse while any session is on a failure streak.
  :budget (N . SECONDS)   refuse after N of this rule in that window.
  :hours (START . END)    allow only between those local hours.

The default matches everything and gates nothing, which is what makes a
freshly delivered candidate visible without any configuration.  It is a
rule like any other rather than a hidden fallback, so removing it is a
thing you can see yourself doing.

A gate must state its reason, which is why a function returns the reason
rather than a boolean.  The refusals are the evidence the later rungs are
armed on, and \"refused\" without \"because the budget was spent\" is not
evidence of anything."
  :type '(repeat sexp))

(defconst agent-river-launch--unmatchable '(:claim)
  "Candidate fields a rule may not match on.

`:claim' is what the subject of the candidate said about itself.  Letting
a rule match it would hand the agent the wiring: it could choose the words
that make its own handoff match the rule it wanted, and a decision made on
an agent's prose is the agent deciding.  What it *may* steer is
`:occasion', deliberately -- a short token from a small vocabulary, which
is a choice a rule author can anticipate and a sentence is not.")

(defun agent-river-launch--field (candidate field)
  "Return CANDIDATE's FIELD as a string, or nil.
Fields in `agent-river-launch--unmatchable' always read as nil, so a rule
naming one matches nothing rather than quietly matching anything."
  (unless (memq field agent-river-launch--unmatchable)
    (let ((value (plist-get candidate field)))
      (and (stringp value) value))))

(defun agent-river-launch--spec-p (spec value)
  "Return non-nil if VALUE satisfies SPEC."
  (and value
       (cond
        ((eq spec t) t)
        ((stringp spec) (string-match-p spec value))
        ((listp spec) (seq-some (lambda (one) (string-match-p one value)) spec)))))

(defun agent-river-launch--matches-p (rule candidate)
  "Return non-nil if RULE's `:match' holds for CANDIDATE."
  (let ((match (plist-get rule :match)))
    (cond
     ((eq match t) t)
     ((functionp match) (funcall match candidate))
     ((null match) nil)
     (t (seq-every-p (lambda (pair)
                       (agent-river-launch--spec-p
                        (cdr pair)
                        (agent-river-launch--field candidate (car pair))))
                     match)))))

(defun agent-river-launch--rule-for (candidate)
  "Return the first rule in `agent-river-launch-rules' matching CANDIDATE.

Asked again at every drain rather than remembered on the candidate: rules
are edited between a delivery and the moment it could run, and a cached
answer would go on citing a rule that no longer says what it used to."
  (seq-find (lambda (rule)
              (condition-case err
                  (agent-river-launch--matches-p rule candidate)
                (error (agent-river-log
                        "fail" (format "rule %s: %s" (plist-get rule :name)
                                       (error-message-string err)))
                       nil)))
            agent-river-launch-rules))

(defvar agent-river-launch--accepted nil
  "Times candidates were accepted, as (TIME . RULE-NAME), newest first.
What `:budget' counts.  In shadow mode these are launches that did not
happen, which is exactly what makes the budget legible before it matters.")

(defun agent-river-launch--spent (name seconds)
  "Return how many of rule NAME were accepted within the last SECONDS."
  (let ((cutoff (time-subtract (current-time) seconds)))
    (seq-count (lambda (entry)
                 (and (equal (cdr entry) name)
                      (time-less-p cutoff (car entry))))
               agent-river-launch--accepted)))

(defun agent-river-launch--agents ()
  "Return how many agents are at work, delegated ones included.

Not `agent-river--active-count', which answers for *sessions* and is
right to: a subagent is a tally on its parent rather than a registry
entry of its own, so a session running three of them counts once there.
It did not always -- a subagent used to be an entry, and this gate was
calibrated when it was, so reading that number now would let a
`:max-concurrent' of 2 stand over eight working agents and refuse
nothing.

This is the one place the distinction matters, because this is the one
question that is about load rather than about sessions: the gate exists
to stop another agent being started while the machine already has its
hands full, and a delegated agent has its hands just as full.  Only
`running' delegates count -- `done' is over and `stale' is a guess, and
a guess must not be what holds a launch back."
  (let ((n 0))
    (maphash (lambda (key state)
               (when (agent-river--active-p state)
                 (setq n (+ n 1 (seq-count
                                 (lambda (child)
                                   (equal (plist-get child :status) "running"))
                                 (agent-river-children key))))))
             agent-river-registry)
    n))

(defun agent-river-launch--working ()
  "Return the label of a session that is mid-turn, or nil."
  (let (label)
    (maphash (lambda (_key state)
               (when (and (not label) (agent-river--state-working-p state))
                 (setq label (agent-river-state-label state))))
             agent-river-registry)
    label))

(defun agent-river-launch--failing ()
  "Return (LABEL . STREAK) for a live session on a failure streak, or nil."
  (let (found)
    (maphash (lambda (_key state)
               (when (and (not found)
                          (agent-river--active-p state)
                          (>= (agent-river-state-fail-streak state)
                              agent-river-fail-streak-threshold))
                 (setq found (cons (agent-river-state-label state)
                                   (agent-river-state-fail-streak state)))))
             agent-river-registry)
    found))

(defun agent-river-launch--within-hours-p (start end)
  "Return non-nil if the local hour is in [START, END).
A window that wraps midnight is the useful case here -- overnight is when
this is meant to run -- so END below START reads as crossing it."
  (let ((hour (string-to-number (format-time-string "%H"))))
    (if (<= start end)
        (and (>= hour start) (< hour end))
      (or (>= hour start) (< hour end)))))

(defun agent-river-launch--check (check value rule)
  "Return why CHECK with VALUE refuses RULE now, or nil to allow."
  (pcase check
    (:max-concurrent
     (let ((n (agent-river-launch--agents)))
       (and (>= n value) (format "%d agent%s working, limit %d"
                                 n (if (= n 1) "" "s") value))))
    (:idle
     (and value (let ((label (agent-river-launch--working)))
                  (and label (format "%s is mid-turn" label)))))
    (:no-failures
     (and value (let ((failing (agent-river-launch--failing)))
                  (and failing (format "%s is on %d consecutive failures"
                                       (car failing) (cdr failing))))))
    (:budget
     (let* ((limit (car value))
            (window (cdr value))
            (spent (agent-river-launch--spent (plist-get rule :name) window)))
       (and (>= spent limit)
            (format "%d in the last %ds, limit %d" spent window limit))))
    (:hours
     (and (not (agent-river-launch--within-hours-p (car value) (cdr value)))
          (format "%s is outside %02d:00-%02d:00"
                  (format-time-string "%H:%M") (car value) (cdr value))))
    (_ (format "unknown gate %s" check))))

(defun agent-river-launch--gate (rule candidate)
  "Return why RULE refuses CANDIDATE now, or nil to allow.

A gate that throws refuses and says so, rather than being treated as
silence.  Silence here means \"go ahead\", and a broken gate must never be
the thing that lets something run."
  (let ((gate (plist-get rule :gate)))
    (condition-case err
        (cond
         ((null gate) nil)
         ((functionp gate) (funcall gate candidate))
         (t (seq-some (lambda (pair)
                        (agent-river-launch--check (car pair) (cdr pair) rule))
                      gate)))
      (error (format "gate errored (%s)" (error-message-string err))))))


;;; Intake

(defun agent-river-launch--settling-p (file)
  "Return non-nil while FILE is too young to be called broken."
  (let ((mtime (file-attribute-modification-time (file-attributes file))))
    (and mtime (< (float-time (time-subtract (current-time) mtime))
                  agent-river-launch-settle))))

(defun agent-river-launch--note-session (candidate)
  "Note in the river that CANDIDATE came out of a session, if it names one.

The producer direction, and what `agent-river-note' is for: something only
this layer can see, folded as an event of the session it is about, so it
is logged, counted in the report and attributable rather than written
straight onto a slot.

What is noted is the *fact*, never the claim.  A note is a measurement and
may therefore feed a signal, so folding in the agent's own words would
launder a claim into an observation about the world -- the very loop the
`intent*' slots are kept apart to prevent.  \"handoff: review\" says what
the agent did; what it thinks stays in `:claim', where nothing reads it
back to anybody."
  (let* ((session (plist-get candidate :session))
         (state (and session (gethash session agent-river-registry))))
    (when state
      (ignore-errors
        (agent-river-note (format "%s: %s"
                                  (plist-get candidate :source)
                                  (or (plist-get candidate :occasion) "?"))
                          session)))))

(defun agent-river-launch--finish (candidate decision reason)
  "File CANDIDATE under `done/' as DECISION, because of REASON."
  (let ((file (plist-get candidate :file)))
    (when (and file (file-exists-p file))
      (rename-file file (agent-river-launch--path
                         "done" (plist-get candidate :key))
                   t)))
  (agent-river-launch--decide decision candidate reason))

(defun agent-river-launch--take-in (file)
  "Take FILE out of the inbox, and return its decision.

Four outcomes, and each moves the file, because a file left in the inbox
is a file that will be read again on the next scan.  Unreadable goes to
`failed/' and is never read again -- kept rather than deleted, since the
only way to fix a source is to look at what it wrote.  A repeat is
deleted: `done/' or `queued/' already holds the canonical copy under the
same name, and a poller with no memory of its own would otherwise fill the
disk with identical files.  One no rule matches is finished in `done/'.
Anything else is moved to `queued/', which is what makes the queue survive
a restart."
  (let ((candidate (condition-case err
                       (agent-river-launch--candidate file)
                     (error
                      ;; A file still being written is not a broken file.  The
                      ;; contract is write-then-rename, but an agent handing
                      ;; off reaches for `Write' rather than `mv', and filing
                      ;; its half-finished JSON under `failed/' would lose a
                      ;; handoff over a contract nobody told it about.  Left
                      ;; alone, it is read again on the next scan.
                      (if (agent-river-launch--settling-p file)
                          nil
                        (rename-file file (agent-river-launch--dir "failed") t)
                        (agent-river-log
                         "fail" (format "spool: %s (%s)"
                                        (file-name-nondirectory file)
                                        (error-message-string err)))
                        (agent-river-launch--decide
                         'malformed file (error-message-string err))
                        nil)))))
    (when candidate
      (let ((key (plist-get candidate :key)))
        (if (agent-river-launch--seen-p key)
            (progn (delete-file file)
                   (agent-river-launch--decide 'duplicate candidate
                                               "already taken in"))
          ;; Noted before the rules get a say: that an agent said something
          ;; about itself is true whether or not anything acts on it, and
          ;; seeing the rate before anything is armed is the whole plan.
          (agent-river-launch--note-session candidate)
          (cond
           ;; No rule is a *final* answer, unlike a gate refusing: `:match' is
           ;; a property of the candidate and nothing about waiting will
           ;; change it, so the candidate is finished here rather than sitting
           ;; in the queue being asked a question that already has an answer.
           ((null (agent-river-launch--rule-for candidate))
            (agent-river-launch--finish candidate 'unmatched "no rule matched"))
           (t
            (let ((dest (agent-river-launch--path "queued" key)))
              (rename-file file dest t)
              (agent-river-launch--enqueue (plist-put candidate :file dest)))
            (agent-river-launch--decide
             'queued candidate
             (format "rule %s"
                     (plist-get (agent-river-launch--rule-for candidate)
                                :name))))))))))

(defun agent-river-launch--inbox ()
  "Return the delivered files, oldest first."
  (sort (directory-files (agent-river-launch--dir nil) t "\\.json\\'" t)
        (lambda (a b)
          (time-less-p (file-attribute-modification-time (file-attributes a))
                       (file-attribute-modification-time (file-attributes b))))))

(defun agent-river-launch--recover ()
  "Rebuild the in-memory queue from `queued/'.

The queue is derivable from the filesystem, which is the whole reason the
filesystem holds it: an Emacs that was restarted -- or crashed mid-task at
three in the morning, which is the case this is really for -- comes back
to the same candidates rather than to an empty queue and a `done/'
directory claiming they were handled."
  (dolist (file (sort (directory-files (agent-river-launch--dir "queued")
                                       t "\\.json\\'" t)
                      #'string<))
    (condition-case err
        (let ((candidate (agent-river-launch--candidate file)))
          (unless (agent-river-launch--queued-p (plist-get candidate :key))
            (agent-river-launch--enqueue candidate)))
      (error (agent-river-log "fail" (format "spool: cannot recover %s (%s)"
                                             (file-name-nondirectory file)
                                             (error-message-string err)))))))

;;;###autoload
(defun agent-river-launch-scan ()
  "Take in everything waiting in the spool.

Called by the watch, by the safety-net timer, and by hand.  Returns how
many candidates were taken in."
  (interactive)
  (agent-river-launch--ensure-dirs)
  (let ((taken 0)
        (files (agent-river-launch--inbox))
        (stopped nil))
    (while (and files (not stopped))
      (if (agent-river-launch--full-p)
          ;; Back-pressure, not loss: the files stay where they are and are
          ;; taken in once the queue has room.  One line per scan rather than
          ;; one per file, or a full queue would be reported a hundred times
          ;; in the log it is supposed to be visible in.
          (progn
            (setq stopped t)
            (agent-river-log "fail"
                             (format "spool: queue full at %d, %d waiting"
                                     (length agent-river-launch--queue)
                                     (length files))))
        (when (eq 'queued (plist-get (agent-river-launch--take-in (pop files))
                                     :decision))
          (setq taken (1+ taken)))))
    (agent-river-launch--drain)
    (agent-river-launch--redraw)
    (when (called-interactively-p 'interactive)
      (message "agent-river: %d taken in, %d queued"
               taken (length agent-river-launch--queue)))
    taken))


;;; Launchers -- the one end that starts a process
;;
;; A launcher is a plist, in the shape the contributors and the sources use:
;;
;;   :name         what the decision log calls it.
;;   :available-p  can it run here at all -- is the package it drives loaded.
;;   :launch       (CANDIDATE PROMPT) -> a handle, or signals.
;;   :resolve      (HANDLE) -> the session key, or nil while it is not known.
;;
;; The split between `:launch' and `:resolve' is forced by a real asymmetry
;; and is not a tidiness.  With agent-shell the ACP session id appears after
;; the process is up, so a launch can hand back only a handle -- the buffer --
;; and the binding candidate -> session is resolved afterwards.  With a
;; headless CLI the session id can be passed *in*, so the key is known before
;; the process starts and `:resolve' has nothing to do.  Where we control the
;; invocation we assign identity; where we do not, we resolve it after the
;; fact.
;;
;; Three switches stand between a candidate and a process, and each answers a
;; different question.  `agent-river-launch-launcher' says whether anything
;; can launch at all; a rule's `:prompt' says whether *this* rule may, since
;; there is nothing to say to an agent without one; and
;; `agent-river-launch-auto' says whether it happens without being asked.
;; That is the ladder: a launcher configured is rung 2, arming one rule is
;; rung 3, `auto' is rung 4 -- and each is a thing you can see yourself turn
;; on.

(declare-function agent-shell--start "agent-shell")
(declare-function agent-shell--insert-to-shell-buffer "agent-shell")
(declare-function shell-maker-busy "shell-maker")
(defvar agent-shell--state)

(defcustom agent-river-launch-launcher nil
  "Name of the launcher in `agent-river-launch-launchers', or nil.

Nil is shadow mode, and the default: an accepted candidate is decided
`ready' and filed, so the pipeline runs end to end with a no-op where the
process would go.  Read the decision log for a fortnight before setting
this, which is the whole reason it runs before there is anything to set."
  :type '(choice (const :tag "Shadow -- nothing starts" nil) string))

(defcustom agent-river-launch-auto nil
  "Launch an accepted candidate without being asked.

Nil holds it in the queue as `armed' and waits for RET, which is the
difference between watching it decide and letting it act.  Turn it on for
one rule's worth of evidence at a time; `:budget' and
`agent-river-launch-max-generation' are what stand between it and a bad
night."
  :type 'boolean)

(defcustom agent-river-launch-max-generation 2
  "How deep a chain of launches may go.

A launched agent produces events, which this layer sees, which can launch
another.  Left alone that feeds itself, and unlike a runaway observer every
iteration of it spends tokens and writes to a repository.

A candidate from a session we started is one generation deeper than that
session.  This is checked on every candidate whatever the rules say, since
a guard you have to remember to add to each rule is not a guard.  The
provenance guard -- not acting on what we ourselves caused -- is the
sharper instrument and belongs in a rule; this is the blunt one that holds
when the sharp one is missing."
  :type 'integer)

(defvar agent-river-launch--generations (make-hash-table :test 'equal)
  "Session key to the generation it was launched at.
A session nobody here started is absent, and reads as generation 0.")

(defun agent-river-launch--generation (candidate)
  "Return which generation CANDIDATE would be launched at."
  (let ((parent (plist-get candidate :session)))
    (1+ (or (and parent (gethash parent agent-river-launch--generations)) 0))))

(defcustom agent-river-launch-shell-config
  (lambda ()
    (when (fboundp 'agent-shell-anthropic-make-claude-code-config)
      (funcall (intern "agent-shell-anthropic-make-claude-code-config"))))
  "Function returning the agent-shell config a launch should start.

A function rather than a value because the config is built, and building
it reaches for authentication that need not exist when this file loads."
  :type 'function)

(defun agent-river-launch--shell-available-p ()
  "Return non-nil if agent-shell can host a session here."
  (and (fboundp 'agent-shell--start)
       (fboundp 'agent-shell--insert-to-shell-buffer)
       (functionp agent-river-launch-shell-config)
       ;; Built, not merely nameable: the config reaches for authentication,
       ;; and a launcher that reports itself available and then fails on its
       ;; first candidate has told the queue something untrue.
       (condition-case nil
           (and (funcall agent-river-launch-shell-config) t)
         (error nil))))

(defcustom agent-river-launch-shell-tries 60
  "How many seconds a launched shell is given to accept its prompt.

The session is not ready the moment the buffer exists -- the ACP handshake
is still running -- and there is no readiness signal to subscribe to, so
the prompt is offered once a second until it is taken.  Giving up says so
in the log rather than leaving a started agent sitting with nothing to do."
  :type 'integer)

(defun agent-river-launch--shell-send (buffer text tries)
  "Offer TEXT to the agent-shell in BUFFER, retrying up to TRIES times.

Busy means not ready rather than queue it: a prompt enqueued into a shell
that has never run one is processed when the *current* prompt completes,
and a shell still shaking hands has no current prompt for it to wait
behind."
  (when (buffer-live-p buffer)
    (unless (condition-case nil
                (with-current-buffer buffer
                  (unless (shell-maker-busy)
                    (agent-shell--insert-to-shell-buffer
                     :text text :submit t :no-focus t)
                    t))
              (error nil))
      (if (> tries 0)
          (run-with-timer 1 nil #'agent-river-launch--shell-send
                          buffer text (1- tries))
        (agent-river-log "fail" (format "launch: %s never took its prompt"
                                        (buffer-name buffer)))))))

(defun agent-river-launch--shell-launch (candidate prompt)
  "Start an agent-shell session for CANDIDATE and hand it PROMPT."
  (let* ((default-directory (or (plist-get candidate :cwd) default-directory))
         (buffer (agent-shell--start
                  :config (funcall agent-river-launch-shell-config)
                  :no-focus t :new-session t)))
    (unless (buffer-live-p buffer)
      (error "agent-shell started no buffer"))
    (agent-river-launch--shell-send buffer prompt
                                    agent-river-launch-shell-tries)
    buffer))

(defun agent-river-launch--shell-resolve (handle)
  "Return the session id agent-shell gave HANDLE, once it has one."
  (when (buffer-live-p handle)
    (with-current-buffer handle
      (alist-get :id (alist-get :session (bound-and-true-p agent-shell--state))))))

(defvar agent-river-launch-launchers
  (list (list :name "agent-shell"
              :available-p #'agent-river-launch--shell-available-p
              :launch #'agent-river-launch--shell-launch
              :resolve #'agent-river-launch--shell-resolve))
  "Available launchers, as plists.  See the section comment above.

agent-shell is the calibration launcher rather than the operating one: a
buffer at three in the morning waiting on a permission prompt is an agent
spending the night waiting for a human.  A headless launcher is the one
rung 4 wants, and it goes here beside this one.")

(defun agent-river-launch--available-p (launcher)
  "Return non-nil when LAUNCHER can run here.

Absent means yes: a launcher that drives nothing it has to check for has
no answer to give, and demanding one would make the protocol's optional
field mandatory by the back door.  Guarded like the rule callbacks, since
this is a user-supplied function too, and a test that throws is not an
availability."
  (let ((test (plist-get launcher :available-p)))
    (or (null test)
        (condition-case nil (and (funcall test) t) (error nil)))))

(defun agent-river-launch--launcher ()
  "Return the configured launcher, or nil for shadow mode.

Unavailable is the same as absent, and this is the one place that decides
it -- so `:available-p', which the protocol has documented from the
start, is finally asked.  Read only at selection time, because it is a
current-state fact: a package loaded after Emacs started makes its
launcher available without anything here being told.

Answering here rather than at the launch is what keeps the failure from
happening at the worst possible moment.  `--refusal' asks only whether a
launcher is *configured*, so with `agent-river-launch-launcher' set to a
package that is not loaded, candidates drew armed, RET passed the check,
the user was asked to confirm -- and only then did `--launch' fail, on a
path that *finishes* the candidate.  The occasion was spent on a launch
that never happened, with a confirmation collected for it.  Unavailable
reading as shadow mode puts the whole dry run back in its place."
  (when agent-river-launch-launcher
    (let ((launcher (seq-find (lambda (l)
                                (equal (plist-get l :name)
                                       agent-river-launch-launcher))
                              agent-river-launch-launchers)))
      (and launcher (agent-river-launch--available-p launcher) launcher))))

(defun agent-river-launch-context (candidate)
  "Return what is measured about CANDIDATE's session, as Markdown.

For a rule's `:prompt' to build on.  It is the Markdown export and not a
fourth rendering of the state: that export exists for where the state
*leaves* the package -- an issue, a pull request, a message -- and a
prompt to another agent is exactly that, so it already escapes the
agent's words and already marks a claim as a claim.

The claim is appended last and quoted, for the same reason `intent' is
last and marked twice over there.  It is the one thing here that is not a
measurement, and a reader -- the next agent -- who takes it for one has no
way back to the distinction."
  (let* ((session (plist-get candidate :session))
         (state (and (fboundp 'agent-river-markdown) session
                     (agent-river-markdown session)))
         (claim (plist-get candidate :claim)))
    (concat (or state "")
            (when claim
              (format "\n> %s said, of its own work: %s\n"
                      (or (plist-get candidate :actor) "the agent")
                      (agent-river--md-escape (agent-river--squish claim)))))))

(defun agent-river-launch-handoff-instructions ()
  "Return the text telling an agent how to hand off when it is done.

For a rule\='s `:prompt' to append.  It belongs here rather than with any
one source: handing off is this layer\='s convention, and a GitHub issue is
only one of the things an agent might be finishing.

Three things it owes.  It carries the **configured** spool rather than a
path written into the sentence, or an agent would be told to write
somewhere nothing is watching.  It is guarded on the directory existing, so
in a checkout where none of this is running the instruction degrades to a
no-op rather than to an error the agent then tries to fix.  And it says
outright that the agent\='s own words are a *quotation* that decides
nothing -- partly because it is true, and partly because an agent told that
its prose will be read as an instruction has been handed a reason to write
prose aimed at the reader."
  (let ((dir (directory-file-name (agent-river-launch--dir nil))))
    (concat
     "## Handing off\n\n"
     "When you have finished, or when there is a reason for another agent to "
     "pick this up, say so by writing one file:\n\n"
     "```sh\n"
     (format "d=%s\n" dir)
     "[ -d \"$d\" ] && {\n"
     "  printf '%s' \"{\\\"source\\\":\\\"handoff\\\","
     "\\\"occasion\\\":\\\"review\\\","
     "\\\"session\\\":\\\"$CLAUDE_CODE_SESSION_ID\\\","
     "\\\"cwd\\\":\\\"$PWD\\\","
     "\\\"text\\\":\\\"one line on why\\\"}\" > \"$d/h-$$.tmp\"\n"
     "  mv \"$d/h-$$.tmp\" \"$d/h-$$.json\"\n"
     "}\n"
     "```\n\n"
     "Once, at the end -- not after every step, and not when you have simply "
     "stopped. `occasion` is one of `done`, `review` or `blocked`, and is the "
     "only field a rule reads. The `text` is your own account of the work: it "
     "is shown as a quotation attributed to you, it is not read as an "
     "instruction, and it decides nothing.\n"))) 

(defun agent-river-launch--prompt (rule candidate)
  "Return what RULE would say to an agent about CANDIDATE, or nil.

Nil means this rule cannot launch and never will -- there is nothing to
say to an agent -- which is what makes `:prompt' the per-rule arming
switch rather than a setting of its own.

A prompt that throws is no prompt, which is the same answer `:match',
`:gate' and `:launch' each get and for the sharper version of their
reason.  Unguarded, one rule whose `:prompt' hits a field the source
happened to omit takes the whole of `--drain' with it -- and the drain
assigns `agent-river-launch--queue' only after its loop, so the unwind
leaves the queue holding candidates it has already decided and filed.
Every tick from then on re-decides them, once a minute, for as long as
Emacs runs, and the only trace is one `scan failed' line an hour.
Falling to the dry run instead is the truthful landing place: a rule that
cannot produce a prompt cannot launch, which is exactly what the dry run
is."
  (let ((prompt (plist-get rule :prompt)))
    (cond
     ((functionp prompt)
      (condition-case err
          (funcall prompt candidate)
        (error
         (agent-river-log "fail" (format "rule %s: :prompt errored (%s)"
                                         (plist-get rule :name)
                                         (error-message-string err)))
         nil)))
     ((agent-river-launch--string prompt) prompt))))

(defvar agent-river-launch--launched nil
  "Launch records still waiting for a session, newest first.
Each is (:key :at :rule :launcher :handle :generation).  A record exists
only to ask its handle what session it became, so that what that session
hands off can be recognised as a generation on -- see
`agent-river-launch--generations', which is where the answer goes and
which is read from.  A record that has answered has nothing left to do
and is dropped, which is also what keeps this list from being a log of
every launch this Emacs ever made.")

(defconst agent-river-launch--resolve-window 300
  "Seconds a launch is asked what session it became before it is given up on.

There has to be a number, and it cannot be inferred: `:resolve' returning
nil means \"not yet\" and \"never\" in the same breath, so nothing in the
answer distinguishes a handshake still running from a process that died
before it announced anything.  Five minutes is far longer than any
handshake and far shorter than an Emacs session, which is the only
property it needs.")

(defun agent-river-launch--resolve-pending ()
  "Ask each pending launch record for its session key, and drop the settled.

Late binding, and it has to be able to give up -- which it now does, in
both directions.  A record that resolves has done its one job and goes;
a record that has not resolved inside
`agent-river-launch--resolve-window' is a launch whose session never
appeared, and asking it again every minute for the life of the Emacs is
what this docstring used to describe while the body kept every record
forever.

Giving up is said out loud.  A launcher that starts something which never
becomes a session is the failure this layer is least able to see -- the
candidate was filed as `launched' and nothing afterwards contradicts it
-- so the one place that notices had better not also be the one place
that stays quiet about it."
  (let (keep)
    (dolist (record agent-river-launch--launched)
      (let* ((launcher (seq-find (lambda (l)
                                   (equal (plist-get l :name)
                                          (plist-get record :launcher)))
                                 agent-river-launch-launchers))
             (resolve (plist-get launcher :resolve))
             (session (and resolve
                           (condition-case nil
                               (funcall resolve (plist-get record :handle))
                             (error nil)))))
        (cond
         (session
          (puthash session (plist-get record :generation)
                   agent-river-launch--generations))
         ;; Nothing to ask.  A launcher with no `:resolve' is one that
         ;; assigns the session id before the process starts, which is the
         ;; headless case the split exists for -- and a launcher that has
         ;; since been unconfigured cannot answer either.  Settled, not
         ;; failed.
         ((null resolve) nil)
         ((> (float-time (time-subtract (current-time)
                                        (plist-get record :at)))
             agent-river-launch--resolve-window)
          (agent-river-log
           "fail" (format "launch: %s never became a session"
                          (plist-get record :key))))
         (t (push record keep)))))
    (setq agent-river-launch--launched (nreverse keep))))

(defun agent-river-launch--launch (rule candidate)
  "Start something for CANDIDATE under RULE, and return its decision.

Never lets a launcher's failure take the drain with it: a launch that
throws is a decision like any other, so the candidate is finished rather
than left in a queue that would try it again every minute."
  (let ((launcher (agent-river-launch--launcher))
        (prompt (agent-river-launch--prompt rule candidate)))
    (condition-case err
        (let* ((handle (funcall (plist-get launcher :launch) candidate prompt))
               (record (list :key (plist-get candidate :key)
                             :at (current-time)
                             :rule (plist-get rule :name)
                             :launcher (plist-get launcher :name)
                             :handle handle
                             :generation (agent-river-launch--generation
                                          candidate))))
          (push record agent-river-launch--launched)
          (agent-river-launch--finish
           candidate 'launched
           (format "rule %s via %s" (plist-get rule :name)
                   (plist-get launcher :name))))
      (error
       (agent-river-log "fail" (format "launch failed: %s"
                                       (error-message-string err)))
       (agent-river-launch--finish candidate 'failed
                                   (error-message-string err))))))

;;; The drain
;;
;; Where a gate is asked and, one commit from now, where a launcher is called.
;; There is no launcher yet, so an accepted candidate is decided `ready' and
;; filed -- the pipeline runs end to end and the last step is a no-op instead
;; of a process.  That is what makes this a dry run rather than a half-built
;; one: the queue drains, the budget is spent, and the log says what would
;; have happened at the moment it would have happened.
;;
;; The gates read the world, so this has to run when nothing has been
;; delivered -- an agent going idle is what unblocks a held candidate, and no
;; file arrives to say so.  `agent-river-launch-poll-interval' is therefore
;; the drain's clock as well as the spool's safety net, which is the second
;; job that variable has and the reason its default is a minute rather than an
;; hour.  Draining on `agent-river-observers' would be sharper and belongs
;; with the launcher, debounced: that hook fires on every tool call.

(defun agent-river-launch--say (candidate decision reason)
  "Decide DECISION about CANDIDATE for REASON, unless that is what it said last.

A candidate that stays in the queue is asked again every minute, and
sixty identical lines an hour would bury the transitions this log exists
to show.  What is remembered is the pair: a hold whose *reason* changes is
news, and so is a held candidate becoming armed."
  (let ((said (cons decision reason)))
    (unless (equal said (plist-get candidate :said))
      (agent-river-launch--decide decision candidate reason))
    (plist-put candidate :said said)))

(defun agent-river-launch--act (rule candidate)
  "Do for CANDIDATE whatever RULE and the switches allow.
Return non-nil if it should stay in the queue."
  (let* ((launcher (agent-river-launch--launcher))
         (prompt (and launcher (agent-river-launch--prompt rule candidate))))
    (cond
     ;; Nothing to launch with, or nothing to say: the dry run, which is
     ;; where every rule starts and where a rule without a `:prompt' stays
     ;; however the other two switches are set.
     ((null prompt)
      (agent-river-launch--spend rule)
      (agent-river-launch--finish
       candidate 'ready
       (format "rule %s, %s" (plist-get rule :name)
               (if launcher "which has no :prompt" "nothing to launch it with")))
      nil)
     (agent-river-launch-auto
      (agent-river-launch--spend rule)
      (agent-river-launch--launch rule candidate)
      nil)
     ;; Armed: everything agrees except that nobody has said now.  It stays
     ;; in the queue, which is what RET acts on -- and the budget is not
     ;; spent, or a candidate waiting an hour would spend it sixty times.
     (t
      (agent-river-launch--say candidate 'armed
                               (format "rule %s, waiting for RET"
                                       (plist-get rule :name)))
      t))))

(defun agent-river-launch--spend (rule)
  "Record that RULE let one through, for `:budget' to count."
  (push (cons (current-time) (plist-get rule :name))
        agent-river-launch--accepted))

(defvar agent-river-launch--draining nil
  "Non-nil while a drain is running, so a second one cannot start.

The queue is rewritten only after the loop below has classified all of
it, and nothing marks a candidate in flight in between.  So a `:launch'
that lets the event loop run -- `accept-process-output', `sit-for', a
prompt, anything a launcher might reasonably do -- lets the poll timer
re-enter on a queue that still holds the candidate being launched, where
it still matches its rule and still passes its gate, and it is launched a
second time.  The ledger cannot help: deduplication happens at intake and
this candidate is long past it.

Whether the launcher that ships pumps the loop today is not the question.
`agent-river-launch-launchers' is a public extension point and the
headless launcher this is waiting for plausibly will, so the guard sits
on the drain rather than on any launcher's good behaviour.")

(defun agent-river-launch--drain ()
  "Ask each queued candidate's gate, and act on the ones that may go."
  (if agent-river-launch--draining
      ;; Skipped rather than queued: the drain already running is walking the
      ;; same queue and will reach whatever this call would have.
      nil
    (let ((agent-river-launch--draining t))
      (agent-river-launch--drain-1))))

(defun agent-river-launch--drain-1 ()
  "Drain the queue once.  See `agent-river-launch--drain', which guards this."
  (agent-river-launch--resolve-pending)
  (let (keep)
    (dolist (candidate agent-river-launch--queue)
      (let ((rule (agent-river-launch--rule-for candidate)))
        (cond
         ;; The rules were edited under it.  Re-asking is the point of not
         ;; caching the match, and the answer is as final here as at intake.
         ((null rule)
          (agent-river-launch--finish candidate 'unmatched
                                      "no rule matches it any more"))
         ;; The chain guard, asked whatever the rules say.  A generation is a
         ;; property of the candidate, so this is as final as a match: no
         ;; amount of waiting makes a fourth-generation launch a third.
         ((> (agent-river-launch--generation candidate)
             agent-river-launch-max-generation)
          (agent-river-launch--finish
           candidate 'refused
           (format "generation %d, cap %d"
                   (agent-river-launch--generation candidate)
                   agent-river-launch-max-generation)))
         (t
          (let ((reason (agent-river-launch--gate rule candidate)))
            (cond
             (reason
              (agent-river-launch--say candidate 'held reason)
              (push candidate keep))
             ((agent-river-launch--act rule candidate)
              (push candidate keep))))))))
    (setq agent-river-launch--queue (nreverse keep))))

(defun agent-river-launch--refusal (candidate)
  "Return why CANDIDATE cannot be launched by hand, or nil.

The three things RET cannot override, in one place because two callers
need the same answer for opposite purposes: `agent-river-launch-now\='
signals it, and the command that asks before calling it has to know
there is something to ask about.  Asked twice, a reader would be made to
confirm a launch that was never going to happen -- and the second copy
would be the one that went stale."
  (let ((rule (agent-river-launch--rule-for candidate)))
    (cond
     ((null (agent-river-launch--launcher))
      ;; Configured and unavailable is a different thing to say than nothing
      ;; configured, and it is the one a reader can act on: the setting is
      ;; right and the package behind it is not loaded.
      (if agent-river-launch-launcher
          (format "Launcher `%s' is not available here"
                  agent-river-launch-launcher)
        "No launcher: set `agent-river-launch-launcher' first"))
     ((null rule)
      "No rule matches this candidate any more")
     ((null (agent-river-launch--prompt rule candidate))
      (format "Rule `%s' has no :prompt, so it can only ever be a dry run"
              (plist-get rule :name))))))

;;;###autoload
(defun agent-river-launch-now (candidate)
  "Launch CANDIDATE now, whatever its gate says.

The gesture rung 2 is made of, and it overrides the gate deliberately:
a gate is this layer\='s guess about whether the moment is right, and a
person pressing RET is not a guess.  What it cannot override is the rule
having nothing to say -- there is no prompt to invent -- or there being no
launcher configured at all."
  (let ((refusal (agent-river-launch--refusal candidate)))
    (when refusal (user-error "%s" refusal))
    (let ((rule (agent-river-launch--rule-for candidate)))
      (agent-river-launch--spend rule)
      (agent-river-launch--launch rule candidate)
      (setq agent-river-launch--queue (delq candidate agent-river-launch--queue))
      (agent-river-launch--redraw))))

;;;###autoload
(defun agent-river-launch-drain ()
  "Ask the gates now, rather than waiting for the next scan."
  (interactive)
  (agent-river-launch--drain)
  (agent-river-launch--redraw)
  (when (called-interactively-p 'interactive)
    (message "agent-river: %d still queued" (length agent-river-launch--queue))))


;;; Watching the spool

(defvar agent-river-launch--watch nil
  "The `file-notify' descriptor for the inbox, or nil.")

(defvar agent-river-launch--timer nil
  "The safety-net scan timer, or nil.")

(defvar agent-river-launch--soon nil
  "A pending debounced scan, or nil.")

(defun agent-river-launch--scan-soon ()
  "Scan shortly, coalescing a burst of deliveries into one scan."
  (unless agent-river-launch--soon
    (setq agent-river-launch--soon
          (run-with-idle-timer
           0.3 nil
           (lambda ()
             (setq agent-river-launch--soon nil)
             (condition-case err
                 (agent-river-launch-scan)
               (error (agent-river-log
                       "fail" (format "spool: scan failed (%s)"
                                      (error-message-string err))))))))))

(defun agent-river-launch--notify (_event)
  "Note that something arrived in the spool."
  (agent-river-launch--scan-soon))

;;;###autoload
(define-minor-mode agent-river-launch-mode
  "Watch `agent-river-launch-spool' and queue what is delivered to it.

Nothing is started.  This is the first of four rungs: candidates arrive,
are deduplicated against the ledger, are matched and gated by
`agent-river-launch-rules', and are decided about in `*agent-river-queue*'
where you can read what would have happened.  There is no launcher in this
file yet, so there is nothing for a wrong rule to cost -- which is what
makes it worth pointing a rule at real events and leaving it running.

Turning it on takes in whatever was delivered while it was off, and
rebuilds the queue from disk."
  :global t
  :lighter " River>"
  (if agent-river-launch-mode
      (progn
        (agent-river-launch--ensure-dirs)
        (agent-river-launch--recover)
        (setq agent-river-launch--watch
              ;; A watch is a nicety, not the mechanism: it is what makes a
              ;; delivery land in under a second, and where it cannot be had
              ;; -- no inotify, a remote spool -- the timer below is still
              ;; the whole guarantee.
              (ignore-errors
                (file-notify-add-watch (agent-river-launch--dir nil)
                                       '(change)
                                       #'agent-river-launch--notify)))
        (when agent-river-launch-poll-interval
          (setq agent-river-launch--timer
                (run-with-timer agent-river-launch-poll-interval
                                agent-river-launch-poll-interval
                                #'agent-river-launch--scan-soon)))
        (agent-river-launch-scan))
    (when agent-river-launch--watch
      (ignore-errors (file-notify-rm-watch agent-river-launch--watch)))
    (when (timerp agent-river-launch--timer)
      (cancel-timer agent-river-launch--timer))
    (when (timerp agent-river-launch--soon)
      (cancel-timer agent-river-launch--soon))
    (setq agent-river-launch--watch nil
          agent-river-launch--timer nil
          agent-river-launch--soon nil)))


;;; The queue, looked at
;;
;; A read-only view of a store written elsewhere, like the map -- so
;; `special-mode', and no gesture that offers an edit the next redraw would
;; throw away.  Not Markdown: a candidate's title comes from whoever opened
;; the issue, and the HUD is not Markdown for exactly that reason.
;;
;; The same keys as the HUD, the map and the approval queue, for the same
;; three grains: `n'/`p' walk every line worth stopping on, `M-n'/`M-p' walk
;; the candidates past their own detail, and `>'/`<' walk the ones RET could
;; act on.  A candidate is a session line is a question block; its rule and
;; claim lines are detail headings; a decision line is the log, and rides
;; the fine grain the way a log line does in the HUD.
;;
;; What `>' means here is "armed": rule matched, gate open, prompt present,
;; launcher configured -- so it and RET agree exactly about what is
;; actionable, which is the property worth having.  In shadow mode that set
;; is empty and the motion refuses, and that is the true answer rather than
;; a dead key: nothing being armed is what shadow mode *is*.

(defvar agent-river-launch--decision-faces
  '((launched . agent-river-prompt)
    (armed . agent-river-signal)
    (failed . agent-river-fail)
    (refused . agent-river-stale)
    (ready . agent-river-prompt)
    (queued . agent-river-act)
    (held . agent-river-signal)
    (duplicate . agent-river-stale)
    (unmatched . agent-river-stale)
    (malformed . agent-river-fail))
  "Alist of decision to the face it is shown in.
Inherited through agent-river's own faces, so the queue reads in whatever
the theme already means by these -- no colour is chosen here.")

(defun agent-river-launch--when (time)
  "Render TIME as a short local clock reading."
  (if time (format-time-string "%H:%M:%S" time) "--:--:--"))

(defmacro agent-river-launch--with-candidate (candidate &rest body)
  "Run BODY, marking everything it inserts as belonging to CANDIDATE."
  (declare (indent 1))
  `(let ((start (point)))
     ,@body
     (put-text-property start (point) 'agent-river-launch-candidate ,candidate)))

(defmacro agent-river-launch--row (row kind &rest body)
  "Run BODY, marking what it inserts as a row of KIND named ROW.

Two properties and not one.  KIND is what a motion may stop on, and it is
a property rather than a regexp over the text for the reason the other
three buffers keep it one: the rendering is there to be changed, and a
motion read off the rendering changes with it.  ROW is what the line
*names*, which is how a redraw finds it again."
  (declare (indent 2))
  `(let ((start (point)))
     ,@body
     (add-text-properties start (point)
                          (list 'agent-river-line ,kind
                                'agent-river-launch-row ,row))))

(defun agent-river-launch-candidate-at-point ()
  "Return the candidate the point is in, or nil."
  (get-text-property (point) 'agent-river-launch-candidate))


;;; Motion -- the three grains, as everywhere else

(defun agent-river-launch--line-p ()
  "Return non-nil on a line any motion may stop on."
  (and (get-text-property (line-beginning-position) 'agent-river-line) t))

(defun agent-river-launch--candidate-line-p ()
  "Return non-nil on the first line of a candidate."
  (eq (get-text-property (line-beginning-position) 'agent-river-line)
      'candidate))

(defun agent-river-launch--armed-line-p ()
  "Return non-nil on a candidate RET could launch."
  (and (get-text-property (line-beginning-position) 'agent-river-launch-armed)
       t))

(defun agent-river-launch--beginning-of-row ()
  "Put point on the first character of the row's own text.
A detail line is indented, and a cursor parked in column zero reads as
though the indent were the content."
  (goto-char (line-beginning-position))
  (skip-chars-forward " "))

(defun agent-river-launch--scan (count test)
  "Move to the COUNTth line satisfying TEST, forward when COUNT is positive."
  (agent-river--scan count test #'agent-river-launch--beginning-of-row))

(defun agent-river-queue-next-line (&optional n)
  "Move to the Nth next line worth stopping on."
  (interactive "p")
  (or (agent-river-launch--scan (or n 1) #'agent-river-launch--line-p)
      (user-error "No further line")))

(defun agent-river-queue-previous-line (&optional n)
  "Move to the Nth previous line worth stopping on."
  (interactive "p")
  (agent-river-queue-next-line (- (or n 1))))

(defun agent-river-queue-next-candidate (&optional n)
  "Move to the Nth next candidate, past this one's own detail."
  (interactive "p")
  (or (agent-river-launch--scan (or n 1) #'agent-river-launch--candidate-line-p)
      (user-error "No further candidate")))

(defun agent-river-queue-previous-candidate (&optional n)
  "Move to the Nth previous candidate."
  (interactive "p")
  (agent-river-queue-next-candidate (- (or n 1))))

(defun agent-river-queue-next-armed (&optional n)
  "Move to the Nth next candidate that is waiting for RET."
  (interactive "p")
  (or (agent-river-launch--scan (or n 1) #'agent-river-launch--armed-line-p)
      (user-error "Nothing is waiting for you")))

(defun agent-river-queue-previous-armed (&optional n)
  "Move to the Nth previous candidate that is waiting for RET."
  (interactive "p")
  (agent-river-queue-next-armed (- (or n 1))))


;;; Finding a line again after the buffer is rebuilt

(defun agent-river-launch--here ()
  "Return what the line at point names, for a redraw to find again.
A cons of the row's name and its kind, or nil where it names nothing."
  (let ((row (get-text-property (line-beginning-position)
                                'agent-river-launch-row)))
    (when row
      (cons row (get-text-property (line-beginning-position)
                                   'agent-river-line)))))

(defun agent-river-launch--find (row kind)
  "Return the position of the line naming ROW as KIND, or nil."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (if (and (equal row (get-text-property (line-beginning-position)
                                               'agent-river-launch-row))
                 (eq kind (get-text-property (line-beginning-position)
                                             'agent-river-line)))
            (setq found (line-beginning-position))
          (forward-line 1)))
      found)))

(defun agent-river-launch--goto (here)
  "Put point back on the line HERE named, or on the first line there is.

By name rather than by position, the way the HUD\='s block, the map\='s
listing and the approval queue\='s rows all do it.  The buffer is rebuilt
on every intake and every drain, and a candidate that left from above
would otherwise slide a different candidate under a finger already on
its way down to RET -- which in this buffer does not answer a question,
it starts a process.

A candidate whose detail line has gone -- it stopped being held, so
there is no longer a reason to show -- keeps the reader on the candidate
itself rather than sending them to the top."
  (let ((pos (and here (or (agent-river-launch--find (car here) (cdr here))
                           (agent-river-launch--find (car here) 'candidate)))))
    (goto-char (or pos (point-min)))
    (unless pos
      (unless (agent-river-launch--line-p)
        (agent-river-launch--scan 1 #'agent-river-launch--line-p)))
    (agent-river-launch--beginning-of-row)))

(defun agent-river-launch--draw ()
  "Render the queue and the recent decisions into the current buffer."
  (let ((inhibit-read-only t)
        ;; Asked before the erase, because the erase takes the properties
        ;; the answer is read off with it.
        (here (agent-river-launch--here)))
    (erase-buffer)
    (insert (propertize (format "%d queued" (length agent-river-launch--queue))
                        'face 'agent-river-session)
            (propertize (format "   %s   %s\n"
                                (abbreviate-file-name
                                 (agent-river-launch--dir nil))
                                (if agent-river-launch-mode "watching" "off"))
                        'face 'agent-river-time))
    ;; What the three switches are set to, because that is the whole answer
    ;; to "why did nothing start" and it is the one thing here that changes
    ;; without an event to announce it.
    (insert (propertize
             (format "  %s\n\n"
                     (cond
                      ((null (agent-river-launch--launcher))
                       (if agent-river-launch-launcher
                           (format "shadow -- %s is not available here"
                                   agent-river-launch-launcher)
                         "shadow -- no launcher, nothing starts"))
                      (agent-river-launch-auto
                       (format "%s, automatic"
                               agent-river-launch-launcher))
                      (t (format "%s, RET to launch"
                                 agent-river-launch-launcher))))
             'face 'agent-river-stale))
    (if (null agent-river-launch--queue)
        (insert (propertize "  queue empty\n" 'face 'agent-river-stale))
      (dolist (candidate agent-river-launch--queue)
       ;; The whole block is marked, not just its first line: RET has to work
       ;; from wherever the eye stopped, and a candidate is three lines deep.
       (agent-river-launch--with-candidate candidate
        (let ((key (plist-get candidate :key))
              (said (plist-get candidate :said))
              (from (point)))
          (agent-river-launch--row key 'candidate
            (insert (propertize (agent-river-launch--when
                                 (plist-get candidate :at))
                                'face 'agent-river-time)
                    " "
                    (propertize (plist-get candidate :source)
                                'face 'agent-river-session)
                    "  "
                    (propertize (or (plist-get candidate :title) "")
                                'face 'agent-river-act)
                    (let ((actor (plist-get candidate :actor)))
                      (if actor (propertize (format "  <%s>" actor)
                                            'face 'agent-river-time)
                        ""))
                    "\n"))
          ;; Read off the decision the drain last recorded rather than asked
          ;; again here: `>' and RET have to agree about what is actionable,
          ;; and asking twice is two answers waiting to differ.
          (when (eq (car-safe said) 'armed)
            (put-text-property from (point) 'agent-river-launch-armed t))
          ;; Why it is still here rather than gone: the rule it is waiting
          ;; under and what that rule is waiting for.  A queue that says only
          ;; what is in it leaves the one question a reader has -- why has
          ;; this not happened -- to be answered from the decision log by
          ;; hand.
          (let ((rule (agent-river-launch--rule-for candidate)))
            (agent-river-launch--row key 'detail
              (insert (propertize (format "         %s%s\n"
                                          (if rule
                                              (format "rule %s"
                                                      (plist-get rule :name))
                                            "no rule")
                                          (if said
                                              (format " -- %s: %s"
                                                      (car said) (cdr said))
                                            ""))
                                  'face 'agent-river-think))))
          ;; The claim last and marked as a quotation, for the reason the
          ;; Markdown export puts `intent' last and marks it twice: it is the
          ;; subject talking about itself, and a reader who takes it for one
          ;; of the measurements above has no way back to the distinction.
          (let ((claim (plist-get candidate :claim)))
            (when claim
              (agent-river-launch--row key 'detail
                (insert (propertize (format "         \"%s\"\n"
                                            (agent-river--clip
                                             (agent-river--squish claim) 60))
                                    'face 'agent-river-intent)))))))))
    (insert (propertize "\ndecisions\n" 'face 'agent-river-prompt))
    (if (null agent-river-launch--decisions)
        (insert (propertize "  none yet\n" 'face 'agent-river-stale))
      (dolist (entry agent-river-launch--decisions)
        (agent-river-launch--row (format "d%s" (plist-get entry :n)) 'decision
          (insert (propertize (agent-river-launch--when (plist-get entry :at))
                              'face 'agent-river-time)
                  " "
                  (propertize (format "%-10s" (plist-get entry :decision))
                              'face (or (alist-get (plist-get entry :decision)
                                                   agent-river-launch--decision-faces)
                                        'default))
                  (propertize (or (plist-get entry :title)
                                  (plist-get entry :key) "")
                              'face 'agent-river-think)
                  (propertize (format "  (%s)" (plist-get entry :reason))
                              'face 'agent-river-time)
                  "\n"))))
    (agent-river-launch--goto here)))

(defun agent-river-launch--redraw ()
  "Redraw the queue buffer if it is open.

Drawn inline rather than on a timer, unlike the map: intake runs at most
once per delivery and the whole view is a few dozen lines, so there is no
rebuild-per-tool-call problem here to debounce away."
  (let ((buffer (get-buffer agent-river-launch-queue-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (agent-river-launch--draw)))))

(defun agent-river-queue-launch ()
  "Start the candidate at point now, after asking.

Deliberately overrides its gate: a gate is this layer\='s guess about
whether the moment is right, and a person pressing RET is not a guess.

And it asks, where the approval queue spends a prompt on the two
`_always\=' answers only.  That reason does not carry over: there the
other answers each decide a single tool call, here every RET starts a
*process* -- the most expensive thing this package does, and the one
gesture with nothing on the far side that can take it back -- so the
second keystroke is earned every time rather than for a standing kind.
`y-or-n-p\=' and not `yes-or-no-p\=', for that buffer\='s reason: a second
gesture is a confirmation, spelling out \"yes\" is a third.

What the question names is what is about to run, which is the half a row
cannot show."
  (interactive)
  (let ((candidate (agent-river-launch-candidate-at-point)))
    (unless candidate
      (user-error "No candidate here"))
    (let ((refusal (agent-river-launch--refusal candidate)))
      (when refusal (user-error "%s" refusal)))
    (if (y-or-n-p (format "Start %s on %s? "
                          (plist-get (agent-river-launch--launcher) :name)
                          (agent-river--clip
                           (agent-river--squish
                            (or (plist-get candidate :title)
                                (plist-get candidate :key)))
                           50)))
        (progn (agent-river-launch-now candidate)
               (message "agent-river: launched"))
      (message "agent-river: left in the queue"))))

(defun agent-river-queue-refresh ()
  "Take in anything waiting, then redraw."
  (interactive)
  (agent-river-launch-scan)
  (agent-river-launch--redraw))

(define-derived-mode agent-river-queue-mode special-mode "Agent-Queue"
  "Major mode for the launch queue and its decisions."
  (setq-local truncate-lines t)
  (setq-local header-line-format nil)
  ;; On, like the map and the approval queue and unlike the HUD: this buffer
  ;; pins its point nowhere, so wherever point is is where a reader put it,
  ;; and the highlight is what says which candidate RET would start.
  (when (fboundp 'hl-line-mode) (hl-line-mode 1))
  (buffer-disable-undo))

(let ((map agent-river-queue-mode-map))
  (define-key map (kbd "g") #'agent-river-queue-refresh)
  (define-key map (kbd "RET") #'agent-river-queue-launch)
  (define-key map (kbd "n") #'agent-river-queue-next-line)
  (define-key map (kbd "p") #'agent-river-queue-previous-line)
  (define-key map (kbd "SPC") #'agent-river-queue-next-line)
  (define-key map (kbd "DEL") #'agent-river-queue-previous-line)
  (define-key map [remap next-line] #'agent-river-queue-next-line)
  (define-key map [remap previous-line] #'agent-river-queue-previous-line)
  (define-key map (kbd "M-n") #'agent-river-queue-next-candidate)
  (define-key map (kbd "M-p") #'agent-river-queue-previous-candidate)
  (define-key map (kbd ">") #'agent-river-queue-next-armed)
  (define-key map (kbd "<") #'agent-river-queue-previous-armed))

;;;###autoload
(defun agent-river-queue ()
  "Show what has been delivered to the spool and what was decided about it.

The view for the first rung: read it for a fortnight and it says which
events are worth acting on and how often a rule would have been wrong,
which is what the later rungs are armed on."
  (interactive)
  (let ((buffer (get-buffer-create agent-river-launch-queue-buffer-name)))
    (with-current-buffer buffer
      (agent-river-queue-mode)
      (agent-river-launch--draw))
    (pop-to-buffer buffer)))

(provide 'agent-river-launch)

;;; agent-river-launch.el ends here
