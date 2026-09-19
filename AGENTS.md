# AGENTS.md

This file provides guidance to coding agents working with code in this
repository. `CLAUDE.md` is a symlink to it, so Claude Code and any host that
reads `AGENTS.md` see the same text.

## What this is

An Emacs package that folds the Claude Code hook event stream into a per-session
*state* (what the agent is working on, which files it revisits, how its tools are
faring) and renders it into `*agent-river*`.

`README.md` is the integration guide — the data model, the entry points and the
extension protocols, written for somebody wiring their own application to this.
It is deliberately *not* the design document any more: **this file is**. The
reasoning behind a decision, and the failure it prevents, lives here and in the
code comments. A change that moves behaviour updates both.

No build system. `agent-river.el` is everything the HUD is;
`agent-river-spool.el` is the door something from outside comes in through,
turning a delivered file into an artifact; `agent-river-launch.el` is the
one thing here that starts a process, pointing an agent at an artifact.
Both are optional and require `agent-river`, and they require nothing of
each other — see the third-direction section for why they were one file and
are not any more. `agent-river-gh.el` and `agent-river-gh.sh` are one
*source* for the spool, and the line they are on the far side of is that a
source knowing about a foreign system lives beside the mechanism rather
than inside it — `river` is the normalised shape and stays in the core, and
the next source (a tracker, a mailbox, a build) goes next to the GitHub
one. `agent-river-tests.el` is the ERT suite for all of it,
`agent-river-hook.sh` is the bridge, and there is one example hook wiring
per host — `claude-settings.json`, `codex-hooks.json`,
`gemini-settings.json`.

## Commands

```sh
# Full suite (436 tests). -L . is required: the tests require all four .el files.
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
(agent-river-touching "agent-river.el")  ; which sessions have reached this file
(agent-river-report)                     ; own state, as a plist
(agent-river-set-intent "chasing why the spinner sticks after a kill")
```

`agent-river-touching` is the one that carries something you do not already
have. Another session, in another worktree, editing the file you are about to
rewrite leaves no trace in your own transcript; the registry is the only place
that fact exists. Worth asking before a wide edit, and the answer is advisory
— there is no lock behind it, and two agents backing off is as likely as one.

The other two address a *session*, and cannot reliably tell which one you
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
  → agent-river--update-panel / agent-river-log     the view
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
  session's own artifact tables, which is what `agent-river-touching` and the
  map already read.
- **The one measurement a delegated failure stays out of is the streak**
  (`agent-river--delegated-p`). Three subagents failing once each is not one
  line of work failing three times, and the streak is what a signal is built
  from — so a merged streak would put a false statement into the session's own
  context. Everything else about the failure is counted: the task tally, the
  tool tally, and the child's own entry, which says whose it was.
- **Two frames, always labelled.** `artifacts`/session-wide survives a new prompt;
  `task-artifacts`/`steps`/`task-failures`/`said` reset on `prompt`. Report keys say which
  (`:task-hottest` vs `:session-hottest`). The panel uses the task frame;
  `agent-river-touching` uses the session frame.
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
- **One log line is one line** (`agent-river--log-text`). The HUD is
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
  and the key back together deliberately (`agent-river--heat-absolute`). Resolving is strictly
  worse than matching on the name for *identity* questions and strictly better
  for *placement* ones, so both readings exist and each says which it is: file
  shading still matches on the basename, directory aggregation resolves.
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
  aggregated at read time (`agent-river--heat-entries`,
  `agent-river--map-reach`). That split is what keeps the frames out of the
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
  `agent-river--heat-absolute` therefore answers **nil** for a non-file key,
  which is what every existing caller already does the right thing with:
  resolved against a cwd, `inc:INC-444` became `/repo/inc:INC-444`, a file in
  a tree it has nothing to do with, which every view would then draw, shade
  and eventually offer to delete. That is the mistake the anchors were folded
  to stop, one domain over. `agent-river--heat-place` is the second reading
  beside it -- "which artifact" where the other says "where on disk" -- and
  it is what the position marker, the party floor and the section listings
  actually want. **Which domains are in play is derived too**
  (`agent-river-domains`, narrowed by `agent-river--map-live-domains`). It
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

Anything that reaches outside this package — shading dired, pulsing a line,
notifying, writing a file — is an *observer*, not a fold branch. `dired`
heat/pulse (`agent-river-heat-mode`) is the worked example; read it before
writing a second one.

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
  consumer's side by basename (what `agent-river-touching` matches on); read an
  extra event key the fold keeps out of the artifact keys (`:path`, the
  absolute name, carried beside `:file`); or resolve a key against
  `agent-river-state-cwd`, falling back to its `anchors` entry where the cwd
  cannot place it (`agent-river--heat-absolute`) — the only one that can place
  a key in a directory tree and the only one that re-splits a worktree from its
  main checkout. Reach for the third when the question is *where*, not *which*.
- **Off by default, and the gesture that turns it on is what turns it off.**
  Writing into buffers the user did not point this at needs consent, which is
  what the global minor mode is for (`agent-river-heat-mode`). A consumer that
  draws only into a buffer of its own needs no mode: opening that buffer is the
  consent and killing it is the retirement (`agent-river-map`, via a local
  `kill-buffer-hook` that is also the `agent-river-retire` property). What does
  not change either way is that there is exactly one gesture and it is
  reversible.
- **The timer stops when nothing is left to *change*, which is not the same
  as nothing being shaded** (`agent-river--map-cooling-p`). Two thresholds
  fade at different depths: the shading runs out at the bottom of
  `agent-river-heat-levels`, `agent-river-map-party-floor` sits below it, and
  asking only the first retired the map's timer while names were still on
  screen waiting to cross the second — so the map froze mid-fade. A name held
  by the `:current` exemption is not cooling and must not keep the timer
  alive either; it never crosses anything. What no timer here can see is the
  disk: a file that comes back while no agent is working redraws on the next
  event or on `g`, the way a dired buffer does.
- **Redraw on a timer, not per event, once the view is bigger than a line.**
  The runner fires on every tool call. Rebuilding a whole listing that often
  moves point under whoever is reading it, thousands of times a task. The
  observer marks dirty and ensures the timer (`agent-river--map-observe`); the
  timer decides how often dirt is worth acting on, and retires itself when
  there is neither dirt nor anything left to cool. **Which is why anything
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
`agent-river-heat-scope`) and say which one the view is showing.

