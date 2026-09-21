# AGENTS.md

This file provides guidance to coding agents working with code in this
repository. `CLAUDE.md` is a symlink to it, so Claude Code and any host that
reads `AGENTS.md` see the same text.

## What this is

An Emacs package that folds the Claude Code hook event stream into a per-session
*state* (what the agent is working on, which files it revisits, how its tools are
faring) and renders it into `*agent-river*`, with the stream it was folded
from beside it in `*agent-river-log*`.

`README.md` is the integration guide — the data model, the entry points and the
extension protocols, written for somebody wiring their own application to this.
It is deliberately *not* the design document any more: **this file is**. The
reasoning behind a decision, and the failure it prevents, lives here and in the
code comments. A change that moves behaviour updates both.

The HUD is two buffers: `*agent-river*` holds the state block, one line per
live session, and `*agent-river-log*` holds the stream it was folded from.
They shared one buffer until the block was torn down and rebuilt directly
above a log being written to at the same moment — see the divider bullet for
what that cost and what the boundary gives back. Where this file says *the
HUD* without qualifying it, it means the pair.

No build system. `agent-river.el` is everything the HUD is;
`agent-river-spool.el` is the door something from outside comes in through,
turning a delivered file into an artifact; `agent-river-launch.el` is the
one thing here that starts a process, pointing an agent at an artifact.
Both are optional and require `agent-river`, and they require nothing of
each other — see the third-direction section for why they were one file and
are not any more. `agent-river-gh.el` and `agent-river-gh.sh` are one
*dialect* for the spool, registered under two source names (`gh`,
`gh-pr`), and the line they are on the far side of is that a source
knowing about a foreign system lives beside the mechanism rather than
inside it — `river` is the normalised shape and stays in the core, and
the next source (a tracker, a mailbox, a build) goes next to the GitHub
one. `agent-river-tests.el` is the ERT suite for all of it,
`agent-river-hook.sh` is the bridge, and there is one example hook wiring
per host — `claude-settings.json`, `codex-hooks.json`,
`gemini-settings.json`.

## Commands

```sh
# Full suite (392 tests). -L . is required: the tests require all four .el files.
emacs -Q --batch -L . -l agent-river.el -l agent-river-tests.el \
      -f ert-run-tests-batch-and-exit

# One test, or a group, by regexp selector
emacs -Q --batch -L . -l agent-river.el -l agent-river-tests.el \
      --eval '(ert-run-tests-batch-and-exit "streak")'

# Lint: byte-compile must be warning-free
emacs -Q --batch -L . -f batch-byte-compile agent-river.el && rm -f agent-river.elc
```

The suite runs in ~20 ms — no frame, no hooks, no live session. Run it on every
change.

Trying a change in a live session: `agent-river-hook.sh` self-arms (it loads the
`.el` if `agent-river-hook` is unbound), so a reload is
`M-x load-file agent-river.el`. If that follows a `cl-defstruct` slot change,
existing registry states are short the slot and the fold errors — `M-x agent-river-reset`.

**A reload does not bring new defaults with it**, and this has cost real time
more than once: `defvar` and `defcustom` both leave an already-bound variable
alone, so after reloading, a changed default is still the old value and a
changed list (`agent-river-map-contributors`) is still the old list — including
one that an error retired. Re-apply by hand: `custom-reevaluate-setting` for a
defcustom (it honours a real customisation), `setq` for a defvar. A timer
already running also keeps the period it was started at, so a changed interval
needs its timer restarted.

Note that `agent-river-reset` clears the *whole* registry, including the session
you are working in — which is usually folding itself while you edit. To drop one
stale entry instead, `(remhash "<key>" agent-river-registry)` then
`(agent-river--redraw-block)`.

Hook wiring lives in a project `.claude/settings.json` or in the user's
`~/.claude/settings.json`; the latter covers every checkout. A change may be
picked up by the running session's settings watcher — observed happening without
a restart — but restart Claude Code if the hooks stay silent.

## Asking the state things, from inside a session

A session being observed can query its own fold through the `emacs` MCP
server, as plain elisp. No tool is exposed for this and nothing advertises
it, which is the only reason this section exists — see the README section of
the same name for what the values mean.

```elisp
(agent-river-report)                     ; own state, as a plist
(agent-river-reaching "inc:INC-444")     ; who else is on this record
(agent-river-set-intent "chasing why the spinner sticks after a kill")
```

There was a third here, `agent-river-touching`, and it was the one this
section was written for: another session, in another worktree, editing the
file you are about to rewrite leaves no trace in your own transcript, and the
registry was the only place that fact existed. It is gone with the views that
named files. What it had going for it was that the fact is genuinely
unavailable elsewhere; what it did not have was a caller — the transcripts
hold exactly one invocation, which answered `nil` and was not believed. If
the contention question comes back, that is the measurement to take first:
why the answer was empty.

Both of these address a *session*, and cannot reliably tell which one you
are. `agent-river-report` only defaults when the registry holds exactly one
session, and `agent-river-set-intent` defaults to whichever session acted most
recently — with several running, quite possibly not you, and the
misattribution is silent. Pass the `session_id` from your own hook payload
when you have it.

`set-intent` is a claim rather than a measurement, and narrating on a schedule
is what breaks it: `agent-river--intent-stale-p` can contradict the claim only
because an agent stops narrating at precisely the moment it loses the thread.
An intent refreshed out of habit never goes stale and stops saying anything.
State one when the sub-goal actually changes, not per tool call.

## Architecture

The data path, one hook event end to end:

```
Claude Code hook                     agent-shell event (no hooks wired)
  → agent-river-hook.sh <kind>         → agent-river--shell-observe
  → agent-river-hook (kind in out)     → agent-river--shell-events
  ↓                                    → agent-river--shell-payload
  → agent-river--event                payload alist → event plist
  → agent-river-observe               addresses the state, folds, renders, signals
  → agent-river-fold                  pure state transition
  → agent-river-registry              key → agent-river-state
  → agent-river--update-block / agent-river-log      the two views
```

And a second, narrower path for what no session did:

```
producer (a webhook, a poll)
  → agent-river-appeared / -ended / agent-river-note-artifact
  → agent-river-observe-artifact      addresses, folds, logs, signals nothing
  → agent-river-fold-artifact         pure state transition
  → agent-river-artifacts             key → agent-river-artifact
```

Two folds, two registries, one rule each way: `agent-river-fold` owns a
session, `agent-river-fold-artifact` owns an artifact, and neither writes
the other's. The edge between them -- a session having reached an
artifact -- is folded onto the *session* as a `touch` event
(`agent-river-reach`), because that is where the two frames are.

Two ways in, one adapter. The right-hand column exists for the agents
agent-shell hosts that have no hooks; it translates into the payload shape the
hooks report rather than building events of its own, so everything from
`agent-river--event` down is shared. Only the hooks can answer the agent —
nothing this package *observes* is ever put back on the stream. The one
thing that travels the other way is not ours: `agent-river--respond` relays a
permission choice the user made, to the session the line names, and only
while `agent-river-approvals-mode` is on (see **Approvals** below). Both
gestures that can make that call — `agent-river-answer` in the HUD and a row
of the approval queue — go through that one function, so they cannot come to
different conclusions about when a question may still be answered.

A third way in, narrower again, for the one thing neither of those carries:

```
agent-shell event (whoever folds the session)
  → agent-river--listen              agent-message-chunk, accumulated
  → agent-river--say-ended           turn-complete: one event, whole text
  → agent-river--event               payload alist → event plist
  → agent-river-observe              from here on, as above
```

`kind` (`prompt` `act` `think` `fail` `done` `idle`) is passed as an argv from
settings.json, not read out of the payload, so the hook-event → fold-event mapping
stays visible in the config. `agent-river--event` may *refine* it — a `think`
whose `tool_response` reports an error becomes a `fail`, since only Claude Code
has a failure event of its own — but it never invents one from scratch.

`agent-river--event` is also the only function that knows a host's dialect:
`agent-river--tool-file` for the several names a file argument goes by, and
`agent-river--arg` because an argument may not even be a string (Codex passes
`command` as a vector). Everything downstream sees one shape. See the README
section on Codex and Gemini CLI for what else differs.

**The shell script only moves bytes.** It does no parsing and has no `jq`
dependency. Both directions go through files so no tool argument is ever
interpolated into an Elisp form that Emacs then evaluates — that was a real
problem in an earlier 224-line version. Keep derivation logic in Elisp where it
is testable.

**The fold is pure and deterministic** given event order, which is why the tests
need nothing else. `agent-river-fold` takes a state and an event plist and mutates
only that struct. Everything downstream (phase, signals, panel, reports) is
derived from the state, never accumulated separately.

### Invariants to preserve

These are load-bearing; the tests enforce most of them.

- **Registry key is `session_id`, and a subagent is not a session.** Subagent
  hook calls arrive with the *parent's* session id and an `agent_id` of their
  own, and that `agent_id` used to make a registry entry beside the parent. It
  failed the definition of a session in four ways — no prompt, no working
  directory, no place, nothing that can be told to it — so every reader of the
  registry began by sorting it back out again, and
  `agent-river--family-in-file` existed for no other purpose than to reach
  back across the split the split had made. It is a **tally on the session**
  now (`agent-river--delegate`, read by `agent-river-children`): what this
  session set in motion, how far it got, whether it is finished. A delegated
  step is a step the session took, and a delegated touch lands in the
  session's own artifact tables rather than in a record of the child's.
- **The one measurement a delegated failure stays out of is the streak**
  (`agent-river--delegated-p`). Three subagents failing once each is not one
  line of work failing three times, and the streak is what a signal is built
  from — so a merged streak would put a false statement into the session's own
  context. Everything else about the failure is counted: the task tally, the
  tool tally, and the child's own entry, which says whose it was.
- **Two frames, always labelled.** `artifacts`/session-wide survives a new prompt;
  `task-artifacts`/`steps`/`task-failures`/`said` reset on `prompt`. Report keys say which
  (`:task-hottest` vs `:session-hottest`). The panel uses the task frame; the
  map's parties are read in whichever `agent-river-map-scope` names, and it
  defaults to the session frame.
- **Claims are separate from measurements.** `intent*` slots come from
  `agent-river-set-intent` — the agent talking about itself. They must never feed
  a signal (this state is fed back to the agent; a claim later read as an
  observation closes the loop). They age out via `agent-river--intent-stale-p`.
- **Signals state facts, never instructions**, stay a single line with no control
  characters (the response is JSON-serialized), and fold back in as a `signals`
  count so "how often was the agent told something" is itself observable. They go
  back in *through* `agent-river-fold` as a `signal` event — `observe` used to
  push straight onto the slot, which made it a second writer to a state the fold
  is supposed to own alone.
- **The fold is the only writer.** Nothing else `setf`s a slot. The fold's
  docstring promises a state can be rebuilt by replaying its events; a second
  writer puts transitions in the state that no event accounts for, and the
  promise stops being true without anything failing.
- **Whatever hook can produce a signal must not set `"async": true`.** An async
  hook's stdout is never read, so only a synchronous hook can inject
  `additionalContext`; and a synchronous `act` orders its log line before its own
  `PostToolUse` line rather than racing it. On Claude Code that means `PreToolUse`
  and `PostToolUseFailure`; on Codex and Gemini CLI the post-tool hook joins them,
  because there it is the event a `fail` is refined out of.
- **One observation is delivered once** (`agent-river--signalled-p`). Entries in
  `signals` are `(:at :text :id)`, so the list is the delivery log and not just
  a tally; `agent-river--signal` returns `(:text … :id …)` and withholds any id
  already logged. The throttle alone was not enough: it keys on the failure
  streak, which does not move when the agent merely acts, so one run of three
  failures was re-delivered on every subsequent tool call. The throttle decides
  which streaks are worth a word; the id decides each gets exactly one.
  The id must identify the *occasion*, not the number — `(streak RUN N)`, where
  `fail-runs` counts runs and never resets. `(streak N)` alone silently
  suppressed a later, genuinely new run of three failures, and a never-reset
  counter is also what stops a new prompt making old ids collide with new ones.
- **Only a reachable state may signal** (`agent-river--answerable-p`): root
  sessions, never subagents. Measured on 2026-09-13, not assumed — a subagent's
  `PostToolUseFailure` is synchronous, `agent-river-hook` writes
  `additionalContext` for it, and the text reaches nobody: two subagents asked
  outright never saw it, a trace confirmed the signal came from a real `fail`
  argv rather than a `think` refined into one, and the transcript holds no
  sidechain entry containing it. Signalling a subagent therefore writes into a
  pipe nobody reads, and counting it repeats the lie the gate below exists to
  stop. Dropped rather than escalated to the parent: a child's failures are a
  statement about a different subject, and `agent-river-children` already
  aggregates them on demand and says whose they are. Claude Code only; nothing
  is known about Codex or Gemini CLI here.
- **Only an answering event may signal** (`agent-river-answering-kinds`, default
  `act` and `fail`). `observe` asks `agent-river--signal` only for those kinds.
  It used to ask on every event, so a fail streak still standing at the end of a
  turn signalled again on `idle` — whose hook is async, so nothing read it — and
  that phantom was logged and folded all the same, leaving the `signals` count
  claiming the agent had been told twice what it was told once. The tally exists
  to make "how often was the agent told something" observable and must not be
  the thing misreporting it. The list decides which events may answer and the
  wiring must mark exactly those non-`async`; Emacs cannot read settings.json,
  so the two are kept in step by this invariant, not by inspection. Anything
  that later reads notes back to the agent hangs off the same gate.
- **Never fail a tool call over the HUD, but never go quiet either.** Every step in
  the script degrades to a no-op; a payload that reaches Emacs and then throws
  writes a `hook failed` / `fold failed` line into the buffer. Silent failure is
  how this has broken before.
- **One log line is one line** (`agent-river--log-text`). The log is
  line-based: a newline in a log line does not make two entries, it makes one
  entry and a remainder carrying none of the properties `n` and `>` read, and
  `agent-river-max-entries` then trims by counting lines that are no longer
  one entry each. The hook path has always squished and clipped where the
  event is built (`agent-river--event`); the artifact path went straight to
  `agent-river-log` with whatever a producer sent, which is the text here
  least likely to be ours -- a ticket title arrives at any length and shape,
  where a tool argument at least came from a host this file knows the dialect
  of. The tag is producer text too, so it gets the same treatment: a label
  column truncates by width and a newline is not width.
- **Paths normalise identically across sessions** (`agent-river--rel`): relative to
  the session cwd when under it, bare basename otherwise. Stripping only the
  session's own cwd makes one file reached from a worktree and from the main
  checkout render as two, which defeats the contention query.
- **The anchor lives beside the keys, never inside them** (`agent-river-state-cwd`).
  A normalised key cannot say which tree it is in, which is the price of the
  invariant above and not a defect in it. The cwd is folded as a measurement of
  its own — refreshed by every event carrying one, though on the hook path
  that never moves it: the payload repeats the directory the agent was started
  in, and a `cd` inside a Bash call is a different process. Only the
  agent-shell path can re-anchor a session, since it reads the buffer's
  `default-directory` per event. A view that needs a real path puts the cwd
  and the key back together deliberately (`agent-river--artifact-absolute`). Resolving is strictly
  worse than matching on the name for *identity* questions and strictly better
  for *placement* ones. Both readings existed and each said which it was;
  what is left is the placement one, since nothing matches a file by name any
  more — `agent-river-touching` did, and the map's directory aggregation
  resolved.
  A file *outside* the cwd is degraded to a bare basename by the same
  normalisation, so the cwd cannot place it either — resolving one against the
  cwd drew a file edited under `~/.claude` inside the project tree. Those keys
  carry their real directory in `anchors` (`agent-river--anchor`), folded from
  `:path` and kept only for the strays: a key under the cwd is placed by the
  cwd already, and a second copy of that fact is only a way for the two to
  disagree. An anchor is dropped as soon as the key is reached from inside the
  cwd, because the same basename is reachable both ways.
