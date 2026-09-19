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
;;   (setq agent-river-launch-brief #'my-brief)        ; is there anything to say
;;   M-x agent-river-launch-artifact
;;
;; Two switches, both off out of the box, and the second is the sharp one: a
;; brief returns what to say about a given artifact or nil, so a launcher
;; with no brief can never launch.
;;
;; `agent-river-launch-artifact' is also suitable as a `:visit' in
;; `agent-river-map-domains', which is the whole of "launching happens from
;; the map" -- RET on the line, no new keymap, no change to `agent-river.el'.
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
;; `:launch' and `:resolve' are split by a real asymmetry.  agent-shell's ACP
;; session id appears after the process is up, so a launch hands back a handle
;; and the key is resolved afterwards; a headless CLI can be *told* its
;; session id, so it is known before the process starts and `:resolve' is nil.
;; Where we control the invocation we assign identity, where we do not we
;; resolve it after -- and resolving is what lets the session be linked to the
;; artifact it was started for.

(declare-function agent-shell--start "agent-shell")
(declare-function agent-shell--insert-to-shell-buffer "agent-shell")
(declare-function shell-maker-busy "shell-maker")
(declare-function agent-shell-anthropic-make-claude-code-config "agent-shell-anthropic")
(defvar agent-shell--state)

(defcustom agent-river-launch-launcher nil
  "Name of the launcher `agent-river-launch-artifact' uses, or nil.

One of the two switches in front of starting anything, and the blunt one:
nil means nothing can be launched at all, whatever else is configured."
  :type '(choice (const :tag "Nothing can launch" nil) string))

(defcustom agent-river-launch-brief nil
  "Function of an artifact plist returning what to say to an agent, or nil.

The other switch, and the sharp one.  It is called with the plist
`agent-river-artifacts-list' produces -- `:key', `:domain', `:name',
`:context' and the rest -- and returns

  (:prompt STRING :cwd DIRECTORY)

or nil, which means there is nothing to say about this artifact and so
nothing to start.  Nil is therefore the arming switch: a launcher with no
brief can never launch, whatever the launcher is.

One function rather than one per domain, because dispatching on
`:domain' is two lines inside it and a second mechanism deciding the same
question is what this package spends its exceptions avoiding.

It is also where a context is read.  This package never reads a value out
of one -- that is what lets a record carry a severity, a body and a URL
without this file learning about any of them -- so the working tree an
agent should start in comes out of the context here, in your code, which
put it there in the first place."
  :type '(choice (const :tag "Nothing to say" nil) function))

(defcustom agent-river-launch-shell-config
  (lambda ()
    (when (fboundp 'agent-shell-anthropic-make-claude-code-config)
      (agent-shell-anthropic-make-claude-code-config)))
  "Function returning the agent-shell config a launched session runs under."
  :type 'function)

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
       ;; and a launcher that reports itself available and then fails on its
       ;; first artifact has said something untrue.
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

(defun agent-river-launch--shell-launch (brief)
  "Start an agent-shell session for BRIEF and hand it its prompt."
  (let* ((default-directory (or (plist-get brief :cwd) default-directory))
         (buffer (agent-shell--start
                  :config (funcall agent-river-launch-shell-config)
                  :no-focus t :new-session t)))
    (unless (buffer-live-p buffer)
      (error "agent-shell started no buffer"))
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
first thing said and not the last.  Asked last, the user was prompted to
confirm a launch that then failed."
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

There has to be a number, and it cannot be inferred: `:resolve' returning
nil means \"not yet\" and \"never\" in the same breath, so nothing in the
answer distinguishes a handshake still running from a process that died
before it announced anything.  Five minutes is far longer than any
handshake and far shorter than an Emacs session, which is the only
property it needs.")

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
         ;; Named *and* heard from.  Both halves are needed: agent-shell
         ;; sets the session id at the handshake and the hooks fold that
         ;; session's first event some moments later, so there is a window
         ;; where the session has a name and no state -- and
         ;; `agent-river-reach' refuses to attach an edge to a state that
         ;; is not there, rightly, because for its other caller that means
         ;; a person named the wrong session.  Waiting is the whole answer
         ;; and the window below is what stops it waiting forever.
         ((and session (gethash session agent-river-registry))
          ;; Guarded like every other call out of this file, and this one
          ;; has the sharpest reason: it is the only one with no user in
          ;; front of it.  A reach folds, redraws the panel and writes the
          ;; HUD, and if it throws here the `setq' below never runs -- so
          ;; the record is not dropped, the timer is not retired, and a
          ;; repeating timer is re-armed before its function runs, which
          ;; means the same error every second for the life of the Emacs.
          ;; A reach that fails is reported and the record goes: a launch
          ;; that cannot be linked is still a launch that happened.
          (condition-case err
              (agent-river-reach (plist-get record :key) session)
            (error
             (agent-river-log
              "fail" (agent-river--log-text
                      (format "launch: %s could not be linked to %s (%s)"
                              (plist-get record :key) session
                              (error-message-string err)))))))
         ;; Nothing to ask: a launcher with no `:resolve' assigned the id
         ;; before the process started, and one that has since been
         ;; unconfigured cannot answer either.  Settled, not failed.
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

(defun agent-river-launch--brief (record)
  "Return what to say to an agent about RECORD, or nil.

A brief that throws is no brief, the way a launcher that throws is a
decision: this is user code called from a command, and an error here
would read as the command being broken rather than the brief."
  (when (functionp agent-river-launch-brief)
    (condition-case err
        (funcall agent-river-launch-brief record)
      (error
       (agent-river-log "fail" (agent-river--log-text
                                (format "brief errored (%s)"
                                        (error-message-string err))))
       nil))))

(defun agent-river-launch--refusal (record brief)
  "Return why RECORD cannot be launched with BRIEF, or nil.

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
   ((null agent-river-launch-brief)
    "Nothing to say to an agent: set `agent-river-launch-brief' first")
   ((null (plist-get brief :prompt))
    (format "The brief has nothing to say about %s" (plist-get record :key)))))