### Producers — the other direction

A *consumer* turns state into an outside effect and hangs off
`agent-river-observers`. A *producer* turns something only Emacs can see into
an event, and hangs off whatever Emacs hook or outside source sees it — not
off `agent-river-observers`, which fires on the agent's events, not yours.
Two ways in: `agent-river-note`, for something about a session, and
`agent-river-appeared`, for something that belongs to no session at all.

```
hooks -> fold -> observers -> outside world    consumer (agent-river-heat-mode)
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
- **The context line is the panel's reading, one field shorter.** It goes
  through `agent-river--artifact-list` rather than `agent-river--hottest` so
  the two cannot disagree about which file it is; the `(N touches)`
  parenthetical is dropped because it is the longest thing on the line and
  the least of what a decision turns on.
- `agent-river--scan` **grew a SETTLE argument rather than a third copy of
  the loop.** What differs between these buffers is only where the text on a
  line starts.

### The block is flat, and a session line is a top-level line

Session lines sit at level 1, one per live session, ordered by label. There
was a grouping here once — a heading per *place*, asked for through
`agent-river-panel-place-functions` and defaulting to the session cwd, with
everything under it pushed a level down — and it is gone, so
`agent-river--star` and `agent-river--panel-details` take no level and
`agent-river-block` holds a plain session id rather than a tagged key. What
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
  `agent-river-domains` -- what the table has -- and pointedly not from
  `agent-river-map-domains`, which is documented as purely presentational: a
  view's settings must not decide what a producer may declare, and reading it
  would have offered domains nothing ever arrived under while the ones that
  did went unlisted.
- **Everything is checked before anything is folded.** Declaring and then
  failing to reach leaves a record nobody asked for, which only
  `agent-river-drop-artifact` takes back -- so the session is looked up while
  there is still nothing to take back. A test pins it.

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
  the context and `agent-river-launch-brief`, which is the user's own code,
  reads it back out.
- **Two switches, and the sharp one is the brief.**
  `agent-river-launch-launcher` says whether anything can launch at all;
  `agent-river-launch-brief` returns what to say about a given artifact, or
  nil, which is the arming switch — a launcher with no brief can never
  launch. One function rather than one per domain, because dispatching on
  `:domain` is two lines inside it and a second mechanism deciding one
  question is what this package spends its exceptions avoiding.
- **Unavailable is absent** (`agent-river-launch--launcher`,
  `--available-p`). Asked at selection, so "this cannot run here" is the
  first thing said rather than the last: asked at the launch, the user was
  prompted to confirm something that then failed. Read every time, because a
  package loaded after Emacs started makes its launcher available without
  anything here being told.
- **Launching asks first** (`agent-river-launch-artifact`). Starting a
  process is the most expensive thing this package does and the one gesture
  with nothing on the far side that can take it back. It is also suitable
  as a `:visit` in `agent-river-map-domains`, which is what makes RET on a
  line of the map start an agent on it — the whole of "launching happens
  from the map", with no new keymap and no change to `agent-river.el`.
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
  about a window that has passed.
- **A source registered by an autoload needs an autoload of its own**
  (`agent-river-gh--read`). The `with-eval-after-load` form puts the reader
  into the alist at startup; without a cookie on the reader, the entry is a
  symbol with an empty function cell, and since the reader runs inside
  `agent-river-spool--take-in`'s guard every `gh` delivery is then read as
  malformed and filed under `failed/`, which nothing re-reads. The same
  silence is why the poller is handed `AGENT_RIVER_SPOOL` — bound into
  `process-environment`, since `make-process` has no `:environment` argument
  and ignores one without complaining.
- **The prompt is still quoted, and the reason has changed** (`agent-river-gh-brief`).
  An issue is text written by whoever can open one and it reaches an agent
  holding tools. With a person in the loop the person is the defence, so the
  quoting is a courtesy rather than the whole of it — and it is kept anyway,
  because it is what has to be right on the day #37 is built.

### One set of motions, every buffer

The HUD, the map and the approval queue take the same keys for the same three
grains, because they are views of one state and learning each separately buys
nothing: `n`/`p` (plus `SPC`/`DEL` and the remapped arrows) walk every line
worth stopping on, `M-n`/`M-p` walk the coarse structure, `>`/`<` walk the
lines that want attention. A session line is a map entry is a question
heading; a
detail heading is a map file line is an answer row; a log line has no analogue
and rides the fine grain. The map's *section* headings have no analogue in
the block, which is flat. `>` is `agent-river-notable-kinds` in the HUD —
which includes `artifact`, because a record arriving is one step further out
than a note (nobody in the session saw it) and it lands when nothing else is
happening, which is when a log is worth scanning at all — "some
agent is under this" on the map, and in the queue it coincides with `M-n` —
bound all the same, because a reader arriving from either of the others
presses it expecting the next thing that wants them, and getting it is the
whole point of the keys being shared.

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
command, and the reason `agent-river-test--hud-lines` has to test the current
line before it starts scanning.

**The HUD follows only the windows still at its head** (`agent-river--head-end`,
`agent-river--following-windows`, read *before* the edit because the edit moves
the head). It used to pin every window to `point-min` on every event, which
makes the buffer unreadable by hand and would have made these motions
pointless. Two halves to it: window points are filtered, and `agent-river-log`
wraps its edit in `agent-river--keeping-place` — in the selected window buffer
point *is* window point, so without it the one window most likely to be the one
being read was dragged back to the top regardless.

**The head is the top line, and a block line is kept by name rather than by
position.** Both halves above were measured against the whole head — the block
*and* the newest log line — and the block is where `n` and `M-n` do most of
their walking, so navigating anywhere in it left a reader still counting as
following and the next tool call pulled them back. Three ways the point ended
up at `point-min`, and each needed its own answer. A window navigated into the
block was filtered back in, so the head is now the first line alone: that is
exactly the span `agent-river--follow` pins to, so it means "nobody has moved
this", and a reader who walks back up to the top rejoins the head the way they
left it. A *buffer* point in the block was inside the region
`agent-river--erase-block` deletes, so `save-excursion`'s marker collapsed to
`point-min` and the rebuilt block went in front of it — silently, on every
refresh tick, which is the block redrawing itself out from under whoever was
reading it. So block lines carry `agent-river-block` (the session id, plus an
index for a detail line) and `agent-river--block-goto` finds the line again by
what it names, the way `agent-river--map-here` does one grain up; a session
that has gone from the block sends point to the head rather than to whatever
that line number now holds. And the newest log line begins exactly at
`agent-river--block-end`, so a marker there was swept up with the block like
any other — it is the one log line that does not ride the text on its own, and
the marker is given an insertion type to keep it in front of what replaces it.
Everything else the log edits is above a reader's position, so their marker
rides the text rather than the offset.

`hl-line-mode` is on in the map and deliberately off in the HUD: the HUD pins
its point to the head until someone navigates, so a permanent highlight there
would mark nothing anyone chose.

### What it costs — a meter read from outside, drawn as a shape

`agent-river-spend-width` puts a braille graph of a session's spending on its
block line (`|⣶⣶⣷⣴⣀⣀|`), one bar per `agent-river-spend-interval`, and
`agent-river-spend` reports the totals. The figure is agent-shell's: the ACP
`usage_update` notification carries a running cost and `agent-shell--state`
holds the latest one. It only ever goes up, so read on its own it says what a
session has cost and nothing about whether it is costing anything *now* — the
difference between two readings says that, and the graph is those differences.

- **The first reading of a session is not spending** (`agent-river--spend-record`).
  A cumulative figure attributed to the moment we first looked draws the whole
  history as one spike, and the session Emacs has just adopted — reloaded into,
  or started watching mid-task — is exactly the one that would draw the biggest
  one. The first reading establishes `:since` and nothing else.
- **A bar holds what was reported in it, not what was spent in it.** Measured
  on 2026-09-19: agent-shell's figure moves once a *turn* rather than steadily
  through one, so a twenty-minute turn lands in the bar it ended in instead of
  across the four it ran through. Spreading it back over them would read better
  and would be an invention — nothing says the money went evenly — so the
  reading stays where the measurement is. The practical consequence is that the
  graph's real resolution is a turn, and a session taking two long turns an
  hour draws two spikes rather than a curve.
- **A falling figure never rebases the total** (`agent-river--spend-record`).
  `:total` is the high-water mark, not the last reading. A figure that goes
  down is somebody else's arithmetic — a server reconnecting, an agent whose
  `usage_update` reports the turn rather than the session — and storing the dip
  would understate the session in `agent-river-spend`, which presents the
  number as a fact, and then measure the next genuine rise from the lower base
  and land it as one inflated bar. That the meter only goes up is an assumption
  about another package, so it is enforced here rather than trusted.
- **The money is named or not named, never guessed** (`agent-river--spend-money`,
  `:currency`). `agent-river-spend` is the one place the figure itself is shown,
  so it carries the currency agent-shell named and sums **per currency**: a
  table of bare numbers added into one headline is how two currencies become a
  total true of neither. A later reading that carries no currency does not
  unname the money, because only the notification carrying a cost carries one.
- **The sweep is over the table, not over the session being written**
  (`agent-river--spend-trim`). Trimming only the one being recorded left a
  session that has stopped being sampled holding its last bars for as long as
  this Emacs runs, and made `agent-river--spend-max` walk every session ever
  seen rather than the ones still spending — which is what makes the per-line
  walk, and the memo rejected beside it, the right trade rather than a lucky
  one. The *entry* is deliberately not dropped: its total is what answers for
  a session whose buffer is gone.
- **The read retires on its first error, and says so** (`agent-river--spend-sample`).
  `ignore-errors` was the first answer and it was the quiet half of the house
  rule: this reads another package's internals on every tool call, so a shape
  that moves would stop the graph for ever with nothing anywhere saying why.
  The observers' idiom instead — guard, log once, stop — and `agent-river-reset`
  is where it is given another go, since a reload may well be the fix.
- **Sampled per event, never on a timer.** A timer would have to run through
  the quiet, which is most of the time and is precisely when there is nothing
  to measure: a session that is not working is not spending. Events arrive
  thickly while an agent works, so the resolution lands where the movement is
  and there is no timer to keep alive, retire or explain. It also means the
  sample is taken outside the fold's guard and wrapped in its own, because a
  meter that cannot be read must not be able to report itself as `fold failed`
  and send somebody to `agent-river-reset`.
- **A side table holding a history, which is the exception to the rule rather
  than an instance of it** (`agent-river--spend`). `agent-river--offers` is a
  side table because a pending question stops being true; this is a history of
  point-in-time facts, which is what the fold is for. Two things buy it. The
  fold's promise is that a state can be rebuilt by replaying its events, and
  **no event carries a cost** — no hook payload has one — so a slot would hold
  transitions the event stream could never account for. And a slot cannot be
  added without `agent-river-reset`, which throws away every session's folded
  state; paying that for a decoration, in a package reloaded into a live Emacs
  several times an hour, is the wrong way round. What a reload costs is the
  shape of the last hour, never the totals: those are agent-shell's figures and
  come back with the next event.
- **One scale for the whole block** (`agent-river--spend-max`). Scaled against
  its own maximum, a dozing session's small change and a busy one's burst both
  draw a full bar, and two lines one above the other say the same thing about
  spending an order of magnitude apart — which is the whole of what a stack of
  graphs is read for. The scale is recomputed per line rather than memoised for
  the draw: a handful of sessions with a few dozen bars between them, where the
  memos of `agent-river--map-draw` were 700 walks of a table, so a dynamic
  binding to get right would cost more than it saved.
- **The bottom level of four is spent on blank versus zero**
  (`agent-river--spend-height`, `agent-river--spend-graph`). A bar the session
  was alive for and spent nothing in draws one dot; a bar from before it was
  first read draws nothing at all. "Here and idle" and "not here" are different
  statements and the graph must not merge them — so blankness is decided by the
  *range*, from `:since` and the table's horizon, and never from an amount.
  That leaves three levels for the value, which is coarse on purpose: the graph
  answers when the money went and the figures beside it answer how much.
- **Every graph is the same length; the line around it is not a column and
  cannot be made one** (`agent-river--spend-column`). This is *not* the map's
  diffstat rule and the analogy was wrong when it was first written here: the
  listing there has aligned prefixes, where a block line is `· `-joined parts
  of whatever width they happen to be — a label, a truncated but unpadded task
  — so what follows the graph already sits somewhere different on every line.
  What the padding buys instead is that two graphs can be read against each
  other, which works at different columns because the rightmost bar is *now* in
  each one wherever it starts, and that a line's own tail stops jumping when
  its session is sampled for the first time. Padded with blank braille rather
  than spaces, so an empty one is exactly as wide as a full one in whatever
  font draws them.
- **Reserved while a session the block is *drawing* has been sampled**
  (`agent-river--spend-measured-p`), and pointedly not while the table is
  non-empty. An entry outlives its session on purpose so that
  `agent-river-spend` can answer for one whose buffer is gone, so asking the
  table whether it holds anything would keep an empty column on every line of
  an Emacs whose agent-shell sessions all ended hours ago.
- **It is in neither frame, and sits between the two readings it belongs
  with.** Every other number on the line is the task's and resets on a prompt;
  this covers a fixed window that runs straight through one. It goes between
  what the agent is doing and how long it has been at it, because those two are
  the same question over the same stretch of time.
- **The total is a query, not a line** (`agent-river-spend`). A total across
  sessions belongs to no session, so it would need a line or a header of its
  own, and this view has spent one of those before and taken it back. The
  totals outlive the buffers they were read from, which is the one thing
  reading `agent-shell--state` directly cannot do.
- **The hooks carry none of this**, so a session run from a terminal has no
  graph — the same price the `◇` and `“` lines pay, and paid the same way
  rather than routed around by reading `transcript_path` per event.

### Markdown belongs where the state leaves, not where it is watched

`agent-river-markdown` / `agent-river-copy-report` render the state for an
issue, a PR or a message. The HUD is deliberately *not* Markdown and must stay
that way: its log carries prompts, reasoning and tool arguments — text the
package does not control — and Markdown would hand that text the power to
restructure the view watching it. A prompt beginning `# ` becomes a heading.
Wrapping the whole payload in code spans would fix that and destroy the
per-kind colouring that is the HUD's main signal.

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