- **An artifact is a subject, and a session reaching it is an edge.**
  What is true of the artifact lives in `agent-river-artifacts`; what is true
  of the *relationship* stays in the session's two tables and is still
  aggregated at read time (`agent-river--artifact-entries`,
  `agent-river--domain-parties`). That split is what keeps the frames out of the
  artifact record: `artifacts` versus `task-artifacts` is a property of the
  reaching, not of the thing reached. The artifact table is **not a mirror**
  of the session tables -- a file an agent touched needs no record there, the
  session's table already says everything true of it, and a second copy is
  only a way for the two to disagree. What belongs there is what the event
  stream could never have produced: something declared in from outside, the
  same rule `agent-river-note` follows one subject over.
- **Appearing is the key entering the table, not the event arriving.**
  `agent-river-observe-artifact` returns the artifact on first sight and nil
  on every repeat, which is the dedup answer given by the table rather than
  by every producer keeping a list of its own -- the shape
  `agent-river--signalled-p` gives one subject over, for the same reason. It
  is a return value rather than a separate query so that asking and folding
  cannot come apart. A repeat still *folds* what it carries: not-news is not
  the same as nothing happened, and a severity that moved has to land.
- **`agent-river-reach` counts no step.** No tool ran. A step count inflated
  there would be wrong in every reading taken from it, to exactly the extent
  the function is used. It is a measurement rather than a claim because
  whoever calls it performed the dispatch and is reporting it -- the same
  standing any measurement made outside the hook stream has.
- **Declaring comes before reaching, and only the caller can get that
  right.** The domain is read off the table and `file` is what a key is when
  nobody has said otherwise, so a key reached before its record exists *is*
  a file: `inc:INC-444` resolves into the session's tree as a name that is
  not on disk, which `agent-river-forget-gone-files` then offers to sweep --
  the mistake below, reached by doing the two calls in the wrong order. Not
  closed in code, and the alternatives are written down rather than merely
  rejected. Declaring from `agent-river-reach` would give a *file* reached
  that way a record saying nothing the session tables do not already say
  (the table is not a mirror) and would make two calls that declare a
  domain; a domain argument on the reach is the same duplication with a
  smaller surface; and anything that decided from the shape of the key is
  the prefix rule the invariant below exists to refuse. What holds instead
  is that the window closes by itself -- the domain is read at every draw,
  so a record landing late repairs the placement -- and that the docstrings
  at both ends say so. A test pins both halves. `agent-river-link-artifact`
  is the one caller that *cannot* get it wrong, and not because it is
  careful: both halves are one function, so there is no order left for a
  caller to choose.
- **A key belongs to a domain, read off the table and never parsed out of the
  key** (`agent-river--key-domain`). `file` is what a key is when nobody said
  otherwise. A prefix rule would have to decide what `c:/tmp/x` means and
  would answer for keys nobody ever declared.
  `agent-river--artifact-absolute` therefore answers **nil** for a non-file key,
  which is what every existing caller already does the right thing with:
  resolved against a cwd, `inc:INC-444` became `/repo/inc:INC-444`, a file in
  a tree it has nothing to do with, which every view would then draw, shade
  and eventually offer to delete. That is the mistake the anchors were folded
  to stop, one domain over. There was a second reading beside it once,
  `agent-river--artifact-place` -- "which artifact" where this one says
  "where on disk" -- and it went with the position marker, its last caller:
  a section listing keys them by the key itself, which is what a non-file
  artifact's name already is. **Which domains are in play is derived too**
  (`agent-river-domains`, and `agent-river--domain-sections` for the
  non-file ones the map draws -- there was a third,
  `agent-river--map-live-domains`, which narrowed one to the other and
  ended up with no caller at all). It
  was a `defcustom` holding `(file)`, documented as the list a reader could
  consult instead of walking the table, and nothing ever added to it -- so
  it went on saying `file` while `inc` records piled up beside it. A
  declared list of what has arrived is a second account of the table by
  construction: right only for as long as somebody keeps it in step, which
  here was nobody.
- **A context is handed out as a copy, and a producer's own list is never
  written into** (`agent-river--artifact-merge`, `agent-river-artifacts-list`).
  The merge used to copy the spine with `copy-sequence` and `setcdr` the
  cells, which are shared: a context read before an update showed the value
  from after it, so a consumer diffing against its own snapshot found no
  change -- the record moving under a reader with no event at that reader's
  end accounting for it, which is the second-account problem arrived at from
  the back. Every cell is built fresh now. The same rule keeps the merge off
  the producer's list, which may well be a quoted literal.
- **Nothing on the artifact path reaches the agent.** Signals travel back
  through `agent-river-observe` alone, and an artifact has no session to
  answer -- which is the case the table exists for. Side effects hang off
  `agent-river-artifact-observers`, a *separate* hook run by the same runner
  (`agent-river--run-observers`, which now takes the hook symbol) under the
  same three rules. Separate because the subject differs: one hook carrying
  either kind would make every consumer begin by asking which it had been
  handed, and one that forgot to ask would be wrong only for the events it
  saw least often. **A consumer that never reads its subject sits on both**,
  which is the map (`agent-river--map-observe`, ignoring both arguments and
  redrawing from the tables): subscribed to the session hook alone it drew
  nothing for a record that arrived while no agent was running — the case
  the table exists for, and so the case the view was blindest to. That is
  the exception the split allows rather than a hole in it, and the price is
  that the retirement has to leave both hooks, since the runner removes a
  thrower only from the one it threw on.
- **One session, one way in — for the kinds both ways in carry**
  (`agent-river--claim`). The hooks and the agent-shell stream describe the
  same session, so folding both counts every step twice — and a doubled
  failure streak states a fact that is false, to the agent itself. The hooks
  win, because only they can carry an observation back; a watched session they
  reach is dropped from the registry and rebuilt from their first event,
  rather than interleaved. This is what makes `agent-river-watch-mode` safe to
  leave on. What it decides is who folds the *steps* and the turn around them,
  which is the whole of what both sources report. A kind only one source can
  produce has nothing to double, and is therefore read wherever it can be got:
  `agent-river--listen` for what the agent said and `agent-river--attend` for
  the permission requests are both ungated, and both serve sessions the hooks
  own — which is the case with the most sessions in it. The rule holds per
  kind, not per session, and the gate's docstring says so.
- **What the agent said is stream-only, and counts nothing**
  (`agent-river--listen`, the `say` branch). No hook carries the message text —
  `Stop` names a transcript that lags by one record, which is why reading it
  was removed — so this follows the `◇` lines: a session agent-shell does not
  host gets no `say` lines, and that is the price rather than a bug. Five
  things it owes. The **accumulator is a side table**
  (`agent-river--say-runs`), for the reason `agent-river--thought-runs` is:
  nothing folds it, no query reads it, and a slot would make every reload
  demand `agent-river-reset`. The **flush is `turn-complete`**, which exists on
  agent-shell's event stream and not on the ACP notification stream the
  thought handler hangs off — it is derived from the `session/prompt` response,
  not sent as a notification, which is why this is a subscription of its own
  (`agent-river--listening`) with `:event` nil and a `pcase` in the handler:
  `:event` names a single symbol and two events are wanted. It is **installed
  when the buffer appears**, from `agent-shell-mode-hook` plus a sweep of
  `buffer-list`, and not from `agent-river-observe` where
  `agent-river--ensure-subscribed` runs — a session that has folded nothing yet
  has no handler attached, and its first turn is exactly the one worth hearing.
  **The event carries the whole text and the slot an excerpt**
  (`agent-river-said-width`): a dialogue act cannot be read off a first
  sentence, which is where this parts from the `◇` line, and the slot is the
  one value in the state whose length the agent chooses. **Which end it keeps
  is a question of its own** (`agent-river--excerpt`, used for the slot and for
  the `“` line): the first WIDTH characters are the least informative an answer
  has, since it opens by restating the question and the middle narrates the
  tool calls the state has already counted in steps, files and failures. So
  both ends are kept and the middle is the gap, marked — the result is a
  quotation with a hole in it and must not read as something the agent said.
  The closing is taken from the last *line* rather than the last sentence,
  because these messages are written as a summary, a list of what was done and
  then the ask; squished to one line the bullets and the ask are one sentence,
  so a last-sentence rule answers with the whole tail and the ask is dropped
  for being too long. Where nothing whole fits it is **cut into from the
  left** rather than given up — measured against a live HUD, not reasoned
  about: every `“` line the first version drew was a plain prefix cut, because
  an answer ending in one long paragraph had its closing rejected and fell
  back to the head alone, which is the cut the function exists to stop
  arrived at by a longer road. What has no closing to cut into is a message
  with no end distinguishable from its body — one line, no sentence inside it
  — and there the head alone is the honest answer. It is kept only while it is
  worth the room (half the width, and never where the head is left too short
  to state anything), and
  cuts fall on a sentence boundary where one lies late enough to be worth
  taking, on a word boundary otherwise, and hard only for a path, a URL or a
  blob. And the excerpt is
  **stored raw, escaped where it is rendered**, the way an intent is — storing
  it escaped would put a rendering decision in the state and show backslashes
  in a HUD that is deliberately not Markdown. A `say` counts no step and warms
  no artifact table, for `agent-river-reach`'s reason: no tool ran, and a file
  named in a sentence is not a file the agent reached. It is not in
  `agent-river-notable-kinds` — every turn has one, and `>` is for the lines
  that want attention.
- **A run that is not said is dropped, and there are three ways to get one**
  (`agent-river--listen`). The accumulator's own docstring names the hazard:
  chunks left in the table are flushed by a turn that is not theirs, glued onto
  the front of its text with no separator. `clean-up` is the buffer going
  mid-sentence. `error` is the `session/prompt` failing — agent-shell answers
  that through its error handler and never emits `turn-complete`, and the
  comment there says the turn may have stopped mid message chunk. And
  `session-restored` is the one that looks like nothing was wrong: a restore
  replays the stored turns through the ordinary notification path, so
  yesterday's chunks arrive exactly as live ones do, with no prompt response
  behind them and hence no `turn-complete`. An *interrupted* turn is not one of
  the three — cancelling resolves the pending prompt with a stop reason, so it
  arrives as a `turn-complete` and is said, **marked** (`✗`,
  `agent-river--unfinished-p`) the way an interrupted tool call is: only a
  reason that was given and is not `end_turn` marks, because unset is "do not
  know" rather than "interrupted".
- **`said` is in the task frame, and a `say` carries no cwd.** The frame is
  forced by the export, which sits the answer under the prompt because the two
  are one exchange: kept across a `prompt` the old answer is filed under a
  question it never heard, which is the mislabelling the frames exist to stop —
  so it clears with `steps` and `task-artifacts`, and the words themselves stay
  in the log. And no cwd, which puts a `say` with the events made inside Emacs
  rather than with the steps: the fold refreshes the anchor from every event
  that carries one, and carrying the shell buffer's `default-directory` had
  every turn end re-anchor a session the *hooks* had anchored — the two
  spellings need not agree, since `expand-file-name` does not resolve a symlink
  and a host's reported cwd may, so keys relativised against one would then
  resolve against the other. The configuration that loses something by it —
  listen-mode alone, no hooks, no watch — has no artifact keys either, and an
  anchor is only ever for those.
- **The stream path builds payloads, not events** (`agent-river--shell-payload`).
  It goes through `agent-river--event` like everything else, so there is one
  place where a file argument can go uncounted rather than two. A tool call is
  counted on its first sighting and reported on its terminal status;
  `agent-river--tool-calls` is what keeps the updates between them from
  counting again, and what supplies the duration ACP does not carry.

### Adding a side-effect consumer

Anything that reaches outside this package — drawing a listing, shading a
buffer, notifying, writing a file — is an *observer*, not a fold branch.
`agent-river-map` (`agent-river--map-observe`) is the worked example; read it
before writing a second one. There was a second, `agent-river-heat-mode`,
which shaded the dired buffer you were already in by how recently an agent
had been in each entry; it is gone, and the rules below that it paid for are
kept where they still bite.

Register on `agent-river-observers`, an abnormal hook of `(STATE EVENT)` run
for effect after each fold. The runner (`agent-river--run-observers`) already
owns the three things every consumer needs, so don't re-implement them:

- **Its own guard, not the fold's.** An error reported as `fold failed` sends
  the user to `agent-river-reset`, discarding every session's state over one
  overlay.
- **Retire on first error**, like the refresh timer. This path runs on *every*
  tool call, so a broken consumer is broken thousands of times. The runner
  removes it and logs `observer ... retired`.
- **Teardown via the `agent-river-retire` symbol property** when removal alone
  would leave something behind (overlays in foreign buffers, a mode variable
  still claiming to be on).

What a consumer must respect:

- **Return values are ignored.** Signals are the only channel back into the
  agent's context and they are kept narrow and factual on purpose; a side
  effect must not speak through it.
- **Never `setf` STATE — but an observer may still produce state**, via
  `agent-river-note`, which folds it as a `note` event. The rule is about the
  *mechanism*, not the effect: a note is in the event stream, logged, counted
  and attributable, where a direct write is none of those. Note only what a
  hook cannot see and the state cannot derive (a human editing a file under the
  agent); anything recomputable is derived where it is read. A note is a
  measurement, so it may feed a signal — which means an observer noting its own
  opinions closes exactly the loop the `intent*` slots are kept apart to
  prevent. Observers run for a note too, but one level deep: a note made while
  a note is being handled is refused and returns nil.
- **The state cannot address a file on disk** — `agent-river--rel` sees to that,
  and it must keep doing so. Three ways out. Look the file up *from* the
  consumer's side by basename (what `agent-river-touching` used to match on,
  before the views that named files went); read an
  extra event key the fold keeps out of the artifact keys (`:path`, the
  absolute name, carried beside `:file`); or resolve a key against
  `agent-river-state-cwd`, falling back to its `anchors` entry where the cwd
  cannot place it (`agent-river--artifact-absolute`) — the only one that can place
  a key in a directory tree and the only one that re-splits a worktree from its
  main checkout. Reach for the third when the question is *where*, not *which*.
- **Off by default, and the gesture that turns it on is what turns it off.**
  Writing into buffers the user did not point this at needs consent, which is
  what a global minor mode is for. A consumer that draws only into a buffer of
  its own needs no mode: opening that buffer is the consent and killing it is
  the retirement (`agent-river-map`, via a local `kill-buffer-hook` that is
  also the `agent-river-retire` property). What does not change either way is
  that there is exactly one gesture and it is reversible.
- **The timer stops when there is nothing left to draw, and nothing here
  changes on its own.** Fading used to be the exception — a view that went on
  changing while no event arrived, which meant the timer had to ask whether
  anything was still moving as well as whether anything was dirty. With the
  decay gone the only answer is dirt (`agent-river--map-tick`), and the price
  is that the relative times in the rows stand still between turns. What no
  timer here can see is the disk either way: a file that comes back while no
  agent is working redraws on the next event or on `g`.
- **Redraw on a timer, not per event, once the view is bigger than a line.**
  The runner fires on every tool call. Rebuilding a whole listing that often
  moves point under whoever is reading it, thousands of times a task. The
  observer marks dirty and ensures the timer (`agent-river--map-observe`); the
  timer decides how often dirt is worth acting on, and retires itself when
  there is no dirt left. **Which is why anything
  that changes the view without folding an event has to draw**, not mark:
  between turns the timer is not running, so a flag is a redraw that never
  happens. `agent-river--forget-reported` is where that is decided for every
  command that removes a subject — the two artifact ones included, since
  dropping a record folds nothing an observer could hear.
- **Test the derivation, not the rendering.** Frame choice, aggregation and
  thresholds are pure functions of the state; geometry is the host package's
  problem. The contract tests live under `;;; Observers` — point a new
  observer at them.

