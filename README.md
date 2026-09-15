# agent-river

Claude Code hooks report events one at a time. `agent-river` folds that
stream into a per-session **state** — what the agent is working on, which
files it keeps returning to, how its tools are faring — and renders it in
Emacs next to the event log.

A flat log answers *what happened*. Only a fold answers *where the work
stands*, because that question quantifies over a set of events.

It grew out of streaming development live: viewers could see *what* changed
in the Emacs frame but not what the agent was paying attention to. It has
two consumers, and they want different things.

- **Onlookers** get the buffer: a state block over a tailing event log.
- **The agent itself** gets a short, factual observation when a signal
  fires, injected back into its own context by the hook.

## Requirements

Emacs 28.1 or later with native JSON, a running Emacs server
(`M-x server-start`), and Claude Code — or Codex or Gemini CLI, whose hooks
are close enough to wire up the same bridge. No external tools: the shell
bridge only moves bytes.

[`agent-shell`](https://github.com/xenodium/agent-shell) is optional for the
HUD and required for the `◇` lines. When it hosts the sessions, agent-river
takes liveness and session names from it instead of estimating them, and
reads the agent's reasoning off the ACP stream — which the hooks do not
carry at all.

## Installing

Clone it, then wire the hooks into the project's `.claude/settings.json`.
`claude-settings.json` in this repo is a working example — six events, with
the paths already in place:

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

Two details in that example are load-bearing rather than cosmetic:

- **`PreToolUse` and `PostToolUseFailure` must not set `"async": true`.**
  A synchronous `PreToolUse` orders its line before its own completion; an
  async hook's stdout is never read, so only a synchronous one can hand an
  observation back to the agent.
- Settings are read at session start, so a change needs a restart.

Nothing needs loading in advance: the first hook call loads the Elisp
itself, and does so again after an Emacs restart.

### Other hosts: Codex and Gemini CLI

Both run hooks the same way Claude Code does — an external command, the
payload as JSON on stdin, the answer as JSON on stdout — and both read an
observation back out of `hookSpecificOutput.additionalContext`, in exactly
Claude's shape. `session_id`, `cwd`, `tool_name`, `tool_input`,
`tool_response` and `prompt` all carry the same names. So the bridge and the
response side are unchanged; only the wiring differs, and
`codex-hooks.json` and `gemini-settings.json` in this repo are the two
examples. Codex needs `[features] codex_hooks = true` in
`~/.codex/config.toml`.

Three differences are real, and two of them are handled in
`agent-river--event` — the one function that knows a host's dialect:

- **Neither has a failure event.** One post-tool event fires whether the
  call worked or not, and the outcome sits in `tool_response`. So a `think`
  whose response carries `error`, `is_error`, `isError`, `success: false`
  or a non-zero `exit_code` is refined to `fail` before it is folded —
  otherwise the failure streak, the one measurement that reads back to the
  agent, could never rise on these hosts. `interrupted` stays a success on
  purpose: the user stopped that call.

  This is why their post-tool hook must be **synchronous** where Claude's
  can be async. It is now the event that can produce a signal.
- **Gemini CLI names a read's argument `absolute_path`**, not `file_path`.
  Unknown to `agent-river--tool-file`, that would not have failed — it
  would have quietly stopped counting files.
- **Codex subagents fold into their parent.** `agent_id` rides
  `SubagentStart` and `SubagentStop` but not the tool events between them,
  and those carry the parent's `session_id`. `agent-river-key` therefore
  cannot separate them the way it does on Claude Code: a Codex subagent's
  steps and failures are counted against its parent. Documented rather than
  guessed around — a key invented from `turn_id` would split a parent's own
  work instead.

Gemini CLI has no subagent hooks at all, so its wiring is four events, not
six: `BeforeAgent`, `BeforeTool`, `AfterTool`, `AfterAgent`.

Both configurations are written from the hosts' documentation and are
covered by tests at the payload level, but have not been run against a live
Codex or Gemini session.

## What you see

One line per step — and one line per *tool call*, which is not the same
thing. Shown oldest-first here for reading; the buffer itself is newest-first.

```
16:22:48 ◆ add a queue-position render field       ← task from the user
16:22:59 ▸ Bash  Syntax-check the updated hook ✓  12ms
                                               ↑ appended when the call returned;
                                                 the timestamp is when it started
16:23:03 ◇ The mode sets truncate-lines, so a…     ← the agent's own reasoning
16:23:03 ▸ Edit  supersonic-mpv.el ✗  2.1s         ← interrupted, not a success
16:23:09 ▸ Bash  Run the test suite ✗  340ms       ← errored
16:23:12 ■ waiting for you                         ← idle
```

A call's outcome is written onto the line that opened it rather than taking
a line of its own, so the timestamp stays the one the call *began* at and
`agent-river-max-entries` holds twice the history. The pairing is by
`tool_use_id`, never by nearness or tool name — two parallel `Bash` calls
would otherwise complete each other. Where the opening line is gone (trimmed
away, or never written because Emacs started mid-run) or the host names no
call at all, the outcome still takes a line of its own, `·` for a completion
and `✗` for a failure: a tidier log that silently drops outcomes is the wrong
trade.

Two things worth knowing about what lands on those lines. `Bash` and `Task`
calls carry a human-written `description` alongside the raw command, and the
HUD prefers it — "Syntax-check the updated hook" reads better on stream than
the shell it expands to. And `PostToolUse` carries `duration_ms` plus
`tool_response`, so the outcome reports how long the call took and marks an
interrupted one with `✗` rather than claiming success.

Failures get their own `PostToolUseFailure` hook and a red `✗` line, which is
a different thing from the `✗` that `think` shows for an *interrupted* call.

## The panel is the view of the state

One buffer, two halves. The state block sits at the top — one line per live
session, rewritten on every fold — and the log runs underneath it **newest
first**:

```
* supersonic.el    · editing · 4m12s · 23 steps · mpv.el (6 touches) · 1 subagent
* supersonic.el<2> · editing · 2 steps · supersonic-mpv.el (2 touches)

19:07:03 super<2> ▸ Edit  supersonic-mpv.el
19:06:58 superson ▸ Read  Cask ✓  2ms
19:06:55 superson ◆ fix the mpv bridge
```

The `*` on a session line spins through a handful of star-like glyphs
(`✢ ✳ ✶ ✻ ✽`) while that session's turn is running, and settles back to a
plain star the moment the turn ends — the same question the elapsed clock
answers, asked at a glance and from across the room. It is drawn as a
`display` property over a star that stays a star in the buffer: the line
has to go on being an outline heading while it spins, and `outline-regexp`
reads the text, not the picture. `agent-river-spinner-frames` set to nil
turns it off, which is also the answer for a font that does not have the
glyphs.

The blank line is the only thing dividing the two halves. There was a
`* -- eventlog` heading there once; it was removed, because a divider that
exists to be a fold handle earns its line from nobody who is reading, and a
blank one separates just as well at no cost in labels. It belongs to the
block and is redrawn with it, so a session ending cannot leave it behind.

Each block line is an outline heading. `TAB` unfolds the session under
point, into the same touch counts the block condenses into its one
parenthetical, at a grain that says what the step count is made of:

```
* supersonic.el    · editing · 4m12s · 23 steps · mpv.el (6 touches) · 1 subagent
** files: mpv.el 6 · supersonic-mpv.el 2 · Cask 1
```

That fold is a flag, not an overlay. The block is erased and rebuilt on
every event, so an outline fold would spring open on the next tool call;
a flag means the rebuilt block is drawn already open and stays that way
until it is asked to close.

A scrolling log shows activity. Only the block answers what is being worked
on right now, which is the question an onlooker actually has — and the
reason the fold exists at all. A live failure run appears there too
(`3 failing`, in the error face), because that is the one thing nobody
should have to reconstruct from scrollback.

Newest-first means there is nothing to tail: the block and the latest event
are both at the head of the buffer and never move, so neither can scroll out
of view as the log grows. Trimming takes the oldest lines off the bottom.

### The block keeps its own time

Elapsed times are only correct at the moment the block is drawn, so drawing
it solely on events makes the clock jump by however long the gap between two
of them was. A repeating timer
(`agent-river-refresh-interval`, 1 s) redraws just the block — the log is
never touched.

It runs only while an agent is actually mid-task, which is narrower than
"the session is live": a turn that has ended leaves the session registered
and reachable, but nothing is happening in it, and a clock ticking over an
idle agent claims work that is not being done. So the timer starts on the
next folded event and retires itself on the first tick that finds no one
working — it is not running between turns, or at all once Emacs is quiet.

A subagent still working keeps it alive even when its parent looks idle. A
redraw that throws cancels the timer rather than repeating the error every
second.

The block is **not** the header line, and that is not a style choice.
`header-line-format` is structurally single-line, so with two sessions it
could only ever show whichever acted last — the step count jumped between 1
and 4 with nothing to say these were different agents, which is worse than
showing nothing. The mode now sets it to nil explicitly: an earlier version
did keep the state there, and a value left behind by that version sat frozen
at the top of the buffer showing a step count and an elapsed time from
whenever it was last written.

A subagent does not get a line: it is counted on its parent, so the session
stays the subject.

### When agent-shell is hosting the sessions

The sessions run as `agent-shell` buffers in this same Emacs, and
`agent-shell--state` carries the ACP session id — which is *verbatim* the
`session_id` the hooks report. So the link is an id comparison, not an
inference from process ancestry or working directory.

That deletes three pieces of guesswork rather than adding a feature:

- **Liveness stops being an estimate.** For a hosted session the buffer
  settles it: the process runs here, so whether it is alive is a fact. The
  TTL is what remains for subagents and for anything this Emacs does not
  own — it was only ever a way of guessing at something we could not see.
- **Labels stop drifting.** They come from the agent-shell buffer name,
  which does not change when the session changes directory.
- **Uniquifying them stops being our job.** agent-shell already numbers its
  buffers (`Claude Agent @ supersonic.el<2>`); the parallel scheme here was
  duplicated work.

Each session line is also a link: `RET` or `mouse-1` jumps to that
session's shell buffer. A line with nothing to jump to does not pretend
otherwise.

All of this degrades to the previous behaviour when agent-shell is absent —
the test is simply whether a buffer in `agent-shell-mode` claims that id.

### Telling two sessions apart

Two agents in one checkout derive the same label from their directory, so
labels are uniquified the way Emacs uniquifies buffers, and the way the
session list already shows them: `supersonic.el`, `supersonic.el<2>`.

The session column truncates to `agent-river-label-width`, and truncating
from the right would cut both down to `superson` — undoing the whole point.
It keeps the suffix instead: `super<2>`.

The label follows the session's working directory, so it changes if the
session moves. That is accurate rather than stable; a session that spends a
while outside the repo will show up under whatever directory it is in.

### The phase

`exploring` / `editing` / `verifying` / `blocked` / `waiting`, read from the
last `agent-river-phase-window` steps. Three rules decide it, in order:

- **`waiting` outranks everything.** The tool window still holds the steps
  of a finished turn, so without this the panel announces `exploring` above
  a log line saying the turn is over — describing what the work *was* while
  presenting it as what the work *is*.
- **`blocked` comes from failures, not tools.** A run of errors says more
  about where the work stands than which tools produced it. Its threshold
  (2) is deliberately lower than the one for interrupting the agent (3): an
  onlooker may see a rough patch early, the agent should only be told once
  it looks like more than bad luck.
- **Otherwise the dominant tool bucket wins**, and only with at least two
  classified steps. One is noise, two is a tendency.

Shell calls stay unclassified unless they match
`agent-river-verify-regexp`, because the same tool runs the test suite, a
git query and a directory listing. The practical consequence is that
shell-heavy work often shows *no* phase at all — abstaining beats guessing.
The pattern is applied only to shell tools: matching it against every step
once classified reading a file called `Cask` as verification.

`M-x agent-river-status` lists every session in full, and
`M-x agent-river-who-touches` answers the contention question. Both exist
because the queries were otherwise reachable only by evaluating Elisp,
which put the state out of reach of exactly the onlookers it is for.

### The agent can read its own state — and state its intent

Both go through the `emacs` MCP server, as plain function calls. No extra
tool is needed, but nothing advertises them either, so: they exist.

```elisp
(agent-river-report "<session-id>")     ; own state
(agent-river-touching "supersonic.el")  ; is another session on this file?
(agent-river-set-intent "narrowing down why queue position goes stale")
```

`set-intent` records the one thing the hooks cannot derive. `:task` is
literally the user's prompt, which stays put for twenty minutes while the
work moves through several sub-goals; the intent names the current one, and
the panel shows it in place of the prompt.

**It is stored as a claim, not a measurement.** Everything else in the state
is counted — touches, durations, failures, tool mix. A value the agent wrote
about itself is different in kind, and this state is fed *back* to the
agent: a claim later read as an observation closes the loop with no ground
truth left in it. So it lives in its own slots, reports under
`:claimed-intent`, and never feeds a signal (there is a test for that: a
cheerful intent cannot talk a failure streak out of firing).

It also ages. An agent remembers to narrate while things go well and forgets
precisely when it has lost the thread — which is when an onlooker most needs
to know. So the measured state is allowed to contradict the claim: after
`agent-river-intent-stale-steps` steps, or once the hottest file has moved
on, the panel greys it and appends `(stale)` rather than letting it pass as
current. Silence about having stopped narrating would be the worse failure.

### Two frames, labelled as such

`artifacts` accumulate for the whole session; `steps` and the task tally
reset with every prompt. Reporting one while labelling it the other is how
a panel starts misleading people, so the report keys say which frame they
are in — `:task-steps`, `:task-hottest`, `:session-hottest`,
`:session-elapsed`. The panel uses the task frame (what is being worked on
now); `agent-river-touching` uses the session frame, because contention
has to survive a change of subject.

### Reloading after a struct change

`cl-defstruct` instances already in the registry do not gain a slot added
later, so reloading this file mid-session can leave the fold erroring
against states built by the previous definition. That once stopped the
display with no error anywhere. The fold now reports such a failure as a
line in the buffer naming `agent-river-reset` as the fix — losing the
folded state is cheap, a HUD that has silently gone dark is not.

## Asking the state things

Events fold into a per-session `agent-river-state` held in
`agent-river-registry`, keyed by session id. The fold is deterministic
given event order, so a state can be rebuilt by replay.
`agent-river-reset` forgets it; `agent-river-clear` only empties the buffer.

Two queries expose the meta level:

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
;;  :signals 1
;;  :subagents (:running 0 :total 1 :steps 2
;;              :each (("Explore" :steps 2 :fail-streak 0 :status "done"))))

