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
(agent-river-clear)                 ; only empty the HUD buffer
```

Several sessions fold side by side. Emacs Lisp is single-threaded, so
concurrent `emacsclient` calls are atomic with respect to each other and the
registry needs no locking.

## Two frames, always labelled

`artifacts` accumulate for the whole session; `steps`, `task-artifacts` and the
task tally reset with every prompt. Reporting one while labelling it the other
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
| **Measurement** | 23 steps, 6 touches of `mpv.el` | folded into the state |
| **Claim** | `agent-river-set-intent` — what the agent says it is doing | its own slots, reports as `:claimed-intent`, **never feeds a signal** |
| **Current-state** | is this buffer modified, is git dirty, is a permission request still open | queried where it is read, **never folded** |

The third distinction is the one integrators get wrong. A fact that stops being
true without an event to say so must not be stored: a pending approval is
answered by a button in another buffer, a diffstat is wrong again by the next
write. Fold what happened; query what is.

## Artifacts: things that are not files

The state is built out of what agents *did*, and an agent only does things to
files. Anything that arrives on its own — an incident routed to you, a review
requested, a build that broke — has no session to hang on, and it matters most
when *no* agent is running, which is exactly when there is no session to hang
it on.

So there is a second table, `agent-river-artifacts`, with a fold of its own. A
non-file **domain** heads a section of its own on the map:

```
# 2 roots  ·  1 agent
##   ⏿ `Incidents`
### ▾ ⏿ `INC-444 disk full on db-3`
- severity: P1
- queue: infra
- alpha · 0s ago
###     `INC-501 cert expiring`
##     `~/src/agent-river`
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
;; the map's parties, the shading and `agent-river-touching' see it without
;; being taught anything — and it counts no step, because no tool ran.
(agent-river-reach "inc:INC-444" session-id)

;; It is over.  Struck through on the map rather than dropped: the ending is
;; itself a thing that happened.  `agent-river-drop-artifact' removes it when
;; that has stopped being news.
(agent-river-ended "inc:INC-444")
```

**Declare before you reach.** A domain is read off the artifact table and
`file` is what a key is when nobody has said otherwise, so a key reached before
its record exists *is* a file: `inc:INC-444` resolves against the session's cwd
and shows up in its tree as a name that is not on disk, which
`agent-river-forget-gone-files` will then offer to sweep. Declaring later
repairs it — the domain is read at every draw — but the order to write is
`appeared`, then `reach`.

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

**A key belongs to a domain, and `file` is what it is when nobody said
otherwise.** A file key is placed by resolving it against the session's working
directory; a declared key has no such answer, and resolving `inc:INC-444`
against a cwd would produce `/repo/inc:INC-444` — a file in a tree it has
nothing to do with, which every view would then draw, shade and eventually
offer to delete as missing. The domain is read off the artifact table, never
parsed out of the key, so a key nobody declared is a file and stays one.

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

## One session, one source

The hooks and the stream describe the same session, so folding both counts every
step twice — and a doubled failure streak states a fact that is false, to the
agent itself. `agent-river--claim` decides: the hooks win, because only they can
carry an observation back, and a watched session they reach is dropped from the
registry and rebuilt from their first event rather than interleaved.

That is what makes `agent-river-watch-mode` safe to leave on. If you add a third
source, it goes through the same claim.

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
;;  :subagents (:running 0 :total 1 :steps 2
;;              :each (("Explore" :steps 2 :fail-streak 0 :status "done"))))

(agent-river-touching "supersonic-mpv.el")
;; (("session-b" :label "worktree-…" :touches 2 :ago "9s"))

