# agent-river

Coding-agent hooks report events one at a time. `agent-river` folds that stream
into a per-session **state** — what the agent is working on, which files it
keeps returning to, how its tools are faring — and hands that state to you.

A flat log answers *what happened*. Only a fold answers *where the work
stands*, because that question quantifies over a set of events.

**This README is for integrating your own application with it.** It covers the
data model, how events get in, how to read the state, how to react to it, and
how to put your own facts into it. It ships views of its own — a HUD, a project
map, an approval queue — and those are described near the end, briefly, as
worked examples of the protocols rather than as the point.

The reasoning behind any given decision, and the failure it prevents, lives in
[`AGENTS.md`](AGENTS.md) and in the code comments. Read that before changing
behaviour; read this before building on it.

## Requirements

Emacs 28.1 or later with native JSON, and a running Emacs server
(`M-x server-start`). No external tools: the shell bridge only moves bytes.

Event sources, any combination:

- **Claude Code**, or **Codex** / **Gemini CLI**, whose hooks are close enough
  to wire up the same bridge.
- [**agent-shell**](https://github.com/xenodium/agent-shell), which is optional
  but carries things the hooks do not — liveness, stable session names, the
  agent's own reasoning off the ACP stream, and permission requests.
- **Your own code**, for anything only Emacs can see and anything that belongs
  to no session at all.

---

# The data model

Four things to understand before you build on this. Everything else in the API
follows from them.

## The fold, the registry, the key

Events fold into an `agent-river-state`, held in `agent-river-registry`, keyed
by session. The fold is deterministic given event order, so **a state can be
rebuilt by replaying its events** — which is the promise that makes everything
here testable, and the reason nothing but the fold ever writes a slot.

If you take one rule from this document, take that one: **you never `setf` a
state.** To put a fact into the state you emit an event; see
[Putting your own facts in](#putting-your-own-facts-in).

The key is the `session_id`, and nothing else. A subagent's calls arrive with
its parent's session id and fold onto that session; see
[Subagents](#subagents).

```elisp
agent-river-registry                ; the hash itself: key -> agent-river-state
(agent-river-state "<session-id>")  ; address one, creating it if needed
(agent-river-reset)                 ; forget every fold
(agent-river-clear)                 ; only empty the event log
```

Several sessions fold side by side. Emacs Lisp is single-threaded, so
concurrent `emacsclient` calls are atomic with respect to each other and the
registry needs no locking.

## Two frames, always labelled

`artifacts` accumulate for the whole session; `steps`, `task-artifacts`, `said`
and the task tally reset with every prompt. Reporting one while labelling it the other
is how a panel starts misleading people, so **every key that leaves this package
says which frame it is in** — `:task-steps`, `:task-hottest`,
`:session-hottest`, `:session-elapsed`. Where you take a scope argument, pass
`'session` or `'task` explicitly and say which one your view is showing.

## Measurements, claims, and current-state facts

Three kinds of fact, kept apart on purpose, because this state is fed *back* to
the agent and a claim later read as an observation closes the loop with no
ground truth left in it.

| Kind | Example | Where it lives |
|---|---|---|
| **Measurement** | 23 steps, 2 failures, 6 touches of `mpv.el` | folded into the state |
| **Claim** | `agent-river-set-intent` — what the agent says it is doing | its own slots, reports as `:claimed-intent`, **never feeds a signal** |
| **Current-state** | is this buffer modified, is this file still on disk, is a permission request still open | queried where it is read, **never folded** |

The third distinction is the one integrators get wrong. A fact that stops being
true without an event to say so must not be stored: a pending approval is
answered by a button in another buffer, a file the state records a touch of
is deleted a second later. Fold what happened; query what is.

## Artifacts: things that are not files

The state is built out of what agents *did*, and an agent only does things to
files. Anything that arrives on its own — an incident routed to you, a review
requested, a build that broke — has no session to hang on, and it matters most
when *no* agent is running, which is exactly when there is no session to hang
it on.

So there is a second table, `agent-river-artifacts`, with a fold of its own.
Each **domain** heads a section of the map, and the map is nothing but this
table:

```
# 2 domains  ·  1 agent
##  ⇄ `inc`
### ▾  `INC-444 disk full on db-3`
- severity: P1
- queue: infra
- alpha · 2 writes · 0s ago
###    `INC-501 cert expiring`
##     `pr`
```

Three calls put it there:

```elisp
;; Something arrived.  Returns the record the first time and nil on every
;; repeat, so a producer that polls needs no bookkeeping of its own — the
;; table is the dedup, and the answer comes back from the same call that
;; folds, so asking and folding cannot come apart.
(agent-river-appeared "inc:INC-444"
                      :domain 'inc
                      :name "INC-444 disk full on db-3"
                      :context '((severity . "P1") (queue . "infra"))
                      :text "INC-444 routed to you")

;; An agent was dispatched to it.  Folded onto the *session* as a touch, so
;; the map's parties and listing and `agent-river-reaching' see it without
;; being taught anything — and it counts no step, because no tool ran.
(agent-river-reach "inc:INC-444" session-id)

;; It is over.  Struck through on the map rather than dropped: the ending is
;; itself a thing that happened.  `agent-river-drop-artifact' removes it when
;; that has stopped being news.
(agent-river-ended "inc:INC-444")
```

**Declare before you reach.** A domain is read off the artifact table, so a key
reached before its record exists is *undeclared* — and undeclared is a path:
`inc:INC-444` resolves against the session's cwd as a name that is not on disk,
which `agent-river-forget-gone-files` will then offer to sweep, and it gets no
line on the map, since the map lists records and it has none yet. Declaring
later repairs it — the domain is read at every draw — but the order to write is
`appeared`, then `reach`.

By hand, those two are one command: **`M-x agent-river-link-artifact`**. Run in
an agent-shell buffer it takes that buffer's session — the one context where
*which session am I* has an exact answer — and completes over the artifacts on
record; a key nothing answers to is declared first, asking for its domain, and
reached after. The order cannot be got wrong there because both halves are one
function. Elsewhere it asks which session, and never guesses.

The `:context` is opaque — this package never reads a value out of it, which is
what lets a record carry a severity, a body and a URL without agent-river having
to learn about any of them. It renders as rows under the line. Text you pass in
is yours and is treated as such: a `:name` or a `:text` is fenced, flattened to
one line and clipped before it reaches a buffer, and the `:context` you get back
from `agent-river-artifacts-list` is a copy, so a reading you took stays the
reading you took.

Two things to know before building on it.

**The split is deliberate.** What is true of the artifact lives in the new
table; what is true of the *relationship* between a session and an artifact
stays in the session's own two tables and is still aggregated at read time.
That is what keeps the frames out of the artifact record. It also means the
table is **not a mirror**: a file an agent touched needs no record there,
because the session's table already says everything true of it. In practice the
artifact table holds tens of records where the session tables hold thousands.

**A key is either declared or it is a path — there is no third thing.** An
undeclared key is placed by resolving it against the session's working
directory; a declared one has no such answer, and resolving `inc:INC-444`
against a cwd would produce `/repo/inc:INC-444` — a file in a tree it has
nothing to do with, which would then be drawn and eventually offered for
deletion as missing. The domain is read off the artifact table, never parsed
out of the key, and `agent-river--key-domain` answers **nil** for a key nobody
declared. There was a `file` domain standing for that case, and it could itself
be declared — at which point a record meant exactly what no record meant:
invisible on the map and counted in `agent-river-domains` all the same. **A
record now requires a domain**, and `agent-river-artifact` refuses to create one
without it.

---

# Getting events in

## From hooks

Wire them into the project's `.claude/settings.json`, or the user's
`~/.claude/settings.json` to cover every checkout. `claude-settings.json` in
this repo is a working example — six events, paths already in place:

```json
{
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command",
                     "command": "\"$HOME/src/agent-river/agent-river-hook.sh\" act",
                     "timeout": 5 } ] }
    ]
  }
}
```

Nothing needs loading in advance: the first hook call loads the Elisp itself,
and does so again after an Emacs restart.

Two details are load-bearing rather than cosmetic:

- **Whatever hook can produce a signal must not set `"async": true`.** An async
  hook's stdout is never read, so only a synchronous one can hand an observation
  back to the agent. On Claude Code that means `PreToolUse` and
  `PostToolUseFailure`; on Codex and Gemini CLI the post-tool hook joins them.
- Settings are read at session start, so a change needs a restart.

The `kind` (`prompt` `act` `think` `fail` `done` `idle`) is passed as an argv
from the settings file rather than read out of the payload, so the hook-event →
fold-event mapping stays visible in the config. `agent-river--event` may
*refine* a kind — a `think` whose `tool_response` reports an error becomes a
`fail` — but never invents one.

`codex-hooks.json` and `gemini-settings.json` are the equivalents for those
hosts; `agent-river--event` is the one function that knows a host's dialect, so
everything downstream sees one shape.

## From agent-shell's ACP stream

Claude Code, Codex and Gemini CLI report themselves through hooks. The other
agents agent-shell hosts — Goose, Qwen Code, opencode, Cursor — do not. But
agent-shell is already reading their ACP stream, and `agent-river-watch-mode`
translates it into the payload shape the hooks report, so everything from
`agent-river--event` down is shared.

What this path cannot do is answer the agent: only the hooks carry text back.

## What the agent said

`agent-river-listen-mode` (off by default) folds the end of each turn as a `say`
event: the `“` lines in the HUD, an excerpt on the state, and a `**said**`
bullet in the export under the prompt it answers.

No hook carries the message text, so this reads agent-shell's own event stream —
`agent-message-chunk` accumulated, flushed on `turn-complete` — and a session
agent-shell does not host gets no `say` lines, exactly as it gets no `◇` ones.
The event handed to observers carries the whole text and the stop reason; the
state keeps a one-line excerpt (`:said` in the report), because this is the one
value in it whose length the agent chooses. The excerpt keeps **both ends** —
the opening and the closing line, with the middle as a marked gap — because the
first N characters of an answer are its least informative: it opens by
restating the question, and the middle narrates the tool calls the state has
already counted. It is in the **task frame**:
it is the answer to the prompt above it, so a new prompt clears it, the way it
clears `steps` — the log keeps every `“` line it drew. A turn that ended some
other way than `end_turn` — cancelled, refused, out of tokens — is marked `✗`,
the way an interrupted tool call is.

A `say` counts no step, touches no artifact table and carries no working
directory: no tool ran, a file named in a sentence is not a file the agent
reached, and the anchor belongs to whoever folds the steps.

## One session, one source — per kind

The hooks and the stream describe the same session, so folding both counts every
step twice — and a doubled failure streak states a fact that is false, to the
agent itself. `agent-river--claim` decides: the hooks win, because only they can
carry an observation back, and a watched session they reach is dropped from the
registry and rebuilt from their first event rather than interleaved.

That is what makes `agent-river-watch-mode` safe to leave on. If you add a third
source of *steps*, it goes through the same claim.

What the claim settles is who folds the events both ways in produce. A kind only
one source can report has nothing to double, and is read wherever it can be got:
a hooked session that agent-shell hosts still gets its messages
(`agent-river-listen-mode`) and its permission requests
(`agent-river-approvals-mode`) from the stream, because no hook carries either.

## Putting your own facts in

Something the fold could never see, turned into an event. Hang it on whatever
Emacs hook or outside source sees it — *not* on `agent-river-observers`, which
fires on the agent's events, not yours. Two ways in:

```elisp
;; About a session: something was observed happening to it.
(agent-river-note "shared.el saved outside the session" session-id path)

;; About nothing in particular yet: it belongs to no session at all.
(agent-river-appeared "inc:INC-444" :domain 'inc :name "…")
```

What may be reported is narrower than "anything from outside". A
**point-in-time fact** — you saved this file at 14:32 — is what a note is for;
nothing can recompute it later. A **current-state fact** — the buffer has
unsaved changes *right now* — should be queried where it is read, because a
note of it goes stale the moment it is folded.

A producer owes three things:

- **A relevance filter.** An Emacs hook fires on everything you do, not on what
  matters: `after-save-hook` fires on every save you make, and without a filter
  the log becomes a list of your keystrokes. The filter is a state query — has
  any session actually reached this thing.
- **A provenance guard.** A producer that cannot tell the agent's own writes
  from yours launders the agent's action into an observation about it. Keep it
  narrow: suppress only while a tool call is open on that exact thing.
- **Say which frame a count came from.** `artifacts` and `task-artifacts`
  answer different questions, and a number under the wrong heading is the
  failure the frames exist to prevent.

A note is a *measurement*, so it may feed a signal — which means a producer
noting its own opinions closes exactly the loop the claim slots are kept apart
to prevent. Note what happened, never what you think about it.

---

# Reading the state

```elisp
(agent-river-report "<session-id>")
;; (:label "supersonic.el" :phase "editing"
;;  :claimed-intent "narrowing down the stale queue position"
;;  :claimed-intent-stale nil
;;  :task "fix the mpv queue position bug"
;;  :task-elapsed "25s" :task-steps 3 :task-failures 0
;;  :task-hottest "supersonic-mpv.el (2 touches)"
;;  :fail-streak 0 :history nil
;;  :session-hottest "supersonic.el (14 touches)" :session-elapsed "41m"
;;  :signals 1 :notes 0
;;  :said "Queue position was stale because the seek handler ran early."
;;  :subagents (:running 0 :total 1 :steps 2
;;              :each (("Explore" :steps 2 :fail-streak 0 :status "done"))))

(agent-river-reaching "inc:INC-444" 'session)
;; (("s1" :label "alpha" :touches 1 :writes 0 :ago "2m"))

(agent-river-artifacts-list 'inc)
;; ((:key "inc:INC-444" :domain inc :name "…" :context ((severity . "P1"))
;;   :gone nil :appeared "4m" :ago "20s" :notes 0 :reached 1))

(agent-river-domains)                   ; which domains are in play
;; (inc review file)

(agent-river-children "<session-id>")   ; subagent states

(agent-river-spend)                     ; what the sessions have cost
;; (:totals (("USD" . 30.62))
;;  :sessions ((:label "event log tweak" :cost 24.32 :currency "USD")
;;             (:label "alpha" :cost 6.30 :currency "USD")))
```

`agent-river-spend` is a query rather than a line in the HUD, because a total
across sessions belongs to no session and would need a line or a header of its
own. The figures are agent-shell's, sampled as the sessions worked, and they
outlive the buffers they came from: a session whose shell buffer has been killed
still answers for what it cost, which reading `agent-shell--state` cannot do.
Totals are summed **per currency**, since this is the one place the figure
itself is shown and two currencies added together are a number true of neither.

`agent-river-reaching` matches the **key exactly**, which is right for an
artifact that has no other spelling. There was a query beside it,
`agent-river-touching`, which asked the same question of a *file* and matched
on the basename so that a worktree and a main checkout counted as one; it went
with the views that named files, along with `M-x agent-river-who-touches`.

Interactively, `M-x agent-river-status` lists every session in full.

`M-x agent-river-markdown` and `agent-river-copy-report` render the state for an
issue or a PR. The export is a third derivation beside the panel and the report,
built on neither — the report's values are already formatted for a human reading
a plist, and re-formatting a formatted string is a second account of the same
data.

## The phase

`exploring` / `editing` / `verifying` / `blocked` / `waiting`, derived from the
last `agent-river-phase-window` steps. Shell-heavy work often shows *no* phase
at all, which is deliberate — the same tool runs the test suite, a git query and
a directory listing, and abstaining beats guessing. Do not treat an absent phase
as an error; `AGENTS.md` has the three rules that decide it.

## Subagents

A subagent's tool calls fire the same hooks and arrive with the **session id and
transcript path of its parent**. The only fields that give them away are
`agent_id` and `agent_type`, absent on a call the parent makes itself:

```
PreToolUse   Bash   -                  -
PreToolUse   Read   a37409f14b2a9aa55  Explore
```

**A subagent is not a session, so it is not in the registry.** It has no
prompt, no working directory, no place and nothing that can be told to it; it
used to get an entry of its own keyed `session_id/agent_id`, and every reader
of the registry then began by sorting it back out again. What it is is a
*tally* on the session that spawned it — what was set in motion, how far it
got, whether it finished — read with `agent-river-children`:

```elisp
(agent-river-children "<session-id>")
;; ((:agent "a1" :type "Explore" :steps 12 :failures 0 :status "running" …))
```

Three consequences worth knowing if you consume this.

- **A delegated step is the session's step**, and a delegated touch lands in
  the session's own artifact tables rather than in a record of the child's.
  You do not have to range over a family to find it.
- **A delegated failure does not raise the session's streak.** Three
  subagents failing once each is not one line of work failing three times, and
  the streak is what a signal is built from. It is counted everywhere else: the
  task tally, the tool tally, and the child's own entry.
- **`:status` distinguishes three things on purpose.** `done` comes from
  `SubagentStop` and is a fact; `stale` means the TTL expired with no end event
  — something went away without saying so; only `running` claims it is still
  working. Inferring "finished" from silence is how a registry starts lying.

## From inside a session

A session being observed can query its own fold through the `emacs` MCP server,
as plain function calls. Nothing advertises this, so: it exists.

```elisp
(agent-river-report "<session-id>")     ; own state
(agent-river-reaching "inc:INC-444")    ; is another session on this record?
(agent-river-set-intent "narrowing down why queue position goes stale")
```

Both of the first two address a *session* and cannot reliably tell which one
the caller is, so pass the `session_id` from the hook payload.

`set-intent` records the one thing the hooks cannot derive: `:task` is literally
the user's prompt, which stays put for twenty minutes while the work moves
through several sub-goals. It is a **claim**, reports as `:claimed-intent`, and
never feeds a signal. It also ages out — an agent remembers to narrate while
things go well and forgets precisely when it has lost the thread, so the measured
state is allowed to contradict it.

---

# Reacting to the state

Five places to hang your own code, and the choice between them is mostly the
answer to one question: *what is it about?*

| You want to… | Hang it on | About |
|---|---|---|
| react to what an agent did | `agent-river-observers` | a session |
| react to something arriving | `agent-river-artifact-observers` | an artifact |
| report what only Emacs can see | `agent-river-note` | a session |
| report something no session owns | `agent-river-appeared` | an artifact |
| annotate the map's lines | `agent-river-map-contributors` | an artifact key |

The first four hang off a **subject** — the thing an event is folded onto, of
which there are exactly two. The last is a view: it is handed something to
annotate and folds nothing, so a path or a key there is not a third subject.

The two observer hooks are separate so that a consumer never has to begin by
asking which kind of subject it was handed. A consumer that reads no subject at
all — it redraws from the tables, or it only wants to know that something moved
— may sit on both, as the map does; if you do that, make sure your teardown
leaves both, because the runner retires a throwing consumer only from the hook
it threw on.

```
hooks → fold → observers → outside world      consumer
Emacs → note → fold → observers               producer
```

## Observers

An abnormal hook called with `(SUBJECT EVENT)` after each fold. The runner
already owns the three things every consumer needs, so don't reimplement them:
its own error guard (an error reported as a fold failure would send the user to
`agent-river-reset` over one overlay), **retirement on the first error** (this
path runs on every tool call, so a broken consumer is broken thousands of
times), and teardown through the `agent-river-retire` symbol property.

```elisp
(defun my/notify-on-streak (state _event)
  (when (>= (agent-river-state-fail-streak state) 3)
    (notifications-notify :body (format "%s is stuck"
                                        (agent-river-state-label state)))))
(add-hook 'agent-river-observers #'my/notify-on-streak)
```

Three rules. **Return values are ignored** — signals are the only channel back
into the agent's context and are kept narrow on purpose, so a side effect must
not speak through it. **Never `setf` the subject** — produce state with
`agent-river-note` instead, which puts it in the event stream where it is
logged, counted and attributable. And **off by default**: writing into buffers
the user did not point you at needs consent, which is what a global minor mode
is for. A consumer that draws only into a buffer of its own needs no mode —
opening it is the consent and killing it is the retirement.

`EVENT` is the raw plist, and is where to look for anything the fold
deliberately drops — `:path`, the absolute file name, being the case in point.
The state deliberately cannot address a file on disk; see
[Placing a key](#placing-a-key).

`agent-river-map` is the one observer that ships. Read it before writing a
second.

## Talking back to the agent

`agent-river-observe` returns an observation when a signal fires, and the hook
turns it into `hookSpecificOutput.additionalContext` — text injected into the
agent's own context. Today one signal exists: a run of consecutive tool
failures.

Four rules bind anything that speaks here, and they are the reason this channel
stays narrow:

- **Signals state facts, never instructions.** They are one line with no control
  characters, and they fold back in as a `signals` count, so "how often was the
  agent told something" is itself observable.
- **One observation is delivered once.** The `signals` list is a delivery log,
  not a tally — each entry carries an `:id`, and an id already logged is
  withheld.
- **Only a reachable state may signal** — root sessions, never subagents.
  Measured, not assumed: a subagent's `additionalContext` reaches nobody.
- **Only an answering event may signal** (`agent-river-answering-kinds`).
  Anything that later reads notes back to the agent hangs off the same gate.

---

# Annotating the views

The state is already there; these change how it reads.

## Map contributors

A contributor is asked `(ROOT NODES)` and answers a hash of path to rows.
`:read` is synchronous and instant, from whatever it already has; `:refresh` may
take as long as it likes and hands its answer back through
`agent-river-map-contribute`, which marks the map dirty rather than drawing —
an answer landing after the redraw timer retired would otherwise reach a cache
and never the screen.

```elisp
(add-to-list 'agent-river-map-contributors
             (list :name 'mine
                   :ttl 5
                   :read (lambda (_root nodes)
                           (let ((table (make-hash-table :test 'equal)))
                             (dolist (node nodes)
                               (puthash (plist-get node :path)
                                        (list (list :key "mine/x"
                                                    :rank 1
                                                    :text "something"))
                                        table))
                             table)))
             t)
```

A row is `:text` (one line; the map escapes it), `:key` (stable across redraws,
or point lands on the wrong row after one), `:rank` (low first) and optionally
`:face` — **a face symbol, never a face on the text**, because tree-sitter owns
`face` in that buffer and would quietly drop a text property.

Rows are detail: a node draws closed and TAB opens it, so a contributor's rows
are read when a reader asks that line for them. Nothing a contributor says
reaches the line itself — the line is the listing, and what can be read straight
down it is the map's own.

Batch per section — thirty lines with a subprocess each, every TTL, is a fork
bomb with a view attached — and expect to be **retired on the first error**,
like an observer.

## Domains

There is nothing to register. Pass `:domain` when you declare an artifact and
it heads a section of the map under that name — something that has arrived
should not have to wait for configuration before it can be seen, which is the
failure mode of every dashboard that has to be taught about a new source.
There was a table for a prettier section heading (`agent-river-map-domains`,
`:label`) and it is gone: a second name for something the artifact table
already holds is right only for as long as somebody keeps the two in step, and
the heading is now the domain itself — the prefix on every key in the section.

## Actions — what RET may do

A line of the map is *asked* what can be done to the thing it names, by every
function in `agent-river-artifact-action-functions`. Each is handed the subject
— the plist `agent-river-artifact-at` produces for a record, plus `:path` where
the line names something absolute on disk — and returns actions, or nil:

```elisp
(defun my/incident-actions (subject)
  (when (eq (plist-get subject :domain) 'inc)
    (list (list :name "Open the ticket"
                :act (lambda () (browse-url (ticket-url (plist-get subject :key)))))
          (list :name "Acknowledge"
                :act (lambda () (ticket-ack (plist-get subject :key)))))))

(add-to-list 'agent-river-artifact-action-functions #'my/incident-actions t)
```

Nil is the whole of the applicability rule — there is no predicate to register
and no domain to be listed under, so something that has arrived is offered
whatever these have for it without waiting to be configured. **One offer is run
without asking**, which is what keeps RET on a plain file a single keystroke;
several are offered by name.

An action that wants confirming asks for it itself, and reads
`agent-river-artifact-chosen` to know whether it still should: that is non-nil
only while an action the user picked *by name out of several* is running. A
menu entry saying `Launch: Review` has already named what will happen, so the
launcher does not ask again — but a line whose only action is a launch runs it
outright, and there the confirmation is the only thing between a keystroke and
a running agent.

Three come registered: opening a file (the default entry), opening a GitHub
issue or pull request in a browser (`agent-river-gh.el`), and one launch per
brief (`agent-river-launch.el`). The order is the list's own — the menu is a
`completing-read`, where order decides what is read first and not what is worth
reading, so unlike a map contributor's rows there is no `:rank` and reordering
is a `setq`.

## Placing a key

`agent-river--rel` normalises an artifact key relative to the session cwd, or to
a bare basename otherwise — so **the state cannot address a file on disk**, and
it must keep working that way: stripping only the session's own cwd makes one
file reached from a worktree and from the main checkout render as two, which
defeats the contention query.

Three ways out, and each answers a different question:

| You are asking | Use |
|---|---|
| *which* file is this | match on the basename yourself |
| *where* is the file the event was about | read `:path` off the raw event |
| *where* does this key sit in a tree | `agent-river--artifact-absolute`, anchor over cwd |

The third is the only one that can place a key in a directory tree and the only
one that re-splits a worktree from its main checkout. It answers **nil** for a
key in a non-file domain, which is what every caller already does the right
thing with — a key that cannot be placed is left alone rather than guessed at.
Only one thing asks it now (`M-x agent-river-forget-gone-files`): the map used
to place every key it drew and lists artifact records instead.

---

# Testing your integration

The fold and the payload parsing are logic rather than formatting, and both are
pure — so they test without a frame, a hook or a live session. Yours should too:
**test the derivation, not the rendering.**

```sh
emacs -Q --batch -L . -l agent-river.el -l agent-river-tests.el \
      -f ert-run-tests-batch-and-exit
```

383 tests, ~0.3 s. The contract tests for the extension points live in `agent-river-tests.el`
under `;;; Observers`, `;;; Artifacts` and `;;; Domains` — point a new consumer
at those rather than writing the guard tests again. Useful helpers:
`agent-river-test--with-session`, `--with-observers`, `--with-artifacts`,
`--fail`, `--acts`, `--payload`, `--with-shell`.

---

# What ships as a view

Worked examples of the protocols above, and the reason each of them exists.

## The HUD (`*agent-river*` and `*agent-river-log*`)

Two buffers: a state block of one line per live session, rewritten on every
fold, and the log of the stream it was folded from — oldest to newest, tailed
by any window you have not scrolled away from.

```
*agent-river*
* │⣶⣶⣷⣴⣀⣀│ · supersonic.el    · editing · fix the mpv bridge · 4m12s · 23 steps
* │⠀⠀⣀⣤⣶⣿│ · supersonic.el<2> · editing · seek handler · 51s · 2 steps · 1 failing

*agent-river-log*
19:06:55 superson ◆ fix the mpv bridge
19:06:58 superson ▸ Read  Cask ✓  2ms
19:07:03 super<2> ▸ Edit  supersonic-mpv.el
```

`M-x agent-river-show` opens the block in a side window on the right, sized to
what it holds; `l` there — or `M-x agent-river-show-log` — opens the log in the
slot beneath it, which is the layout the two had when they shared one buffer.
`agent-river-auto-display` opens **the block** on the first event of an Emacs
session, if nothing is showing it — once, and then not again: closing that
window is you saying what you want your screen to be, and a view that comes
back on the next tool call overrules you several times a minute. Never the log,
which is written whether or not anybody is looking at it. Either one comes back
by asking. The keys are shared with the map and the approval queue, but each
buffer takes only the grains its own content answers: `n`/`p` in both, and
`>`/`<` over the landmarks (`agent-river-notable-kinds`) in the log. The block
takes neither `M-n`/`M-p` nor `>`/`<` — it is one line per live session with
nothing under it, so the coarse grain would land where `n` does.

One tool call is **one line**: the outcome is written onto the line that opened
it, so the timestamp stays the one the call began at. Pairing is by
`tool_use_id`, never by nearness or tool name — two parallel `Bash` calls would
otherwise complete each other. The block is one line per live session, ordered
by label. `◇` lines are the agent's own reasoning and `“` lines
what it said at the end of a turn; neither is in any hook payload, so both come
from the session's agent-shell buffer where there is one.

The `│…│` column leading each line is how much **context** the session has been
taking on, one bar per `agent-river-tokens-interval` (five minutes) across
`agent-river-tokens-width` characters of braille — two bars to a character, so
the default six cover an hour. A bar holds how many tokens the window grew by
while it ran, which is the work arriving as it arrives: the cost and the token
counts agent-shell keeps only move once a turn, so a graph of those would land a
twenty-minute turn as a single spike in the bar it ended in. All the session
lines share one scale so they can be read against each other, which is why the
graph comes first: only the outline marker precedes it, so the graphs stack into
a strip read straight down; a bar the session
was alive for and nothing arrived in draws one dot where a bar from before it
was first seen draws none; the first reading of a session is never growth, or a
session Emacs has just adopted would draw its whole window as one spike; and a
compaction is taken as it comes rather than counted as negative work.
`agent-river-tokens-width` nil turns it off. No hook payload carries any of
this, so a session run from a terminal has no graph, the way it has no `◇`
lines. What it **cost** is a separate question with a separate answer:
`M-x agent-river-spend`.

Neither buffer is Markdown: the log carries prompts, reasoning and tool
arguments — text this package does not control — and Markdown would let that
text restructure the view watching it.

## The map (`M-x agent-river-map`)

The view of `agent-river-artifacts`: one section per domain, one line per
record, each annotated with whoever has reached it. **The listing is the table**
— nothing is read off the disk and nothing here is a path. Who has been on a
record and how long ago are rows under it (TAB); the line carries what can be
read straight down the listing. RET on a section zooms into it, `^` comes back
out, and RET on a record does whatever that record offers (see *Actions*).

Two facts per line, each on its own channel: contention is a marker and having
ended is a strike-through. `n`/`p`, `M-n`/`M-p` and `>`/`<` are three grains of
motion, shared with the HUD and the approval queue — and `>` deliberately does
*not* stop on a record nobody has reached, because it means "some agent is
under this".

The single most important line here is the one **nobody has picked up**: an
unreached record is listed like any other, which is the whole reason this view
exists. It was a lens over dired for most of its life — one directory listed in
full, each entry carrying what had been reached beneath it — and that is gone.
What an agent did to a file is counted in the session tables and named by no
view: the block says what a session is doing, not which files it is in.

Nothing drops out of this view by getting old. `M-x agent-river-drop-artifact`
forgets one record, `M-x agent-river-artifacts-reset` forgets them all.

## The approval queue (`M-x agent-river-approval-queue`)

What each session is waiting to be *allowed*, as a buffer you can answer from
with a thumb — `agent-river-approvals-mode` chains onto agent-shell's
`agent-shell-permission-responder-function`. A pending approval is a
current-state fact and is **not folded**: it stops being true the moment
somebody presses a button in the session buffer, which nothing here would hear.

This is the one gesture in the package that relays something back to a session
on the user's behalf; it is off by default, and the gesture that turns it on is
what turns it off.

---

# Design notes

[`AGENTS.md`](AGENTS.md) is the design document: what each rule prevents, which
invariants are load-bearing, and what was tried first and lost something. It is
written for whoever is changing this code — including an agent — and it is the
file to read before altering behaviour rather than building on it.

## A third direction: something arrives, and you point an agent at it

Two optional files, and they require nothing of each other:

```
agent-river-spool.el    a file in a directory  ->  an artifact, drawn on the map
agent-river-launch.el   an artifact            ->  an agent session, when you ask
```

### Delivering something

**Write a JSON file into a directory.** That is the whole integration: no
Elisp, no registration, and nothing that needs Emacs to be running when your
side does its work.

```sh
d=${XDG_STATE_HOME:-$HOME/.local/state}/agent-river/spool
printf '%s' '{"source":"river","key":"inc:INC-444","domain":"inc",
              "name":"Checkout 500s","context":{"url":"https://…"}}' \
  > $d/INC-444.tmp
mv $d/INC-444.tmp $d/INC-444.json
```

On the Emacs side, once: `(agent-river-spool-mode 1)`.

| field | | |
|---|---|---|
| `source` | **required** | which reader to use. `river` is this shape, and an unknown name falls back to it |
| `key` | **required** | the identity. Put the domain in it (`inc:INC-444`), or two producers numbering from 1 will collide |
| `domain` | **required** | what kind of thing this is; heads its own section of the map. A delivery without one goes to `failed/`: nothing could say what it is carrying |
| `name` | | what a person sees on the line. Defaults to the key |
| `context` | | an object, carried and never read by agent-river. Drawn as rows under the line |
| `gone` | | `true` when the thing is over: the line is struck through, not removed |
| `text` | | the line for the event log |
| `session` | | an agent-river session id, if one caused this — see below |

A delivery that is `gone` the **first** time a key is seen declares nothing.
The ending being worth folding and the record being worth creating are two
different questions: a source that polls a world it did not watch re-sees
everything that changed, so without this the first wide poll fills the domain
section — the queue of what nobody has picked up — with records created purely
to be struck through, and an artifact record does not fade the way a reached
name does. A key already in the table gets its ending as usual; there the
striking through is the news rather than the whole of the record.

Two rules a writer keeps:

- **Build elsewhere, `rename` in.** Only `.json` is taken in, which leaves
  `.tmp` free for the writing half; a watcher sees the file the moment it
  appears, and a half-written one would be read as broken.
- **The same key twice is the same thing twice.** A second delivery updates
  the record rather than making another, so a poller needs no memory of its
  own.

**Did it work?** `M-x agent-river-map` lists it under its domain, and
`*agent-river-log*` gets a line either way. If nothing appears, look in
`<spool>/failed/`: an unreadable delivery is kept there and the reason is in
the log.

### If your system speaks its own dialect

Register a reader in `agent-river-spool-sources` under your `source` name and
the raw payload can land in the spool unchanged — the reader turns it into
the fields above. That is what keeps the knowledge of what a foreign system
calls things in Elisp and under test, rather than in whatever wrote the file.

`agent-river-gh.el` is the worked example: a shell script that asks `gh` for
issues and pull requests and interprets nothing, and one reader that knows
what GitHub calls a title. It is registered under two source names, `gh` and
`gh-pr`, and the delivery says which query it came out of — the reader is
told the kind rather than working it out from the shape of what it was
handed.

### If a session caused it

`session` names an agent-river session, and the fact that the delivery
happened is noted on it — logged, counted, attributable.

Note the fact, never an opinion. A note may feed a signal that goes back into
an agent's own context, so an account of the work written *by* that agent
belongs in `context`, where it is shown and read by nobody.

### Starting a session

Two switches, and both are off out of the box.

```elisp
(setq agent-river-launch-launcher "agent-shell")   ; can anything launch
(setq agent-river-launch-briefs                    ; is there anything to say
      (list (list :name "Review" :brief #'my/review-brief)
            (list :name "Rebase" :brief #'my/rebase-brief)))
```

A **brief** is a function of the artifact plist returning what to say, where to
say it and who says it, or nil:

```elisp
(defun my/review-brief (record)
  (when (eq (plist-get record :domain) 'pr)
    (list :prompt (concat "Review " (plist-get record :name) ".\n\n"
                          (agent-river-markdown))
          :cwd (alist-get 'cwd (plist-get record :context))
          ;; Optional, and the same shape as `agent-river-launch-shell-config':
          ;; this brief's sessions run under this model and session config.
          :config #'my/reviewer-config)))
```

Nil is the arming switch: a launcher with no brief can never launch. It is
also the only place a context is read, which is what lets a record carry a
severity, a body and a URL without agent-river learning about any of them.

A **list** of briefs rather than one function, because a brief is not one
thing: the same pull request is a thing to review and a thing to rebase, and
those are different prompts and quite possibly different models. Which one is
wanted is a question for the person at the line, not something a `:domain` can
answer once — so every brief with something to say about a record is one entry
in the menu RET opens, and nil is what keeps the others out of it. There is no
applicability predicate beside it; that would be a second account of the answer
the brief already gives.

`M-x agent-river-launch-artifact` asks before it starts anything, and takes an
optional brief name so the map can reach a particular one without asking twice.
Launching from the map needs no configuration at all: this file registers
itself on `agent-river-artifact-action-functions`, so a line already offers
`Launch: Review` beside `Open on GitHub`.

A **launcher** is a plist in `agent-river-launch-launchers`:

| | |
|---|---|
| `:name` | what a message calls it |
| `:available-p` | can it run here at all — is the package it drives loaded |
| `:launch` | `(BRIEF) -> HANDLE`; BRIEF also carries `:key` and `:name` |
| `:resolve` | `(HANDLE) -> session id`, once there is one, or nil |

The shipped agent-shell launcher always starts a **new** session
(`:session-strategy 'new`), whatever `agent-shell-session-strategy` is set to.
Not a preference: this layer links the session a launch *became* to the
artifact, so a resumed one would be linked to something nobody started for it,
with the brief landing in a conversation about another thing.

`:resolve` exists because agent-shell's session id only appears after the
handshake: a launch hands back a buffer and the id is asked for afterwards,
where a headless CLI can be *told* one and answers nil. It is what links the
session to the artifact it was started for, so the two are related on the
map without anybody recording it.

There are no rules, gates or budgets here — a person decides every launch.
What it would take to decide without one is issue #37.

### GitHub as a source

`agent-river-gh.el` and `agent-river-gh.sh` are one dialect, and the first
thing here that knows a system other than this package — which is why they
live beside the mechanism rather than inside it.

```elisp
(setq agent-river-gh-repos '("~/src/agent-river"))
(agent-river-gh-mode 1)
```

The script asks `gh` for recently updated issues and pull requests and
writes one file per object, interpreting nothing. It is the same program
cron would run: an Emacs that is not running must not be a reason for an
issue to go unseen.

Two kinds, under two domains. `agent-river-gh-kinds` says which to ask for
and defaults to both; a pull request heads its own `pr` section on the map,
with `pr:owner/repo#42` for a key. Set it to `'(issue)` for the old
behaviour, and note that each kind is one API call per repository per poll.

| variable | environment | |
|---|---|---|
| `agent-river-gh-repos` | *(the argument)* | checkouts to poll |
| `agent-river-gh-kinds` | `AGENT_RIVER_GH_KINDS` | `issue`, `pr`, or both |
| `agent-river-gh-interval` | | seconds between polls |
| | `AGENT_RIVER_SPOOL` | where deliveries are written |
| | `AGENT_RIVER_GH_STATE` | where the watermark is kept |
| | `AGENT_RIVER_GH_LIMIT` | how many of each to ask for |
| | `AGENT_RIVER_GH_SINCE` | first-run lookback |
| | `AGENT_RIVER_GH_RESCAN` | ignore the watermark for one run |
| `agent-river-gh-search` | `AGENT_RIVER_GH_SEARCH_ISSUE`, `_PR` | extra qualifiers, per kind |

A watermark keeps an object from being delivered twice; the first poll after
the mode is switched on ignores it and asks wide, because the artifact table
does not survive a restart. `C-u M-x agent-river-gh-poll` does that by hand.
It is one mark per repository, held whenever any kind could not be asked or
came back at the limit, so the window is never advanced past something that
was not looked at. A query that fails is reported into the log rather than
passed over — a kind that fails persistently would otherwise be invisible
behind the one that still works.

The poll asks for every state, not only the open ones: something that closes
or merges is delivered once more on the tick it ended in, so its record is
struck through rather than sitting in the section for ever.

`agent-river-gh-search` narrows a kind's own query by an extra GitHub search
qualifier, sharing the one `since` window rather than opening a second query.
It is an alist keyed by kind, because a qualifier is usually a kind's own
concept — `review-requested:@me` and `draft:false` mean nothing to an issue,
and asking `gh issue list` for either does not error, it answers with
nothing, silently, every poll:

```elisp
(setq agent-river-gh-search '((pr . "review-requested:@me draft:false")))
```

only asks about pull requests that are not drafts and where you are a
requested reviewer, and leaves the `issue` query — if `agent-river-gh-kinds`
still asks for one — untouched. It costs something the unfiltered default
does not: a review request is commonly withdrawn the moment you submit a
review, so the object can drop out of the search without ever coming back
with a closed or merged state — and a closed or merged state landing in one
more delivery is the only thing that strikes a record through. A record you
have already reviewed can therefore sit on the map looking exactly like one
nobody has touched; `agent-river-forget-artifacts` is the existing answer for
a record that has stopped being news, used more often than the unfiltered
default would need it.

`agent-river-gh-brief` is the worked example of a brief, and handles both
domains. It shows the one thing a brief for foreign text owes: everything
GitHub said — title, url, branch names, body — is quoted and introduced as
somebody else's words, so nothing in it reads as an instruction that arrived
with your standing. An issue is framed as a request to weigh, a pull request
as a change to read.

The quoting itself — `agent-river-launch-quote`, in `agent-river-launch.el` —
is not GitHub's: any brief that embeds an artifact's own text faces the same
question, whatever wrote that text, so it is shared rather than reimplemented
per source. Everything a producer wrote goes through it together, one call,
because a field quoted on its own can close the quotation early and hand
everything after it the operator's own standing.
