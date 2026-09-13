# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Emacs package that folds the Claude Code hook event stream into a per-session
*state* (what the agent is working on, which files it revisits, how its tools are
faring) and renders it into `*agent-river*`. `README.md` is the design document —
it explains the reasoning behind nearly every decision here and is worth reading
before changing behaviour.

Four files, no build system: `agent-river.el` (everything), `agent-river-tests.el`
(ERT), `agent-river-hook.sh` (the bridge), `claude-settings.json` (example hook
wiring).

## Commands

```sh
# Full suite (110 tests). -L . is required: the tests (require 'agent-river).
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
Claude Code hook
  → agent-river-hook.sh <kind>        payload in a temp file, response in another
  → agent-river-hook (kind in out)    parses JSON, writes additionalContext back
  → agent-river--event                payload alist → event plist
  → agent-river-observe               addresses the state, folds, renders, signals
  → agent-river-fold                  pure state transition
  → agent-river-registry              key → agent-river-state
  → agent-river--update-panel / agent-river-log     the view
```

`kind` (`prompt` `act` `think` `fail` `done` `idle`) is passed as an argv from
settings.json, not read out of the payload, so the hook-event → fold-event mapping
stays visible in the config.

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
- **`PreToolUse` and `PostToolUseFailure` must not set `"async": true`.** An async
  hook's stdout is never read, so only a synchronous hook can inject
  `additionalContext`; and a synchronous `act` orders its log line before its own
  `PostToolUse` line rather than racing it.
- **Never fail a tool call over the HUD, but never go quiet either.** Every step in
  the script degrades to a no-op; a payload that reaches Emacs and then throws
  writes a `hook failed` / `fold failed` line into the buffer. Silent failure is
  how this has broken before.
- **Paths normalise identically across sessions** (`agent-river--rel`): relative to
  the session cwd when under it, bare basename otherwise. Stripping only the
  session's own cwd makes one file reached from a worktree and from the main
  checkout render as two, which defeats the contention query.

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
  and it must keep doing so. Two ways out, both in the heat code: look the file
  up *from* the consumer's side by basename (what `agent-river-touching`
  matches on), or read an extra event key the fold ignores. `:path` is that
  key — the absolute name, carried beside `:file` and never folded.
- **Off by default, behind a global minor mode.** Writing into buffers the user
  did not point this at needs a consent gesture, and turning it off has to take
  the effects with it.
- **Test the derivation, not the rendering.** Frame choice, aggregation and
  thresholds are pure functions of the state; geometry is the host package's
  problem. The contract tests live under `;;; Observers` — point a new
  observer at them.

Two frames again: pick `task` or `session` scope *explicitly* (see
`agent-river-heat-scope`) and say which one the view is showing.

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
