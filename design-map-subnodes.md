# Sub-nodes on the map, and who may contribute them

A design note. It is **built** — `agent-river-map-contributors`, the rows
under each node, and the diffstat moved over to it — so what is left here is
the argument, which `CLAUDE.md` now carries in shorter form. Delete this file
once nothing in it is news.

The idea: a node in `*agent-river-map*` should be able to carry a handful of
child rows of *different kinds*, and those rows should be able to come from
anywhere — including from work that takes time to finish.

## What is already there, so it is not rebuilt

Two things, and noticing them changes the shape of the feature.

**The enrichment half exists and is full.** A map line already carries five
facts, each on its own channel: weight is shading, party is the text in the
brackets, contention and position are markers, existence is a strike-through,
and the state of the work is the diffstat column (`+12 -6`, `?`, `✓`). That is
the ceiling. The header legend was removed last week precisely because the view
had started explaining itself instead of showing something; a sixth fact on the
line would undo that. **So the new mechanism is the detail half. Enrichment is
not a thing to add — it is a thing to ration.**

**The detail half exists in one flavour.** A directory entry unfolds into the
files reached beneath it (`:files`, `agent-river--map-open-p`, TAB via
`agent-river-map-toggle`, folds kept as data in `agent-river--map-folds`
because the buffer is rebuilt every few seconds and an overlay fold would
spring open on the next redraw). Sub-nodes generalise exactly this: a child row
that is not a file.

**The async half exists too, unnamed.** The diffstat is already a contributor
in everything but name: `agent-river--vc-run` spawns processes, a sentinel
stores the answer, `agent-river--vc-store` marks the map dirty and restarts its
timer, and the redraw never waits for any of it. The protocol below is that
code with the special-casing taken out.

## The rule: which channel a fact goes on

A fact belongs **on the line** only if it is all three of:

- **scannable** — it answers a question asked of the whole listing at once
  ("what is still dirty", "what has not landed"), which means reading a column
  downward;
- **bounded** — fixed shape, fixed width, or the column frays and stops being
  one (which is why the ragged brackets are last on the line);
- **always available** — computable for every line, or the column lies by
  absence.

A fact belongs **in sub-nodes** if it is a list, or is asked of one node after
the eye has already chosen it, or may be missing or late without misleading
anyone — which it cannot be, if it is only visible on a node you opened.

And the relation that makes having both cost nothing: **the line is a
projection of the sub-nodes, never a second account of them.** This is the rule
the listing already follows one grain up — a directory's reading is the
aggregate of what lies beneath it and never a tally of its own, so the entry
and its files cannot disagree. A contributor therefore supplies sub-nodes, and
any line-level reading is a summary *of those same rows*: a count, a worst
severity, one glyph. Not other data. The same data, smaller.

## Both, without a second mechanism

The question that started this was whether we need detail *and* enrichment. We
do, and we get them from one thing: **sub-nodes follow the same fold rule as
files** — shown by default where there is something to show, hidden by TAB,
with the choice remembered in `agent-river--map-folds`.

Visible by default *is* the enrichment. Collapsible *is* the detail. No new
channel on the line, no disclosure twisty to invent, and the fold machinery is
already written and already survives the redraw.

## The contract

A contributor is a plist on `agent-river-map-contributors`:

```elisp
(list :name    'tests          ; symbol: attribution, retirement, the off switch
      :read    #'my-read       ; (ROOT) -> hash of absolute path -> list of rows
      :refresh #'my-refresh    ; (ROOT PATHS) -> nil, may take as long as it likes
      :ttl     30)             ; seconds before `refresh' is offered the root again
```

Two functions, not one, and that split is forced by the timer: the redraw fires
every few seconds and must never wait, so **`read` is synchronous, instant, and
answers from whatever the contributor has** — while `refresh` is where the
waiting happens, and hands its result back by calling
`agent-river-map-contribute` when it has one. That is `agent-river--vc-stats`
and `agent-river--vc-store` with the names changed.

A row is a plist:

```elisp
(list :text "failing: should fold a subagent's steps"  ; one line, ours to escape
      :face 'agent-river-fail                          ; symbol, applied by the map
      :key  "ert/fold-subagent"                        ; stable across redraws
      :visit (lambda () ...))                          ; optional, what RET does
```

What the map owes the contributor: the fold, the motion, the redraw, the
escaping, the cap, and a guard. What the contributor owes back:

- **Rows, not rendered lines.** A contributor that hands over formatted text
  takes the encoding discipline with it, and the next one formats differently.
- **One line per row, no control characters.** The buffer is line-based:
  positions, text properties and every motion assume it. A newline in a row's
  text does not make two rows, it makes one broken one. Sanitised at the door,
  the way a signal's text is.
- **A stable `:key`.** The redraw restores point by what the line names
  (`agent-river--map-here`, `agent-river--map-goto`), and today that is the
  entry name and the file's `:rel`. A sub-node has neither and would inherit
  its parent's — landing point on the wrong row after every redraw. The key is
  the third component of that identity.
- **Deterministic order**, within a contributor and between them (registration
  order). Anything else jitters between two redraws with nothing having
  happened.
- **Nothing accumulated.** A contributor may cache what it read; it may not
  build a history. What has to be remembered goes through `agent-river-note`
  into the fold, where it is logged, counted and attributable. A second
  ledger beside the fold drifts from it, silently and eventually.
- **No route back to the agent.** Signals stay narrow and factual; a
  contributor's opinion must not reach them. Notes may feed a signal, which is
  exactly why a contributor must note what happened and never what it thinks.
- **"Do not know" renders as absent**, never as a zero or an empty result. The
  landed marker learned this the expensive way: a reading that has not come
  back yet must not be drawn as a negative answer.

And what the map does about a contributor that throws: **retires it**, once,
with a message, like `agent-river--run-observers` does. This path runs on every
redraw; a broken contributor is broken thousands of times, and a view that dies
with it is a worse outcome than a view missing a row.

## Three things that nearly got missed

**Markdown is only safe because every token in it is ours.** That is written
down as the condition for rendering the map as Markdown at all — and a
contributor's text is *not* ours. A test name containing a backtick, a
diagnostic beginning with `#`, a branch called `feature/*bold*`: all of them
restructure the view that is displaying them. The HUD is deliberately not
Markdown for this exact reason. So rows are escaped and fenced where they are
inserted (`agent-river--md-escape`, `agent-river--md-code` already exist for the
export), and the condition stays true by force rather than by luck.