### The two views of the artifact tables

`agent-river-heat-mode` shades the dired buffer you are already in.
`agent-river-map` (`*agent-river-map*`) is the lens over it: one directory
listed in full, each entry annotated with what has happened *beneath* it, so
several agents spread over a large repository are visible at once. Same
weighting, same `agent-river--heat-entries` derivation, different grain — so
the two cannot drift.

Four things about the map are load-bearing:

- **There is no reference project, so the map opens on all of them.** The
  state spans whatever directories the sessions were started in; a heading
  naming one of them — the most recently seen, as it used to be — reads as
  though that tree were the project and the others were somewhere inside it.
  `agent-river--map-root` nil is the overview, and each tree heads its own
  section (`agent-river--map-all-roots`). Setting it is a *zoom*, which is
  where RET goes and where `^` comes back from: at a touched root `^` returns
  to the overview rather than climbing into directories no agent has been
  near. One tree is drawn without a section heading, since the header already
  names it and repeating it would indent the listing to say nothing — which is
  also why a file passes `file` to `agent-river--map-marker` rather than a
  number, so that pushing entries down a level for the root headings cannot
  push files into being headings too. Folds are keyed on absolute paths for
  the same reason: `src` under one root is not `src` under another.
- **A repository's worktrees are one tree, and only the map ever thought
  otherwise** (`agent-river-map-worktrees`, default on; `w` splits them for
  one buffer). Artifact keys are relative to the session cwd, so `src/foo.el`
  in a worktree and in the main checkout is the same key and
  `agent-river-touching` has always answered for both at once; it is
  *placement* that split them, in the two places placement is decided — a
  root is a session's cwd, and `agent-river--map-reach` relativised against
  one prefix. `agent-river--map-groups` sits above `agent-river--map-all-roots`,
  which stays the state's own reading, and merges roots that git says share a
  `--git-common-dir`; `agent-river--map-member-trees` is what the rest of the
  draw reads, so the listing, the reached paths, the changed paths and the
  diffstat cannot come to different conclusions about what a section is
  showing. Six things it owes. **Merging only where there is something to
  merge** — the general rule is in **Conventions**; this is the case that paid
  for it. Two *trees* of one repository, both in the state: grouping
  unconditionally would widen a session started in `repo/backend` to the whole
  checkout, which is a different change wearing this one's clothes. **The
  section is headed by the main worktree even when no agent is in it**, which
  is not a tree becoming a section for being dirty but the repository the
  worked trees belong to — naming it after the busiest sibling makes one
  worktree look like the parent of the others. **The party carries its tree**
  (`alpha@feature-x`): merging answers "is this the same file" and would
  otherwise delete "where is this agent working", which is the more pressing
  of the two once worktrees are in play. **The listing is the union** — a file
  living only on one branch is on one member's disk, and listing the head
  worktree alone drew it struck through, a deletion the map made up. **The
  diffstat is per tree** and therefore a row apiece: two worktrees are two
  working trees on two branches, and summing them states a number true of no
  tree. The column then follows the work — one answer is the column as ever,
  two answers go to the tree this line's agents are in, and it is given up only
  where even that is ambiguous. Which is also why a landing is counted with
  `agent-river--map-writes` *per tree*: asked of the whole line, every merged
  file was "in the main branch" in the checkout on the strength of somebody
  having rewritten it on a branch. And **what git says is cached without a
  TTL** (`agent-river--worktree-cache`) — which worktree a directory is in
  changes about as often as the directory does, a worktree added later is a
  new root and asked on its first draw, and `g` is where a tree that has been
  moved or pruned is noticed. The read is asynchronous like every other, so
  the first draw shows the trees apart and the answer merges them a moment
  later; `agent-river--git-run` is the process without the diffstat's
  in-flight counting around it, because a `rev-parse` holding that counter
  open would stop a tree being read for a question it was not asking.
