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
;; What is built here is the first rung of four: source, ledger and queue,
;; with **no launcher at all**.  Candidates arrive, are deduplicated, are
;; queued, and are looked at in `*agent-river-queue*'.  Nothing starts,
;; because nothing here can.  That is the point rather than an unfinished
;; edge: the path from "watch it decide" to "let it run overnight" is paved
;; with a fortnight of decisions, and the decisions only accrue in wall-clock
;; time, so the log has to be running long before the launcher exists.
;;
;; Rules and the launcher are the next two commits.  See the README section
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
;;   :source   which adapter read it, and which dialect :payload is in
;;   :at       when the occasion happened
;;   :title    one line, for a human reading the queue
;;   :actor    who caused it -- the provenance guard's input, later
;;   :cwd      where a session for this would be started
;;   :payload  the source's own data, unread by anything generic
;;   :file     where the candidate currently lives on disk

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
          :title (or (agent-river-launch--string (alist-get 'title data)) id)
          :actor (agent-river-launch--string (alist-get 'actor data))
          :cwd (let ((cwd (agent-river-launch--string (alist-get 'cwd data))))
                 (and cwd (expand-file-name cwd)))
          :payload (alist-get 'payload data))))

(defvar agent-river-launch-sources
  (list (cons "river" #'agent-river-launch--read-river))
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


;;; Intake

(defun agent-river-launch--take-in (file)
  "Take FILE out of the inbox, and return its decision.

Three outcomes, and each moves the file, because a file left in the inbox
is a file that will be read again on the next scan.  Unreadable goes to
`failed/' and is never read again -- kept rather than deleted, since the
only way to fix a source is to look at what it wrote.  A repeat is
deleted: `done/' or `queued/' already holds the canonical copy under the
same name, and a poller with no memory of its own would otherwise fill the
disk with identical files.  Anything else is moved to `queued/', which is
what makes the queue survive a restart."
  (let ((candidate (condition-case err
                       (agent-river-launch--candidate file)
                     (error (rename-file file (agent-river-launch--dir "failed")
                                         t)
                            (agent-river-log
                             "fail" (format "spool: %s (%s)"
                                            (file-name-nondirectory file)
                                            (error-message-string err)))
                            (agent-river-launch--decide
                             'malformed file (error-message-string err))
                            nil))))
    (when candidate
      (let ((key (plist-get candidate :key)))
        (cond
         ((agent-river-launch--seen-p key)
          (delete-file file)
          (agent-river-launch--decide 'duplicate candidate "already taken in"))
         (t
          (let ((dest (agent-river-launch--path "queued" key)))
            (rename-file file dest t)
            (agent-river-launch--enqueue (plist-put candidate :file dest)))
          (agent-river-launch--decide 'queued candidate "no rule yet")))))))

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
    (agent-river-launch--redraw)
    (when (called-interactively-p 'interactive)
      (message "agent-river: %d taken in, %d queued"
               taken (length agent-river-launch--queue)))
    taken))


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
are deduplicated against the ledger, and wait in `*agent-river-queue*'
where you can read what would have happened.  There is no launcher in this
file yet, so there is nothing for a wrong rule to cost.

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
  '((queued . agent-river-act)
    (duplicate . agent-river-stale)
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
                "\n")))
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