(agent-river-touching "supersonic-mpv.el")
;; (("session-b" :label "worktree-…" :touches 2 :ago "9s"))
```

`agent-river-touching` is the one that earns its keep: two agents editing
the same file without knowing about each other is a real hazard in a
worktree setup. Several sessions fold side by side already; Emacs Lisp is
single-threaded, so concurrent `emacsclient` calls are atomic and the
registry needs no locking.

### Subagents

A subagent's tool calls fire the same hooks, and arrive with the **session
id and transcript path of its parent**. The only fields that give them away
are `agent_id` and `agent_type`, which are absent on a call the parent makes
itself:

```
PreToolUse   Bash   -                  -
PreToolUse   Read   a37409f14b2a9aa55  Explore
```

So the registry key is `session_id`, or `session_id/agent_id` for a
subagent. Keying on the session alone folded a subagent's work into its
parent — inflating the step count and, worse, letting one subagent's
failures raise a streak that got reported against the parent. `agent_type`
doubles as the label, which reads better than a directory name:

```
18:25:38 Explore  ▸ Read  Makefile
18:25:36 superson ▸ Agent  Verify subagent tree folding ✓  7.8s
```

The parent still sees what it set in motion, aggregated on demand from the
registry rather than mirrored onto the parent (so the two cannot drift):

```elisp
(agent-river-report "<session>")
;; … :steps 3
;;   :subagents (:running 1 :total 1 :steps 2
;;               :each (("Explore" :steps 2 :fail-streak 0 :status "running")))
```

`:status` distinguishes three things on purpose. `done` comes from
`SubagentStop` and is a fact. `stale` means the TTL expired with no end
event — something went away without saying so. Only `running` is a claim
that it is still working. Inferring "finished" from silence is how a
registry starts lying, and a `done` event that carries no `agent_id` is
dropped rather than applied to the parent key.

### One buffer, several sessions

Every session renders into the same `*agent-river*` buffer, so a session
column appears as soon as a second one is live:

```
18:05:40 ▸ Edit  supersonic.el                 ← one session: no column
18:05:48 other    ▸ Edit  supersonic.el        ← two: who did it matters
18:05:48 superson ▸ Bash  Run the test suite
```

Two details that are easy to get wrong and were:

- **Paths must normalise identically across sessions.** They render relative
  to the session cwd when under it, and as a bare basename otherwise. An
  earlier version stripped only the session's own cwd, so the same file
  reached from a worktree and from the main checkout produced two different
  strings — and the view showed a collision as two unrelated files, which is
  the exact opposite of the point.
- **The column is liveness-gated**, not registry-gated: a session silent for
  `agent-river-session-ttl` stops counting, so a crashed session does not
  leave a column behind forever.

The label is the cwd basename, truncated to `agent-river-label-width` (8),
which makes `supersonic.el` read as `superson`. Ugly but distinguishing;
widen it, or the window, if it bothers you. Lines already in the buffer keep
whatever format they were written with — it is an append-only log, not a
re-rendered table.

A buffer per session, with an overview, is the obvious next step. It is
deliberately not built yet: it costs real work and only pays off once
several agents run in parallel routinely.

## Talking back to the agent

`agent-river-observe` returns an observation when a signal fires, and the
hook turns it into `hookSpecificOutput.additionalContext` — text injected
into the agent's own context. Today one signal exists: a run of
`agent-river-fail-streak-threshold` consecutive tool failures.

```
agent-river: 3 consecutive tool failures (Edit x2, Bash x1), 7s into the
current task. Most-revisited file: supersonic-mpv.el (2 touches). This is an
observation, not an instruction — weigh it against what you know; repeated
failure is sometimes the right path.
```

Three constraints hold this together, and each is load-bearing:

- **Only a synchronous hook can inject.** An async hook's stdout is never
  read, which is why `PostToolUseFailure` alone omits `"async": true`.
- **Observations, never instructions.** Signals are heuristics and will
  misfire; sometimes six edits to one file is exactly right. A wrong fact
  costs tokens, a wrong instruction derails a correct solution.
- **Rare, and never a target.** Emitted signals fold back into the state as
  a `signals` count, so "how often did the agent have to be told" is itself
  observable. If that count ever becomes a measure of quality, the whole
  mechanism is corrupted — an agent can lower it by avoiding the *measure*
  rather than the problem.

## Tests

The fold and the payload parsing are the parts that are logic rather than
formatting, and both are pure — so they are tested without a frame, a hook
or a live session:

```
emacs -Q --batch -L . -l agent-river.el -l agent-river-tests.el \
      -f ert-run-tests-batch-and-exit