Two frames again: pick `task` or `session` scope *explicitly* (see
`agent-river-map-scope`) and say which one the view is showing.

### Producers — the other direction

A *consumer* turns state into an outside effect and hangs off
`agent-river-observers`. A *producer* turns something only Emacs can see into
an event, and hangs off whatever Emacs hook or outside source sees it — not
off `agent-river-observers`, which fires on the agent's events, not yours.
Two ways in: `agent-river-note`, for something about a session, and
`agent-river-appeared`, for something that belongs to no session at all.

```
hooks -> fold -> observers -> outside world    consumer (agent-river-map)
outside -> note/appeared -> fold -> observers  producer
```

**Nothing that ships is a note producer any more.**
`agent-river-watch-saves-mode` was the worked example — it noticed you saving
a file an agent was working in, which no hook can see because the agent's
staleness check knows the disk and not your buffers — and it was removed
having never been switched on: off by default, and in the one live Emacs that
could be asked, zero notes in the registry and zero `◉` lines in a HUD that
outlives a reset. A feature nobody has run is not a worked example, it is an
untested claim about what this protocol is for. The artifact path
(`agent-river-appeared`) is the producer that is actually used.

What may be noted is narrower than "anything from outside":

- **Point-in-time facts** — you saved this file at 14:32, during this task.
  Once past, nothing can recompute it. This is what notes are for.
- **Current-state facts** — the buffer has unsaved changes *right now*. Query
  it where it is read (`buffer-modified-p`); a note would go stale the moment
  it is folded.

Three things a producer owes:

- **A relevance filter.** An Emacs hook fires on everything you do, not on
  what matters — `after-save-hook` fires on every save you make, and without a
  filter the log becomes a list of your keystrokes. The filter is a state
  query: has any session actually reached this thing.
- **A provenance guard.** A producer that cannot tell the agent's own writes
  from yours launders the agent's action into an observation about it. Keep it
  narrow — the one that was here suppressed only while a tool call was open on
  that exact file, and widening it before there is evidence of noise would be
  tuning on a guess.
- **Say which frame a count came from.** `artifacts` and `task-artifacts`
  answer different questions, and a number under the wrong heading is the
  failure the frames exist to prevent.

Reading notes back and deciding what to tell the agent is deliberately not
built: `agent-river--signal` fires on fail streaks only. The condition written
here was that the rate should be seen first — notes are visible in the HUD
(`◉`) and counted in the report (`:notes`) — and with the save watcher gone
there is no note producer shipping at all, so that rate is not low, it is
unobserved. Anything built on it would be designed against a guess.

### Approvals — the one thing that travels back

`agent-river-approvals-mode` (off by default) shows what each session is
waiting to be *allowed*, and `a` in the HUD answers it. The HUD could not
see this at all before: the `waiting` phase is `idle`, the end of a turn,
not "is holding a door open for you" — and with five sessions, which of
them is waiting and for what is the question the HUD exists to answer.

- **The offer is read in two halves that share a request id, because
  neither source has both.**
  `agent-shell-permission-responder-function` is handed the tool call, the
  options and a `:respond` function, and is not told whose session it is;
  the `permission-request` event is dispatched in the session's own buffer
  and carries no options. The responder runs first, so
  `agent-river--attend` finds the entry and fills in the session.
- **The slot is chained, never claimed** (`agent-river--responder`). It is
  one variable rather than a hook, and returning non-nil means "handled,
  skip the UI" — so this hands back whatever the function it replaced
  returns, and a responder somebody else installed goes on deciding.
  Turning the mode off puts the old value back *only* if the slot is still
  ours, or the mode would undo a setting made while it was on. Its own
  guard, like an observer's: this runs inside agent-shell's request
  handler, and a HUD that cannot note a question must not be able to stop
  one being asked.
- **A pending approval is a current-state fact, so it is not folded**
  (`agent-river--offers`). It stops being true the moment it is answered —
  including by a button pressed in the session buffer, which nothing here
  would hear — so it lives in a side table the panel queries where it is
  read, the way `buffer-modified-p` is asked rather than noted. What *is*
  point-in-time is that the question was put, and that gets a log line
  (`ask`, `?`). No struct slot, so a reload does not demand a reset.
- **Liveness is agent-shell's answer, not ours** (`agent-river--offer-live-p`).
  It clears `:permission-request-id` from the tool call when it answers and
  documents that consumers may read it that way; our table is the second
  account and the one that can be behind, so the command asks the first
  before it speaks and drops its own entry when the answer is no.
- **Answering is behind its own gesture, and asks which option.** A global
  mode, because installing yourself in another package's decision path is
  not something a view does unasked; and a prompt rather than a key per
  option, because `allow_always` from a typo is the wrong thing for a
  buffer that is otherwise only looked at — the options are also the
  agent's own words, which no fixed key could keep meaning.
- **Its own subscription** (`agent-river--attending`), not
  `agent-river--shell-observe`'s. That one is gated on
  `agent-river--claim`, which decides who *folds* a session so no step is
  counted twice; a session the hooks own would otherwise have its open
  questions go unseen, which is the case with the most sessions in it.

### The approval queue — the same questions, for a screen held in one hand

`agent-river-approval-queue` (`*agent-river-approvals*`) is the second view
of `agent-river--offers`, and the shape is decided by the screen rather than
by the state: a phone, over emacsclient in a terminal emulator, in portrait,
answered with a thumb. The panel says *which* session is waiting; this is
where the door is opened. Read the section comment before changing it — what
follows is what is load-bearing.

- **One question is a block, not a line, and every answer is a row.** A
  narrow screen has lines and no columns. `RET` or a tap on the row answers
  it, which is exactly what `agent-river-answer` refuses to do — and the
  reason does not survive the trip: at a desk a prompt costs one keystroke
  and stops a slip granting `allow_always`, here it costs the screen the
  arguments are being read on. The friction is kept where it still earns its
  place (`agent-river--approval-confirm-p`): the two `_always` kinds ask
  `y-or-n-p`, the ones that decide a single call do not, and spelling out
  "yes" would be a third gesture rather than a second.
- **A row is propertised through its newline** (`agent-river--approval-row`).
  A tap lands past the end of a short row about as often as on it, so a row
  whose properties stop at its last character is a target that has to be hit
  rather than reached for. The heading is wrapped in
  `agent-river--make-visitable` *around* the row for the same reason, which
  is also why the queue does not name `agent-river-session-line-map` itself.
- **Wrapped, never measured.** The width is the window's, so a rotation is a
  resize and nothing here notices. Counting columns would mean redrawing on
  every rotation to arrive at what `word-wrap` does for free — and it is why
  there is no `-width` setting to keep in step with anything.
