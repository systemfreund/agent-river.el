;;; agent-river-spool.el --- Something from outside becomes an artifact -*- lexical-binding: t; -*-

;; Author: systemfreund <github@o9z.de>
;; Keywords: tools

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The door.  `agent-river.el' listens to what an agent does; this is where
;; something from *outside* becomes a subject here -- an issue is opened, a
;; build goes red, a ticket is assigned.  A file lands in the spool and comes
;; out as an artifact, which is drawn in its own section of the map.
;;
;; Nothing here starts anything.  Pointing an agent at one of these is
;; `agent-river-launch.el', which shares nothing with this file but the
;; subject they both address.
;;
;;   (agent-river-spool-mode 1)   ; watch the spool
;;   M-x agent-river-map          ; see what has arrived
;;
;; Delivering by hand, which is also how a poller does it -- built elsewhere,
;; renamed in:
;;
;;   d=${XDG_STATE_HOME:-$HOME/.local/state}/agent-river/spool
;;   printf '%s' '{"source":"river","key":"inc:INC-444","domain":"inc",
;;                 "name":"Checkout 500s","context":{"url":"https://..."}}' \
;;     > $d/x.tmp
;;   mv $d/x.tmp $d/x.json
;;
;; There used to be more here -- a candidate with an occasion-shaped key, a
;; durable ledger in `queued/' and `done/', rules, gates, a chain cap, a
;; decision log and a queue buffer -- and taking it out is what left this
;; file the size it is.  Nearly every part of it was the price of deciding
;; **unattended**, and with a person pressing the key each one either
;; disappears or turns out to be something `agent-river-artifacts' already
;; does: it answers nil for a key it has, its map section lists what nobody
;; has picked up, and `agent-river-ended' is what `done/' was for.  One
;; sentence pays for the deletion -- a repeat is a line, not an agent -- and
;; issue #37 is what would have to come back to lose that sentence.

;;; Code:

(require 'filenotify)
(require 'agent-river)

(defgroup agent-river-spool nil
  "Taking things in from outside, through a directory."
  :group 'agent-river
  :prefix "agent-river-spool-")

;;; Customisation

(defcustom agent-river-spool
  (expand-file-name "agent-river/spool/" (or (getenv "XDG_STATE_HOME")
                                             "~/.local/state/"))
  "Directory things are delivered to.

The only door.  A GitHub poller, a webhook, an agent writing a file, and
you with `echo' all write the same shape to the same place -- so a new kind
of source is a new writer and never a new mechanism.

Deliberately not under `user-emacs-directory', which is where a package's
data would otherwise go.  Everything else this package writes is written
by Emacs; this is written *to* Emacs, by processes that should not have to
know how an Emacs configuration is laid out -- and it is a working
directory rather than state anyone would keep.  It is also somewhere
people symlink package checkouts into, which on the first run of this put
a spool full of JSON inside a git repository.

One subdirectory underneath, and it is for what could not be read:

  <spool>/            the inbox: delivered, not yet taken in
  <spool>/failed/     unreadable, kept for you to look at

There used to be `queued/' and `done/' as well, and they were a durable
record of what had already been acted on -- which mattered when a machine
was doing the acting and a second launch was the cost of forgetting.
Nothing is launched from here any more without somebody asking, so a
delivery that arrives twice is a line that is already on the map, which
`agent-river-appeared' answers for by itself.  A second account of that on
disk would only be a way for the two to disagree.  A file that has been
taken in is therefore deleted.

A writer must build the file elsewhere and `rename' it in.  The watcher
sees a file the moment it appears, and a half-written one would be read as
malformed; a rename within a filesystem is atomic, so the file is never
visible incomplete.  Only names ending in \".json\" are taken in, which is
what leaves \".tmp\" free for the writing half."
  :type 'directory)

(defcustom agent-river-spool-poll-interval 60
  "Seconds between safety-net scans of the spool, or nil for none.

`file-notify' is the primary way a delivery is noticed and is far
quicker.  It is also not guaranteed: watches are lost when a directory is
recreated, the kernel runs out of them, and nothing over TRAMP has them
at all.  A delivery that is silently never noticed is the failure this
prevents, and at a minute the cost of preventing it is a `directory-files'
on a directory that is almost always empty."
  :type '(choice (const :tag "No safety net" nil) integer))

(defcustom agent-river-spool-settle 2
  "Seconds a file that will not parse is given before it is called broken.

The contract is write-then-rename, and a poller can be held to it.  A
writer that is not a program cannot be: an agent told to report something
reaches for `Write', which creates the file where the watch can already
see it, so its JSON is briefly half there.  Filing that under `failed/'
would throw the delivery away over a contract nobody told the writer
about, and throw it away *quietly* -- nothing tells a writer that what it
wrote was discarded.

So a file too young to be trusted is simply left for the next scan.  The
cost is that a genuinely broken file is filed a couple of seconds late."
  :type 'number)


;;; What a delivery says
;;
;; A reader turns one delivered file into a *spec*: the arguments an artifact
;; is declared with, and nothing else.
;;
;;   :key      the identity, carrying its domain -- `issue:owner/repo#42'
;;   :domain   the symbol that says who understands the key
;;   :name     what a human calls it
;;   :context  the producer's own data, an alist, opaque here
;;   :gone     non-nil if the thing is over -- closed, resolved, deleted
;;   :text     the line for the log
;;   :session  the agent-river session this came out of, where one did
;;
;; A reader returns a spec rather than declaring one, so there is one place
;; things enter the table and a reader tests without a table, a spool or a
;; timer.
;;
;; `:session' is noted on that session rather than folded into the record --
;; see `agent-river-spool--note-session'.
;;
;; There is no `:cwd': where an agent would start is not a property of the
;; thing it works on.  A source that knows a working tree puts it in the
;; context, and the brief reads it back out.

(defun agent-river-spool--string (value)
  "Return VALUE if it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun agent-river-spool--alist (value)
  "Return VALUE as an alist of symbol to value, or nil.
What `json-parse-buffer' hands back for an object, and nothing else --
a producer that sends a string or an array where a context belongs gets
no context rather than a record shaped like its mistake."
  (and (consp value) (consp (car value)) value))

(defun agent-river-spool--read-river (_source data)
  "Read DATA, already in the normalised shape, as a spec.

The built-in reader, and the fallback for a source with no adapter
registered -- which is why the adapter protocol below is not speculative.
A source that can write this shape directly needs no adapter at all, and
one that cannot has exactly one place to be taught.

`key' is the identity and should carry its domain, the way
`inc:INC-444' does: two producers that both number things from one would
otherwise collide on a bare number.

`domain' is required, and refused here rather than two layers down so
that the message names the field the delivery is missing.  It used to be
optional and a delivery without one made a record in the `file' domain --
which was this package's word for a key nobody had declared, so the
record was indistinguishable from no record at all: listed by no section
and drawn on no line.  A delivery that cannot say what kind of thing it
is carrying is a delivery nothing can show, and it goes to `failed/'
where its author can see it.

`session' is the one field that is not about the artifact at all.  A
producer that knows which session caused the thing it is delivering says
so, and that is noted on *that session* -- see
`agent-river-spool--note-session'."
  (let ((key (agent-river-spool--string (alist-get 'key data)))
        (domain (agent-river-spool--string (alist-get 'domain data))))
    (unless key
      (error "No `key': nothing to identify this by"))
    (unless domain
      (error "No `domain': nothing can say what kind of thing this is"))
    (list :key key
          :domain (intern domain)
          :name (agent-river-spool--string (alist-get 'name data))
          :context (agent-river-spool--alist (alist-get 'context data))
          :gone (and (alist-get 'gone data) t)
          :text (agent-river-spool--string (alist-get 'text data))
          :session (agent-river-spool--string (alist-get 'session data)))))

(defvar agent-river-spool-sources
  (list (cons "river" #'agent-river-spool--read-river))
  "Alist of (SOURCE . READER) turning a delivered file into a spec.

READER is called with the source name and the parsed JSON as an alist,
and returns a spec plist or signals.  It is the one place that knows a
source's dialect -- exactly the role `agent-river--event' plays for the
hosts, and for the same reason: a poller should move bytes and understand
nothing, so `gh's raw JSON is what lands in the spool and the knowledge of
what `gh' calls things lives in Elisp, under test.

A reader that throws costs its own file and nothing else: that file is
filed under `failed/' and never read again, so there is no runaway to
retire it from.  Unlike an observer, it cannot fail repeatedly.")

(defun agent-river-spool--spec (file)
  "Read FILE as a spec, or signal saying why it is not one."
  (let* ((data (with-temp-buffer
                 (insert-file-contents file)
                 (json-parse-buffer :object-type 'alist
                                    :null-object nil
                                    :false-object nil)))
         (source (or (agent-river-spool--string (alist-get 'source data))
                     (error "No `source': nothing says how to read this")))
         (reader (or (alist-get source agent-river-spool-sources
                                nil nil #'equal)
                     #'agent-river-spool--read-river))
         (spec (funcall reader source data)))
    (unless (agent-river-spool--string (plist-get spec :key))
      (error "Reader for `%s' produced no key" source))
    spec))


;;; Intake

(defun agent-river-spool--dir (name)
  "Return the spool subdirectory NAME, or the inbox for nil."
  (let ((dir (if name
                 (expand-file-name name agent-river-spool)
               agent-river-spool)))
    (file-name-as-directory (expand-file-name dir))))

(defun agent-river-spool--ensure-dirs ()
  "Create the spool and its subdirectory if they are not there."
  (dolist (name '(nil "failed"))
    (make-directory (agent-river-spool--dir name) t)))

(defun agent-river-spool--settling-p (file)
  "Return non-nil while FILE is too young to be called broken."
  (let ((mtime (file-attribute-modification-time (file-attributes file))))
    (and mtime (< (float-time (time-subtract (current-time) mtime))
                  agent-river-spool-settle))))

(defun agent-river-spool--fail (file err)
  "File FILE under `failed/' because of ERR, and say so.

This cannot be allowed to signal, and the reason is where it is called
from: both call sites are inside a `condition-case' *handler*, and an
error raised in a handler is not caught by its own `condition-case'.  So a
`rename-file' that fails here escapes the scan, leaving the file in the
inbox -- which `--inbox' sorts oldest-first, so every later scan reads the
same file and dies in the same place.  One delivery nobody can file stops
every delivery behind it, for good, while the safety net logs one
identical line a minute.  Measured: `failed/' at mode 500, and the good
delivery behind the broken one was never declared.

Two ways to get there and neither is exotic -- `failed/' not writable (a
spool on a mount, a root-owned directory a cron-run poller left behind),
and the file going away between the listing and the rename, which is the
in-place rewriting `agent-river-spool-settle' exists to tolerate.

Where it cannot be filed it is deleted, which is the lesser of the two
losses on offer: `failed/' is there so a source's author can look at what
their program wrote, and that is worth less than the door.  What is *not*
lost is the reason, which was already in the log a line earlier."
  (agent-river-log "fail" (agent-river--log-text
                           (format "spool: %s (%s)"
                                   (file-name-nondirectory file)
                                   (error-message-string err))))
  (condition-case filing
      (rename-file file (agent-river-spool--dir "failed") t)
    (error
     (agent-river-log "fail" (agent-river--log-text
                              (format "spool: cannot file %s (%s)"
                                      (file-name-nondirectory file)
                                      (error-message-string filing))))
     (ignore-errors (delete-file file)))))

(defun agent-river-spool--note-session (spec)
  "Note in the river that SPEC came out of a session, if it names one.

The producer direction, and what `agent-river-note' is for: something
only this layer can see, folded as an event of the session it is about,
so it is logged, counted in the report and attributable rather than
written straight onto a slot.

What is noted is the *fact*, never the claim.  A note is a measurement
and may therefore feed a signal, so folding in the agent's own words
would launder a claim into an observation about the world -- the very
loop the `intent*' slots are kept apart to prevent.  The words stay in
the artifact's context, where they are shown and read by nobody."
  (let* ((session (plist-get spec :session))
         (state (and session (gethash session agent-river-registry))))
    (when state
      (ignore-errors
        (agent-river-note (or (plist-get spec :text)
                              (plist-get spec :key))
                          session)))))

(defun agent-river-spool--declare (spec)
  "Declare what SPEC names, and return the artifact when that is news.

Nothing is declared for a **first sighting that is already over**.  The
ending being worth folding and the record being worth creating are two
different questions, and one call used to answer both: a source that
polls a world it did not watch re-sees everything that changed, so the
first wide poll declared a record for every thing that had ended since
the window opened, purely in order to strike it through.  The domain
section is the queue of what nobody has picked up, and an artifact
record does not fade the way a reached name does -- it stays until
`agent-river-drop-artifact\=' -- so those lines are permanent and there
are more of them than there are live ones.  Measured on one repository:
nine deliveries, seven of them over before anything here had heard of
the thing.

Which of the two it is, is a question the *table* answers, the way
`agent-river-observe-artifact\=' answers it for a producer that would
otherwise keep a list of its own.  `agent-river-artifact-at\=' rather
than `agent-river-artifact\=', which creates the record it is asked
about.

No log line, and that is the rule applied rather than a gap in it: the
spool logs failures, this is not one, and `artifact\=' is a notable kind
-- `>' stops on it -- where a thing that was over before anybody here
heard of it is the definition of a line that does not want attention.
A first sighting that is already over is not-news in the strongest
sense there is."
  (if (and (plist-get spec :gone)
           (not (agent-river-artifact-at (plist-get spec :key))))
      nil
    (prog1 (agent-river-appeared (plist-get spec :key)
                                 :domain (plist-get spec :domain)
                                 :name (plist-get spec :name)
                                 :context (plist-get spec :context)
                                 :text (plist-get spec :text))
      ;; An ending is folded even when appearing was not news: a repeat
      ;; report of a closed thing still says something moved.
      (when (plist-get spec :gone)
        (agent-river-ended (plist-get spec :key) (plist-get spec :text))))))

(defun agent-river-spool--take-in (file)
  "Take FILE out of the inbox.  Return non-nil if something was declared.

Three outcomes, and each gets the file out of the inbox, because a file
left there is a file the next scan reads again.  Unreadable goes to
`failed/' and is never read again -- kept rather than deleted, since the
only way to fix a source is to look at what it wrote.  Anything read is
declared and the file is *deleted*: the artifact table is the record now,
and a copy on disk beside it would only be a second account of what
arrived."
  (let ((spec (condition-case err
                  (agent-river-spool--spec file)
                (error
                 ;; A file still being written is not a broken file.
                 (unless (agent-river-spool--settling-p file)
                   (agent-river-spool--fail file err))
                 nil))))
    (when spec
      (condition-case err
          (prog1 t
            (agent-river-spool--note-session spec)
            (agent-river-spool--declare spec)
            (delete-file file))
        ;; Declaring threw; treat it like a file that would not parse rather
        ;; than retry it forever.
        (error (agent-river-spool--fail file err) nil)))))

(defun agent-river-spool--inbox ()
  "Return the delivered files, oldest first.

Each file is stat-ed once rather than once per comparison: the inbox is
empty most of the time and this is invisible, and the time it is not empty
is a backlog after a restart, which is exactly when a sort that stats
2·n·log n times is worst."
  (mapcar #'cdr
          (sort (mapcar (lambda (file)
                          (cons (file-attribute-modification-time
                                 (file-attributes file))
                                file))
                        (directory-files (agent-river-spool--dir nil) t
                                         "\\.json\\'" t))
                (lambda (a b) (time-less-p (car a) (car b))))))

;;;###autoload
(defun agent-river-spool-scan ()
  "Take in everything waiting in the spool.

Called by the watch, by the safety-net timer, and by hand.  Returns how
many deliveries were taken in."
  (interactive)
  (agent-river-spool--ensure-dirs)
  (let ((taken 0))
    (dolist (file (agent-river-spool--inbox))
      ;; Guarded per file, so a delivery that throws costs only itself and
      ;; the rest of the queue keeps moving.
      (when (condition-case err
                (agent-river-spool--take-in file)
              (error
               (agent-river-log "fail"
                                (agent-river--log-text
                                 (format "spool: %s could not be taken in (%s)"
                                         (file-name-nondirectory file)
                                         (error-message-string err))))
               nil))
        (setq taken (1+ taken))))
    (when (called-interactively-p 'interactive)
      (message "agent-river: %d taken in" taken))
    taken))


;;; Watching the spool

(defvar agent-river-spool--watch nil
  "The `file-notify' descriptor for the inbox, or nil.")

(defvar agent-river-spool--timer nil
  "The safety-net scan timer, or nil.")

(defvar agent-river-spool--soon nil
  "A pending debounced scan, or nil.")

(defun agent-river-spool--scan-safely ()
  "Scan, and report rather than signal.  What both timers call."
  (condition-case err
      (agent-river-spool-scan)
    (error (agent-river-log
            "fail" (agent-river--log-text
                    (format "spool: scan failed (%s)"
                            (error-message-string err)))))))

(defun agent-river-spool--scan-soon ()
  "Scan shortly, coalescing a burst of deliveries into one scan.

For the watch only.  The safety net calls `agent-river-spool--scan-safely'
directly: the debounce is an *idle* timer, and an Emacs that never goes
idle for a third of a second -- a long synchronous process, a tight loop
-- would never scan, which would make the one guarantee
`agent-river-spool-poll-interval' offers conditional on something it never
mentions.  A burst is what there is to coalesce, and the safety net has no
burst."
  (unless agent-river-spool--soon
    (setq agent-river-spool--soon
          (run-with-idle-timer
           0.3 nil
           (lambda ()
             (setq agent-river-spool--soon nil)
             (agent-river-spool--scan-safely))))))

(defun agent-river-spool--notify (_event)
  "Note that something arrived in the spool."
  (agent-river-spool--scan-soon))

;;;###autoload
(define-minor-mode agent-river-spool-mode
  "Watch `agent-river-spool' and declare what is delivered to it.

Nothing is started by this.  What arrives becomes an artifact, which is
drawn in its own section of \\[agent-river-map]; pointing an agent at one
is \\[agent-river-launch-artifact], and needs two more things configured.

Turning it on takes in whatever was delivered while it was off."
  :global t
  :lighter " River<"
  (if agent-river-spool-mode
      (progn
        (agent-river-spool--ensure-dirs)
        (setq agent-river-spool--watch
              ;; A nicety, not the guarantee: it lands a delivery quickly
              ;; where available, but the timer below is the real promise.
              (ignore-errors
                (file-notify-add-watch (agent-river-spool--dir nil)
                                       '(change)
                                       #'agent-river-spool--notify)))
        (when agent-river-spool-poll-interval
          (setq agent-river-spool--timer
                (run-with-timer agent-river-spool-poll-interval
                                agent-river-spool-poll-interval
                                #'agent-river-spool--scan-safely)))
        (agent-river-spool-scan))
    (when agent-river-spool--watch
      (ignore-errors (file-notify-rm-watch agent-river-spool--watch)))
    (when (timerp agent-river-spool--timer)
      (cancel-timer agent-river-spool--timer))
    (when (timerp agent-river-spool--soon)
      (cancel-timer agent-river-spool--soon))
    (setq agent-river-spool--watch nil
          agent-river-spool--timer nil
          agent-river-spool--soon nil)))

(provide 'agent-river-spool)

;;; agent-river-spool.el ends here
