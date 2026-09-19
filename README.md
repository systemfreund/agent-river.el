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

Rows are detail: a node whose only children are rows draws closed and TAB opens
it, so a contributor's rows are read when a reader asks that line for them.
`:summary` is the way onto the line itself, and the only thing a contributor
can say that is read without a keystroke.

Batch per root — thirty lines with a subprocess each, every TTL, is a fork bomb
with a view attached — and expect to be **retired on the first error**, like an
observer. The diffstat (`agent-river--rows-vc`) is the asynchronous, batched and
aggregating case at once; read it before writing anything that shells out.

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
otherwise complete each other. The block is one line per live session, ordered
by label. `◇` lines are the agent's own reasoning and `“` lines
what it said at the end of a turn; neither is in any hook payload, so both come
from the session's agent-shell buffer where there is one.

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

## A third direction: starting a session from an event

**Built, and deliberately unarmed.** The code is `agent-river-launch.el`, a
fifth file, optional and opt-in; this section is both the design and what it
has to answer to. All five roles exist, including the launcher — what does
not exist is a reason for it to fire, because three switches stand in front
of it and all three are off by default.

```elisp
(agent-river-launch-mode 1)   ; watch the spool
M-x agent-river-queue         ; read what was delivered and decided
```

Out of the box that is rung 1: candidates arrive, are matched, are gated, and
are decided `ready` — the whole pipeline with a no-op where the process would
go. Set `agent-river-launch-launcher` and give one rule a `:prompt` and that
rule can be launched with `RET`; set `agent-river-launch-auto` and it goes by
itself.

The want is ordinary: a GitHub issue is opened and an agent goes to work on
it. GitHub is only the example. The same mechanism should serve a file
appearing in a directory, a build going red, or one agent finishing and a
second being sent to review it.

### Why this is not an observer

Everything in this package so far runs in one direction. The stream is
listened to, not spoken on; even a signal is deliberately narrow — facts,
never instructions, one line, folded back in so its own rate is visible.
Producers (`agent-river-note`) add events *about a session that exists*;
consumers (`agent-river-observers`) carry state outward.

Starting a session is neither. It is the first thing here that would *act*,
and it is the most expensive action there is — an agent that writes files,
makes commits, opens pull requests. So it lives in its own file behind its
own opt-in, and the package's read-only posture is unchanged: what the
launch layer takes from agent-river is the **state it decides on**, and what
it gives back is a session that then folds like any other.

An observer may still take part, but only at one point: it may **enqueue a
candidate**, never launch one. Its return value stays ignored, it still
speaks through no channel of its own, and a broken one is still retired on
its first error. Everything expensive sits behind the queue, the budget and
the gate.

### Five roles, and three of them are pure

```
source   → candidate   an issue was opened; a session handed off
rule     → decision    does this match, may it run now, with what prompt
ledger   → dedupe      has this occasion already been acted on
launcher → session     start it
queue                  what has been decided and not yet started
```

`rule`, `ledger` and the queue are functions over a candidate and the
registry, so they are testable the way the fold is: no GitHub, no
subprocess, no frame. `source` and `launcher` are the two dirty ends.

### The spool is the only door

A candidate arrives as a file in a spool directory. Processed means moved,
so the state *is* the filesystem — there is no second account of what has
been handled that can disagree with the first, it survives an Emacs restart,
and it can be read and fixed by hand.

```
<spool>/          the inbox: delivered, not yet taken in
<spool>/queued/   taken in and waiting — the queue's durable form
<spool>/done/     decided: launched, or refused with a reason
<spool>/failed/   unreadable, kept for you to look at
```

`queued/` is why there are three and not two. A candidate taken in and
recorded straight into `done/` would be gone from the queue and marked
handled the moment Emacs restarted — which is the state a machine that works
overnight is in most mornings. The queue is rebuilt from `queued/` instead,
so it is derivable from disk the way a session's state is derivable from its
events.

A writer builds its file elsewhere and renames it in. The watch sees a file
the moment it appears, and a half-written one would be read as malformed and
filed as such; only `.json` is taken in, which leaves `.tmp` free for the
writing half.

This is the same decision the bridge already made: `agent-river-hook.sh`
does no parsing, passes files in both directions, and keeps the derivation
in Elisp where it is under test. `agent-river-gh.sh` writes `gh`'s raw JSON
into the spool and understands none of it; `agent-river-gh.el` turns that
into a candidate. One place knows a dialect, exactly as `agent-river--event`
is the one place that knows a host's.

