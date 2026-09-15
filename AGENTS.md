# AGENTS.md

This file provides guidance to coding agents working with code in this
repository. `CLAUDE.md` is a symlink to it, so Claude Code and any host that
reads `AGENTS.md` see the same text.

## What this is

An Emacs package that folds the Claude Code hook event stream into a per-session
*state* (what the agent is working on, which files it revisits, how its tools are
faring) and renders it into `*agent-river*`. `README.md` is the design document —
it explains the reasoning behind nearly every decision here and is worth reading
before changing behaviour.

Four files, no build system: `agent-river.el` (everything), `agent-river-tests.el`
(ERT), `agent-river-hook.sh` (the bridge), and one example hook wiring per host —
`claude-settings.json`, `codex-hooks.json`, `gemini-settings.json`.

## Commands

```sh
# Full suite (200 tests). -L . is required: the tests (require 'agent-river).
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

Two ways in, one adapter. The right-hand column exists for the agents
agent-shell hosts that have no hooks; it translates into the payload shape the
hooks report rather than building events of its own, so everything from
`agent-river--event` down is shared. Only the hooks can answer the agent —
the stream is listened to, not spoken on.

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

- **Registry key is `session_id`, or `session_id/agent_id` for a subagent**
  (`agent-river-key`). Subagent hook calls arrive with the *parent's* session id;
  keying on session alone folds a subagent's steps and failure streaks into its
  parent. Subagents get no panel line — they are counted on the parent, aggregated
  on demand via `agent-river-children` rather than mirrored (so the two cannot drift).
- **Two frames, always labelled.** `artifacts`/session-wide survives a new prompt;
  `task-artifacts`/`steps`/`task-failures` reset on `prompt`. Report keys say which
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
- **One session, one way in** (`agent-river--claim`). The hooks and the
  agent-shell stream describe the same session, so folding both counts every
  step twice — and a doubled failure streak states a fact that is false, to the
  agent itself. The hooks win, because only they can carry an observation back;
  a watched session they reach is dropped from the registry and rebuilt from
  their first event, rather than interleaved. This is what makes
  `agent-river-watch-mode` safe to leave on.
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
  there is neither dirt nor anything left to cool.
- **Test the derivation, not the rendering.** Frame choice, aggregation and
  thresholds are pure functions of the state; geometry is the host package's
  problem. The contract tests live under `;;; Observers` — point a new
  observer at them.

Two frames again: pick `task` or `session` scope *explicitly* (see
`agent-river-heat-scope`) and say which one the view is showing.

### Producers — the other direction

A *consumer* turns state into an outside effect and hangs off
`agent-river-observers`. A *producer* turns something only Emacs can see into
an event, via `agent-river-note`, and hangs off whatever Emacs hook sees it —
not off `agent-river-observers`, which fires on the agent's events, not yours.
`agent-river-watch-saves-mode` is the worked example: it notices you saving a
file an agent is working in, which no hook can see because the agent's
staleness check knows the disk and not your buffers.

```
hooks -> fold -> observers -> outside world    consumer (agent-river-heat-mode)
Emacs -> note  -> fold -> observers            producer (agent-river-watch-saves-mode)
```

What may be noted is narrower than "anything from outside":

- **Point-in-time facts** — you saved this file at 14:32, during this task.
  Once past, nothing can recompute it. This is what notes are for.
- **Current-state facts** — the buffer has unsaved changes *right now*. Query
  it where it is read (`buffer-modified-p`); a note would go stale the moment
  it is folded.

Three things a producer owes:

- **A relevance filter.** `after-save-hook` fires on every save you make.
  Without a filter the log becomes a list of your keystrokes. The filter is a
  state query — `agent-river--frame-touches` is the one used here.
- **A provenance guard.** A producer that cannot tell the agent's own writes
  from yours launders the agent's action into an observation about it.
  `agent-river--agent-in-flight-p` is the guard here, and it is deliberately
  narrow: it suppresses only while a tool call is open on that exact file.
  Widening it before there is evidence of noise would be tuning on a guess.
- **The family, not the session** (`agent-river--family-in-file`). A delegated
  file lands in the *subagent's* task frame and never in its parent's, so
  asking the root alone produced no note at all when a subagent held the file
  — silence in the case with the least supervision in it. Both the relevance
  filter and the provenance guard therefore range over the root and its live
  children.

Where a note is **addressed** is forced by the invariant above: only a root can
be told anything, so the note goes to the root even when a subagent holds the
file — which is exactly why it has to name the holder. Addressed to the parent
and silent about the child, "shared.el saved outside the session" reads as a
statement about the parent's own work. Say which frame the count came from too
(`agent-river--frame-word`); the text used to read "this task" whatever
`agent-river-foreign-save-scope` was set to.

Reading notes back and deciding what to tell the agent is a separate step, and
is deliberately not built: `agent-river--signal` still fires on fail streaks
only. Notes are visible in the HUD (`◉`) and counted in the report (`:notes`)
first, so the rate can be seen before anything is fed back.

### One set of motions, both buffers

The HUD and the map take the same keys for the same three grains, because
they are two views of one state and learning each separately buys nothing:
`n`/`p` (plus `SPC`/`DEL` and the remapped arrows) walk every line worth
stopping on, `M-n`/`M-p` walk the coarse structure, `>`/`<` walk the lines
that want attention. A session line is a map entry; a detail heading is a map
file line; a log line has no analogue and rides the fine grain. `>` is
`agent-river-notable-kinds` here and "some agent is under this" there.

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
wraps its edit in `save-excursion` — in the selected window buffer point *is*
window point, so without it the one window most likely to be the one being
read was dragged back to the top regardless. Everything the log edits is above
a reader's position, so their marker rides the text rather than the offset.

`hl-line-mode` is on in the map and deliberately off in the HUD: the HUD pins
its point to the head until someone navigates, so a permanent highlight there
would mark nothing anyone chose.

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
  code spans long enough to hold a backtick (`agent-river--md-code`). Only two
  values are the agent's, which is the whole reason this is tractable here and
  is not in the HUD.

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
  buffer killed, and its name and `▸` stayed pinned to one file for as long as
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
  ordinary: they fade at the floor like any other name.
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
  **enrichment and detail at once**: drawn by default wherever there are any,
  hidden by the same TAB that hides a directory's files, so there is one
  mechanism rather than two and no disclosure twisty to invent.
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
- **Weight and position are different readings.** The numbers say where an
  agent has *been*; `:current` says where it *is*, and after a long task those
  are different places. `:current` is computed across everything a party
  reached, not just what falls under the map root, or descending would invent a
  second "most recent" file that only looks like one because the real one is
  out of view.
- **The listing is filtered to what has been reached**
  (`agent-river-map-untouched` nil, the default; `a` toggles it for one
  buffer). Agents spread over several roots turn the full listing into mostly
  context — every sibling of every tree anyone started a session in, with the
  handful of lines that carry an agent somewhere among them. What the filter
  gives up is breadth: a view of only the touched paths says where without
  saying where that is *relative to* anything, which is what the full listing
  was for, and non-nil buys it back as the union of disk and state.
  **Activity the map does not show is the one thing it exists not to do**, so
  the filter drops an entry for having no parties and never for being absent
  from disk — `:missing`, an entry only the state knows about (deleted,
  renamed, or reached through an anchor this root has nothing to do with), is
  precisely what a disk-shaped filter would have swallowed. An empty listing
  says which kind of empty it is: a filtered tree full of files nobody has
  been near would otherwise read as a map that had lost them.

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
the brackets are for, into the margin. The position marker is repeated
*inside* the brackets against the party it belongs to — in the left-hand
column it is scannable but anonymous, and "where is this agent now" is a
question about a party.

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
- **Names are code spans.** A path is what a code span is for, and inline
  markup does not apply inside one; bare, `foo_bar_baz.el` renders with `bar`
  in italics and the underscores eaten.
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
