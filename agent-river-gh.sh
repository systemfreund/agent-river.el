#!/bin/sh
# agent-river-gh.sh -- deliver recently updated GitHub issues to the spool.
#
# The pull half of agent-river-launch.el's third direction.  Like
# agent-river-hook.sh it is deliberately thin: it asks `gh' for issues and
# writes what comes back.  It interprets no field, makes no decision and knows
# nothing about rules -- the knowledge of what GitHub calls things lives in
# agent-river-gh.el, in Elisp, under test.
#
# The one thing it does beyond moving bytes is *split*: the spool's unit is
# one occasion, so one issue is one file.  That has to happen before the spool
# or the ledger, the dedupe and the recovery all stop being single-valued.
# The split is `gh --jq', which is bundled with gh -- no external jq.
#
# Usage:  agent-river-gh.sh [DIRECTORY]
#
# Run it from cron, a systemd timer, or `agent-river-gh-mode'.  It is the same
# program either way, which is the point: an Emacs that is not running must
# not be a reason for an issue to go unseen.
#
# Environment:
#   AGENT_RIVER_SPOOL      where candidates are delivered
#   AGENT_RIVER_GH_STATE   where the watermark is kept
#   AGENT_RIVER_GH_LIMIT   how many issues to ask for (default 50)
#   AGENT_RIVER_GH_SINCE   first-run lookback, a gh search date (default 1 day)

set -eu

dir=${1:-$PWD}
cd "$dir" 2>/dev/null || exit 0

xdg=${XDG_STATE_HOME:-$HOME/.local/state}
spool=${AGENT_RIVER_SPOOL:-$xdg/agent-river/spool}
state=${AGENT_RIVER_GH_STATE:-$xdg/agent-river/gh}
limit=${AGENT_RIVER_GH_LIMIT:-50}

# Every step degrades to a no-op.  A poller that fails loudly in a cron job
# every minute is a poller someone switches off.
command -v gh >/dev/null 2>&1 || exit 0
[ -d "$spool" ] || exit 0

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || exit 0
[ -n "$repo" ] || exit 0

# JSON-quote one of *our* strings.  Not parsing: this escapes a value we
# already have so it can sit inside the wrapper, and never reads gh's output.
quote() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

slug=$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')
mkdir -p "$state" || exit 0
mark="$state/$slug.since"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ -r "$mark" ]; then
  since=$(cat "$mark")
else
  since=${AGENT_RIVER_GH_SINCE:-$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")}
fi

# `>=' rather than `>', and the watermark is the time of the run rather than
# the newest issue seen.  Both over-fetch a little, and over-fetching is free:
# the spool deduplicates on the occasion key, so a repeat costs one deleted
# file.  Missing an issue costs an issue.
gh issue list --state open --limit "$limit" \
   --search "updated:>=$since" \
   --json number,title,updatedAt,author,labels,state,url,body \
   --jq '.[]' 2>/dev/null | while IFS= read -r issue; do
  [ -n "$issue" ] || continue
  tmp=$(mktemp "$spool/gh.XXXXXXXX" 2>/dev/null) || continue
  # Built where the watcher does not look -- only `.json' is taken in -- and
  # renamed into place, so the file is never visible half written.
  if printf '{"source":"gh","repo":%s,"cwd":%s,"issue":%s}' \
       "$(quote "$repo")" "$(quote "$PWD")" "$issue" > "$tmp"; then
    mv "$tmp" "$tmp.json" || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
done

# Only after a run that got this far: a failed query must not move the
# watermark past issues it never looked at.
printf '%s' "$now" > "$mark"