- **Depth only where there is activity.** A whole tree unfolded is unreadable
  in a monorepo, so RET descends (`agent-river-map-descend`) rather than
  widening, and a file five directories down is shown under the one entry the
  listing has a line for, with the rest of its path inline.
- **A name fades like the shading does** (`agent-river-map-party-floor`).
  The shading has always had a floor — `agent-river-heat-levels` runs out at
  1, below which there is no face and no overlay — and the name in the
  brackets had none. The weights decay exponentially, so they approach zero
  without reaching it, and after an hour in a small repository every file
  carried a name and every line read alike. A view where everything is marked
  marks nothing. Two things hold it together: **a party that still exists is
  never dropped from the one file it reached most recently**, whatever that
  weighs, because cold is not the same as gone and that file is the answer to
  "where is this agent now" — so a quiet map settles at one line per agent
  rather than at none; and the floor is applied at **both** reads of the
  artifact tables (`agent-river--map-live-p`, asked by
  `agent-river--map-all-roots` and `agent-river--map-reach`), since a root
  kept alive by a touch too cold to name would head a section with nothing
  under it.
- **A party that is gone keeps no file, and no marker** (`agent-river--gone-p`,
  applied in `agent-river--map-newest`). Both of the readings above are
  present tense, so for a session that has ended they claim a position on
  behalf of nobody — and the exemption made that permanent: an agent-shell
  buffer killed, and its name and `⏿` stayed pinned to one file for as long as
  the registry held the state, since nothing decays past a floor it is exempt
  from. Left out of the `newest` hash, a gone party loses the marker at once
  and the name fades at the floor like any other. Three things to keep:
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
  buffer; without that the map goes on naming it until someone presses `g`.