The one thing the poller does beyond moving bytes is **split**: the spool's
unit is one occasion, so one issue is one file. That has to happen before the
spool, or the ledger, the dedupe and the recovery all stop being
single-valued. It is `gh --jq`, which ships with `gh`, so there is still no
external dependency and still no field interpreted.

It is the same program from cron, a systemd timer or `agent-river-gh-mode` —
deliberately, because an Emacs that is not running must not be a reason for
an issue to go unseen. Its watermark is the time of the last run, asked with
`>=`, so it over-fetches a little. That is free: the spool deduplicates on
the occasion key, so a repeat costs one deleted file where a miss costs an
issue.

```elisp
(setq agent-river-gh-repos '("~/src/agent-river"))
(agent-river-gh-mode 1)
```

Everything writes to that door — the poller, the observer, an agent, and you
with `echo`.

### One occasion, one launch

This is `agent-river--signalled-p` again, with real money on it. A poller
sees the same issue on every tick; the candidate therefore carries the id of
an **occasion**, not of an object. `issue-42` alone is wrong — an issue
reopened two weeks later is a new reason to act, and the same mistake was
made once already with `(streak N)`, which silently suppressed a genuinely
new run of failures. So `(issue 42 <updated-at>)`.

The difference from the signal log is durability. A lost signal is a
sentence nobody heard; a lost launch record is a second agent on the same
issue.

### An agent may hand off, and the claim is the occasion — never the content

An agent can signal that it is done by writing a candidate into the spool.
It needs no new tool and no new hook to do it: that is an ordinary `Write`
or `Bash` call, the source reads it like any other, and nothing in the fold
changes.

```json
{"source":   "handoff",
 "occasion": "review",
 "session":  "<its session id>",
 "cwd":      "/path/to/tree",
 "text":     "the gate ordering is worth a second pair of eyes"}
```

It is the better anchor of the two available. A turn ending says only that
it ended; a handoff carries arguments — review this, against that branch,
with this question — and it fires *during* a session, which is the only way
a session that goes on working can be the occasion for more than one thing.

Its key is **minted** rather than derived, and that is where this parts
company with a poller. The rule that a key must name the occasion and not
the object is a rule about *re-seeing*: a pull source meets issue 42 again
on every tick, so its key has to say which visit this is or one issue
becomes an agent an hour. A push source is delivered once and consumed
once — there is nothing to re-see, so every write is its own occasion and
minting says exactly that. An `id` may still be supplied, for a writer that
retries and wants its second attempt recognised as its first.

(The design first reached for `SESSION\0CALL-ID`, the tool-call id
`agent-river--event` already assembles. It is a fine identity and the wrong
one here: the agent writing the file does not know it, and correlating the
file with the call that wrote it would be machinery bought to solve a
problem a push source does not have.)

But a handoff is the agent talking about itself, which is the thing the
`intent*` slots are kept apart from the measurements to contain. The line
that keeps it usable:

> **A claim may be the occasion. It must not be the content.**

That the write happened is a measurement — it is on disk, with a time and a
session. What it says is a claim. So the handoff *triggers*, and the prompt
for the next agent is built from the **state**: which files, which task,
which branch, what failed. The agent's own words travel as quoted context,
marked as its, the way `intent` is marked twice and placed last in the
Markdown export. Otherwise the first agent writes the second one's
instructions and the chain contains no measurement at all.

That separation is enforced rather than advised. The words land in `:claim`,
and a rule **cannot match on it** — otherwise an agent could pick the wording
that arms the rule it wanted, which is the agent deciding rather than the
rule. What a source *is* meant to steer is `:occasion`, a short token from a
small vocabulary: a choice a rule author can anticipate, where a sentence is
not.

Two consequences:

- **Reliability runs the other way.** The host observes a turn ending; a
  handoff requires the agent to remember. So the handoff is the good path and
  the turn ending is the fallback, and the ledger deduplicates them against
  each other: a turn that has already handed off does not end a second time.
- **A handoff belongs in the river.** The session that writes one gets a
  `note` for it, so it shows in the HUD and is counted in the report —
  which is how the rate becomes visible before anything is automated. The
  note says `handoff: review` and not a word of the claim: a note is a
  measurement and may feed a signal, so folding the agent's prose into one
  would launder a claim into an observation about the world.