- **Listing and answering ask opposite questions about the same fact.**
  `agent-river--offer-live-p` answers "still open" and says no where nothing
  can be seen, which is right for a command about to speak on a session's
  behalf (`agent-river--respond`, the one place an answer is sent, shared
  with the HUD's prompt so the two cannot drift).
  `agent-river--offer-answered-p` answers "agent-shell says it is over" and
  says no in that same unseeable case, which is right for a listing: a
  question dropped because its buffer could not be reached is silence exactly
  where this view exists to speak. It uses `assoc`, not `alist-get` — an
  answered call stays in `:tool-calls` with its request id removed, and a
  lookup returning nil cannot tell that from the call being absent.
- **A redraw finds a row by what it names** (`agent-river--approval-here`,
  `--approval-find`). The buffer is rebuilt every couple of seconds; found by
  position, a question answered above would slide a different question's
  `Allow` under a thumb already on its way down. Same rule as
  `agent-river--block-goto` and `agent-river--map-here`, and the reason the
  rows carry `agent-river-approval` and `agent-river-approval-option`.
- **Drawn inline, not marked dirty** (`agent-river--approval-refresh`), which
  is the opposite of the map and for the opposite reason: that observer fires
  on every tool call, this fires when somebody has been asked a question and
  is waiting. The timer is only for what moves with no event of its own — how
  long a question has waited, and what the session has done since — and
  retires after one last draw once nothing can change
  (`agent-river--approval-changing-p`), or the question just answered would
  sit on screen until somebody pressed `g`.
- **Opening it takes the mode and gives it back only while it is still ours**
  (`agent-river--approval-owns-mode`). There is nothing to queue without
  `agent-river-approvals-mode` — the options and `:respond` are only ever
  seen by the responder it installs — so opening the buffer is the gesture,
  the way opening the map is. Killing it turns the mode back off unless it
  was already on, which is `agent-river--responder-before`'s rule one level
  up.
- **The context line is the only place a file is still named.** It was the
  panel's reading one field shorter — through `agent-river--artifact-list`
  rather than `agent-river--hottest` so the two could not disagree about
  which file it was, with the `(N touches)` parenthetical dropped as the
  longest thing on the line and the least of what a decision turns on. The
  panel's reading is gone and this one is not, because the question differs:
  the block says what a session is *doing* and this says what it is about to
  be allowed to do it *to*, which is most of what an allow-or-deny turns on.
  It is the last caller of `agent-river--artifact-list`, and the summing rule
  in that function\'s docstring is the one `agent-river-touching` left behind.
- `agent-river--scan` **grew a SETTLE argument rather than a third copy of
  the loop.** What differs between these buffers is only where the text on a
  line starts.

### The block is flat, and a session line is a top-level line

Session lines sit at level 1, one per live session, ordered by label. There
was a grouping here once — a heading per *place*, asked for through
`agent-river-panel-place-functions` and defaulting to the session cwd, with
everything under it pushed a level down — and it is gone, so
`agent-river--star` takes no level and `agent-river-block` holds a plain
session id rather than a tagged key. It held a cons of the id and an index
for as long as a session had detail headings under it, and those went with
the file touches they listed: the block is now one line per session and
nothing else, which is what "flat" had only half meant. What
the removal took with it is the one thing the label cannot say: two sessions
in two checkouts of one project read alike. That is a real loss and the
answer, if it is wanted back, is not the heading again but something on the
line itself, since a heading cost a line per group and pushed the whole block
down a level to state a fact about *where* rather than about the work.

**`agent-river--panel-states` answers "which sessions, in what order" once.**
The block and `agent-river-markdown` both read it, which is what keeps the
export's claim to be a snapshot of the block true: two orderings would be two
accounts of one question, right only for as long as somebody kept them in
step. Ordered by label rather than by whichever session acted last, so a line
does not move under the eye because another agent took a step.

### Linking a session to an artifact by hand

`agent-river-link-artifact` is the user as the producer: it declares an
artifact if the key is new and reaches it from a session, which is the pair of
calls the README tells an integrator to make in that order. It is the first
shipping caller of either, and it exists because `agent-river-reach` had none
-- the edge between a session and an artifact can only be reported by whoever
performed the dispatch, and nothing in this package performs one. A user does.

- **The agent-shell buffer is the one place "which session am I" is exact.**
  `agent-river--shell-session` reads the id the hooks use straight off
  `agent-shell--state`, so typed there the command asks nothing. Typed
  anywhere else it *prompts*, and pointedly does not fall back to
  `agent-river--current` the way `agent-river-reach` does when handed no id:
  that default is whichever session acted most recently, and a wrong edge in
  the artifact tables reads exactly like a right one. The session prompt
  carries the id beside the label, because a label need not be unique --
  agent-shell uniquifies the ones it hosts and nothing uniquifies the rest.
- **The completion candidates are keys, and the name is an annotation**
  (`agent-river--read-artifact-key`). The key is the identity
  `agent-river-reaching` matches on, so a `KEY -- NAME` display string would
  have to be parsed back into one, and that parse is a second account of what
  the user picked. It is also why the user types the *key* rather than a name
  the command mints one from: a minted key will not match what a webhook
  producer later declares for the same subject, and then the table holds two
  records for one thing.
- **The domain is asked every time, never defaulted**
  (`agent-river--read-domain`). There is no default right often enough to be
  worth the one time it is not, and the one time it is not is the failure the
  invariant above describes. `file` is refused for every caller and not only
  at the prompt, because the table is not a mirror. The candidates come from
  `agent-river-domains` -- what the table has. There was a presentational
  list beside it once, `agent-river-map-domains`, and reading *that* would
  have let a view's settings decide what a producer may declare: it would
  have offered domains nothing ever arrived under while the ones that did
  went unlisted.
- **Everything is checked before anything is folded.** Declaring and then
  failing to reach leaves a record nobody asked for, which only
  `agent-river-drop-artifact` takes back -- so the session is looked up while
  there is still nothing to take back. A test pins it.

### Actions — what RET may do to the thing a line names

`agent-river-artifact-action-functions` is the third extension protocol
beside consumers and producers, and the only one that answers a question
rather than carrying state either way: a line of the map is *asked* what can
be done to the thing it names, by every function in the list, and the answers
are collected (`agent-river--artifact-actions`) and either run or offered
(`agent-river--artifact-act`). Each is handed the subject and returns
`(:name STRING :act THUNK)` entries, or nil.

- **It replaced a `:visit` per domain, and the reason is that "what may be
  done to this" is not a property of the domain.** An issue on the map is a
  thing to read *and* a thing to start an agent on; a single thunk had to be
  one or the other, and which is wanted is the question the person at the
  line is asking. So the domain table is `:label` and nothing else — one
  mechanism answers this and a `:visit` beside it would be a second.
- **Opening a file is an action like any other** (`agent-river--actions-file`,
  the default entry). It was a branch of `agent-river-map-visit` and leaving
  it there would be exactly the second mechanism this collapses: a file line
  answering the question somewhere else. Nothing about it reads differently
  to a user, which is the point of the next bullet.
- **One offer is run without asking.** A menu with one entry is a question
  with no alternative, so RET on a plain file still opens it with one
  keystroke. The friction a sharp action needs is the action's own, and
  **whether it is still worth asking for is what `agent-river-artifact-chosen`
  answers**: bound around the thunk when the user picked it by name out of
  several, nil when the line's one offer was run outright. A menu entry
  reading `Launch: Review` has already named what will happen, so
  `agent-river-launch--confirm-p` takes it as the deliberate act and does not
  put a second question to an answer just given — which is
  `agent-river--approval-confirm-p`'s rule one subject over: keep the friction
  where it earns its place, not where the mechanism happens to pass. Where it
  still earns it is the case the flag exists to keep apart: a line whose only
  action is a launch runs it outright, so there the confirmation is the only
  thing between a keystroke and a running agent. Hence a *choice was made*
  rather than *how this was called* — a brief name handed to
  `agent-river-launch-artifact` proves nothing, since the same argument
  arrives from a line that offered no alternative.
- **Nil is the whole of the applicability rule.** There is no predicate to
  register and no domain to be listed under, which is the rule the domain
  sections already live by: something that has arrived is offered whatever
  these have for it without waiting to be configured. Asking twice — a
  predicate and then the thing itself — would be a second account of one
  answer, which is why `agent-river-launch--offers` returns the brief it
  already computed rather than a yes.
- **Guarded per function, reported and skipped, never retired.** This runs on
  a keystroke rather than on every tool call, so there is no runaway to stop
  — an observer's third rule does not apply and the other two do. What the
  guard is for is the other half: one thrower must not take the offers beside
  it down with it, which leaves a line that does nothing and no account of
  why.
- **The subject carries `:path` beside the key, never inside it**
  (`agent-river--map-subject`). An artifact record where the table has one,
  and where it has none the line names a file — `file` is what a key is when
  nobody said otherwise. What an action needs of a file is the absolute name,
  and it travels as a separate key for `agent-river--artifact-absolute`'s
  reason: a key cannot say where it is, and a non-file key resolved against a
  directory becomes a file in a tree it has nothing to do with. Here the
  absolute name is what the map already had, so there is nothing to resolve,
  and it is set only where the name genuinely is absolute — which is never
  true of a domain key.
- **Order is the list's own, and deliberately not a `:rank`.** A contributed
  row has one because which contributor was registered first says nothing
  about which row is worth reading, and every row is on screen at once. A
  menu is a `completing-read`, where order decides what is read first and not
  what is worth reading. What the two shipped registrations append is
  therefore in load order, and reordering is a `setq`.
- **Two things register themselves and both are appended**: the GitHub
  source's `browse-url` (`agent-river-gh--actions`) and one launch per brief
  (`agent-river-launch--actions`). The GitHub one is **gated on the domain,
  not on a `url` cell being present** — any producer may call a cell `url`,
  and offering to open somebody's incident tracker "on GitHub" would be that
  file answering for a record it has never seen. It ships there rather than
  in a user's config because that is the file that put the cell in the
  context: the core never reads a value out of one, so what a cell means is
  known only beside the reader that wrote it.

### The third direction — `agent-river-spool.el`, `agent-river-launch.el`

Consumers carry state outward, producers add events about a session that
already exists. These two are where something from *outside* becomes a
subject here, and where an agent can afterwards be pointed at one: a file
in the spool becomes an **artifact**, and an artifact becomes a **session**
when a person asks for one. Both are optional, opt-in, and do not touch
`agent-river.el`.

**Two files, because they touch at nothing.** They were one while an agent
finishing was the occasion for the next launch: the text telling an agent
how to hand back had to carry the spool's own path, so the out-half read
the in-half and the two were a cycle. That text is gone — what it existed
to keep alive was the chain, and a person is the link now, so its purpose
left with the machinery it was built for. It was also a second account of
something the stream already carries: `say` folds the end of every turn,
excerpts it in the HUD and puts it in the export, and asking the agent to
write a file as well is the same fact from a less reliable source. Measured
before removing it, the spool had existed for five days and had never held
a single file. With it gone, `agent-river-spool--dir` had one caller and
now has none, and the two halves share nothing at all.

**There are no rules here, no gates, no budget and no queue, and the
deletion is the design.** There was all of that once (`db0aa5c`): a
candidate with an occasion-shaped key, a durable ledger in `queued/` and
`done/`, matches and gates and a chain cap and a decision log and
`*agent-river-queue*`. Nearly every part of it was the price of deciding
**unattended**, and with a person pressing the key each one either
disappears or turns out to be something the artifact table already does —
`agent-river-appeared` answers nil for a key it has, the map's domain
section is the queue and already lists what nobody has picked up, and
`agent-river-ended` is what `done/` was for. What pays for all of it is one
sentence: **a repeat is a line, not an agent.** What would have to come back
to launch unattended, and what each piece prevents, is issue #37 — written
before the deletion, so that deferring is not the same as forgetting.

- **The spool is the only door**, and what makes it worth keeping when the
  ledger goes is that it needs no Emacs running: a cron poller, a webhook
  and an agent handing off by writing a file are one mechanism. Two
  directories now, `<spool>/` and `<spool>/failed/`, and a delivery that is
  taken in is **deleted** — the artifact table is the record, and a copy on
  disk beside it could only disagree with it.
- **A reader returns a spec; one place declares.** A source adapter
  (`agent-river-spool-sources`) is the only thing that knows a dialect,
  exactly as `agent-river--event` is for the hosts, and it hands back the
  arguments an artifact is declared with rather than declaring one — so a
  reader is a pure translation that tests without a table, a spool or a
  timer, and there is one place a thing enters the table. A reader that
  throws costs its own file: it goes to `failed/`, which nothing re-reads,
  so unlike an observer there is no runaway to retire.
- **A half-written file is not a broken one** (`agent-river-spool-settle`).
  The contract is write-then-rename and a poller can be held to it; a writer
  that is not a program cannot be — an agent told to report something
  reaches for `Write`, so its JSON is briefly half there. Filing that under
  `failed/` would throw the delivery away over a contract nobody told the
  writer about, and throw it away *quietly*. A file too young is left for
  the next scan. It covers "parses but has no key" too, because a truncated
  write can land as valid JSON with the key not in it yet.
- **An ending is folded; a first sighting that is already over is not
  declared** (`agent-river-spool--declare`). One call used to answer both
  questions, and they are different ones: a source that polls a world it did
  not watch re-sees everything that changed, so the first wide poll declared
  a record for every thing that had ended since the window opened, purely in
  order to strike it through. An artifact record does not fade the way a
  reached name does — it stays until `agent-river-drop-artifact` — so the
  domain section, the queue of what nobody has picked up, opened with more
  dead lines than live ones. Measured on one repository: ten deliveries,
  seven over before anything here had heard of the thing, and three records
  after. Which of the two it is, is a question the **table** answers, the way
  `agent-river-observe-artifact` answers it for a producer that would
  otherwise keep a list of its own — through `agent-river-artifact-at`, not
  `agent-river-artifact`, which creates the record it is asked about. It sits
  here rather than in the reader, which is a pure translation and cannot know
  what the table has, and rather than in `agent-river-appeared`, whose return
  value already means first-sight-versus-repeat and would then mean two
  things. **No log line**, which is the rule applied rather than a gap in it:
  the spool logs failures and this is not one, and `artifact` is a notable
  kind — `>` stops on it — where a thing that was over before anybody heard
  of it is the definition of a line that does not want attention.
- **A declaration that throws is treated like a file that would not parse.**
  Left in the inbox it would be retried every minute for the life of the
  Emacs, which is the one outcome worse than losing it.
- **Filing a failure must not be able to fail**
  (`agent-river-spool--fail`), and the reason is where it is called from:
  both call sites are inside a `condition-case` *handler*, and an error
  raised in a handler is not caught by its own `condition-case`. So a
  `rename-file` into `failed/` that signalled escaped the scan and left the
  file in the inbox — which `--inbox` sorts oldest-first, so every later
  scan read the same file and died in the same place. One delivery nobody
  could file stopped every delivery behind it, permanently, while the safety
  net logged one identical line a minute. Measured with `failed/` at mode
  500. Two ordinary ways in: a `failed/` that is not writable, and the file
  going away between the listing and the rename. Where it cannot be filed it
  is **deleted** — `failed/` exists so a source's author can see what their
  program wrote, and that is worth less than the door; the reason was in the
  log a line earlier either way. The scan loop guards per file besides, for
  whatever a delivery throws that nobody anticipated.
- **The safety net does not go through the debounce**
  (`agent-river-spool--scan-safely`). `agent-river-spool-poll-interval` is
  the one guarantee the spool offers — a delivery is never silently unseen —
  and pointing it at `--scan-soon` made it conditional on something it never
  mentions, since that schedules an *idle* timer and an Emacs that never
  idles for a third of a second would never scan. The debounce is for the
  watch's bursts; the safety net has no burst to coalesce.
- **`:session` is the one spec field that is not about the artifact**
  (`agent-river-spool--note-session`). A producer that knows which session
  caused the thing it is delivering says so, and that is noted on *that
  session* — the producer direction, and the only note producer that ships.
  What is noted is the fact, never a claim: a note may feed a signal, so
  folding in an agent's own words would launder a claim into an observation
  about it.
- **A key names the object.** A pull source re-sees the same issue every
  tick, so `issue:owner/repo#42` and a second sighting is the same line.
  There was an occasion-shaped key here once, pairing the object with the
  moment it moved, and it was for the launcher that would otherwise never
  act twice on one issue — it went with the launcher. Getting it back is
  part of #37, and the open question there is where an occasion lives once
  the subject is the object.
- **There is no `:cwd` on a spec.** Where an agent would be started is not a
  property of the thing it would work on, and this package never reads a
  value out of a context — so a source that knows a working tree puts it in
  the context and a brief, which is the user's own code, reads it back out.
- **Two switches, and the sharp one is the brief.**
  `agent-river-launch-launcher` says whether anything can launch at all;
  a brief returns what to say about a given artifact, or nil, which is the
  arming switch — a launcher with no brief can never launch.
- **A brief is not one thing, so there is a list of them**
  (`agent-river-launch-briefs`, `agent-river-launch--offers`). It was one
  function dispatching on `:domain` inside itself, and what that cannot
  express is the ordinary case: the same pull request is a thing to review
  and a thing to rebase, and those are different prompts under quite
  possibly different models. Which is wanted is a question for the person at
  the line, not something a domain answers once. So every brief with
  something to say about a record is one offer, and **nil is the whole of
  the applicability rule** — the answer the brief already gives, read once
  rather than restated as a predicate beside it, which would be the second
  account this package spends its exceptions avoiding. A brief with no
  `:prompt` is one of those and not an offer that fails when it is taken:
  what a launch *is*, is a prompt reaching an agent. Guarded per entry, so a
  thrower costs its own offer and not the ones beside it, and the log line
  names it — with several of them, which one threw is the half of the report
  worth having.
- **The model is the brief's to name** (`:config`,
  `agent-river-launch--shell-config`). A prompt is worth little without the
  configuration it is said under, and `agent-river-launch-shell-config` is
  one thunk for the whole package — so a brief may return a `:config` of the
  same shape, which that thunk is the default for. **A function on both
  sides rather than a built config**, and the reason is where the offers are
  computed: building one reaches for authentication (see
  `--shell-available-p`), and the briefs are read on every RET to work out
  what a line offers. Only the one that is launched is built. Launcher-
  specific keys on a brief are that launcher's to read; `:prompt` and `:cwd`
  are everybody's.
- **Quoting producer text is a launch concern, not a GitHub one**
  (`agent-river-launch-quote`, moved here from `agent-river-gh.el`). A brief
  that embeds an artifact's own text — a body, a title, a branch a fork
  spelled however it liked — answers the identical question whatever wrote
  that text: is this quoted material or is it read as the operator's own
  instruction. `agent-river-gh-brief` was the only brief when this was
  written and kept its own copy, but the file's own commentary expects a
  tracker, a mailbox or a build to follow it, and each would face the same
  question — which is what the merge rule in the Conventions section is for:
  sameness of the *question answered* licenses sharing a mechanism, and this
  is the identical question with different producer text each time. The
  stakes are sharper than the ordinary case for that rule: the copy that
  drifts here is not a rendering that looks different, it is an injection
  defence quietly not applied to the next source's text. It stayed a GitHub
  function until a second brief needed it, which is the point in
  "merge only where there is something to merge" at which there is.
- **A launched shell always starts a new session**
  (`:session-strategy 'new` in `agent-river-launch--shell-launch`).
  agent-shell's own default is `prompt`, which puts a modal question about
  resuming between the choice and the agent — the failure
  `agent-river-launch--confirm-p` answers one gesture up, arriving from
  underneath. But it is the layer's premise rather than a tidiness: a launch
  here is a session that *did not exist*, which is what
  `--resolve-pending` waits for and links to the artifact. A resumed session
  existed before the launch and is quite possibly in the registry already, so
  the "named and heard from" wait would settle instantly onto something nobody
  started for this thing, and the brief would land in a conversation about
  another one. Deliberately not a setting: the alternative is not a preference
  somebody might hold, it is this layer not working.
- **Unavailable is absent** (`agent-river-launch--launcher`,
  `--available-p`). Asked at selection, so "this cannot run here" is the
  first thing said rather than the last: asked at the launch, the user was
  prompted to confirm something that then failed. Read every time, because a
  package loaded after Emacs started makes its launcher available without
  anything here being told.
- **Launching asks first** (`agent-river-launch-artifact`). Starting a
  process is the most expensive thing this package does and the one gesture
  with nothing on the far side that can take it back. What the question
  names is what will run, **the brief included** now that there may be
  several. It takes an optional brief name, which is how the map reaches a
  particular one: the line was already the menu, so asking again would put
  the question behind the answer — and `agent-river-launch--confirm-p` is
  where that is decided, off `agent-river-artifact-chosen` rather than off
  the argument, for the reason the actions section gives.
- **The map offers one launch per brief, not one `Launch` that then asks**
  (`agent-river-launch--actions`, registered on
  `agent-river-artifact-action-functions`). What a reader is choosing
  between is what the agent will be told, so that is what the menu says;
  folded into one entry it would take two prompts to reach, the second
  asking what the first presented as answered. This is the whole of
  "launching happens from the map" — no new keymap and no change to
  `agent-river.el`. Nothing is offered where the launcher cannot run here
  (unavailable is absent, asked at selection) or where the subject has no
  `:key`: a file line names something the map placed on disk, not a record,
  and there is nothing a brief was written about. **The registering form
  needs an autoload cookie on the function too**, for
  `agent-river-gh--read`'s reason one file over — extracted into the
  autoloads file it runs before anything here is defined, and a symbol with
  an empty function cell is caught by the guard, reported and skipped, which
  leaves every launch quietly unofferable.
- **The edge lands by itself, and that is the point of doing it here**
  (`agent-river-launch--resolve-pending`). Whoever starts an agent on an
  artifact is the one caller holding both ends of the relationship, so the
  reach is recorded without an ordering for anybody to get wrong — the
  thing the old layer never did and `agent-river-link-artifact` closes one
  subject over. It is late because the session id does not exist when the
  process starts, which is the `:launch`/`:resolve` split: agent-shell
  announces its id after the handshake, a headless CLI can be told one
  before it starts.
- **Named is not the same as heard from.** The reach waits for the session
  to be in the registry as well as to have an id: agent-shell sets the id at
  the handshake and the hooks fold that session's first event afterwards,
  and `agent-river-reach` refuses to attach an edge to a state that is not
  there — rightly, since for its other caller that means a person named the
  wrong session. Waiting is the answer and the window is what bounds it.
- **Nothing is asked forever** (`agent-river-launch--resolve-window`). A
  record that resolves has done its one job and goes, which is also what
  stops the list becoming a log of every launch this Emacs made; one that
  has not resolved inside the window is given up on **out loud**, because a
  launcher that starts something which never becomes a session is the
  failure this layer is least able to see. The window exists because
  `:resolve` returning nil means "not yet" and "never" in one answer. A
  launcher with no `:resolve` is settled at once rather than given up on.
- **Every callback a user supplies is guarded** — `:available-p`, `:launch`,
  and the brief. A brief that throws is no brief: this is user code called
  from a command, and an error there would read as the command being broken.
  **And so is the one call that is not a callback**: `agent-river-reach` in
  `--resolve-pending` is the only thing in either file with no user in front
  of it, and it runs on a *repeating* timer. A throw there skipped the
  `setq` that drops the record, so the record stayed, the timer was never
  retired, and a repeating timer is re-armed before its function runs — the
  same error every second for the life of the Emacs. A reach that fails is
  reported and its record dropped: a launch that cannot be linked is still a
  launch that happened.
- **Producer text goes through `agent-river--log-text`, on every path.**
  `agent-river-log` sanitises nothing of its own, and a key, a buffer name
  or an `error-message-string` can carry a newline — which makes one log
  entry and a remainder carrying none of the properties `n` and `>` read.
  Six sites drifted apart from this while the files were being split, two
  definitions away from one that had it right.
- **The watermark is still incremental, and one poll a session is not**
  (`AGENT_RIVER_GH_RESCAN`). `agent-river-gh.sh` stamps a watermark so an
  issue is delivered once, and what receives a delivery is now a table that
  does not survive a restart — so incremental polling alone leaves a
  restarted Emacs looking at an empty map until somebody touches an issue on
  GitHub. The first poll after the mode is switched on asks wide; every one
  after it is incremental again. `C-u M-x agent-river-gh-poll` is the same
  thing by hand, for after `agent-river-artifacts-reset`.
