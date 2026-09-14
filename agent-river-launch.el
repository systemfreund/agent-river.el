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
;; What is built here is the first rung of four: source, rule, ledger and
;; queue, with **no launcher at all**.  Candidates arrive, are deduplicated,
;; are matched against a rule, are held until its gate opens, and are then
;; decided `ready' -- the whole pipeline, with a no-op where the process
;; would go.  It is a dry run rather than a half-built one, and that is the
;; point rather than an unfinished edge: the path from "watch it decide" to
;; "let it run overnight" is paved with a fortnight of decisions, and
;; decisions only accrue in wall-clock time, so the log has to be running
;; long before the launcher exists.
;;
;; The launcher is the next commit.  See the README section
;; "A third direction: starting a session from an event" for the reasoning
;; behind all of it, including the parts not written yet.
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

(defun agent-river-launch--decide (decision candidate reason)
  "Record DECISION about CANDIDATE, because of REASON.
CANDIDATE may be a plist or, where reading failed, a file name."
  (let ((entry (list :at (current-time)
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
:session :key :cwd, and SPEC is a regexp, or a list of regexps of which
one must match.  All pairs must hold.  A regexp rather than a comparison
because several of these are prose; anchor it (\"\\\\`gh\\\\'\") where you
mean the whole value.

`:claim' is not among them and cannot be added: it holds what the subject
of the candidate said about itself, and a rule matching it would let an
agent choose the words that arm the rule it wanted.  `:occasion' is the
field a source is meant to steer -- a short token from a small vocabulary,
which is a choice a rule author can anticipate where a sentence is not.

In a `:gate' alist CHECK is one of:

  :max-concurrent N       refuse while N or more sessions are running.
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
     (let ((n (agent-river--active-count)))
       (and (>= n value) (format "%d session%s running, limit %d"
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

(defun agent-river-launch--drain ()
  "Ask each queued candidate's gate, and file the ones that may go."
  (let (keep)
    (dolist (candidate agent-river-launch--queue)
      (let ((rule (agent-river-launch--rule-for candidate)))
        (cond
         ;; The rules were edited under it.  Re-asking is the point of not
         ;; caching the match, and the answer is as final here as at intake.
         ((null rule)
          (agent-river-launch--finish candidate 'unmatched
                                      "no rule matches it any more"))
         (t
          (let ((reason (agent-river-launch--gate rule candidate)))
            (cond
             (reason
              ;; Logged on change only.  A candidate held by a budget for an
              ;; hour is asked sixty times, and sixty identical lines would
              ;; bury the transitions this log exists to show.
              (unless (equal reason (plist-get candidate :held))
                (agent-river-launch--decide 'held candidate reason))
              (push (plist-put candidate :held reason) keep))
             (t
              (push (cons (current-time) (plist-get rule :name))
                    agent-river-launch--accepted)
              (agent-river-launch--finish
               candidate 'ready
               (format "rule %s, nothing to launch it with yet"
                       (plist-get rule :name))))))))))
    (setq agent-river-launch--queue (nreverse keep))))

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

(defvar agent-river-launch--decision-faces
  '((ready . agent-river-prompt)
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

(defun agent-river-launch--draw ()
  "Render the queue and the recent decisions into the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "%d queued" (length agent-river-launch--queue))
                        'face 'agent-river-session)
            (propertize (format "   %s   %s\n"
                                (abbreviate-file-name
                                 (agent-river-launch--dir nil))
                                (if agent-river-launch-mode "watching" "off"))
                        'face 'agent-river-time))
    (insert (propertize "  no launcher yet -- nothing here starts\n\n"
                        'face 'agent-river-stale))
    (if (null agent-river-launch--queue)
        (insert (propertize "  queue empty\n" 'face 'agent-river-stale))
      (dolist (candidate agent-river-launch--queue)
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
                "\n")
        ;; Why it is still here rather than gone: the rule it is waiting under
        ;; and what that rule is waiting for.  A queue that says only what is
        ;; in it leaves the one question a reader has -- why has this not
        ;; happened -- to be answered from the decision log by hand.
        (let ((rule (agent-river-launch--rule-for candidate))
              (held (plist-get candidate :held)))
          (insert (propertize (format "         %s%s\n"
                                      (if rule
                                          (format "rule %s" (plist-get rule :name))
                                        "no rule")
                                      (if held (format " -- held: %s" held) ""))
                              'face 'agent-river-think)))
        ;; The claim last and marked as a quotation, for the reason the
        ;; Markdown export puts `intent' last and marks it twice: it is the
        ;; subject talking about itself, and a reader who takes it for one of
        ;; the measurements above has no way back to the distinction.
        (let ((claim (plist-get candidate :claim)))
          (when claim
            (insert (propertize (format "         \"%s\"\n"
                                        (agent-river--clip
                                         (agent-river--squish claim) 60))
                                'face 'agent-river-intent))))))
    (insert (propertize "\ndecisions\n" 'face 'agent-river-prompt))
    (if (null agent-river-launch--decisions)
        (insert (propertize "  none yet\n" 'face 'agent-river-stale))
      (dolist (entry agent-river-launch--decisions)
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
                "\n")))
    (goto-char (point-min))))

(defun agent-river-launch--redraw ()
  "Redraw the queue buffer if it is open.

Drawn inline rather than on a timer, unlike the map: intake runs at most
once per delivery and the whole view is a few dozen lines, so there is no
rebuild-per-tool-call problem here to debounce away."
  (let ((buffer (get-buffer agent-river-launch-queue-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((line (line-number-at-pos)))
          (agent-river-launch--draw)
          (forward-line (1- line)))))))

(defun agent-river-queue-refresh ()
  "Take in anything waiting, then redraw."
  (interactive)
  (agent-river-launch-scan)
  (agent-river-launch--redraw))

(define-derived-mode agent-river-queue-mode special-mode "Agent-Queue"
  "Major mode for the launch queue and its decisions."
  (setq-local truncate-lines t)
  (setq-local header-line-format nil)
  (buffer-disable-undo))

(define-key agent-river-queue-mode-map (kbd "g") #'agent-river-queue-refresh)

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