- **A half-written file is not a broken one.** The contract is
  write-then-rename, and a poller can be held to it. An agent reaches for
  `Write`, which creates the file where the watch can already see it — so a
  file that will not parse and is younger than `agent-river-launch-settle`
  is left for the next scan rather than filed under `failed/`. Losing a
  handoff to a contract nobody told the agent about would also lose it
  silently, since the agent has no way to find out.

### Chains

A launched agent produces events, which the same observer sees. Left alone
that is a thing that feeds itself, and unlike a runaway observer every
iteration of this one spends tokens and writes to the repository.

The first guard is provenance, as with any producer: a candidate whose actor
is us does not fire. The second is blunter and holds when the first fails —
each session carries the **generation** it was launched at (issue → A is 1,
A → B is 2) and a cap cuts the chain. Notes already work this way, one level
deep: a note made while a note is being handled is refused. This is the same
idea with a counter instead of a flag, plus a rate budget and a kill switch
that stops everything without anyone first having to work out which rule was
at fault.

### Three switches, three different questions

Between a candidate and a process stand `agent-river-launch-launcher` (can
*anything* launch), a rule's `:prompt` (may *this rule*, since there is
nothing to say to an agent without one) and `agent-river-launch-auto` (does it
happen *without being asked*). They are the rungs: a launcher configured is
2, arming one rule is 3, `auto` is 4 — and each is something you can see
yourself turn on. A rule with no `:prompt` stays a dry run however the other
two are set, which is what lets one rule be armed while the rest keep
producing evidence.

`RET` in the queue overrides a candidate's **gate** and nothing else. A gate
is this layer's guess about whether the moment is right, and a person
pressing `RET` is not a guess; but it cannot invent a prompt a rule does not
have, and it cannot launch with no launcher.

The budget is spent by launching and never by waiting. An armed candidate is
asked again every minute, and charging it each time would spend a
four-an-hour budget fifteen times over in an hour of sitting still.

### Identity is assigned where we control the call, and resolved where we do not

A launcher is a plist — `:name :launch :resolve :available-p` — in the shape
`agent-river-map-contributors` already uses.

With **agent-shell**, the ACP session id appears after the process is up, so
`:launch` can hand back only a handle (the buffer) and the binding candidate
→ session key is resolved late, on the three-state pattern
`agent-river--shell-buffer` already uses: seen / nothing yet / looked and
found nothing, with the time. That last state must not become permanent here
either.

With a **headless** CLI the session id can be passed in, so the key is known
before the process starts and the first hook event lands in the right place
without being looked for. `:resolve` is nil there.

The asymmetry is the protocol boundary, not a wart: **where we control the
invocation we assign identity; where we do not, we resolve it afterwards.**

It also decides which launcher is which. An agent-shell buffer at three in
the morning waiting on a permission prompt is an agent spending the night
waiting for a human. agent-shell is the calibration launcher; headless is
the operating one. Switching is a setting, not a rewrite.

### The queue is state; the buffer is a view of it

Because it has to drain by itself eventually, the queue cannot be a feature
of a buffer. It is a store and a drainer, and `RET` is one drain mode beside
*automatic*. The buffer is a read-only view of state written elsewhere —
the same role the map has, under the same rules.

It is deliberately **not** in the registry. The fold's docstring promises a
state can be rebuilt by replaying its events, and a candidate that has not
started is none of its events.

Being a view, it takes the keys the other views take: `n`/`p` walk every
line, `M-n`/`M-p` walk the candidates past their own detail, `>`/`<` walk
the ones `RET` could start. And being rebuilt on every intake and every
drain, it finds its lines again by what they *name* rather than by where
they were — a candidate that left from above would otherwise slide a
different one under a finger already on its way down, and here that finger
does not answer a question, it starts a process.

Which is also why `RET` asks first. The approval queue spends a prompt only
on the two `_always` answers, because the rest decide a single tool call;
in this buffer every `RET` is the expensive kind.

### Refusals are the measurement

The path from *watch it decide* to *let it run overnight* is the whole
point, and it only works if the ledger records **decisions** rather than
launches: fired, and refused with the reason — no rule matched, budget
spent, someone is already in those files, generation too deep, the actor was
us. After a fortnight that log says which rule would have been wrong how
often, and one rule is armed on the evidence.

That is the same move notes make: visible in the HUD and counted in the
report first, so the rate can be seen before anything is fed back.

Four rungs:

1. **Shadow.** Nothing starts. Everything is decided and logged.
2. **`RET` starts it**, through agent-shell, while you watch.
3. **One rule armed**, headless, in a worktree, a budget of one an hour,
   only while you are at the keyboard.