- **The watermark moves only after a query that was answered and was not cut
  short.** A pipeline exits with the status of its right-hand side and a
  `while` whose body never ran exits 0, so a failed `gh` read exactly like a
  quiet hour and stamped the mark over every issue the outage hid. It is the
  one step in that script that does not degrade to a no-op — everything else
  loses nothing, this loses issues permanently, because the next run asks
  about a window that has passed. **One mark per repository, not per kind**
  now that there are two: what it records is the moment before which this
  repository has been asked about *completely*, so every query shares the
  one `since` and a kind that failed or came back at the limit holds the
  mark for all of them. Loose in one direction only — the kinds that did
  answer are asked again next run, which costs their deleted files.
  **Asking nothing is not the same as asking and being answered**
  (`asked`): `complete` starts at 1 and an unknown kind is skipped without
  clearing it, so a run whose every kind was a typo asked GitHub nothing and
  then stamped the mark at the moment of the run — after which the next
  correctly configured run asks about a window that has passed, and
  everything before it is missed permanently. The per-kind reasoning (no
  window is being missed, because nothing will ever ask about one) is sound
  and does not cover every kind at once, which is precisely what a typo in a
  crontab is.
- **The one thing the script says out loud is a kind that did not come back
  whole**, one line on stdout, logged by `agent-river-gh--reporter`. Three
  ways to get one and they are the three that hold the mark, which is what
  makes the set exactly right: the query **failed**; it came back at the
  **limit**, so the window was not seen to its end; or the answer could not
  be **written**. The last was the `asked` failure in a different branch —
  neither the `mktemp` nor the write cleared `complete`, so a spool at mode
  500, or a full filesystem, delivered nothing, exited 0, said nothing and
  stamped the mark over every object in the window. AGENTS.md records the
  same incident one directory over, with `failed/` at mode 500. The
  truncation half was silent until `--state all` made it likely: the close
  rate multiplies the objects in a window, and a held mark grows the window,
  which returns more objects, which makes the next truncation likelier — a
  short runway into a permanent stall, where the operator's levers are
  `AGENT_RIVER_GH_LIMIT` and a narrower `agent-river-gh-kinds`. The write
  report is **per kind, not per object**, because a spool that cannot be
  written cannot be written fifty times and fifty lines would bury the one
  that matters. It is the exception
  to the no-op rule and the reason is that two kinds hide what one could
  not: a kind failing *persistently* — an old `gh` rejecting a field, a
  token short a scope, pull requests disabled — holds the mark for ever
  while the other kind goes on delivering, so the window grows without bound
  and the poll looks healthy from Emacs. With one query a failure meant no
  deliveries at all, which is at least visible. The filter is line-buffered
  because a filter is handed whatever arrived rather than whatever was
  written.
- **The poll asks `--state all`, and that is what makes the queue a queue.**
  Asked for the open ones alone, a thing that merges simply stops being
  delivered: `:gone` is never set and the record sits in the domain section
  — the queue of what nobody has picked up — until somebody runs
  `agent-river-drop-artifact` by hand. Pull requests close far faster than
  issues, which is what made it worth fixing rather than a second thing to
  live with. It costs no extra request, where a second query for what has
  closed would, and what arrives is bounded by the window either way: it is
  what *ended* since the last poll, not every closed thing there is.
- **`agent-river-gh-search` narrows a kind's own query by that kind's own
  qualifier** (`agent-river-gh--search-env`, `AGENT_RIVER_GH_SEARCH_ISSUE`,
  `_PR`). It was one string shared across every configured kind at first,
  on the reasoning that a second setting would answer a question
  `agent-river-gh-kinds` already does — which conflates two different
  questions: `agent-river-gh-kinds` decides *whether* a kind is asked about
  at all, this decides *which objects within it* are worth asking about,
  and a shared string cannot answer the second question without smuggling
  an answer to the first in with it. `review-requested:@me` and
  `draft:false` are pull-request concepts, and handing either to `gh issue
  list` does not error — it answers with nothing, every poll, silently,
  which is the "quiet week" `agent-river-gh-kinds`'s own docstring already
  worries about, reached this time by a configuration nobody mistyped
  rather than one that was. **Per kind costs nothing extra either** — the
  "shares `since` rather than a second query" reasoning that justified
  sharing was only ever an argument against a *third*, qualifier-only
  query: each kind already runs its own `gh $kind list`, so its own
  qualifier goes into the search string that call already builds, not a
  further request. Bound into the poller's environment the way
  `AGENT_RIVER_GH_KINDS` is, and **absent rather than empty per kind when
  unset** — the script tells the two apart with
  `${AGENT_RIVER_GH_SEARCH_PR:-}`, and a customisation nobody made for a
  kind must reach it as nobody having made one for it, not as an empty
  qualifier that happens to search for everything the same way; three ways
  to say nothing (absent from the alist, present with nil, present with
  `""`) all answer alike. Narrowing `pr` to `review-requested:@me` costs
  something the unfiltered default never has to pay: the previous bullet's
  `:gone` depends on an object still matching the query one more time with
  a closed or merged state, and a review request is commonly withdrawn the
  moment you submit a review — which drops the object out of the search
  without its state ever changing in a delivery this poller sees. A record
  you have already reviewed then sits on the map exactly as if nobody had,
  because from here the two read alike. `agent-river-forget-artifacts` is
  the existing answer for a record that has stopped being news; this
  setting asks for it more than the unfiltered default ever needed to.
- **An issue and a pull request are one dialect and two source names**
  (`agent-river-gh--domains`, `AGENT_RIVER_GH_KINDS`). The script names
  which query an answer came out of — `gh` or `gh-pr` — and nests it under
  a uniform `object`; the reader is *told* the kind rather than working it
  out from which key happened to be present, which would be inferring a
  domain from a spelling, the thing `agent-river--key-domain` refuses one
  subject over. One reader, because everything else is shared: both are a
  number, a title, a body somebody else wrote and a state that can be over,
  and the domain symbol is also the key's prefix, from one `format`, so the
  two cannot come apart. `:gone` needed nothing — `merged` had been written
  into it before there was anything that could be merged. Three things it
  owes. **The PR-only context cells are asked for, never branched on**
  (`branch`, `base`, `review`, `draft`, `fork`): the chain already asks that
  way for a `body` an issue may not have, and a domain test there would be a
  second place the kind is decided. **The registering form spells the two
  names out** rather than reading the table, because it is extracted into
  the autoloads file and runs before the table exists — a test is what holds
  the two lists together, since adrift, a delivered kind reads as malformed
  and goes to `failed/`, which nothing re-reads. And **Emacs rejects an
  unknown kind before the poller sees it** (`agent-river-gh--kinds`): the
  script spells its default with `:-`, which fires on an empty value as
  readily as on an unset one, so handing it a list that came to nothing
  would ask for both — the drift `agent-river-gh-kinds` exists to shut,
  arrived at from the inside.
- **A source registered by an autoload needs an autoload of its own**
  (`agent-river-gh--read`). The `with-eval-after-load` form puts the reader
  into the alist at startup; without a cookie on the reader, the entry is a
  symbol with an empty function cell, and since the reader runs inside
  `agent-river-spool--take-in`'s guard every `gh` delivery is then read as
  malformed and filed under `failed/`, which nothing re-reads. The same
  silence is why the poller is handed `AGENT_RIVER_SPOOL` — bound into
  `process-environment`, since `make-process` has no `:environment` argument
  and ignores one without complaining. **Everything in `--poll-1` is inside
  the guard, the bindings included** — they were above it, and this runs on
  a repeating timer, so a non-string in `agent-river-gh-repos` threw out of
  `agent-river-gh-poll` before the guard could catch it: the
  `--resolve-pending` shape at a five-minute period. The handler drops what
  it recorded pushing rather than what it was passed, because it must not
  assume the binding that threw ever completed.
- **Four places know the kinds, and all four are pinned.**
  `agent-river-gh--domains` is the table; the registering form spells the
  source names out because it runs before the table exists; and the
  script's two `case` arms are read by a test rather than run, since asking
  one question is not worth becoming the first test in this suite that
  shells out. Unpinned, the script's arms fall through to `return 1` for a
  kind Emacs happily asks for — nothing delivered, nothing logged, an empty
  section that reads as a quiet week.
- **The prompt is still quoted, and the reason has changed** (`agent-river-gh-brief`).
  An issue is text written by whoever can open one and it reaches an agent
  holding tools. With a person in the loop the person is the defence, so the
  quoting is a courtesy rather than the whole of it — and it is kept anyway,
  because it is what has to be right on the day #37 is built.
- **The quoting itself is `agent-river-launch-quote` now, not this file's.**
  It is where the pull request paid for the lesson that still governs it: the
  body was split on newlines from the start, and the branch name added
  beside it was `format`ed into a single line instead, so a name carrying a
  newline closed the quotation and everything after it read as the
  operator's own words. Moved to the launch layer for the reason given
  there — the question it answers has nothing to do with GitHub, and every
  future source asks it too. What is left here is what genuinely is GitHub's:
  a branch name is a stranger's text exactly as a body is, a fork spells one
  however it likes, and both are handed to the shared quoting call rather
  than interpolated by hand. What stays outside the quotation entirely is
  ours and interpolates nothing — the framing, the export, and the note that
  a pull request is a draft, which is a sentence read off a boolean.
- **Two framings, dispatched on the domain** (`agent-river-gh--framing`),
  which is the two lines inside one brief that `agent-river-launch-briefs`
  asks for rather than a brief per domain. They are written side by side
  because what has to stay parallel is the part that is not about the work:
  both introduce the same quotation and both say it is not an instruction.
  Only the ask differs — an issue is a request to weigh, a pull request is a
  change to read — and anything else falls back to the issue's, the more
  careful of the two.

### One set of motions, every buffer

The block, the log, the map and the approval queue take the same keys for the
same three grains, because they are views of one state and learning each
separately buys nothing: `n`/`p` (plus `SPC`/`DEL` and the remapped arrows)
walk every line worth stopping on, `M-n`/`M-p` walk the coarse structure,
`>`/`<` walk the lines that want attention. A session line is a map entry is a
question heading; a map row is an answer row; a log line has no analogue
and rides the fine grain. The block has **only** the fine grain now: a
session line had detail headings under it — a `files` line — and both went
when the block stopped naming files, so `M-n` there would land where `n`
does. The map's *section* headings have no analogue in it either, since it
is flat. `>` is `agent-river-notable-kinds` in the log —
which includes `artifact`, because a record arriving is one step further out
than a note (nobody in the session saw it) and it lands when nothing else is
happening, which is when a log is worth scanning at all — "some
agent is under this" on the map, and in the queue it coincides with `M-n` —
bound all the same, because a reader arriving from either of the others
presses it expecting the next thing that wants them, and getting it is the
whole point of the keys being shared.

**A view takes only the grains its own content answers**, which the split
made plain rather than changed, and which has since taken a key off the
block. The block has the fine grain alone — one line per live session — and
no landmarks, because nothing in it is a log line and `>` would have stopped
on nothing; the log is the other way round, since it has lines and landmarks
among them and no structure over them. Both were bound in the one buffer they
used to share and each was dead in half of it. The block kept a coarse grain
for as long as a session line had detail headings under it, and `M-n` went
when they did — it would now stop on exactly the lines `n` stops on, which is
the same fault in a quieter form. A key bound where its content is not is
worse than an unbound one: pressing it answers with an error about there
being no further anything, which reads as the state being empty rather than
as the question being the wrong one to ask here.

Three rules, shared by `agent-river--scan` and `agent-river--map-scan`:

- **Which lines a motion may stop on is a text property, never a regexp over
  the rendered text.** `agent-river-line` and `agent-river-kind` are marked
  where the line is built. The rendering is customisable, so a regexp would
  let a user's setting change what `n` does.
- **Marked for motion is not the same as actionable.** Session lines carry
  `agent-river-line` whether or not `agent-river--make-visitable` found an
  agent-shell buffer — tying the two together made `n` skip exactly the
  sessions RET cannot open, which is the case where looking is all there is.
- **A motion with nowhere to go refuses and leaves point alone**, rather than
  landing near. The next RET would otherwise act on something the eye never
  chose.

`agent-river--scan` deliberately starts *past* the current line — right for a
command, and the reason `agent-river-test--marked-lines` has to test the
current line before it starts scanning.

**Each half keeps a reader's place its own way, and that is what the split
left standing.** Both answers were arrived at while the two shared a buffer and
both were about only one of them; apart, each is stated where it belongs and
neither has to be true of the other.

**The log follows only the windows still at its tail** (`agent-river--tail-start`,
`agent-river--following-windows`, read *before* the edit because the edit moves
the tail). It used to pin every window to the newest line on every event, which
makes the buffer unreadable by hand and would have made these motions
pointless. Two halves to it: window points are filtered, and `agent-river-log`
wraps its edit in `agent-river--keeping-place` — in the selected window buffer
point *is* window point, so without it the one window most likely to be the one
being read was carried along by every tool call regardless. The tail is **the
last line alone**: it was the *first* line once, with the block underneath it
in the same buffer, and the block is where the motions did most of their
walking, so navigating anywhere in it left a reader still counting as
following. That is exactly the span `agent-river--follow` pins to, so it means
"nobody has moved this", and a reader who walks back down onto the newest entry
rejoins the tail the way they left it. Both edits are now at the ends — the
insertion at `point-max`, the trim at `point-min` — so every reader's marker
rides the text, and the one case `save-excursion` cannot cover is a reader
sitting *at* `point-max`: that is nobody's place but the tail's, and they
follow it onto the new line rather than being left one line above it.

**A block line is kept by name rather than by position**
(`agent-river--keeping-block-place`). A buffer point in the block is inside the
region the rebuild deletes, so `save-excursion`'s marker collapsed to
`point-min` and the new block went in front of it — silently, on every refresh
tick, which is the block redrawing itself out from under whoever was reading
it. So block lines carry `agent-river-block` (the session id, plus an index
for a detail line) and `agent-river--block-goto` finds the line again by what
it names, the way `agent-river--map-here` does one grain up; a session that has
gone from the block sends point to the head rather than to whatever that line
number now holds. No following here, and nothing to filter: the block does not
grow, so there is no head to lose.

`hl-line-mode` is on in the map and deliberately off in both of these: each
pins its point until someone navigates, so a permanent highlight would mark
nothing anyone chose.

### What a session is using — two meters read from outside, one drawn

`agent-river-tokens-width` puts a braille graph on a session's block line
(`│⣶⣶⣷⣴⣀⣀│`), one bar per `agent-river-tokens-interval`, and
`agent-river-spend` reports what the sessions have cost. Both figures are
agent-shell's: `:context-used` says how full the window is, `:cost-amount` what
has been spent, and they sit in one alist the sampler reads once per event.

**Which of them the graph is made of was decided by measurement, not by
preference — and what differs is not the channel.** Both come off the one
`usage_update` notification, written by one function
(`agent-shell--update-usage-from-notification`); what differs is which of them
the server bothers to *move*. Measured on 2026-09-19, four readings over two and
a half minutes: the context fill climbed through all four while the cost stood
still and then moved exactly once, on the turn boundary. So a graph of cost is a
graph with one point per turn, and a twenty-minute turn lands as a single spike
in the bar it ended in, saying the work happened when it was *reported*. The
context has seconds of resolution, so the bars are the context: a bar holds how
many tokens the window grew by while it ran.

The third figure is not a way out, which is worth writing down because the shape
of it invites the question: `:total-tokens` and the input/output counts beside it
come back on the *response* to `session/prompt` (`agent-shell--save-usage`), so
they exist once a turn by construction rather than by a server's habit. The graph
never reads them.

That is also what retired the open question this section used to carry — whether
to spread a turn's figure back across the bars it ran through. Nothing needs
spreading now, and the invention that would have been is not needed either.

- **The first reading of a session is not growth** (`agent-river--usage-record`).
  A context attributed to the moment we first looked draws the whole window as
  one spike, and the session Emacs has just adopted — reloaded into, or started
  watching mid-task — is exactly the one that would draw the biggest. The first
  reading establishes `:since` and nothing else.