- **The header is a name and a count, not a legend**
  (`agent-river--map-header`). It carried the frame the numbers were read
  from and, once the diffstat arrived, that the diffstat was read from HEAD
  instead — two facts that are true, do not change, and were being redrawn
  every few seconds onto a line that is read once. A legend belongs where the
  thing is decided (`agent-river-map-scope`, `agent-river--map-stats`), not
  in the view. What stays is what *moves*: which tree is being shown, and how
  many agents are in it. That count is of agents that **still exist**
  (`agent-river--gone-parties`), not of names on the map — a name outlives
  its session on purpose, fading through `agent-river-map-party-floor`
  because the file was still touched, so counting names would report an
  audience that has left as though it were still there.
- **A file that is gone is struck through, not dropped**
  (`agent-river-gone`, set on `:missing`). Removing them was tried first, in
  two shapes, and both lost something. Dropping a deletion outright throws
  away the deletion itself, which is a thing the agent *did* — and it would
  make the map flicker every time a branch switch took files away and put
  them back. Refusing them only the `:current` exemption was narrower, but it
  left an agent whose last act was a deletion named nowhere at all, and
  losing a party off the map is the worse of the two readings. The worry
  behind both — that `:current` on a vanished file reads as "the agent is
  here" — was a rendering problem, and it is fixed where it was: struck
  through, the line says the agent's last move was into a file that has since
  gone, which is true and worth knowing. Everything else about them is
  ordinary: they fade at the floor like any other name. The strike is asked
  of a file line too, not only of a top-level entry — a deletion three
  directories down used to draw as an ordinary line, which stopped being a
  corner case once `agent-river-map-dirty` began reaching deletions through
  git, where one is a change like any other.
- **A node's rows are contributed; the line is their summary**
  (`agent-river-map-contributors`, `agent-river--map-rows`). The line carries
  what can be read *down* the listing — shading, the two markers, one
  fixed-width column — and everything else lives in rows under the node. The
  party names used to be on the line and were the one ragged thing on it,
  which is why nothing scannable could ever follow them; moving them into
  rows is what freed the column that `:summary` now competes for. **The line
  is a projection of the rows, never a second account of them** — the same
  rule the listing follows one grain up, where a directory's reading is the
  aggregate of what lies beneath it so the two cannot disagree. Rows are
  **detail, and wait to be asked for**: a node whose only children are rows
  draws closed, and the same TAB that hides a directory's files opens it, so
  there is one mechanism rather than two and no disclosure twisty to invent.
  They were enrichment and detail at once — drawn wherever there were any —
  and in a listing whose entries are mostly files that is a row or three
  beneath every line the map has, so the view read as a stack of rows with
  names threaded through it. What stays enrichment is a directory's *files*,
  because those are the listing one grain down rather than an annotation on
  it, and that is the whole of what `agent-river--map-open-p` now asks. The
  price is that the party names are behind a keystroke, having just been
  moved off the line: the gutter's `⏿` and `>`/`<` still say some agent is
  here, and who it is is now a question you ask the line. Deliberately no
  setting to put the old default back — TAB already asks per node, where a
  reader is looking, and a buffer-wide answer to the same question is the
  second mechanism this design spent its one fold avoiding.
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
- **What an asynchronous read costs is round trips, not the command.**
  Measured on this machine: git answers in ~1 ms, `make-process` costs
  0.1 ms, and each sentinel is another ~1–2 ms through the event loop — so a
  chain of four reads spent almost all of its time waiting to be told the
  last one had finished. The diffstat's reads therefore run *beside* each
  other behind a counted barrier (`agent-river--vc-claim` counts reads, it
  does not hold the last process, or the first to finish would clear the
  flag while its sibling was still running), and the main branch is
  remembered in the cache rather than resolved again every time. Cold ~11 ms
  to the landed marker, warm ~8 ms — and **what a reader waits for was never
  that**. The answer used to sit in the cache until the next tick of
  `agent-river-map-refresh-interval`, behind a read that did not start until
  the cache was `agent-river-map-vc-ttl` (then ten seconds) old: about
  thirteen seconds end to end for eight milliseconds of work. An answer
  landing now draws the map (`agent-river-map-contribute`), debounced by
  `agent-river--map-contribution-delay` so answers arriving together make one
  draw, and the TTL is three seconds because the measurement says a read
  costs a third of a percent of the interval it sits in. Draw-to-shown is
  ~60 ms. A **floor on how recently the map was drawn** was tried first and
  was exactly backwards: a read is started *by* a draw and answers ten
  milliseconds later, so every answer there has ever been arrives inside the
  floor and none of them drew.
