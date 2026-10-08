;;; agent-river-launch.el --- Point an agent at an artifact -*- lexical-binding: t; -*-

;; Author: systemfreund <github@o9z.de>
;; Keywords: tools

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The other direction, and the only thing in this package that starts a
;; process.  An artifact is on the map -- an issue, an incident, whatever a
;; producer declared -- and this is how an agent gets pointed at one.
;;
;;   (setq agent-river-launch-launcher "agent-shell")  ; can anything launch
;;   (setq agent-river-launch-briefs                   ; is there anything to say
;;         (list (list :name "Review" :brief #'my-review-brief)))
;;   M-x agent-river-launch-artifact
;;
;; Two switches, both off out of the box, and the second is the sharp one: a
;; brief returns what to say about a given artifact or nil, so a launcher
;; with no brief can never launch.
;;
;; Each brief that has something to say about a thing is one entry in the menu
;; RET opens on the map -- this file registers itself on
;; `agent-river-artifact-action-functions', which is the whole of "launching
;; happens from the map": no new keymap and no change to `agent-river.el'.  A
;; brief may name its own `:config', so "review this PR" and "rebase this PR"
;; can be different prompts under different models.
;;
;; A person decides, every time.  What it would take to decide without one --
;; a durable ledger, occasion-shaped keys, matches and gates and a budget and
;; a refusal log to calibrate on -- is issue #37, and none of it is here.
;;
;; This file requires nothing of `agent-river-spool.el' and is required by
;; nothing in it.  They were one file while an agent finishing was the
;; occasion for the next launch and the instructions for handing back had to
;; carry the spool's path; with the chain gone there is no such text, and the
;; two halves stopped touching.

;;; Code:

(require 'seq)
(require 'agent-river)

(defgroup agent-river-launch nil
  "Starting a coding-agent session on an artifact."
  :group 'agent-river
  :prefix "agent-river-launch-")

;;; Quoting producer text -- a mechanism every brief needs, not a GitHub one
;;
;; A brief that embeds an artifact's own text -- a body, a title, a branch --
;; is putting text an operator did not write into a prompt an agent will read
;; as instructions.  Every source faces the identical question, so the
;; quoting lives here rather than being copied per source: a copy that drifts
;; is a prompt-injection defence quietly not applied.  `agent-river-gh.el'
;; calls this rather than keeping its own.

(defun agent-river-launch-quote (parts)
  "Return PARTS as one blockquote, every line of each of them inside it.

The `>' goes on in exactly one place, and that is the whole point of the
function.  A source that builds a quotation field by field instead --
title here, a name added beside it there -- reopens the injection this
exists to close: a field carrying a newline closes the quotation early,
and everything after it reads as the operator's own words.  Anything from
a producer goes through here, together, so the next field to arrive is
covered before it is written rather than after something breaks on it.

An empty part is the blank quoted line between two others, and is spelled
without the trailing space a prefix alone would leave.

A part's *trailing* blank lines are dropped, because producer text
commonly ends in a newline and `split-string' answers that with a final
empty string, which would hang a lone `>' under the quotation.
Only the trailing ones: a blank line inside a part is a paragraph break
and is the producer's, and an empty part is a separator between fields
and is the brief's."
  (mapconcat
   (lambda (part)
     (if (string-empty-p (or part ""))
         ">"
       (let ((lines (split-string part "\r?\n")))
         (while (and (cdr lines) (string-empty-p (car (last lines))))
           (setq lines (butlast lines)))
         (mapconcat (lambda (line)
                      (if (string-empty-p line) ">" (concat "> " line)))
                    lines "\n"))))
   parts "\n"))

;;; Launchers -- the one end that starts a process
;;
;; A launcher is a plist:
;;
;;   :name         what a message calls it.
;;   :available-p  can it run here at all -- is the package it drives loaded.
;;   :launch       (BRIEF) -> HANDLE.  Start something, hand back whatever
;;                 identifies it afterwards.
;;   :resolve      (HANDLE) -> the agent-river session id, once there is one,
;;                 or nil.  Nil for a launcher that assigns the id itself.
;;
;; `:launch' and `:resolve' are split because agent-shell's session id only
;; appears after the process is up, so it is resolved afterwards; a headless
;; CLI can be told its id up front, so `:resolve' is nil there.  Resolving is
;; what lets the session be linked back to the artifact it was started for.

(declare-function agent-shell--start "agent-shell")
(declare-function agent-shell--insert-to-shell-buffer "agent-shell")
(declare-function shell-maker-busy "shell-maker")
(declare-function agent-shell-anthropic-make-claude-code-config "agent-shell-anthropic")
(declare-function shell-maker-set-buffer-name "shell-maker")
(defvar agent-shell--state)

(defcustom agent-river-launch-launcher nil
  "Name of the launcher `agent-river-launch-artifact' uses, or nil.

One of the two switches in front of starting anything, and the blunt one:
nil means nothing can be launched at all, whatever else is configured."
  :type '(choice (const :tag "Nothing can launch" nil) string))

(defcustom agent-river-launch-briefs nil
  "What an agent may be started on, as a list of named briefs.

The other switch, and the sharp one: with no brief nothing can launch.
Each entry is a plist, and what the agent is told is written here --
this package ships no prompt text:

  :name            what the menu calls it, and what
                   `agent-river-launch-artifact' takes to pick it
  :domain          a domain or a list of them the brief is for
  :when            (RECORD) -> non-nil where the brief applies
  :prompt          a template, or (RECORD) -> STRING
  :cwd             a template for where to start, default \"{cwd}\"
  :worktree        t, or a template naming a branch
  :worktree-fetch  a template naming a remote to fetch that branch from
  :buffer-name     a template for the session's buffer
  :options         an alist for `agent-river-launch-shell-config-with-options'
  :config          a config function, instead of :options

A template is a string in which `{cell}' is the context cell of that name
-- whatever the producer delivered, `{body}', `{url}', `{branch}' -- and
`{name}', `{key}' and `{domain}' are the record's own; `{state}' is
`agent-river-markdown'.  `{>cell}' is the value as a blockquote, through
`agent-river-launch-quote'; `{{' is a literal brace.  See
`agent-river-launch-expand'.

Whether a producer's text is quoted is the template's to say.  A body is
written by whoever could open the issue, and inserted bare it reads to an
agent holding tools with the standing of your own words.

A brief applies to a record when the domain matches, `:when' agrees, the
prompt expands to something and a declared `:worktree' does too -- a
brief that asked for a tree of its own and got none would start the agent
in yours.  Every brief that applies is one entry in the menu RET opens:
the same pull request is a thing to review and a thing to rebase, under
different prompts and quite possibly different models.

`:brief', a function (RECORD) -> (:prompt STRING :cwd DIRECTORY ...) or
nil, takes the place of all of the above for what a template cannot say.
RECORD is the plist `agent-river-artifacts-list' produces.

`:buffer-name', `:worktree', `:worktree-fetch', `:options' and `:config'
are agent-shell's: see `agent-river-launch--shell-name' and
`agent-river-launch--make-worktree'."
  :type '(repeat (plist :key-type symbol :value-type sexp)))

(defcustom agent-river-launch-shell-config
  (lambda ()
    (when (fboundp 'agent-shell-anthropic-make-claude-code-config)
      (agent-shell-anthropic-make-claude-code-config)))
  "Function returning the agent-shell config a launched session runs under.

The default for every brief.  A brief that wants its own model or session
configuration returns a `:config' of the same shape, which is preferred
over this one -- see `agent-river-launch-briefs'."
  :type 'function)

(defun agent-river-launch-shell-config-with-options (options &optional base)
  "Return a config function like BASE, with OPTIONS set on the session.

For a brief\='s `:config\=' -- the model and session configuration a prompt
is worth nothing without.  BASE defaults to
`agent-river-launch-shell-config\=', so what comes back is the *configured*
agent plus these options rather than an agent of this brief\='s own; that
is why this is here rather than in everybody\='s config, where the same
lines would have to name some agent\='s config maker and
`agent-river-launch-shell-config\=' would stop deciding anything.

OPTIONS is an alist of (OPTION . VALUE) in the agent\='s own vocabulary --
\"model\", \"mode\", \"effort\".  This package neither knows nor checks what
any of them mean, the way it never reads a value out of an artifact\='s
context: what a cell means is known beside whoever wrote it.  Their order
is the caller\='s to get right and it is the agent that cares -- they are
applied one at a time and re-advertised after each, so a model has to
come before anything scoped to it.

BASE is read now rather than at every call, which is what makes setting
`agent-river-launch-shell-config\=' to the result of this the ordinary
thing it looks like.  Read later it would be its own base and call itself
for ever, on the availability check as much as on the launch.

Nil in is nil out.  Nil is what the default answers where agent-shell
cannot build a config at all, and `agent-river-launch--shell-available-p\='
reads it to say the launcher cannot run here."
  (let ((base (or base agent-river-launch-shell-config)))
    (lambda ()
      (when-let* ((config (funcall base)))
        (setf (alist-get :default-config-options config) (lambda () options))
        config))))

(defcustom agent-river-launch-shell-tries 60
  "How many times a launched shell is offered its prompt, one a second.

The session is not ready the moment the buffer exists -- the ACP handshake
is still running -- and there is no readiness signal to subscribe to, so
the prompt is offered once a second until it is taken.  Giving up says so
in the log rather than leaving a started agent sitting with nothing to do."
  :type 'integer)

(defun agent-river-launch--shell-available-p ()
  "Return non-nil if agent-shell can host a session here."
  (and (fboundp 'agent-shell--start)
       (fboundp 'agent-shell--insert-to-shell-buffer)
       (functionp agent-river-launch-shell-config)
       ;; Built, not merely nameable: the config reaches for authentication,
       ;; so a launcher must not claim availability it can't back up.
       (condition-case nil
           (and (funcall agent-river-launch-shell-config) t)
         (error nil))))

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
        (agent-river-log "fail" (agent-river--log-text
                                 (format "launch: %s never took its prompt"
                                         (buffer-name buffer))))))))

(defun agent-river-launch--shell-config (brief)
  "Return the agent-shell config BRIEF asked for, or the configured default.

Built here rather than where the brief was read, which is the reason it
is a function on both sides: building a config reaches for
authentication, and the briefs are read on every RET to work out what a
line offers.  Only the one that is launched is built."
  (funcall (or (plist-get brief :config) agent-river-launch-shell-config)))

(defun agent-river-launch--shell-name (buffer name)
  "Give BUFFER the NAME a brief asked for, where it asked for one.

A brief\='s `:buffer-name\=', and a launcher-specific key the way `:config\=' is:
what a headless CLI would do with one is nothing.  Absent is the ordinary
answer and leaves agent-shell the name it chose, so nothing renames
anything unless somebody wrote a name down.  The brief knows which of two
briefs on one artifact this is, and this layer does not -- named from the
record here, `Review\=' and `Address the review\=' would be one name and a
`<2>\='.

`shell-maker-set-buffer-name\=' and not `agent-shell-rename-buffer\=', which is
buffer-locally aliased to a command taking no argument that prompts for
one.  The setter is what agent-shell calls itself in `agent-shell-restart\=',
and it records the name as an override -- a bare `rename-buffer\=' would be
undone by the next thing that asks shell-maker what this buffer is called.

Guarded, because everything here happens *after* the launch: the process
is up and the prompt is already on its way.  A throw would leave
`:launch\=' through `agent-river-launch-artifact\='s handler, which writes
`launch failed\=' and never pushes the record `--resolve-pending\=' reads --
so a session that is running would be unnamed, unlinked to the artifact it
was started for, and described in the log as one that never started."
  (when (and (stringp name)
             (not (string-empty-p (string-trim name)))
             (fboundp 'shell-maker-set-buffer-name))
    (condition-case err
        (shell-maker-set-buffer-name buffer (string-trim name))
      (error
       (agent-river-log "fail"
                        (agent-river--log-text
                         (format "launch: %s could not be named %s (%s)"
                                 (buffer-name buffer) name
                                 (error-message-string err))))))))

;;; Worktrees -- a launched session in a tree of its own
;;
;; Two agents launched on two issues of one repository must not write into
;; one tree, and neither into the one the user is working in.  A brief opts
;; in with `:worktree', a launcher-specific key like `:config': t is a new
;; branch off `HEAD', a string is that branch checked out -- a pull request
;; is worked on in its own branch, not beside it.  Git runs through
;; `process-file' with an argv, so nothing a producer wrote reaches a shell.

(defcustom agent-river-launch-worktree-directory
  (lambda (root) (expand-file-name ".agent-shell/worktrees" root))
  "Function of a repository's main worktree returning where worktrees go.

The default is agent-shell's own location, so the worktrees it makes and
the ones made here land in one place."
  :type 'function)

(defconst agent-river-launch--worktree-adjectives
  '("adoring" "brave" "calm" "eager" "focused" "gentle" "happy" "jolly"
    "keen" "lucid" "merry" "nifty" "quirky" "serene" "sharp" "tender"
    "upbeat" "vibrant" "witty" "zealous")
  "First halves of a worktree's random name.")

(defconst agent-river-launch--worktree-scientists
  '("bohr" "curie" "darwin" "euler" "fermi" "gauss" "hopper" "hypatia"
    "kepler" "lovelace" "meitner" "noether" "pascal" "ramanujan" "shannon"
    "tesla" "turing" "volta" "wright" "yalow")
  "Second halves of a worktree's random name.")

(defconst agent-river-launch--worktree-slug-width 24
  "How much of an artifact key a worktree name keeps.")

(defun agent-river-launch--slug (text width)
  "Return TEXT reduced to `[a-z0-9-]', keeping at most its last WIDTH chars.

The end rather than the start, because that is where a key keeps what
tells two of them apart -- the number of an issue, not the name of the
repository it is in.  Mechanical: a key is a name to be made safe, never
something to be parsed for what it means."
  (let* ((slug (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase text)))
         (slug (string-trim slug "-+" "-+")))
    (when (> (length slug) width)
      (setq slug (string-trim-left (substring slug (- width)) "-+")))
    slug))

(defun agent-river-launch--worktree-name (key)
  "Return a fresh worktree and branch name for the artifact KEY.
The key's slug, so `git worktree list' says which is which, and a random
pair, so a second launch on one artifact is a second tree."
  (let ((slug (agent-river-launch--slug (or key "")
                                        agent-river-launch--worktree-slug-width))
        (pair (format "%s-%s"
                      (seq-random-elt agent-river-launch--worktree-adjectives)
                      (seq-random-elt agent-river-launch--worktree-scientists))))
    (if (string-empty-p slug) pair (concat slug "-" pair))))

(defun agent-river-launch--worktree-argv (path name spec)
  "Return the `git' arguments making a worktree at PATH for SPEC.

SPEC t is a new branch NAME off `HEAD'.  A string is that branch checked
out, with no `-b': git then makes a local branch tracking the remote one
where only that exists, and refuses where the branch is already checked
out elsewhere -- which is the refusal worth showing."
  (if (stringp spec)
      (list "worktree" "add" path spec)
    (list "worktree" "add" "-b" name path "HEAD")))

(defun agent-river-launch--git (dir &rest args)
  "Run git with ARGS in DIR, returning its trimmed output or signalling.
The output is in the error, since what git said is the whole of the
reason a launch did not happen."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (let ((status (apply #'process-file "git" nil t nil args)))
        (unless (eq status 0)
          (error "git %s: %s" (car args)
                 (string-trim (buffer-string))))
        (string-trim (buffer-string))))))

(defun agent-river-launch--worktree-root (cwd)
  "Return (ROOT . COMMON) for the repository CWD is in, or signal.

The common directory rather than the toplevel, because CWD may itself be
a worktree, and worktrees made from its toplevel would nest inside it.
ROOT is the main worktree, the one the common directory belongs to."
  (unless (file-directory-p cwd)
    (error "Not a directory: %s" cwd))
  (let* ((common (expand-file-name
                  (agent-river-launch--git cwd "rev-parse" "--git-common-dir")
                  cwd))
         (root (file-name-directory (directory-file-name common))))
    (when (equal (agent-river-launch--git cwd "rev-parse" "--is-bare-repository")
                 "true")
      (error "A bare repository has no tree to branch from: %s" cwd))
    (cons root common)))

(defun agent-river-launch--worktree-exclude (root common dir)
  "Keep DIR out of `git status' in ROOT, through COMMON's info/exclude.

Asked of git rather than read off the file: an entry agent-shell or the
user already made answers as readily as one made here."
  (when (file-in-directory-p dir root)
    (let ((default-directory (file-name-as-directory root)))
      (unless (eq 0 (process-file "git" nil nil nil "check-ignore" "-q"
                                  (file-relative-name dir root)))
        (let ((exclude (expand-file-name "info/exclude" common)))
          (make-directory (file-name-directory exclude) t)
          (with-temp-buffer
            (when (file-exists-p exclude) (insert-file-contents exclude))
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert "/" (file-name-as-directory (file-relative-name dir root)) "\n")
            (write-region nil nil exclude nil 'silent)))))))

(defun agent-river-launch--shown-path (path)
  "Return PATH short enough to lead a log line, keeping its end.
The end is the worktree's own name, which is what tells it apart; a log
line is clipped from the right, which would keep only the repository."
  (let ((shown (abbreviate-file-name path)))
    (if (> (length shown) 56)
        (concat "…" (substring shown -55))
      shown)))

(defun agent-river-launch--make-worktree (brief)
  "Make the worktree BRIEF asks for and return its path, or nil if none.

Everything is checked before anything is made, and nothing here falls
back to `:cwd': a brief that asked for a tree of its own and got the
user's would be the agent writing exactly where it was told not to."
  (when-let* ((spec (plist-get brief :worktree)))
    (unless (or (eq spec t)
                (and (stringp spec) (not (string-empty-p (string-trim spec)))))
      (error "`:worktree' is t or a branch, not %S" spec))
    (pcase-let* ((cwd (expand-file-name (or (plist-get brief :cwd)
                                            default-directory)))
                 (`(,root . ,common) (agent-river-launch--worktree-root cwd))
                 (dir (funcall agent-river-launch-worktree-directory root))
                 (remote (plist-get brief :worktree-fetch))
                 (name nil)
                 (path nil))
      ;; A fetch is a network call, so only where the brief asked for one.
      (when (and (stringp spec) (stringp remote))
        (agent-river-launch--git root "fetch" remote spec))
      (while (or (null path) (file-exists-p path))
        (setq name (agent-river-launch--worktree-name (plist-get brief :key))
              path (expand-file-name name dir)))
      (make-directory dir t)
      (agent-river-launch--worktree-exclude root common dir)
      (apply #'agent-river-launch--git root
             (agent-river-launch--worktree-argv path name spec))
      ;; The path leads, since a log line is clipped and it is what nothing
      ;; else will say once the tree has outlived the session.
      (agent-river-log "artifact"
                       (agent-river--log-text
                        (format "worktree %s (%s)" (agent-river-launch--shown-path path)
                                (if (stringp spec) spec name)))
                       (agent-river--log-text (or (plist-get brief :key) "?")))
      path)))

(defun agent-river-launch--shell-launch (brief)
  "Start an agent-shell session for BRIEF and hand it its prompt.

`:session-strategy \='new\=' rather than agent-shell\='s own default of
`prompt\=', and it is the layer\='s premise rather than a preference.  A
launch here is a session that did not exist: `--resolve-pending\=' waits for
an id to appear and links *that* session to the artifact.  A resumed
session existed before the launch and is quite possibly in the registry
already, so the wait would settle instantly onto something nobody started
for this thing -- and the brief would land in a conversation about another
one.  It also stops a modal question arriving between the choice and the
agent.

A `:worktree' is made first, so a git failure starts nothing.  One that
outlives a failed start is left where it is and named in the error: it
is a working tree, and removing one is not a failed launch's to do."
  (let* ((worktree (agent-river-launch--make-worktree brief))
         (default-directory (file-name-as-directory
                             (or worktree (plist-get brief :cwd)
                                 default-directory)))
         (buffer (condition-case err
                     (agent-shell--start
                      :config (agent-river-launch--shell-config brief)
                      :session-strategy 'new
                      :no-focus t :new-session t)
                   (error
                    (if worktree
                        (error "worktree left at %s: %s"
                               (agent-river-launch--shown-path worktree)
                               (error-message-string err))
                      (signal (car err) (cdr err)))))))
    (unless (buffer-live-p buffer)
      (error "%sagent-shell started no buffer"
             (if worktree
                 (format "worktree left at %s: " (agent-river-launch--shown-path worktree))
               "")))
    (agent-river-launch--shell-name buffer (plist-get brief :buffer-name))
    (agent-river-launch--shell-send buffer (plist-get brief :prompt)
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
  "Available launchers, as plists.  See the section comment above.")

(defun agent-river-launch--available-p (launcher)
  "Return non-nil when LAUNCHER can run here.

Absent means yes: a launcher that drives nothing it has to check for has
no answer to give, and demanding one would make the protocol's optional
field mandatory by the back door.  Guarded, since this is a user-supplied
function and a test that throws is not an availability."
  (let ((test (plist-get launcher :available-p)))
    (or (null test)
        (condition-case nil (and (funcall test) t) (error nil)))))

(defun agent-river-launch--launcher ()
  "Return the configured launcher, or nil when nothing can launch.

Unavailable is the same as absent, and this is the one place that decides
it.  Read at selection rather than remembered, because it is a
current-state fact: a package loaded after Emacs started makes its
launcher available without anything here being told.

Asked here rather than at the launch so that \"this cannot run\" is the
first thing said and not the last: asked at the launch, the user would be
prompted to confirm something that then failed."
  (when agent-river-launch-launcher
    (let ((launcher (seq-find (lambda (l)
                                (equal (plist-get l :name)
                                       agent-river-launch-launcher))
                              agent-river-launch-launchers)))
      (and launcher (agent-river-launch--available-p launcher) launcher))))


;;; Starting a session on an artifact

(defvar agent-river-launch--launched nil
  "Launches still waiting for a session, newest first.
Each is (:key :at :launcher :handle).  A record exists only to ask its
handle what session it became, so that the session can be linked to the
artifact it was started for; having answered, it is dropped.")

(defconst agent-river-launch--resolve-window 300
  "Seconds a launch is asked what session it became before it is given up on.

There has to be a number: `:resolve' returning nil means \"not yet\" and
\"never\" in the same breath, so nothing in the answer distinguishes a
handshake still running from a process that died before it announced
anything.  Five minutes is far longer than any handshake and far shorter
than an Emacs session, which is the only property it needs.")

(defvar agent-river-launch--resolve-timer nil
  "Timer asking pending launches what they became, or nil.")

(defun agent-river-launch--resolve-pending ()
  "Ask each pending launch what session it became, and link it.

The edge, and the reason it cannot be got wrong here: whoever starts an
agent on an artifact knows both ends of the relationship, so the reach is
recorded by the one caller that had them both in hand.  It is late rather
than immediate because the session id does not exist yet when the process
starts.

Gives up in both directions.  A launch that resolves has done its one job
and goes; one that has not resolved inside
`agent-river-launch--resolve-window' is said to have never become a
session, out loud -- a launcher that starts something which never
announces itself is the failure this layer is least able to see, since
nothing afterwards contradicts it."
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
         ;; Named *and* heard from: agent-shell sets the session id at the
         ;; handshake, but the hooks fold its first event slightly later, and
         ;; `agent-river-reach' refuses to attach an edge to a state that
         ;; isn't there yet.  Wait for both, bounded by the window below.
         ((and session (gethash session agent-river-registry))
          ;; Guarded, and more strictly than the rest of this file: this
          ;; runs on a repeating timer with no user in front of it, so a
          ;; throw here would skip the `setq' below and repeat forever.  A
          ;; reach that fails is reported and the record dropped anyway.
          (condition-case err
              (agent-river-reach (plist-get record :key) session)
            (error
             (agent-river-log
              "fail" (agent-river--log-text
                      (format "launch: %s could not be linked to %s (%s)"
                              (plist-get record :key) session
                              (error-message-string err)))))))
         ;; Nothing to ask: a launcher with no `:resolve' assigned the id
         ;; up front, so there's nothing to wait for.  Settled, not failed.
         ((null resolve) nil)
         ((> (float-time (time-subtract (current-time)
                                        (plist-get record :at)))
             agent-river-launch--resolve-window)
          (agent-river-log
           "fail" (agent-river--log-text
                   (format "launch: %s never became a session"
                           (plist-get record :key)))))
         (t (push record keep)))))
    (setq agent-river-launch--launched (nreverse keep))
    (unless agent-river-launch--launched
      (when (timerp agent-river-launch--resolve-timer)
        (cancel-timer agent-river-launch--resolve-timer))
      (setq agent-river-launch--resolve-timer nil))))

(defun agent-river-launch--ensure-resolve-timer ()
  "Ask pending launches what they became, until none are left.
Its own timer rather than a general one: it runs only between a launch
and the session appearing, which is a handful of seconds a day."
  (unless (timerp agent-river-launch--resolve-timer)
    (setq agent-river-launch--resolve-timer
          (run-with-timer 1 1 #'agent-river-launch--resolve-pending))))

(defun agent-river-launch--cell (record name)
  "Return what the template cell NAME stands for in RECORD, or nil."
  (let ((value (pcase name
                 ('name (plist-get record :name))
                 ('key (plist-get record :key))
                 ('domain (plist-get record :domain))
                 ('state (agent-river-markdown))
                 (_ (alist-get name (plist-get record :context))))))
    (cond ((null value) nil)
          ((stringp value) value)
          (t (format "%s" value)))))

(defun agent-river-launch-expand (template record)
  "Return TEMPLATE with RECORD's cells put in.

`{cell}' is the cell as it is, `{>cell}' the cell as a blockquote, and a
cell RECORD does not have is empty.  `{{' is a literal brace.  What is
quoted is the template's choice: nothing here decides it on the
template's behalf."
  (replace-regexp-in-string
   "{\\(?:\\({\\)\\|\\(>\\)?\\([a-z][a-z0-9-]*\\)}\\)"
   (lambda (match)
     (let ((brace (match-string 1 match))
           (quoted (match-string 2 match))
           (name (match-string 3 match)))
       (if brace
           "{"
         ;; The splice reads the match data after this returns, and both
         ;; the quoting and a cell's own reading may match strings.
         (save-match-data
           (let ((value (agent-river-launch--cell record (intern name))))
             (cond ((null value) "")
                   (quoted (agent-river-launch-quote (list value)))
                   (t value)))))))
   template t t))

(defun agent-river-launch--field (spec record)
  "Return SPEC for RECORD: a template expanded, a function called.
Nil where it comes to nothing, so an empty expansion reads as absent."
  (let ((value (cond ((stringp spec) (agent-river-launch-expand spec record))
                     ((functionp spec) (funcall spec record)))))
    (and (stringp value) (not (string-empty-p (string-trim value))) value)))

(defun agent-river-launch--declared-brief (entry record)
  "Return the brief ENTRY declares for RECORD, or nil where it does not apply."
  (let ((domain (plist-get entry :domain))
        (applies (plist-get entry :when))
        (worktree (plist-get entry :worktree))
        (options (plist-get entry :options)))
    (when (and (or (null domain)
                   (memq (plist-get record :domain) (ensure-list domain)))
               (or (null applies) (funcall applies record)))
      (let ((prompt (agent-river-launch--field (plist-get entry :prompt) record))
            (tree (if (eq worktree t)
                      t
                    (agent-river-launch--field worktree record))))
        (when (and prompt (or (null worktree) tree))
          (append
           (list :prompt prompt
                 :cwd (agent-river-launch--field
                       (or (plist-get entry :cwd) "{cwd}") record))
           (when tree
             (list :worktree tree
                   :worktree-fetch (agent-river-launch--field
                                    (plist-get entry :worktree-fetch) record)))
           (when-let* ((name (agent-river-launch--field
                              (plist-get entry :buffer-name) record)))
             (list :buffer-name name))
           (cond ((plist-get entry :config)
                  (list :config (plist-get entry :config)))
                 (options
                  (list :config (agent-river-launch-shell-config-with-options
                                 options))))))))))

(defun agent-river-launch--offers (record)
  "Return (ENTRY . BRIEF) for every brief with something to say about RECORD.

The whole of which briefs apply to a thing, and there is no second
mechanism deciding it: a brief answering nil is a brief with nothing to
say, so the list of briefs is the list of offers.

A brief with no `:prompt' is one of those, not an offer that fails later:
what a launch is, is a prompt reaching an agent, so an answer without one
has said nothing and is not put in front of the user as though it had.

Guarded per entry, so one brief that throws costs its own offer rather
than the ones beside it.  This is user code called from a command, and an
error here would read as the command being broken rather than the brief."
  (let (offers)
    (dolist (entry agent-river-launch-briefs)
      (let* ((fn (plist-get entry :brief))
             (brief (condition-case err
                        (if (functionp fn)
                            (funcall fn record)
                          (agent-river-launch--declared-brief entry record))
                      (error
                       (agent-river-log
                        "fail"
                        (agent-river--log-text
                         (format "brief %s errored (%s)"
                                 (or (plist-get entry :name) "?")
                                 (error-message-string err))))
                       nil))))
        (when (plist-get brief :prompt)
          (push (cons entry brief) offers))))
    (nreverse offers)))

(defun agent-river-launch--pick (offers name)
  "Return the offer called NAME, the only one, or the one chosen from OFFERS.

NAME is how the map reaches a particular brief without asking again: the
menu there is already one entry per offer, so the choice was made on the
line and repeating it would put the question behind the answer."
  (cond
   (name (or (seq-find (lambda (offer)
                         (equal (plist-get (car offer) :name) name))
                       offers)
             (user-error "No brief `%s' has anything to say about this" name)))
   ((null (cdr offers)) (car offers))
   (t (let ((by-name (mapcar (lambda (offer)
                               (cons (plist-get (car offer) :name) offer))
                             offers)))
        (cdr (assoc (completing-read "Brief: " by-name nil t) by-name))))))

(defun agent-river-launch--confirm-p (record key brief-name &optional worktree)
  "Return non-nil when starting BRIEF-NAME on RECORD may go ahead.

Asks, unless the gesture that reached here already named what would run:
a map menu entry reading `Launch: Review\=' is the deliberate act the
question would be asking for, and a second prompt after it is put to an
answer just given.  `agent-river-artifact-chosen\=' is what says a choice
was made rather than how this was called -- BRIEF-NAME alone would not,
since the same argument arrives from a line that offered no alternative
and ran its one action outright.

Asked otherwise, and that is the ordinary case: starting a process is the
most expensive thing this package does and the one gesture with nothing
on the far side that can take it back.  What the question names is what
will run, the brief included -- and WORKTREE, the brief's `:worktree',
since a tree made on disk is a second thing the answer sets in motion."
  (or agent-river-artifact-chosen
      (y-or-n-p (format "Start %s on %s (%s)%s? "
                        agent-river-launch-launcher
                        (or (plist-get record :name) key)
                        (or brief-name "?")
                        (cond ((stringp worktree)
                               (format " in a worktree of %s" worktree))
                              (worktree " in a new worktree")
                              (t ""))))))

(defun agent-river-launch--refusal (record offers)
  "Return why RECORD cannot be launched, given OFFERS, or nil.

One account of what stands in the way, read before the user is asked to
confirm: asked afterwards, they would be confirming something that was
never going to happen."
  (cond
   ((null record) "No such artifact")
   ((null (agent-river-launch--launcher))
    ;; Configured and unavailable is a different thing to say than nothing
    ;; configured, and it is the one a reader can act on.
    (if agent-river-launch-launcher
        (format "Launcher `%s' is not available here"
                agent-river-launch-launcher)
      "No launcher: set `agent-river-launch-launcher' first"))
   ((null agent-river-launch-briefs)
    "Nothing to say to an agent: set `agent-river-launch-briefs' first")
   ((null offers)
    (format "No brief has anything to say about %s" (plist-get record :key)))))

;;;###autoload
(defun agent-river-launch-artifact (key &optional brief-name)
  "Start an agent on the artifact KEY names, briefed as BRIEF-NAME.

The whole of what this layer does with a launcher, and it is a gesture
rather than a rule: a person looked at the thing and said so.

BRIEF-NAME names an entry of `agent-river-launch-briefs'.  Without one,
the only brief with something to say about KEY is used and several are
offered by name -- so this is the same command whether it is reached by
`M-x' with nothing chosen or from the map, where the line has already
been asked and the brief was the choice.

It asks first, unless the gesture that reached it already named what
would run -- see `agent-river-launch--confirm-p'."
  (interactive (list (agent-river--read-artifact-key)))
  (let* ((record (agent-river-artifact-at key))
         (offers (and record (agent-river-launch--offers record)))
         (refusal (agent-river-launch--refusal record offers)))
    (when refusal (user-error "%s" refusal))
    (let* ((offer (agent-river-launch--pick offers brief-name))
           (chosen (plist-get (car offer) :name)))
      (if (not (agent-river-launch--confirm-p
                record key chosen (plist-get (cdr offer) :worktree)))
          (message "agent-river: not started")
        (let ((launcher (agent-river-launch--launcher))
              ;; Ours first, so the record's own identity wins: a headless
              ;; launcher names its session after the key, and a brief has
              ;; no business renaming the thing it was asked about.
              (brief (append (list :key key :name (plist-get record :name))
                             (cdr offer))))
          (condition-case err
              (let ((handle (funcall (plist-get launcher :launch) brief)))
                (push (list :key key
                            :at (current-time)
                            :launcher (plist-get launcher :name)
                            :handle handle)
                      agent-river-launch--launched)
                (agent-river-launch--ensure-resolve-timer)
                (agent-river-log "artifact"
                                 (agent-river--log-text
                                  (format "%s: started %s on %s"
                                          key (plist-get launcher :name)
                                          (or chosen "?"))))
                (message "agent-river: started"))
            (error
             (agent-river-log "fail" (agent-river--log-text
                                      (format "launch failed: %s"
                                              (error-message-string err))))
             (message "agent-river: launch failed, see the log"))))))))

;;;###autoload
(defun agent-river-launch--actions (record)
  "Offer one launch per brief with something to say about RECORD.

An `agent-river-artifact-action-functions' entry, and the reason this
file needs no keymap of its own: a line of the map is asked what it
offers, and this answers with the launches that are actually possible on
it.  Nothing where the launcher cannot run here, which is
`agent-river-launch--launcher' answering at selection: an offer that can
only fail is worse than no offer.

The entries are the briefs themselves rather than one `Launch' that then
asks which.  What a reader is choosing between is what the agent will be
told, so that is what the menu says; folded into one entry it would take
two prompts to reach, with the second asking the question the first had
already presented as answered.

Nothing for a subject with no `:key' -- a file line names something the
map placed on disk, not a record, and there is nothing for a brief to
have been written about."
  (let ((key (plist-get record :key)))
    (when (and key (agent-river-launch--launcher))
      (mapcar (lambda (offer)
                (let ((name (plist-get (car offer) :name)))
                  (list :name (format "Launch: %s" name)
                        :act (lambda ()
                               (agent-river-launch-artifact key name)))))
              (agent-river-launch--offers record)))))

;; Appended rather than pushed, so opening a file stays the first offer on a
;; line that is one.  The autoload cookie above is required: this form runs
;; before the function is defined, and without it the list holds a symbol
;; with an empty function cell, silently disabling every launch.
;;;###autoload
(with-eval-after-load 'agent-river
  (add-to-list 'agent-river-artifact-action-functions
               #'agent-river-launch--actions t))

(provide 'agent-river-launch)

;;; agent-river-launch.el ends here