- **A zero is agent-shell's starting value, not a reading** (`agent-river--usage-read`).
  `:context-used` is born `0` and `:cost-amount` `0.0`, so by type alone every
  session looks like it is reporting both from its first event. Taken at face
  value, a server that reports no context has the graph draw a full row of
  single dots — *the agent is here and nothing is arriving*, the strongest
  statement this view can make — about a session that may be working hard; and a
  server that reports no cost puts an unnamed `0.00` in the totals of the one
  command whose whole subject is money, which is neither named nor unnamed. So a
  context counts only when positive (a session that has been prompted holds
  thousands of tokens before the agent says a word), and a cost when it is
  positive **or** a currency was named beside it — the currency being the
  evidence that the figure is the server's rather than the value the state was
  born with, which is also what leaves a genuinely free run its zero.
- **An entry is not a meter** (`:since`, read by `agent-river--usage-graph` and
  `agent-river--usage-measured-p`). `:since` is set by the first *context*
  reading rather than by the first sample of anything, so a session on record
  for its cost alone has an entry and no graph — and no column reserved across
  the block for one that nothing can ever fill, which is the blank half of the
  same mistake.
- **The two meters are kept under opposite rules, and the asymmetry is the
  point** (`agent-river--usage-cost`). A context that falls has been compacted,
  which is ordinary and true, so the reading is taken as it comes and growth is
  measured from the new floor. A cost that falls is somebody else's arithmetic —
  a server reconnecting, an agent whose `usage_update` reports the turn rather
  than the session — so `:cost` is a high-water mark: a stored dip would
  understate the session in `agent-river-spend`, which presents the number as a
  fact.
- **Deltas are between samples, not between bar edges.** A compaction mid-bar
  therefore costs nothing: the readings after it are differenced against the new
  floor, and the work done in the rest of that bar still lands in it.
- **Sampled per event, never on a timer.** A timer would have to run through the
  quiet, which is most of the time and is precisely when there is nothing to
  measure: a session that is not working is not using anything. Events arrive
  thickly exactly while an agent works, so the resolution lands where the
  movement is and there is no timer to keep alive, retire or explain. It also
  means the sample is taken outside the fold's guard and carries its own,
  because a meter that cannot be read must not be able to report itself as
  `fold failed` and send somebody to `agent-river-reset`.
- **The read retires on its first error, and says so** (`agent-river--usage-sample`).
  `ignore-errors` was the first answer and it was the quiet half of the house
  rule: this reads another package's internals on every tool call, so a shape
  that moves would stop the graph for ever with nothing anywhere saying why.
  The observers' idiom instead — guard, log once, stop — and `agent-river-reset`
  is where it is given another go, since a reload may well be the fix.
- **A side table holding a history, which is the exception to the rule rather
  than an instance of it** (`agent-river--usage`). `agent-river--offers` is a
  side table because a pending question stops being true; this is a history of
  point-in-time facts, which is what the fold is for. Two things buy it. The
  fold's promise is that a state can be rebuilt by replaying its events, and
  **no event carries either figure** — no hook payload has one — so a slot would
  hold transitions the event stream could never account for. And a slot cannot
  be added without `agent-river-reset`, which throws away every session's folded
  state; paying that for a decoration, in a package reloaded into a live Emacs
  several times an hour, is the wrong way round. What a reload costs is the
  shape of the last hour, never the totals: those are agent-shell's figures and
  are re-read on the next event.
- **One scale for the whole block** (`agent-river--usage-max`). Scaled against
  its own maximum, a dozing session's trickle and a busy one's burst both draw a
  full bar, and two lines one above the other say the same thing about work an
  order of magnitude apart — which is the whole of what a stack of graphs is
  read for. Recomputed per line rather than memoised for the draw: a handful of
  sessions with a few dozen bars between them, where the memos of
  `agent-river--map-draw` were 700 walks of a table.
- **The sweep is over the table, not over the session being written**
  (`agent-river--usage-trim`). Trimming only the one being recorded left a
  session that has stopped being sampled holding its last bars for as long as
  this Emacs runs, and made the walk above grow with every session ever seen
  rather than with the ones still working — which is what makes that walk, and
  the memo rejected beside it, the right trade rather than a lucky one. The
  *entry* is deliberately not dropped: its cost is what answers for a session
  whose buffer is gone.
- **The bottom level of four is spent on blank versus zero**
  (`agent-river--usage-height`, `agent-river--usage-graph`). A bar the session
  was alive for and nothing arrived in draws one dot; a bar from before it was
  first read draws nothing. "Here and idle" and "not here" are different
  statements and the graph must not merge them — so blankness is decided by the
  *range*, from `:since` and the table's horizon, and never from an amount. That
  leaves three levels for the value, which is coarse on purpose: the graph
  answers when the work happened and `agent-river-spend` answers what it cost.
- **It leads the line, ahead of the name, and that is what makes it a column**
  (`agent-river--usage-column`). Only the outline marker comes before it, so
  every graph in the block starts in the same place and they stack into a strip
  that can be read straight down — which is what sharing one scale was for, and
  what the field could not do anywhere else. It sat between the task and the
  clock first, and there the block's `· `-joined parts, each of whatever width
  the session happened to have, put it somewhere different on every line: the
  padding still bought the comparison, since the rightmost bar is *now* in every
  graph wherever it starts, but nothing else. Being
  first also squares up its neighbour, the name being the one field after it
  that now starts at a fixed place. Padded with blank braille rather than
  spaces, so an empty one is exactly as wide as a full one in whatever font
  draws them, and so a line's own tail does not jump when its session is
  sampled for the first time.
- **Reserved while a session the block is *drawing* has been sampled**
  (`agent-river--usage-measured-p`), and pointedly not while the table is
  non-empty. An entry outlives its session on purpose so that
  `agent-river-spend` can answer for one whose buffer is gone, so asking the
  table whether it holds anything would keep an empty column on every line of an
  Emacs whose agent-shell sessions all ended hours ago.
- **It is in neither frame, which is the second reason it comes before the
  name.** Every other number on the line is the task's and resets on a prompt;
  this covers a fixed window that runs straight through one. Read before the
  name it is plainly about the session rather than about the turn, where in the
  middle of the line it sat among numbers that reset without saying that it
  does not.
- **The money is named or not named, never guessed** (`agent-river--usage-money`,
  `:currency`). `agent-river-spend` is the one place the figure itself is shown,
  so it carries the currency agent-shell named and sums **per currency**: a table
  of bare numbers added into one headline is how two currencies become a total
  true of neither. A later reading that carries no currency does not unname the
  money, because only the notification carrying a cost carries one. And the word
  *total* leads the sums rather than trailing them — after a list of sessions it
  attached to whichever currency happened to be last, and read as that one being
  the total of the others.
- **The total is a query, not a line** (`agent-river-spend`). A total across
  sessions belongs to no session, so it would need a line or a header of its
  own, and this view has spent one of those before and taken it back. The totals
  outlive the buffers they were read from, which is the one thing reading
  `agent-shell--state` directly cannot do.
- **The hooks carry none of this**, so a session run from a terminal has no
  graph — the same price the `◇` and `“` lines pay, and paid the same way
  rather than routed around by reading `transcript_path` per event.

### Markdown belongs where the state leaves, not where it is watched

`agent-river-markdown` / `agent-river-copy-report` render the state for an
issue, a PR or a message. Neither HUD buffer is Markdown and neither may
become one: the log carries prompts, reasoning and tool arguments — text the
package does not control — and Markdown would hand that text the power to
restructure the view watching it. A prompt beginning `# ` becomes a heading.
Wrapping the whole payload in code spans would fix that and destroy the
per-kind colouring that is the log's main signal. The block holds only text
this package wrote, so it is the one that could have gone Markdown, and it
does not: it is a fixed handful of lines with no structure to fake, so the
four conditions below are not met by it either, and a rendering that differed
between the two halves of one view would have to be learned twice.

The map could go Markdown because four things held: the content *is* a
document, every token in it is ours, it is rebuilt every few seconds rather
than every event, and it had structure being faked with `*`. Check all four
before rendering anything else as Markdown.