- **The diffstat is a contributor like any other** (`agent-river--rows-vc`),
  and that is load-bearing rather than tidy. It is the asynchronous case, the
  batched case and the aggregating case at once, so if the protocol needed an
  exception for it the protocol would be wrong. Its row spells out what its
  `:summary` abbreviates, in the one place where letting the two drift would
  have been most tempting.
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
- **A row the line already carries is not drawn under it**
  (`:summarised`, `agent-river--map-said-p`). `- +529 -122 vs HEAD` beneath
  a line reading `+529 -122` is the line's own reading written out a second
  time — the thing the projection rule exists to prevent, arrived at from
  the other side. Dropping it is that rule applied rather than broken: the
  row still *produces* the column, which is why it is still asked for it,
  and only the repetition goes. Three things hold it: the map never judges
  redundancy by looking, because `+2 -1 vs HEAD` and `+2 -1 vs HEAD in 12
  files` differ by a fact no column can hold, so the **contributor declares
  it** per row; it applies only where the **column is actually reserved**,
  since with nothing holding the width open the row is the whole answer;
  and it is decided **per contributor, not per row** — a set with one row
  taken out of it reads as the line's number belonging to whichever rows
  are left, which in a merged repository is the wrong worktree. The filter
  runs before the fold marker is chosen, so a node whose only row the line
  carries shows no twisty rather than one that opens onto nothing.
- **Order is declared, not positional** (`:rank`, low first, ties keeping
  the order of `agent-river-map-contributors`). Which contributor was
  registered first is not a statement about which of their rows is worth
  reading: what is happening in the file *now* (`step`, rank 0) outranks
  who has been in it (`parties`, 1), which outranks the state of the tree
  (`vc`, 2). It is also what `agent-river-map-detail-rows` cuts from — the
  tail is the least worth keeping rather than whoever was registered last.
- **Rows ride the fine grain only.** `n`/`p` stop on them; `M-n`/`M-p` skip
  them (`agent-river--map-row-line-p`, since a row inherits its node's path
  and cannot be told apart by the path alone); `>`/`<` pass over them because
  they carry no `agent-river-map-active` — that motion is for finding the
  agents, and a contributor able to put itself on it would be competing for
  the one gesture that is about them.
- **Fading is not finishing** (`agent-river-forget-artifacts`). The floor
  handles the everyday case on its own, but work that has just landed — a
  merge, a release — is history rather than cold, and only the user knows
  which has happened. The command empties the artifact tables and the anchors
  with them, and nothing else: steps, failures and the task survive, so it is
  not `agent-river-reset` in a smaller hat. It goes through the fold as a
  `forget` event rather than clearing the tables where the command is
  written, because the fold owns the state. Deliberately not on the map's
  keymap: it throws measurements away, and a single keystroke in a view
  buffer is the wrong gesture for that.
- **A deletion is news, and then it is history**
  (`agent-river-forget-gone-files`, `C` in the map). The strike-through keeps a
  gone file on the map on purpose — the deletion is a thing the agent did — but
  after a merge or a cleanup those lines are a list of what used to be there,
  and only the user knows when that moment came. So it is a command, not a
  rule. Three things hold it apart from the one above, which is what earns it a
  key in a view buffer. Its **subject is already gone**, so what is lost is the
  record of an absence rather than the record of the work. It is **measured
  against the disk, never against the strike-through**: an entry is also drawn
  as missing when it was reached through an anchor the listed root has nothing
  to do with, and that file is elsewhere rather than gone — so such a line
  stays struck through afterwards, which looks like the command missing one and
  is the command refusing one. And a key **nothing can place is unplaceable,
  not gone** (`agent-river--artifact-gone-p` goes through
  `agent-river--heat-absolute`, so the anchor wins over the cwd), or a state
  folded without a cwd would have every artifact it ever recorded swept away by
  a command that found none of them. It narrows the same `forget` event with
  `:files` rather than adding a kind of its own: the transition is identical
  and only its subject differs, and a second kind would be a second place for
  what forgetting means to be decided. It asks first, because nothing undoes it.
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
- **Weight and position are different readings.** The numbers say where an
  agent has *been*; `:current` says where it *is*, and after a long task those
  are different places. `:current` is computed across everything a party
  reached, not just what falls under the map root, or descending would invent a
  second "most recent" file that only looks like one because the real one is
  out of view.
- **The listing is filtered to what is known about, which is no longer only
  what was reached** (`agent-river-map-untouched` nil, the default; `a`
  toggles it for one buffer). Agents spread over several roots turn the full
  listing into mostly context — every sibling of every tree anyone started a
  session in, with the handful of lines that carry an agent somewhere among
  them. What the filter gives up is breadth: a view of only the touched paths
  says where without saying where that is *relative to* anything, which is
  what the full listing was for, and non-nil buys it back as the union of
  disk and state. **Activity the map does not show is the one thing it exists
  not to do**, so the filter drops an entry for having nothing known about it
  and never for being absent from disk — `:missing`, an entry the disk does
  not have (deleted, renamed, or reached through an anchor this root has
  nothing to do with), is precisely what a disk-shaped filter would have
  swallowed. An empty listing says which kind of empty it is: a filtered tree
  full of files nobody has been near would otherwise read as a map that had
  lost them.
- **The working tree is the listing's second source, because the fold has a
  blind spot it can never close** (`agent-river-map-dirty`, default on,
  `agent-river--map-changed`). A file is counted when a tool *names* one, and
  a shell command names none: `sed -i`, `rm`, a formatter, a codemod, a `git
  checkout` all change files through a call whose only argument is a string of
  shell. No amount of teaching `agent-river--tool-file` new keys reaches
  those. Git can, so an entry earns a line for differing from HEAD — staged
  and unstaged alike, plus what git has never seen — and it is the same table
  the diffstat column is already read from, so this costs no further
  subprocesses. Four things it owes. Such a line has **no parties, and that is
  the whole truth of it rather than a gap**: git cannot say who changed a
  file, which is the same reason the diffstat is not an attribution, so the
  brackets stay empty and the column says what is different. It follows that
  a changed name **is not activity** — `>`/`<` pass over it (no
  `agent-river-map-active`, which is read off the parties), and it is what
  `agent-river-map-ignore` is allowed to drop, where a *reached* name is
  listed whatever it matches. It **reads the cache and starts nothing**
  (`agent-river--vc-cached`), because the read is the contributor's to
  schedule on its own TTL and a second caller would race it; the first draw of
  a root therefore shows what was reached and the answer lands a moment later,
  which is what `agent-river--vc-store` marking the map dirty is for. And it
  brings a **different tense** onto the map: a reached name fades out through
  `agent-river-map-party-floor`, a changed one stays until it is committed or
  thrown away, which is git's answer and not this package's — in a tree with a
  great deal of uncommitted work that is most of the listing, and the reason
  this is a setting at all. Roots stay state-derived (`agent-river--map-all-roots`
  reads `agent-river--heat-entries` alone): a tree nobody has worked in does
  not become a section for being dirty, or the map would be a second
  `magit-status` rather than a view of where the agents are.

