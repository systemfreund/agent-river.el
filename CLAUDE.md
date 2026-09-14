# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
  its own — refreshed by every event carrying one, so a session that changes
  directory re-anchors — and a view that needs a real path puts the two back
  together deliberately (`agent-river--heat-absolute`). Resolving is strictly
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
- **Breadth at one level, depth only where there is activity.** A whole tree
  unfolded is unreadable in a monorepo; a view of only the touched paths says
  where without saying where that is *relative to* anything. So RET descends
  (`agent-river-map-descend`) rather than widening, and a file five directories
  down is shown under the one entry the listing has a line for, with the rest
  of its path inline.
- **Weight and position are different readings.** The numbers say where an
  agent has *been*; `:current` says where it *is*, and after a long task those
  are different places. `:current` is computed across everything a party
  reached, not just what falls under the map root, or descending would invent a
  second "most recent" file that only looks like one because the real one is
  out of view.
- **The listing is the union of disk and state.** `:missing` marks an entry
  only the state knows about — deleted, renamed, or reached through an anchor
  this root has nothing to do with. Activity the map does not show is the one
  thing it exists not to do.

Encoding discipline, since there are three facts on a line: weight is shading
(the same `agent-river-heat-levels` faces), party is text, contention is a
marker. A fourth colour would leave a reader unable to say which fact any
given colour meant, and one fact must not take two encodings either — the
brackets used to read `[alpha:4]`, which gave the weight a second rendering
nobody could reconcile against the first and pushed the names, which is what
the brackets are for, into the margin. The position marker is repeated
*inside* the brackets against the party it belongs to — in the left-hand
column it is scannable but anonymous, and "where is this agent now" is a
question about a party.

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

## Conventions

- `agent-river-` is public, `agent-river--` is internal; the split is meaningful —
  `;;;###autoload` marks the entry points and interactive commands.
- Comments here explain *why*, at paragraph length, usually naming the failure the
  code prevents. Match that density; a change that removes a guard should remove
  its comment, and a new guard should say what went wrong without it.
- Tests are named as sentences (`agent-river-test-waiting-outranks-blocked`) and
  assert the reason, not just the value. Helpers: `agent-river-test--with-session`,
  `--fail`, `--acts`, `--payload`, `--with-shell`.