The export is a third derivation of the state beside the panel and the report,
built on neither — the report's values are already formatted for a human
reading a plist, and re-formatting a formatted string is the second-account
problem in a different hat (see `agent-river--md-child`, which reads the
child's state rather than take a file name back out of
`agent-river--child-digest`'s prose). Three things it owes:

- **Both frames named in words** (`**this task**` / `**this session**`). The
  report gets that free from its key names; here it is hand-written, so it is
  tested.
- **The claim marked twice and placed last.** `intent` is the agent talking
  about itself, and it is leaving the package — a reader who takes it for one
  of the measurements above it has no way back to the distinction.
- **The agent's words escaped** (`agent-river--md-escape`), names fenced as
  code spans long enough to hold a backtick (`agent-river--md-code`). Only
  three values are the agent's — the prompt it was given, an intent it stated
  and the end of its last turn — which is the whole reason this is tractable
  here and is not in the HUD. The third arrives clipped
  (`agent-river-said-width`) and sits directly under the prompt, because those
  two are one exchange: an export with the tool calls and not the words is a
  tool log, and the answer filed below the tallies reads as another
  measurement rather than as the end of the thing above it.

### The view of the artifact tables

`agent-river-map` (`*agent-river-map*`) is what has arrived and who is on
it: one section per domain, one line per record of `agent-river-artifacts`,
each annotated with whoever has reached it. Everything reads
`agent-river--artifact-entries` and the artifact table, so no two parts of
the draw can disagree about what the tables say.

**It was a lens over dired for most of its life**, and the removal is the
thing to understand before changing anything here. One directory was listed
in full, each entry carried what had been reached beneath it, RET descended
into the next, and a diffstat read off git said what had changed. All of
that is gone, and so is what it answered: *is anybody else in this file* was
`agent-river-touching` and went with it; *which files is this session in* was
the block's `files` heading and went too. The counts are still folded and no
view names a file. What has **no** other answer is the thing that arrived on its own
— an incident routed to you, a review requested, a build that broke — which
nothing in the event stream could have produced and which matters most when
no agent is running. That is what this view is now, and the line it exists
to carry is the one nobody has picked up.

What went with the trees, in one place so that nothing is reintroduced
piecemeal: `agent-river--map-all-roots` and `--map-section-roots` (a session
cwd is not a section any more), `--map-reach`, `--map-listing`,
`--map-tree-entries`, `agent-river-map-untouched` and its `a`,
`agent-river-map-ignore`, `agent-river-map-descend`,
`--map-default-root`, `--map-node-path`, `--parties-by` (one bucket left,
so the function that chose one is an indirection standing where a `when`
is), `--rows-step` (a step is on a file and a line is a record, so it could
never match again), the `:dir` cell on an entry and on a contributor's
nodes, and the `:abs` derivation in `agent-river--artifact-walk` — nothing
resolves a key per node any more, and a cache nobody reads is a second
account waiting to happen. `agent-river-forget-gone-files` lost its `C`
key with the file lines it was about; the command stays, since the session
tables still record files.

Four things about the map are load-bearing:

- **A section is a domain, and the listing is the table.** There is no
  per-domain listing function to write: a record carries its own name,
  whether it has ended and whatever context its producer put on it, and
  asking a domain to answer those again would be the second account the
  table exists to avoid. `agent-river--map-root` nil is the overview and
  each domain heads its own section; setting it is a *zoom*, which is where
  RET goes on a heading and where `^` comes back from. One domain is drawn
  without a section heading, since the header already names it and repeating
  it would indent the listing to say nothing — which is also why a leaf line
  passes `file` to `agent-river--map-marker` rather than a number, so that
  pushing records down a level for the section headings cannot push the
  elision and empty-map lines into being headings too.
- **A section root is an identity, never a path**
  (`agent-river--domain-root`, `agent-river--map-domain`). `inc:` is a
  string built from the domain because everything downstream compares roots
  with `equal` and puts them on text properties; a line is identified by the
  artifact key for the same reason. Expanded against `default-directory`,
  two maps drawn from different buffers would disagree about which line was
  which.
- **An unreached record is listed, and that is the opposite of what the tree
  listing decided.** There the unreached entries were the rest of the disk
  and swamped the few that mattered, which is what `agent-river-map-untouched`
  was for; here an unreached record is a thing nobody has picked up, which
  is the single most important line this view can carry.
- **Nothing leaves this view by getting old.** A record stands until
  `agent-river-drop-artifact` or `agent-river-artifacts-reset` takes it
  away, and a name on it until `agent-river-forget-artifacts` or a new
  prompt clears the task frame. There was a floor here once
  (`agent-river-map-party-floor`, under an exponential decay): weights
  approached zero without reaching it, so after an hour everything carried a
  name and the floor was what kept a view where everything is marked from
  marking nothing. It is gone with the decay, and the answer to a map that
  has filled up is a gesture rather than a half-life.

- **A party that is gone is not counted** (`agent-river--gone-p`,
  `agent-river--gone-parties`, read by the header). Its *name* stays on the
  lines it reached, because the record was still reached and that does not
  stop being true; what goes is the claim that somebody is there. There was
  a present-tense reading on the line once -- `:current`, drawn as an eye in
  the gutter -- and the hard case it kept getting wrong was exactly this
  one: an agent-shell buffer killed, and the marker stayed pinned to one
  file for as long as the registry held the state. It went, and so did the
  row that replaced it (`agent-river--rows-step`, which named the session
  and the tool): a step is a call open on a *file*, and there are no file
  lines left for it to land on. Three things to keep:
  **gone is narrower than not-active** — `agent-river--active-p` falls back to
  the TTL, which is a guess, and a name is not withdrawn on a guess; the facts
  are a buffer we saw and that has since been killed (`agent-river--shell-hosted`,
  which is per session — a hooks-only CLI session never had a buffer here and
  must not be called gone for it) and a subagent's own `SubagentStop`, plus a
  subagent whose root is gone. **Gone is folded over
  the party, not the session** (`agent-river--gone-parties`): two `Explore`
  children of one root share the label `alpha/Explore`, so one live sibling
  keeps the party. And **the kill has to say so itself** — a dead session
  sends no further events, so `agent-river--shell-died` marks the map dirty
  (`agent-river--map-invalidate`) and lets the timer redraw past the dying
  buffer; without that the header goes on counting it until someone presses
  `g`.
- **The header is a name and a count, not a legend**
  (`agent-river--map-header`). It carried the frame the numbers were read
  from — a fact that is true, does not change, and was being redrawn every
  few seconds onto a line that is read once. A legend belongs where the
  thing is decided (`agent-river-map-scope`), not in the view. What stays is
  what *moves*: which domain is being shown — or how many there are, in the
  overview, since no one of them may stand for the rest — and how many
  agents are in it. That count is of agents that **still exist**
  (`agent-river--gone-parties`), not of names on the map — a name outlives
  its session on purpose, because the record was still reached, so counting
  names would report an audience that has left as though it were still
  there.
- **A record that is over is struck through, not dropped**
  (`agent-river-gone`, set on `:missing` from `agent-river-artifact-gone`).
  It was worked on and it is over, which is history and stays until somebody
  says otherwise (`agent-river-drop-artifact`, which leaves the sessions'
  tables alone — they reached it, and that stays true whatever became of the
  thing at the other end). The same rendering and the same argument used to
  apply to a deleted *file* on the tree listing, and dropping those outright
  was tried and lost the deletion itself, which is a thing the agent did.
- **A node's rows are contributed; the line is the listing**
  (`agent-river-map-contributors`, `agent-river--map-rows`). The line carries
  what can be read *down* the listing — the fold marker and the contention
  marker — and everything else lives in rows under the node. The party names
  used to be on the line and were the one ragged thing on it, which is why
  nothing scannable could ever follow them. Rows are **detail, and wait to
  be asked for**: every node draws closed with a twisty, and TAB opens it,
  so there is one mechanism rather than two and no disclosure twisty to
  invent. They were enrichment and detail at once — drawn wherever there
  were any — which in the tree listing this replaced meant a row or three
  beneath every line the map had, so the view read as a stack of rows with
  names threaded through it. There was a way onto the line itself once
  (`:summary`, a fixed-width column), and it went with the diffstat that was
  its only user: a column reserved buffer-wide for something no contributor
  can fill is a column in name only, and what a contributor has to say now
  is read where a reader asked for it. The price is that the party names are
  behind a keystroke: `>`/`<` still says some agent is here, and who it is
  is a question you ask the line. Deliberately no setting to put the old
  default back — TAB already asks per node, where a reader is looking, and a
  buffer-wide answer to the same question is the second mechanism this
  design spent its one fold avoiding.
- **A contributor answers twice, and the split is forced by the timer.**
  `:read` is synchronous and instant, from whatever it already has; `:refresh`
  is where waiting is allowed and hands the answer back through
  `agent-river-map-contribute`, which marks the map dirty rather than drawing
  — an answer landing after the redraw timer retired would otherwise reach a
  cache and never the screen. The map throttles how often it *asks*
  (`:ttl`, `agent-river--map-refreshed`); whether a read is already in flight
  is the contributor's business, since only it knows what it started. Batch
  per root: thirty lines with a subprocess each, every TTL, is a fork bomb
  with a view attached. A contributor that throws is **retired on the spot**,
  like an observer — this runs on every draw.
- **An answer that has just landed draws the map** (`agent-river-map-contribute`,
  debounced by `agent-river--map-contribution-delay` so answers arriving
  together make one draw). Leaving it to the redraw timer was most of how
  long an asynchronous read appeared to take: the answer sat in the
  contributor's cache for up to `agent-river-map-refresh-interval` seconds
  before anybody drew it, on top of the TTL that decided when to read at all
  — the diffstat that used to live here measured about eight milliseconds of
  work and thirteen seconds end to end. A **floor on how recently the map
  was drawn** was tried first and was exactly backwards: a read is started
  *by* a draw and answers milliseconds later, so every answer there has ever
  been arrived inside the floor and none of them drew.

- **Three things a row owes, each preventing something specific.** Its text is
  **escaped** (`agent-river--map-row-line`): the map is Markdown only because
  every token in it is ours, and a row is the first text here that is not — a
  row beginning with `#` restructures the view showing it, which is exactly
  why the HUD is not Markdown at all. It is **one line, control characters
  stripped** (`agent-river--map-one-line`), because the buffer is line-based
  and a newline makes one broken row rather than two. And it carries a
  **`:key`**: the redraw finds a line again by what it names
  (`agent-river--map-here`), and a row that named only its node would inherit
  its node's identity and land point a line or two off after every draw. Its
  `:face` is **named, never set** — tree-sitter owns `face` here.
- **Order is declared, not positional** (`:rank`, low first, ties keeping
  the order of `agent-river-map-contributors`). Which contributor was
  registered first is not a statement about which of their rows is worth
  reading: what a record *is* (`artifact`, rank 0) outranks who has been on
  it (`parties`, 1). It is also what `agent-river-map-detail-rows` cuts
  from, where it is set at all — the tail is the least worth keeping rather
  than whoever was registered last.
- **Nothing is elided by default** (`agent-river-map-detail-rows` nil). The
  cap was inherited from the elision the file lines had, and the reason did
  not come with it: those were drawn wherever a node was open, where a node
  draws *closed*. So rows are on screen only because somebody opened that
  one node, and a wall across the answer they opened it for is the cap
  cutting where nothing asked it to — the clutter it was defending against
  is already held off by the fold. A number still caps, for a contributor
  with more to say than a node can hold.
- **Rows ride the fine grain only.** `n`/`p` stop on them; `M-n`/`M-p` skip
  them (`agent-river--map-row-line-p`, since a row inherits its node's key
  and cannot be told apart by the path alone); `>`/`<` pass over them because
  they carry no `agent-river-map-active` — that motion is for finding the
  agents, and a contributor able to put itself on it would be competing for
  the one gesture that is about them.
- **Nothing here is forgotten by itself** (`agent-river-forget-artifacts`).
  Work that has just landed — a merge, a release — is history rather than
  cold, and only the user knows when that moment came. The command empties
  the artifact tables and the anchors
  with them, and nothing else: steps, failures and the task survive, so it is
  not `agent-river-reset` in a smaller hat. It goes through the fold as a
  `forget` event rather than clearing the tables where the command is
  written, because the fold owns the state. Deliberately not on the map's
  keymap: it throws measurements away, and a single keystroke in a view
  buffer is the wrong gesture for that.
- **A deletion is news, and then it is history**
  (`agent-river-forget-gone-files`). It had a key in the map, `C`, on the
  grounds that its **subject is already gone** — what is lost is the record
  of an absence rather than the record of the work. The map lists artifact
  records now and draws no files at all, so the lines it was about are not
  there and it is an `M-x` command like the one above. The state still
  records the files, which is why the command stays. Two things hold it. It
  is **measured against the disk, never against any rendering**: a key
  reached through an anchor some other tree has nothing to do with is
  elsewhere rather than gone. And a key **nothing can place is unplaceable,
  not gone** (`agent-river--artifact-gone-p` goes through
  `agent-river--artifact-absolute`, so the anchor wins over the cwd), or a state
  folded without a cwd would have every artifact it ever recorded swept away by
  a command that found none of them. It narrows the same `forget` event with
  `:files` rather than adding a kind of its own: the transition is identical
  and only its subject differs, and a second kind would be a second place for
  what forgetting means to be decided. It asks first, because nothing undoes
  it. It is also the last caller of `agent-river--artifact-absolute`: the map
  used to place every key it drew, which is what the `:abs` derivation in
  `agent-river--artifact-walk` existed for, and both went together.
- **The artifact-side forgets ask and report on the same terms**
  (`agent-river-drop-artifact`, `agent-river-artifacts-reset`). Wholesale
  asks, like the one above and for a sharper version of its reason: a
  session folds again from its next hook call, where a record that arrived
  from a webhook an hour ago arrived once, so this is the half of the state
  no event can rebuild. Unconditionally rather than on
  `called-interactively-p`, which answers nil in batch and would have made
  the question the one behaviour here the suite could not hold; code that
  means it says `clrhash`. One record does *not* ask, because naming it out
  of a completing list is already the deliberate act the prompt would be
  asking for -- and it reports only when something was removed, since a log
  line saying a record was forgotten is a measurement of something that
  happened.
- **Registering a domain is not a thing, and neither is naming one**
  (`agent-river--domain-label`, which is now `symbol-name`). **There is
  nothing to register** (`agent-river--domain-label`, which is now `symbol-name`). The
  table that did it, `agent-river-map-domains`, held a `:visit` for RET --
  a second place answering what may be *done* to a thing, which is not the
  domain's to answer once (see the actions section below) -- and then held
  only a `:label`, which is the failure `agent-river-domains` had one grain
  up: a declared second name for something the table already holds, kept in
  step by nobody. Its default was quietly wrong for what actually arrived,
  capitalising `pr` into a section called `Pr`. A domain nothing knows about
  was always drawn anyway, because something that has arrived
  must not wait for configuration before it can be seen, which is the failure
  mode of every dashboard that has to be taught about a new source -- and now
  that holds for its name as well as for its existence.
- **`>`/`<` does not stop on a record nobody has reached, and that is a
  decision rather than an oversight.** The motion is read off
  `agent-river-map-active`, which is set from the parties, so an incident
  sitting in a queue with no agent on it is passed over — while being, very
  possibly, the line you opened the map to find. It stays that way because
  `>` means one thing today, "some agent is under this", and a motion that
  also meant "somebody should be" would be two questions sharing a keystroke,
  with no way to ask either on its own. If this is revisited, the answer is a
  motion of its own, not a widening of this one: the map has three grains
  already and they are separable because each answers exactly one question.
- **The context rows are an ordinary contributor** (`agent-river--rows-artifact`),
  gated on the *lookup* rather than on the section being a domain's: one
  special case fewer, and a record declared against a key the map already
  draws annotates that line too. It is also what makes it cheap -- the
  artifact table holds only what was declared into it, so the lookup misses
  for every ordinary line on the map. This package never reads a value out of
  a context, which is what lets a record hold a severity, a body and a URL
  without this file learning about any of them; the rows are escaped like
  every other contributed row, since a context cell is the least of our text
  there is. It is the only contributor left that is about the subject rather
  than about who has been on it, which is what the section listing being the
  artifact table makes of it: the rows say what the record *is*.

Encoding discipline, since there are two facts on a line: contention is a
marker and having ended is a strike-through. There were two more. How heavily
a name had been reached was drawn as shading, and it went with the decay that
made it worth watching; what state the work was in was a fixed column read off
git, and it went with the file lines it was mostly annotating. The
strike-through is deliberately not a colour: `:missing` used to be drawn in
the grey `agent-river-stale`, where grey already meant stale and elided
besides. A second colour there would leave a reader unable to say which fact
any given colour meant, and one fact must not take two encodings either — the
brackets used to read `[alpha:4]`, which gave the touch count a second
rendering nobody could reconcile against the first and pushed the names,
which is what the brackets were for, into the margin.

There was a third marker in the gutter until recently, the position one, and
it is worth recording what taking it out settled rather than only that it
went. It said "this is the file that party touched last", and it was the
map's one present-tense reading; it was repeated in a party's own row, but
only where there were several parties to attribute it to, because with one
party the gutter mark, the row's face and the row's glyph were three
renderings of one fact about the only name there is. That exception needed a
rule of its own — decided per node rather than per row, or the gutter's mark
would read as belonging to whichever rows kept theirs. What replaced it was a
row that said the same thing in words (`agent-river--rows-step`: session, tool
and file), and that went too when the file lines did — a step is a call open
on a file, and this view has no line for one. **There is no present-tense
reading on the map any more**, and the right place to add one back is a row,
not a marker: a row can say who and what, where a glyph can only point.

The rule for colour here generally: inherit a face the theme knows unless the
value needs a shade no built-in face has. Nothing here does any more. The four
that did — the three `agent-river-heat-*` and `agent-river-pulse`, spelled out
per light and dark background — went with the shading they were for, and the
two that inherited `success` and `error` went with the diffstat. Those two
were also the one case where a colour was not a channel of its own: `+` and
`-` had already said which half was which, so the green and the red were
reinforcement inside a column rather than something a reader had to decode.

The buffer is Markdown, rendered by `markdown-ts-view-mode` — the read-only
variant, which already has `special-mode` among its parents, and a view of a
state written elsewhere must not offer edits the next redraw throws away.
`agent-river-map-plain-mode` is the fallback: the mode ships with Emacs 31,
the grammars do not, and `agent-river--markdown-ts-p` checks both (loading
the library, because only `markdown-ts-mode` is autoloaded — `fboundp` on the
view mode answers no on an Emacs that has it). Same text either way; only the
fontification is missing, so the fallback is not a second view to keep in
step. Four things the Markdown base forces:

- **Faces go on `agent-river-map-face`, never on `face`.** tree-sitter owns
  `face` here: it refontifies on redisplay and appends or removes faces as
  the structure changes, so a face written as a text property is drawn once
  and then quietly gone. `agent-river--map-shade` turns the marks into
  overlays after the text is in, because an overlay sits above the
  fontification rather than competing with it.
- **Markup stays visible** (`markdown-ts-hide-markup` nil). Hiding it is the
  view mode's default and reads better on prose, but here the marker *is* the
  indentation — hidden, a section and the records under it start in the same
  column and the structure stops being one.
- **Names are code spans, fenced and on one line**
  (`agent-river--map-name`). A path is what a code span is for, and inline
  markup does not apply inside one; bare, `foo_bar_baz.el` renders with `bar`
  in italics and the underscores eaten. That holds only for as long as the
  name cannot close the span it sits in, and **a name stopped being ours the
  moment a record could carry one**: an artifact's is a ticket title from
  whoever declared it, and `Fix ``foo`` in *bar*` ended the span at its first
  backtick and italicised the rest of the line. So the fence is measured
  (`agent-river--md-code`, the export's answer) and the text is held to one
  line (`agent-river--map-one-line`, the rule a contributed row already
  owes) — a newline made one entry and one stray, and the stray carried none
  of the properties the motions and `agent-river--map-here` read. Fixed in
  the one place every name goes through rather than beside the record that
  made it likely, so a path with a backtick in it is covered by the same
  change; `agent-river--map-beginning-of-name` steps over the whole fence
  for the same reason, or point lands on markup in exactly the case the
  longer fence exists for. The **rows** were escaped from the start
  (`agent-river--md-escape`) and the **name was the hole beside them** —
  when the next piece of foreign text arrives on this buffer, this is the
  question to ask of it first.
- **`outline-minor-mode-cycle` is off.** It puts a `keymap` text property on
  every heading that wins over the mode map and swallows TAB — but the real
  reason is that its fold lives in overlays, and this buffer is rebuilt every
  few seconds, so a heading folded that way springs open on the next redraw.
  `agent-river-map-toggle` folds by deciding what gets drawn, which is the
  only kind of fold that survives here.

Padding is measured from the whole prefix, not from the name: `## ` and `- `
are different widths, and measured from the name alone every list item's
reading sits one column left of every heading's.

Motion is dired's, because the map was a lens over dired for most of its
life and the gestures outlived the listing. Three grains, and collapsing them
loses the one a reader wants: `n`/`p` (and the remapped arrow keys) walk
every line that names something, rows included, `M-n`/`M-p` walk the
listing's own entries past an open node's rows, and `>`/`<` walk only the
lines with agents on them — with a queue of records that last one is the
difference between reading the view and searching it. Three rules hold it
together:

- **Which lines a motion may stop on is read off text properties, not off the
  text.** `agent-river-map-path` marks a line that names something (the
  header, the elision line and the empty-map line have none, which is what
  makes them unstoppable-on), `agent-river-map-row` separates a contributed
  row from the record it hangs under, and `agent-river-map-active` is set
  from the parties rather than from the rendered annotation — so a
  reformatting cannot pull the motion and the reading apart.
- **Point lands on the name** (`agent-river--map-beginning-of-name`), never in
  column zero, where it would sit on the Markdown marker and read as though
  the markup were the content. `agent-river--map-settle-point` runs after every
  redraw, so a freshly drawn map is never left with point on the header.
- **A motion with nowhere to go refuses** rather than landing somewhere near.
  The next RET would otherwise visit something the eye never chose, and this
  view's whole job is being trusted about where things are.

### Pieces that span files or need context

- **agent-shell integration** (`agent-river.el`, "when it is hosting the sessions"):
  `agent-shell--state` carries the ACP session id verbatim as the hooks' `session_id`,
  so liveness, labels and uniquifying come from the buffer rather than being
  estimated. These degrade to the TTL-based path when agent-shell is absent — keep
  that optional. The reasoning lines below are the one exception: they have no
  fallback.
- **A draw derives once and reads everything else off that**
  (`agent-river--artifact-memo`, `agent-river--section-memo`). Two boxes,
  one shape, both bound by
  `agent-river--map-draw` and thrown away with it -- a draw is synchronous
  Lisp, nothing on that path folds or declares, so the binding cannot
  outlive the walk it was made for and there is no invalidation to get
  wrong. Outside a draw they are nil and every call reads what is there,
  which is what a caller outside a draw is asking about. The entry list
  came first; the section reading is a reading *of* that list, and was
  being taken once per node rather than once per draw. There was a third,
  `agent-river--newest-memo`, and it went with the position marker it was
  memoising. Measured on
  2026-09-17, 3000 artifacts and 200 records: 697 walks of the artifact
  table and 3 of the entry list, down to one each, and the draw from ~205 ms
  to ~145 ms. At 20 records it is inside the noise -- the win is in the
  count of records, not in the mechanism -- which is the honest way round
  for a cache whose cost is a variable somebody has to remember to bind.
  Each memo has a test that pins both halves: one read inside a draw, and a
  full read outside one.
- **Which buffer hosts a session is indexed, never searched**
  (`agent-river--shell-sessions`, read through `agent-river--shell-buffer`).
  Every redraw asks this of every session three times over — label, is the
  line visitable, is it still alive — and the search is a walk of every
  buffer in Emacs: 1.4 ms a call in a long-lived one (10k buffers), which was
  ~13 ms of the 13 ms a block redraw took. Indexed it is a hash lookup, and
  the redraw is 0.1 ms. Three states, and the distinction between the last
  two is the whole design: **a buffer we have seen** — live it is the answer,
  dead the session is over and nothing will host that id again, since
  `agent-shell-restart` starts a *new* one, so both answers are free;
  **nothing recorded** — look once and remember; and **looked and found
  nothing, with the time**, re-looked every `agent-river--shell-rescan`
  seconds. That last one must not become permanent: a session whose first
  event beats agent-shell to setting its id would be counted unhosted for the
  rest of the Emacs session — no label, no reasoning lines, no RET — and
  nothing would ever say so. The index is also what replaced the sticky
  "agent-shell is the authority here" flag: keeping a dead buffer is what the
  flag was really for, and it did it globally, which called every session run
  from a terminal inactive as soon as agent-shell had hosted anything.
  `agent-river--shell-hosted` is the per-session form of that question and is
  what both liveness predicates gate on.
- **Reasoning (`◇` lines) comes only from the ACP stream.** `agent_thought_chunk`
  notifications carry it; `agent-river--ensure-subscribed` attaches the handler on
  a session's first folded event, via `agent-river--acp-client`. Chunks accumulate
  in `agent-river--thought-runs` until a sentence is complete — the run is then
  emitted and its remainder dropped — and a run with no sentence boundary is
  flushed by the next non-thought notification. Waiting for the boundary is the
  point: a chunk usually ends mid-clause. Deliberately not a struct slot, so a
  reload does not demand `agent-river-reset`. The hooks carry no thinking text, so
  a session agent-shell does not host gets no `◇` lines; that is accepted, not a
  bug to route around.
- **What the agent said (`“` lines) comes only from agent-shell's own event
  stream** (`agent-river-listen-mode`, `agent-river--listen`), which is a
  different mechanism from the one above and not a second use of it:
  `agent-message-chunk` and `turn-complete` are agent-shell events, published
  per buffer through `agent-shell-subscribe-to`, where the thought handler
  reads ACP notifications off the client. `turn-complete` does not exist on
  that notification stream at all, which is what forced the split. The chunks
  accumulate in `agent-river--say-runs` and are folded as one `say` on
  `turn-complete`; a turn that said nothing folds nothing, and a buffer dying
  mid-turn drops what it had. Off by default, like the other two modes that
  subscribe, because what it adds to the log is the agent's own prose at the
  length the agent chose.
- **The phase is read from the last `agent-river-phase-window` steps**, by
  three rules in order. **`waiting` outranks everything** — the tool window
  still holds the steps of a finished turn, so without it the panel announces
  `exploring` above a log line saying the turn is over, describing what the
  work *was* while presenting it as what the work *is*. **`blocked` comes
  from failures, not tools**, and its threshold (2) is deliberately lower
  than the one for interrupting the agent (3): an onlooker may see a rough
  patch early, the agent should only be told once it looks like more than bad
  luck. **Otherwise the dominant tool bucket wins**, and only with at least
  two classified steps — one is noise, two is a tendency. Shell calls stay
  unclassified unless they match `agent-river-verify-regexp`, because the
  same tool runs the test suite, a git query and a directory listing; the
  practical consequence is that shell-heavy work often shows *no* phase at
  all, and abstaining beats guessing. The pattern is applied only to shell
  tools — matched against every step, it once classified reading a file
  called `Cask` as verification.
- **The block's fold is a flag, not an overlay.** The block is erased and
  rebuilt on every event, so an outline fold would spring open on the next
  tool call. A flag means the rebuilt block is drawn already open and stays
  that way until it is asked to close. Same rule as `agent-river-map-toggle`,
  which folds by deciding what gets drawn, and for the same reason.
- **The divider is a buffer boundary, and everything before it was an
  attempt at the same thing one notch cheaper.** There was a `* -- eventlog`
  heading between block and log once — a divider that exists to be a fold
  handle earns its line from nobody who is reading — and then a blank line
  that separated just as well at no cost in labels. What neither could buy
  is what the boundary gives for nothing: the block redrawn without an offset
  saying where to stop deleting, the log trimmed without one saying where to
  start counting, and each half sized, scrolled and navigated without the
  other moving under it. Two buffers is also two windows, which is the one
  thing that is worse, and it is answered where it arises. The slots are
  adjacent (`agent-river-show`, `agent-river-show-log`) so the layout is the
  one they used to share, and the block's window is fitted to the block
  (`agent-river--fit-block-windows`) so it takes a line per session rather
  than half a column. **And only the block opens itself**: one buffer meant
  one answer to `agent-river-auto-display`, and the log inherited an opening
  that was right for the pair and wrong for it alone — it reappeared on the
  event *after* the one a reader had closed it on, which is a view overruling
  a decision somebody had just made. The log is asked for (`l` in the block,
  `agent-river-show-log`). What that gives up is that a line nobody is
  looking at is a line nobody sees; the never-go-quiet rule is about writing
  the line, not about seizing a window for it.
- **The block opens itself once, and the second time was the same mistake
  one buffer over** (`agent-river--block-shown`). The condition was "no
  window is showing it", which is true again the moment a reader deletes
  one — so the block came back on the next tool call, and on the one after
  that, which in a running task is several times a minute. That is the
  reopening the log was spared above, arrived at from the other side: there
  the view appeared on every event because every event wrote a line, here
  because every event redraws the block. So the flag records that the
  *offer* was made rather than what is on screen, which is the fact the old
  test could not hold — a deleted window leaves nothing behind to ask.
  Whether one is showing is still asked, because it answers the other
  question (is it on screen *now*), and the branch where it is sets the flag
  rather than doing nothing: this file is reloaded into a live Emacs several
  times an hour, which clears the flag, so without that a block that had
  been up all morning would be offered once more the next time its window
  was closed. `agent-river-show` sets it too — a reader who put the window
  there has said where the block goes, so closing it is that decision
  changing rather than an offer they have not had. Nothing clears it,
  `agent-river-reset` least of all: forgetting what the sessions did is not
  a request for a window.
- **The log runs oldest to newest**, the way every other log does: the new
  line goes on at the bottom, the trim takes from the top, and a window
  nobody has moved tails it (`agent-river--tail-start`,
  `agent-river--follow`). It ran the other way for as long as the state block
  was pinned above it in the same buffer — newest first put the two things
  worth seeing together at the top, where neither could scroll away and
  nothing had to be tailed — and that was an answer to the block being there,
  not a claim about logs. With the block in its own buffer the reason was
  gone and only the surprise was left. What the reversal costs is one
  computation: `agent-river--follow` works out `window-start` itself rather
  than leaving it to redisplay, which finds point below the window and
  recentres — the newest line in the middle with half a window of nothing
  under it, once per tool call. `vertical-motion` is given the window, so it
  counts screen lines and stays right where the long lines wrap. The block is
  deliberately *not* `header-line-format` (single-line, can't show two
  sessions); both modes set that to nil explicitly, since the state used to
  live there and a value left behind by an older version of this file sits
  frozen at the top of a buffer.
- **The block is drawn by whatever folded, never by whatever logged**
  (`agent-river--update-block`). It used to come along with the log line, in
  `agent-river-log`, which is why the split has to name the four places a
  state changes — `observe`, `set-intent`, `note`, and a permission request
  arriving — rather than one. That is the price, and it is paid where it
  catches something the old arrangement got wrong by luck: an outcome written
  onto the line that opened its call writes no line of its own, so a `fail`
  landing that way used to leave the block claiming nothing had failed until
  the next event. Two ways in, and the difference is what a *tick* may do:
  `agent-river--redraw-block` creates nothing, so a buffer the user killed
  stays killed, and `agent-river--update-block` may, because an event is the
  something that brings it back.
- **One tool call is one line.** The `act` line carries the call's id as
  `agent-river-call`, and its outcome is written onto that line rather than
  taking one of its own (`agent-river--log-outcome`) — so the timestamp stays
  the one the call *began* at, and `agent-river-max-entries` holds twice the
  history. The id is `SESSION\0CALL-ID` (`agent-river--event`), paired with the
  session because Claude Code's `tool_use_id` is unique everywhere and ACP's
  only within its session. Three things this owes: it **falls back to a line of
  its own** whenever the opening line is gone (trimmed, or never written because
  Emacs started mid-run) or the host names no call at all, since a tidier log
  that silently drops outcomes is the wrong trade; it **clears the id** after
  answering, so a repeated terminal status cannot append a second verdict; and
  the **face comes from the closing kind**, so a `✗` still reads as a failure
  against the `act` colouring it lands on. Pairing by nearness or tool name
  instead would fold two parallel calls of one tool into each other — which is
  exactly the case the id exists for.
- **A handful of tools are drawn as a glyph rather than named**
  (`agent-river-tool-glyphs`, `agent-river--tool-label`). Usually the host's
  own word is the most specific thing the line can say — `Grep` and
  `WebFetch` are two different things being done, and neither is frequent
  enough that reading the word costs anything. What earns a glyph is a call
  made so often that its name is the part of the line a reader has stopped
  seeing, while the argument beside it — a command, a path, clipped to
  `agent-river-detail-width` — is what differs between two of them. Three
  things it owes. **Keyed by name, not by class**: the shell glyph was
  class-keyed at first, read straight off `agent-river-shell-tools`, since
  `Bash`, `BashOutput` and `execute` are three hosts' names for one thing —
  but `Edit` and `Write` are not a class, they are two tools that differ and
  the glyph is *how* they differ, so the table has to answer per name, and a
  second class-keyed path beside it would be two mechanisms deciding one
  question. Both dialects are then listed by hand, as in
  `agent-river-phase-buckets` and for its reason. It is **drawn and never
  folded**: `:tool` keeps the host's word, because the tool tally, the phase
  bucket and `agent-river--writing-p` all match on it and a glyph folded in
  would stop all three matching, silently — the signal text keeps the word
  too, since that line goes back to the agent. And **a tool absent from the
  table keeps its name**, which is both how a glyph is turned off and the
  answer for a font without it, where the box drawn instead says less than
  `Bash` does — not held to the one-column rule
  `agent-river-spinner-frames` has, since nothing is aligned after a tool
  name and what follows it is free text.
- **The refresh timer** (`agent-river--ensure-timer`) redraws only the block, runs
  only while someone is mid-task, retires itself on the first tick that finds no
  one working, and cancels itself if a redraw throws.
- **The session marker spins while the turn runs**, and is a *second* timer
  (`agent-river--ensure-spinner`) on the same gate as the refresh timer, so
  the two cannot disagree about when a turn is over. Frames have to land
  often enough to read as motion, and rebuilding the whole block eight times
  a second would both cost far more than the animation is worth and drag the
  block out from under a reader — so this timer only writes a `display`
  property onto stars the panel already marked with `agent-river-spinner`,
  and derives nothing. Five things it owes: the buffer text stays a literal
  `*`, because `outline-regexp` is matched against the text and animating the
  character would stop the block being a document the moment an agent started
  working; the spinning stars are found by that property rather than by
  looking for a star in the text — which the log running underneath made
  urgent, since a line of the agent's own words may well begin with one, and
  which is kept now that it does not, because the property is also what says
  which session a star belongs to and no search of the text could answer
  that; **clearing is part of stopping**
  (`agent-river--stop-spinner`) — the last frame is a `display` property, so
  a timer that merely cancelled itself would leave every finished session
  showing whichever glyph it stopped on; **the phase belongs to the session,
  not to the block**; and **the gate is read off the marks, not re-derived**.
  `agent-river-spinner-frames` nil is the off switch, and the answer for a
  font that has no such glyphs.
- **The phase is each session's own** (`agent-river--spinning-since`,
  `agent-river--spinner-glyph`). One counter for the whole block put every
  marker on the same frame whatever each agent was doing, and a row of
  markers moving as one reads as a single animation about the block rather
  than as one apiece — two agents prompted a moment apart *are* a moment
  apart. So the frame is `(age of this turn) / agent-river-spinner-interval`,
  the mark on the star carries that turn's start, and the timer advances
  nothing: with no counter to keep, a redraw mid-turn cannot jog the marker
  and the phase survives a reload.
- **What keeps the animation running is the marks, not the registry**
  (`agent-river--spinning-p`). The gate is the same one — `agent-river--star`
  marks a star exactly when `agent-river--state-working-p` holds — but read
  off the rendering the panel has already done. Asking the registry per tick
  meant `agent-river--active-p` per session, which then walked every buffer
  in Emacs for a hosted one: ~3 ms a tick in a long-lived Emacs (10k
  buffers), most of it consing a buffer list for the collector. That lookup
  is indexed now, but the gate stays here — reading the marks is ~3 µs and
  the whole tick 9 µs, and it derives nothing at all. The price
  is that something has to take the marks away when a turn ends with no event
  to announce it — a killed agent-shell buffer reports nothing — so
  `agent-river--tick` redraws *before* it retires the refresh timer, which it
  did not use to do.

## Conventions

- `agent-river-` is public, `agent-river--` is internal; the split is meaningful —
  `;;;###autoload` marks the entry points and interactive commands.
- Comments here explain *why*, at paragraph length, usually naming the failure the
  code prevents. Match that density; a change that removes a guard should remove
  its comment, and a new guard should say what went wrong without it.
- Tests are named as sentences (`agent-river-test-waiting-outranks-blocked`) and
  assert the reason, not just the value. Helpers: `agent-river-test--with-session`,
  `--fail`, `--acts`, `--payload`, `--with-shell`.
- **Subject** means what an event is folded onto: an `agent-river-state` or an
  `agent-river-artifact`. There are exactly two, and each has the same five
  things — a struct, a fold, a registry, an observer hook and an entry point.
  Anything else keyed in a hash here is a side table for a current-state fact,
  queried where it is read rather than folded, and is not a subject however
  much it looks like one. Where a rule turns on the word, this is what it
  means. Two subjects is not a
  reason to unify anything: the scaffolding that exists per subject is
  duplicated *because* the subjects differ, which is what makes them two.
- **Merge only where there is something to merge.** Sameness of *form* is what
  tempts; sameness of the *question answered* is what licenses. Two things that
  compute alike but answer different questions are two things, and folding them
  together performs a change nobody asked for while wearing the clothes of the
  one that was. The test is not how many callers there are: a count is a
  threshold, and a threshold decides by arithmetic what has to be decided by
  looking. Ask instead what each caller is *for*, and where they part, leave
  them apart and say why.

  Deliberately not phrased as "the same subject", though that is the shorter
  word: **subject** is taken, and by the thing most likely to be confused with
  this — two functions can share one and still answer different questions. That
  is exactly the trap here. `agent-river--map-reach` and
  `agent-river--map-merge-parties` were both about sessions, computed the
  same arithmetic over the same cell shape, and answered *what has this party
  done to this key* versus *what has been done anywhere beneath this
  directory*. Read as "same subject", the rule licensed folding them
  together; read as written, it forbade it. The first is gone with the tree
  listing and `agent-river--parties-by`, which was what the rule *did* allow,
  went with it: one bucket left is not a shared mechanism, it is a function
  taking an argument that can only have one value. That is the rule\'s other
  half arriving later — what licensed the sharing was two callers asking
  genuinely different questions of one arithmetic, and with one of them gone
  the sharing had nothing left to be.