4. **Overnight**, with the budget and the kill switch, and a Markdown digest
   in the morning through `agent-river-markdown`.

### Rules are data, with functions as the way out

A rule is a plist, and `:match`, `:gate` and `:prompt` each take a
declarative value *or* a function.

```elisp
(setq agent-river-launch-rules
      '((:name "trusted issues"
         :match ((:source . "\\`gh\\'") (:actor . ("oemer" "octocat")))
         :gate ((:max-concurrent . 2) (:no-failures . t)
                (:budget . (4 . 3600))))))
```

`:max-concurrent` counts **agents**, not sessions: a subagent is a tally on
its parent rather than a registry entry, so a session running three of them
is one session and four agents, and the cap is about the machine.

The default is the declarative form, and the reason is rung 1: calibrating
means reading. A declarative rule can be explained in the queue buffer —
matched on source `gh`, held because two agents are already working —
where a function can only be named. What holds either way is that the ledger
records the *outcome* of every gate, so a function rule is still answerable
for afterwards; it just cannot explain itself in advance.

**`:match` is final and `:gate` is not**, and the split is the useful part
rather than a tidy one. A match is a property of the candidate: nothing about
waiting will change whether this is a GitHub issue by someone trusted, so a
candidate no rule matches is *finished* — filed, not left to be asked the
same question every minute for the rest of the week. A gate is a property of
the world, which changes: two agents are running now and will not be at four,
the budget window moves, midnight passes. So a gate refusal leaves the
candidate in the queue to be asked again, and refusing it finally would throw
work away for having arrived while an agent happened to be busy.

Which means the gates have to be asked with nothing being delivered. An agent
going idle is what releases a held candidate and no file arrives to say so,
so `agent-river-launch-poll-interval` is the drain's clock as much as the
spool's safety net.

**A gate states its reason, and silence means yes.** That is why a gate
function returns the reason rather than a boolean — "refused" without
"because the budget was spent" is not evidence of anything, and the refusals
are what the later rungs are armed on. It is also why a gate that *throws*
refuses and says it broke, and why an unknown check refuses rather than
passing: a typo in a config must not silently arm a rule its author gated.

**A hold is logged on change, not on every ask.** A candidate held by a
budget for an hour is asked sixty times, and sixty identical lines bury the
transitions the log exists to show.

### Two things that must be settled before rung 4

- **The prompt is the attack surface.** An issue body is written by whoever
  can open an issue, and it would arrive as instructions to an agent holding
  tools. The defence is not phrasing, it is the gate: a trusted author, or a
  label only a maintainer can set. The body travels as data, framed as such,
  and the rule decides how much of it comes along at all.

  That is why the GitHub source carries the body in `:payload`, where no rule
  can match it, and offers `:actor` and `:labels` to decide on instead. A
  label is the better half of the two: `:actor` says who opened the issue,
  but a label can only be set by someone with write access, so it is a
  maintainer saying *this one may be worked on* rather than a guess about a
  stranger. Labels are comma-**wrapped** (`,bug,`) so that the obvious
  spelling is the exact one — unwrapped, a rule for `bug` would also fire on
  `debug`, and a loose match here is a stranger's issue reaching an agent.
  `agent-river-gh-example-rule` shows the shape and is deliberately not
  installed: a default that launches on a stranger's issue is the one thing
  this must not ship.
- **Never in the working checkout.** A worktree per launch, a branch rather
  than `main`. The path normalisation here is already built for this — one
  file reached from a worktree and from the main checkout is the same file
  for identity, and `anchors` keeps the trees apart for placement.

### Left open on purpose

One of the two questions left open here has answered itself, and it is worth
saying how, because the answer was smaller than the question.

**How a rule builds a prompt out of the state** without becoming a fourth
renderer: it does not render anything. `agent-river-launch-context` hands back
the **Markdown export**, which exists precisely for where the state leaves the
package — an issue, a pull request, a message — and a prompt to another agent
is exactly that. It already escapes the agent's words and already marks a
claim as a claim. The claim is appended last and quoted, for the same reason
`intent` is last and marked twice over there.

Still open, and still not guessed at:

- What becomes of a candidate that never resolves — the launcher started
  something and no session ever appeared. Today the record is simply asked
  again on every drain and a dead handle is dropped, which is enough while
  the only consumer is the generation counter.
- The **provenance filter** — not acting on what we ourselves caused — which
  is the sharp instrument next to `agent-river-launch-max-generation`. It
  needs a fortnight of decisions to say what noise it would actually be
  filtering.