- **A section need not be a directory** (`agent-river-map-domains`,
  `agent-river--map-domain`). A non-file domain heads a section of its own,
  and **the section's listing is the artifact table itself** -- which is why
  there is no per-domain listing function to write: a record already carries
  its name, whether it has ended, and whatever context its producer put on
  it, and asking a domain to answer those again would be the second account
  that table exists to avoid. Five things it owes. **Registering one is
  optional and only about presentation** -- `:label` and `:visit`; a domain
  absent from the list is still drawn, because something that has arrived
  must not wait for configuration before it can be seen, which is the failure
  mode of every dashboard that has to be taught about a new source. **An
  unreached record is still listed**, which is the opposite of what
  `agent-river-map-untouched` decides for a tree and deliberately so: there
  the unreached entries are the rest of the disk and swamp the few that
  matter, here an unreached record is a thing nobody has picked up, the
  single most important line this view can carry. **git is asked nothing**
  (`agent-river--domain-p`, the guard `agent-river--rows-vc` and
  `agent-river--refresh-vc` begin with) -- a diffstat is a reading of a
  working tree and a domain has none, and answering something rather than
  nothing would reserve the fixed column across the whole buffer for a number
  only half the sections could carry. **A line is identified by its key**
  (`agent-river--map-node-path`), never by an expanded path: expanded, the
  identity would depend on whatever `default-directory` happened to be, and
  two maps drawn from different buffers would disagree about which line was
  which. And **domain roots are appended after the grouping**
  (`agent-river--map-groups`), not folded into it -- a domain has no
  worktrees to merge and no `--git-common-dir` to ask for, so putting one
  through that loop would run a subprocess over a name that is not a path.
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
- **An ended record is struck through, like a gone file** -- `:missing` set
  from `agent-river-artifact-gone`, saying the same thing for the same
  reason: it was worked on and is over, which is history and stays until
  somebody says otherwise (`agent-river-drop-artifact`, which leaves the
  sessions' tables alone -- they reached it, and that stays true whatever
  became of the thing at the other end).
- **The context rows are an ordinary contributor** (`agent-river--rows-artifact`),
  gated on the *lookup* rather than on the section being a domain's: one
  special case fewer, and a record declared against a key the map already
  draws annotates that line too. It is also what makes it cheap -- the
  artifact table holds only what was declared into it, so the lookup misses
  for every ordinary line on the map. This package never reads a value out of
  a context, which is what lets a record hold a severity, a body and a URL
  without this file learning about any of them; the rows are escaped like
  every other contributed row, since a context cell is the least of our text
  there is.
- **The diffstat is the one fact on a line the fold cannot produce**
  (`agent-river-map-vc`, default on). Weight says how heavily a name was
  reached, and an agent that read a file forty times and one that rewrote it
  once weigh the same — so `(+10 -6)` is read straight off the working tree
  instead. It is neither folded nor observed: a diffstat is a *current-state*
  fact in the producer sense, true of the disk now and wrong again by the next
  write, so it is queried where it is read (`agent-river--vc-stats`) the way
  `buffer-modified-p` is, and nothing downstream of the fold knows it exists.
  Four things it owes. It is **not an attribution** — git cannot say who
  changed a file, so a line's stat is about the tree beneath that name and is
  deliberately *not* intersected with what the agents reached, which would read
  as "the agent changed this much" and become a lie the moment a human edited a
  file the agent only read; the brackets say who has been here and the column
  says what is different. It **never blocks** — two subprocesses per root,
  asynchronous, cached for `agent-river-map-vc-ttl` against a timer that
  redraws every few seconds, so a draw shows the last answer and is at worst
  one redraw behind the disk (`g` drops the cache, because a reading asked for
  by hand is about now). It **names untracked files** rather than counting
  them (`agent-river-map-new-marker`), since a file an agent has just written
  is exactly the line the column would otherwise be silent about, and it is
  read `--relative` so a session started inside a subdirectory is annotated
  with its own subtree rather than the whole checkout. It **has no frame** —
  every other number on a line comes from the task or session frame, this one
  comes from HEAD, so after several prompts `+10 -6` is not this task's work.
  The header used to say so and no longer does; see the header below for why
  a caption is the wrong place to keep that.
- **Landed is the one reading neither git nor the fold can give alone**
  (`agent-river-map-landed-marker`, `agent-river--vc-landed-p`). Git can say a
  file is identical to the main branch; it cannot say whether that is because
  the work landed there or because nobody ever changed it — and most of what
  an agent touches, it only read, so marking on git's answer alone puts a tick
  down nearly every line. The fold therefore counts **writes apart from
  touches** (`agent-river--writing-p`, read off the `editing` bucket of
  `agent-river-phase-buckets` rather than from a second list of tool names),
  and the marker is the intersection: an agent wrote this, and git says
  nothing of ours is left outside the main branch. Four things it owes.
  **Three dots, not two** — `MAIN...HEAD` asks what *this branch* did since it
  diverged, so a main branch that has moved on since does not read as this
  branch's work still being out. **`:ahead` unset is "do not know", never
  "landed"** — no main branch here, or the read has not come back — because
  the marker says work is safely in the main branch and that is the last
  thing to claim on a guess; an *empty* `:ahead` is the opposite and is what
  a landing looks like. **The three readings are one question** (what state
  is the work on this line in), so they are exclusive and ordered: pending
  changes outrank a landing, because a file you can still lose is the news.
  And **a failed read costs the marker only** — the diffstat is stored before
  any of this runs, and every step here falls back to `:ahead` unset, so the
  column never blinks out over a question that was extra to begin with.