```

121 tests covering the state transitions, streak accounting, signal
threshold and throttle, the phase, subagent isolation, the registry and its
TTL, the cross-session `touching` query, the reasoning stream — chunk
accumulation, the sentence boundary, which path serves a hosted session —
the payload derivation: which argument of a call is the interesting one, how
a duration is formatted, what counts as an interrupted call, what a host
other than Claude Code calls a file and how it reports a failure — and the
second way in: one step per tool call however often it is updated, and the
hooks taking a watched session over.

Verified to actually fail rather than merely pass: mutating the streak
reset in a scratch copy turns exactly the two responsible tests red, and
three mutations of the reasoning path — accepting an incomplete sentence,
dropping the end-of-run flush, letting two sessions share one thought run —
turn three, one and three.

## The `◇` lines: reasoning

Where agent-shell hosts the session, the reasoning comes off the ACP stream
that already drives the shell. `agent_thought_chunk` notifications carry it,
`agent-shell--state` hands over the client, and the handler is attached the
first time a session folds an event.

That makes the order chronological rather than arranged: a thought arrives
when the agent thinks it, which is before the tool call it explains. The
difference is visible in the timestamps — the fallback below emits its line
*inside* the `act` hook, so `◇` and `▸` share a second; a streamed thought
carries its own.

A thought arrives in chunks, which is the one thing this path makes harder.
Only the first sentence is shown, so a run is emitted as soon as one is
complete and the rest of it is dropped; a run that ends without a sentence
boundary is flushed by the next notification that is not a thought. Waiting
for the boundary is the point — a chunk usually ends mid-clause, and showing
that would put a truncated sentence on screen and never correct it.

The reasoning is in whatever language the agent thinks in, which is not
necessarily the language of the conversation.

This is the one thing agent-shell is *required* for rather than merely
better with. It replaced lifting the thinking out of the session
transcript, which the hooks point at but which is always one step behind:
the record holding the current `tool_use_id` is still unflushed when the
hook fires. That path compensated by placing its line inside the `act`
hook; it is gone, and a session this Emacs does not host now gets no `◇`
lines at all.

It is driven by Claude Code hooks, not by the agent choosing to call
something — this repo's `.claude/settings.json` wires six events to
`~/src/agent-river/agent-river-hook.sh`, which turns the hook's JSON
payload into an `agent-river-observe` call over `emacsclient`:

| Hook event           | Kind     | Means                                     |
|----------------------|----------|-------------------------------------------|
| `UserPromptSubmit`   | `prompt` | a task arrived                            |
| `PreToolUse`         | `act`    | done thinking, about to act — and on what |
| `PostToolUse`        | `think`  | tool returned, reasoning follows          |
| `PostToolUseFailure` | `fail`   | the call errored                          |
| `SubagentStop`       | `done`   | a subagent finished                       |
| `Stop`               | `idle`   | turn over                                 |

`PreToolUse` runs **synchronously**, which is not a detail. Both it and
`PostToolUse` used to be async, and the `act` path was then the slower of
the two (17 ms against 11 ms, because it scanned the transcript for
reasoning), so a line could lose the race against its own completion and
the buffer showed `· Read ✓` *above* `▸ Read Makefile`. That scan is gone
now, but the ordering argument does not depend on it: running `act` before
the tool starts orders the pair by construction rather than by luck, and
nothing about two async hooks guarantees which lands first.
`emacsclient` is wrapped in `timeout` (`AGENT_RIVER_TIMEOUT`, 2 s) so a
wedged Emacs cannot stall the stream.

The gap between a `think` line and the next `act` line *is* the thinking
window. Hooks carry no thinking text, so tool-call granularity is the finest
resolution available — and the right one for a viewer anyway.

There is nothing to arm. Every hook call wraps its payload in

```elisp
(progn (unless (fboundp 'agent-river-log) (load "…/agent-river.el" t t))
       (agent-river-log …))
```

so the first hook after an Emacs restart loads the Elisp, and every later
one skips the load. No init-file entry is needed, and restarting Emacs mid
stream costs nothing. Override the path with `AGENT_RIVER_LISP` if you move
the file.

This matters because the failure is invisible: a hook firing into a session
where `agent-river-log` is undefined errors inside `emacsclient`, the script
swallows it by design, and the HUD simply stays blank with nothing to
suggest why. Self-arming removes the only way that happened in practice.

Logging pops the side window by itself (`agent-river-auto-display`), so
there is nothing else to do. `M-x agent-river-show` reopens it after a
`C-x 1`, `M-x agent-river-clear` empties it.

### The shell script only moves bytes

`agent-river-hook.sh` is 56 lines and does no parsing. It writes the
payload to a file, hands Emacs the two paths, and prints whatever Emacs
wrote back.

It was 224 lines of `jq` that parsed the payload and assembled Elisp *as
text* — which meant every tool argument was interpolated into a form Emacs
then evaluated, safe only for as long as the escaping held. Passing files
in both directions removes that class of problem entirely, drops the `jq`
dependency, and puts the derivation under test: which argument of a call is
the interesting one, how a duration is formatted, what counts as an
interrupted call. None of that was covered while it lived in the shell.

The bridge sits on the critical path of every tool call and must never fail
one, so every step degrades to a no-op — no Emacs server, unreadable
payload, no `mktemp`. But a payload that reaches Emacs and then fails to
parse writes a `hook failed` line into the buffer rather than going quiet:
silence is how this has broken before, three times.

## A second way in, for sessions no hook reaches

Claude Code, Codex and Gemini CLI report themselves through hooks. The other
agents agent-shell hosts — Goose, Qwen Code, opencode, Cursor, whatever it
grows next — do not. But agent-shell is already reading their ACP stream,
and it publishes what it learns:

```elisp
(agent-river-watch-mode 1)          ; every agent-shell session
(agent-river-watch-shell)           ; or just this buffer
```

`agent-shell-subscribe-to` is a documented API rather than something read
over agent-shell's shoulder, and three of its events carry what the fold
wants:

| agent-shell event  | Kind             | Carries                                    |
|--------------------|------------------|--------------------------------------------|
| `input-submitted`  | `prompt`         | the prompt text                            |
| `tool-call-update` | `act`/`think`/`fail` | status, kind, title, `rawInput`        |
| `turn-complete`    | `idle`           | the stop reason                            |

The translation is deliberately shallow: it builds the *same payload shape
the hooks report* and hands that to `agent-river--event`, the one function
that resolves a host's dialect. So a file argument that path learns to count
is counted here too — `agent-river--tool-file`, written for Gemini's
`absolute_path`, reads ACP's `rawInput` unchanged — and nothing downstream
learns that a second source exists.

Three differences from the hook path are worth knowing:

- **A step is counted once, and timed here.** A tool call is announced and
  then updated, so the first sighting is the `act` and the terminal status
  is the `think` or the `fail`; the updates between them are not steps. ACP
  carries no duration, so the two sightings supply one — which is how the
  `·` lines keep their timings.
- **The failure is the protocol's, not a guess.** `status: "failed"` says
  so outright, where Codex and Gemini leave it to be read out of a tool
  response.
- **A tool has no name, only a kind.** ACP gives `read`, `edit`, `execute`
  and a handful more, plus a free-text title. The tallies use the kind,
  because they want a small stable vocabulary; the title reaches the log
  line through the same `description` slot a `Bash` call's would.

### One session, one source

A session folded from both would count every step twice. That is not merely
untidy: a doubled failure streak states a fact that is false, to the agent
itself.

So a session belongs to whichever way in claimed it, and **the hooks win** —
they are the only ones that can carry an observation back. A watched session
that turns out to have hooks is given up whole rather than interleaved: what
the stream folded is dropped, the hooks rebuild it from their first event,
and the buffer says so once. `agent-river-watch-mode` is therefore safe to
leave on; it only ever supplies the sessions the first way in cannot reach.

What this path cannot do, and will not learn to:

- **Talk back.** A signal still reaches the buffer, but there is no
  `additionalContext` on a stream we only listen to.
- **Tell a subagent apart.** ACP has no notion of one, so a delegated task
  folds as a single step of its parent — `agent-river-key` has nothing to
  key on.