;;;###autoload
(defun agent-river-launch-artifact (key)
  "Start an agent on the artifact KEY names.

The whole of what this layer does with a launcher, and it is a gesture
rather than a rule: a person looked at the thing and said so.  What would
be needed to make that decision without them is issue #37, and none of it
is here.

Suitable as a `:visit' in `agent-river-map-domains', which is what makes
RET on a line of the map start an agent on it.

It asks first.  Starting a process is the most expensive thing this
package does and the one gesture with nothing on the far side that can
take it back, so the second keystroke is earned every time.  What the
question names is what will run, which is the half a line cannot show."
  (interactive (list (agent-river--read-artifact-key)))
  (let* ((record (agent-river-artifact-at key))
         (brief (and record (agent-river-launch--brief record)))
         (refusal (agent-river-launch--refusal record brief)))
    (when refusal (user-error "%s" refusal))
    (if (not (y-or-n-p (format "Start %s on %s? "
                               agent-river-launch-launcher
                               (or (plist-get record :name) key))))
        (message "agent-river: not started")
      (let ((launcher (agent-river-launch--launcher))
            ;; What the brief said, plus what it had no business repeating.
            ;; Ours first, so the record's own identity is the one a
            ;; launcher sees: a headless launcher names its session after
            ;; the key, and a brief is in no position to rename the thing
            ;; it was asked about.
            (brief (append (list :key key :name (plist-get record :name))
                           brief)))
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
                                (format "%s: started %s"
                                        key (plist-get launcher :name))))
              (message "agent-river: started"))
          (error
           (agent-river-log "fail" (agent-river--log-text
                                    (format "launch failed: %s"
                                            (error-message-string err))))
           (message "agent-river: launch failed, see the log")))))))

(provide 'agent-river-launch)

;;; agent-river-launch.el ends here
