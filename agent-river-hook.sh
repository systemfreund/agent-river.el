#!/usr/bin/env bash
#
# Bridge a Claude Code hook event into Emacs.
#
# Usage: agent-river-hook.sh <kind>     (hook payload JSON on stdin)
#
# <kind> is passed from settings.json rather than read out of the payload,
# so the mapping from hook event to focus event stays visible in the config:
#
#   prompt  a task arrived from the user
#   act     the agent is about to run a tool
#   think   a tool returned
#   fail    a tool call errored
#   done    a subagent finished
#   idle    the turn ended
#
# Everything else lives in agent-river.el.  This script only moves bytes:
# the payload goes in through a file and the answer comes back through one,
# so no part of a tool call is ever interpolated into an Emacs Lisp form,
# and no JSON tooling is needed here.
#
# It sits on the critical path of every tool call and must never fail one,
# so every step degrades to a silent no-op.

set -uo pipefail

kind="${1:-act}"
lisp="${AGENT_RIVER_LISP:-$HOME/src/agent-river/agent-river.el}"

payload="$(cat)"
[ -n "$payload" ] || exit 0

in="$(mktemp -t agent-river-in.XXXXXX 2>/dev/null)" || exit 0
out="$in.out"
printf '%s' "$payload" >"$in" || { rm -f "$in"; exit 0; }
: >"$out"

# Emacs forgets everything on restart, and a hook firing into a session
# where agent-river-hook is undefined fails silently, leaving the HUD blank
# with nothing to suggest why.  So every call self-arms.
#
# Bounded: PreToolUse runs synchronously so its line cannot lose the race
# against its own PostToolUse, which puts this on the critical path.  A
# wedged Emacs must cost a bounded pause, not the stream.
timeout "${AGENT_RIVER_TIMEOUT:-2}" emacsclient --eval \
  "(progn (unless (fboundp 'agent-river-hook) (load \"$lisp\" t t))
          (agent-river-hook \"$kind\" \"$in\" \"$out\"))" \
  >/dev/null 2>&1

# Only a synchronous hook can hand anything back -- an async hook's stdout
# is never read -- so the hook carrying signals must not set "async" in
# settings.json.
[ -s "$out" ] && cat "$out"

rm -f "$in" "$out"
exit 0