(agent-river-reaching "inc:INC-444" 'session)
;; (("s1" :label "alpha" :touches 1 :writes 0 :ago "2m"))

(agent-river-artifacts-list 'inc)
;; ((:key "inc:INC-444" :domain inc :name "…" :context ((severity . "P1"))
;;   :gone nil :appeared "4m" :ago "20s" :notes 0 :reached 1))

(agent-river-domains)                   ; which domains are in play
;; (inc review file)

(agent-river-children "<session-id>")   ; subagent states
```

`agent-river-touching` is the one that earns its keep: two agents editing the
same file without knowing about each other is a real hazard in a worktree setup.
It matches on the **basename**, so one file reached from a worktree and from the
main checkout counts as one artifact. `agent-river-reaching` matches the **key
exactly**, which is right for an artifact that has no other spelling.

Interactively, `M-x agent-river-status` lists every session in full and
`M-x agent-river-who-touches` answers the contention question.

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
  the session's own artifact tables — which is what `agent-river-touching` and
  the map read. You do not have to range over a family to find it.
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
(agent-river-touching "supersonic.el")  ; is another session on this file?
(agent-river-set-intent "narrowing down why queue position goes stale")
```

`agent-river-touching` is the one that carries something the agent does not
already have — another session, in another worktree, editing the file it is
about to rewrite leaves no trace in its own transcript. The other two address a
*session* and cannot reliably tell which one the caller is, so pass the
`session_id` from the hook payload.

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
| annotate the map's lines | `agent-river-map-contributors` | a path or key |
| say where a session belongs | `agent-river-panel-place-functions` | a session |

The first four hang off a **subject** — the thing an event is folded onto, of
which there are exactly two. The last two are views: they are handed something
to annotate and fold nothing, so a path or a key there is not a third subject.

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

`agent-river-map` and `agent-river-heat-mode` are both observers. Read one
before writing a third.

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
`face` in that buffer and would quietly drop a text property. `:summary` is how
a contributor earns the line's fixed-width column, and it must be a reading *of
the rows*, the same data smaller, never a second account of it.

Batch per root — thirty lines with a subprocess each, every TTL, is a fork bomb
with a view attached — and expect to be **retired on the first error**, like an
observer. The diffstat (`agent-river--rows-vc`) is the asynchronous, batched and
aggregating case at once; read it before writing anything that shells out.

## Where a session belongs

A place function is called with one state and answers nil ("not mine") or a
plist of `:key` (identity, compared with `equal`), `:name` and an optional
`:visit`. The first to answer wins, so the list reads from the most specific
question to the most general.

```elisp
(add-to-list 'agent-river-panel-place-functions
             (lambda (state)
               (when-let* ((team (agent-river-state-label state)))
                 (list :key (concat "team:" team)
                       :name (concat "team " team)
                       :visit (lambda () (browse-url "https://…"))))))
```

**The working directory is the default anchor, not the only one.** It is what
the hooks happen to report, not something a session fundamentally has: this
already folds sessions that touch no file, and a session with no disk at all is
not thereby unplaceable — it is placed by something the fold does not know,
which is what the extension point is for.

A place function is asked on every redraw, so it answers from what it already
has, and one that throws is retired on the spot.

## Domains

Registering a domain in `agent-river-map-domains` is optional and only ever
about presentation — a `:label` for the section and a `:visit` for RET:

```elisp
(add-to-list 'agent-river-map-domains
             (cons 'inc (list :label "Incidents"
                              :visit (lambda (key) (browse-url (ticket-url key))))))
```

A domain absent from it is still drawn: something that has arrived should not
have to wait for configuration before it can be seen, which is the failure mode
of every dashboard that has to be taught about a new source.

## Placing a key

`agent-river--rel` normalises an artifact key relative to the session cwd, or to
a bare basename otherwise — so **the state cannot address a file on disk**, and
it must keep working that way: stripping only the session's own cwd makes one
file reached from a worktree and from the main checkout render as two, which
defeats the contention query.

Three ways out, and each answers a different question:

| You are asking | Use |
|---|---|
| *which* file is this | match the basename, as `agent-river-touching` does |
| *where* is the file the event was about | read `:path` off the raw event |
| *where* does this key sit in a tree | `agent-river--heat-absolute`, anchor over cwd |

The third is the only one that can place a key in a directory tree and the only
one that re-splits a worktree from its main checkout. It answers **nil** for a
key in a non-file domain, which is what every caller already does the right
thing with — a key that cannot be placed is left alone rather than guessed at.

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

## The HUD (`*agent-river*`)

One buffer, two halves: a state block of one line per live session, rewritten on
every fold, over a **newest-first** log.

```
* supersonic.el    · editing · 4m12s · 23 steps · mpv.el (6 touches) · 1 subagent
* supersonic.el<2> · editing · 2 steps · supersonic-mpv.el (2 touches)

19:07:03 super<2> ▸ Edit  supersonic-mpv.el
19:06:58 superson ▸ Read  Cask ✓  2ms
19:06:55 superson ◆ fix the mpv bridge
```

One tool call is **one line**: the outcome is written onto the line that opened
it, so the timestamp stays the one the call began at. Pairing is by
`tool_use_id`, never by nearness or tool name — two parallel `Bash` calls would
otherwise complete each other. The block groups sessions by place once there is
more than one place to be. `◇` lines are the agent's own reasoning, which only
the ACP stream carries.

The HUD is deliberately **not** Markdown: its log carries prompts, reasoning and
tool arguments — text this package does not control — and Markdown would let
that text restructure the view watching it.

## The map (`M-x agent-river-map`) and dired heat

Two views of the same artifact tables. `agent-river-heat-mode` shades the dired
buffer you are already in; the map lists one directory in full, each entry
annotated with what has happened *beneath* it, so several agents spread over a
large repository are visible at once. Same weighting, same derivation, different
grain.

Five facts per line, each on its own channel: weight is shading, party is text,
contention is a marker, existence is a strike-through, and the diffstat is a
fixed column. `n`/`p`, `M-n`/`M-p` and `>`/`<` are three grains of motion, shared
with the HUD and the approval queue.

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