**Faces cannot be set as text properties here.** tree-sitter owns `face` in
this buffer and refontifies on redisplay, which is why the map's own shading
goes on `agent-river-map-face` and becomes overlays after the text is in
(`agent-river--map-shade`). A contributor naming a face is fine; a contributor
setting one would have it quietly disappear on the next redisplay.

**A cap, and a visible one.** `agent-river-map-detail-files` already caps a
directory's files at eight and draws an elision line, because a listing that
can be arbitrarily long is not a listing. A contributor returning two hundred
diagnostics must meet the same wall, and the wall must say it is there.

## Node identity and aggregation

Rows are keyed by **absolute path**, which is the only identity that survives a
redraw, a zoom (`agent-river--map-root`) and two roots with a `src` each. It is
what the folds are keyed on already.

Two cases need an answer rather than a default:

- **A node with no file behind it.** `:missing` entries are real and are drawn
  on purpose — a deletion is something the agent did. A contributor may have
  nothing to say about them, and must not be asked to invent something.
- **Directories and the root.** The diffstat aggregates by prefix because the
  listing gives a directory a line and the line has to mean something. Rows do
  not aggregate: a directory shows the rows a contributor returned *for that
  directory*, and nothing from beneath it. Summing rows would be the second
  account the rule above forbids — the count on the line is the aggregate, the
  rows are not.

## Async, and where `aio` fits

The door is `refresh` plus `agent-river-map-contribute`, and the shape of the
work behind it is the contributor's business: a process sentinel, a timer, a
network call, `aio`. The protocol is "hand back a table when you have one",
which a promise and a callback both satisfy.

`aio` would make a *multi-step* contributor much nicer to write — the diffstat
refresh is four nested callbacks (`diff` → `ls-files` → `for-each-ref` →
`diff MAIN...HEAD`) and would be four sequential awaits. It would also be this
package's first dependency, in a package whose every optional part degrades to
nothing. So: optional sugar for contributor authors, never a requirement of the
protocol, and if it is ever adopted in the core it should be decided on its own
and land first in `agent-river--vc-refresh`, which is where the pain actually
is.

Three costs that are not about the mechanism and will bite regardless:

- **Batch per root, not per node.** Thirty visible lines, one subprocess each,
  every TTL, is a fork bomb with a view attached. `refresh` is handed the root
  and the paths currently drawn, and answers for all of them at once.
- **A TTL and an in-flight guard**, or every redraw starts the work again
  before the last attempt has finished (`:at` and `:proc` in the vc cache).
- **Work stops when the view closes.** Nothing here polls on its own: refresh
  is driven by draws, and the map's teardown already stops the timer and takes
  it off the event stream. A contributor that starts its own timer breaks that
  and must not.

## What was built, and what the first draft got wrong

Two things changed between this note and the code, both on the same point.

**The line had room after all — because the party names left it.** The draft
said enrichment was full and therefore closed. It was full *of the names*, and
the names were the one ragged thing on it, which is why nothing scannable could
ever follow them. Moving them into rows freed the tail and made `:summary` a
real channel rather than a designed-but-unbuilt one. So it is built.

**The diffstat is retrofitted, and that is what makes the protocol real.** The
draft deferred it and offered it as a later test. Deferring a test that decides
whether a design is right keeps the special case alive for the next person to
copy. Moved over, it fits without an exception: `:read` from its own cache,
`:refresh` on its TTL, its own aggregation over a subtree, `:summary` for the
column, and "do not know" as absence. The row spells out what the column
abbreviates, which is the projection rule holding in the one place it would
have been most tempting to break.

Three sorts ship, so that "different kinds" is demonstrated rather than
asserted: **vc** (asynchronous, batched per root, summarised onto the line),
**parties** (from the state, one row each, what the brackets could not fit),
and the **step in flight** (at most one row, and the only present-tense one).

Still not built, deliberately: nothing competes for a second column, because
nothing has earned one. The next contributor that wants the line will find out
whether "the map decides which channel, not the contributor" survives contact.

## Open

- RET on a row without `:visit` opens the node the row is about. The stricter
  reading of "a motion with nowhere to go refuses" is about landing *near*
  something the eye did not choose; the file a row sits under is what it chose.
- No per-contributor off switch beyond editing the list, which is the gesture
  everywhere else in this package.
- **A folded node gives no hint that it has rows.** Directories have always had
  the same silence, so this is consistent rather than new — but it is the one
  place a sixth channel (a disclosure marker) could still earn its keep.