- **How long the landing holds: as long as the line does, and never more
  than one poll stale.** It is not a remembered event with a lifetime — it is
  re-derived from git on every read, so it is at worst `agent-river-map-vc-ttl`
  seconds behind the disk and corrects itself: write the file again and it is
  pending again, rebase again and it comes back. The only thing remembered is
  the write count in the artifact tables, which lives exactly as long as the
  line it annotates — cleared by a new prompt in the task frame, by
  `agent-river-forget-artifacts` when work lands and the user says so, and
  faded out of view by `agent-river-map-party-floor` like everything else.

Encoding discipline, since there are five facts on a line: weight is shading
(the same `agent-river-heat-levels` faces), party is text, contention is a
marker, existence is a strike-through, and the diffstat is a fixed column of
its own — placed before the brackets, because the brackets are a
variable-length list of names and anything meant to be read *down* the listing
has to come before them, and reserved on every line as soon as any root is a
repository, since a width chosen per line is a column in name only. The
strike-through is deliberately not
a colour: `:missing` used to be drawn in the grey `agent-river-stale`, which
put "this file is gone" on the same channel as the heat, where grey already
meant stale and cold and elided besides. A fifth colour would leave a reader
unable to say which fact any given colour meant, and one fact must not take two encodings either — the
brackets used to read `[alpha:4]`, which gave the weight a second rendering
nobody could reconcile against the first and pushed the names, which is what
the brackets are for, into the margin. The position marker is repeated in a
party's own row against the party it belongs to — in the gutter it is
scannable but anonymous, and "where is this agent now" is a question about a
party — but **only where there is something to attribute**
(`agent-river--rows-parties`). With one party on the node the gutter's
marker, the row's face and the row's glyph are three renderings of one fact
about the only name there is, which is the rule above broken rather than the
exception to it earned; with several, the gutter says somebody is here and
cannot say who, and that is the question the rows exist for. The condition is
the node's party count, not the row's own `:current`, for the reason
`agent-river--map-said-p` is per contributor: dropping the glyph from one row
of several would leave the gutter's marker reading as though it belonged to
whichever rows still had theirs. Note this is *not* the `:summarised`
mechanism and cannot be — that one is keyed on a contributor's `:summary`
earning the fixed-width column, and `parties` has no `:summary`; the gutter
is a second reader of `:current` that never goes through the contributor
protocol at all.

The green and red in the diffstat are not a counter-example to that, and the
distinction is worth keeping straight: they do not encode a fact of their own,
they separate the two halves of one — and `+` and `-` have already said which
is which, so the colour is reinforcement inside a column, not a channel a
reader has to decode. (They are also `success` and `error` inherited rather
than chosen, so they are whatever the user's theme already means by good and
bad. That is the rule for colour here generally: inherit a face the theme
knows unless the value needs a shade no built-in face has — the three
`agent-river-heat-*` and `agent-river-pulse` are the only four that do, and
they are spelled out per light and dark background for exactly that reason.)

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
  the structure changes, so a shading written as a text property is drawn
  once and then quietly gone. `agent-river--map-shade` turns the marks into
  overlays after the text is in, which is how the dired heat survives dired's
  fontification too.
- **Markup stays visible** (`markdown-ts-hide-markup` nil). Hiding it is the
  view mode's default and reads better on prose, but here the marker *is* the
  indentation — hidden, a directory and the files under it start in the same
  column and the tree stops being one.
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

Motion is dired's, because the map answers dired's question over a wider
area. Three grains, and collapsing them loses the one a reader wants: `n`/`p`
(and the remapped arrow keys) walk every entry, `M-n`/`M-p` walk the listing's
own entries past an unfolded directory's files, and `>`/`<` walk only the
lines with agents on them — in a thirty-module repository that last one is the
difference between reading the view and searching it. Three rules hold it
together:

- **Which lines a motion may stop on is read off text properties, not off the
  text.** `agent-river-map-path` marks a line that names something (the root
  heading and the elision line have none, which is what makes them
  unstoppable-on), `agent-river-map-rel` separates a file from its entry, and
  `agent-river-map-active` is set from the parties rather than from the
  rendered annotation — so a reformatting cannot pull the motion and the
  reading apart.
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
  (`agent-river--heat-memo`, `agent-river--section-memo`,
  `agent-river--newest-memo`). Three boxes, one shape, all bound by
  `agent-river--map-draw` and thrown away with it -- a draw is synchronous
  Lisp, nothing on that path folds or declares, so the binding cannot
  outlive the walk it was made for and there is no invalidation to get
  wrong. Outside a draw they are nil and every call reads what is there,
  which is what a caller outside a draw is asking about. The entry list
  came first; the two added after it are readings *of* that list, and both
  were being taken once per node rather than once per draw. Measured on
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
- **The blank line between block and log is the whole divider.** There was a
  `* -- eventlog` heading there once, and it was removed: a divider that
  exists to be a fold handle earns its line from nobody who is reading, and a
  blank one separates just as well at no cost in labels. It belongs to the
  block and is redrawn with it, so a session ending cannot leave it behind.
- **The buffer is newest-first** with the state block pinned at the top
  (`agent-river--block-end`), so nothing has to be tailed and trimming takes from
  the bottom. The block is deliberately *not* `header-line-format` (single-line,
  can't show two sessions); the mode sets that to nil explicitly.
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
  looking for a star in the text, since the log below carries the agent's own
  words and a line may well begin with one; **clearing is part of stopping**
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
  them apart and say why. First paid for by the map's worktree grouping, where
  the concrete case is written out.

  Deliberately not phrased as "the same subject", though that is the shorter
  word: **subject** is taken, and by the thing most likely to be confused with
  this — two functions can share one and still answer different questions. That
  is exactly the trap here. `agent-river--map-reach` and
  `agent-river--map-merge-parties` are both about sessions, compute the same
  arithmetic over the same cell shape, and answer *is this the file the party
  touched last* versus *is the agent anywhere beneath this directory*. Read as
  "same subject", the rule licenses folding them together; read as written, it
  forbids it. `agent-river--parties-by` is what the rule did allow, and the
  seam beside it is what it did not.
