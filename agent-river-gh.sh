#!/bin/sh
# agent-river-gh.sh -- deliver recently updated GitHub issues to the spool.
#
# The pull half of agent-river-spool.el's third direction.  Like
# agent-river-hook.sh it is deliberately thin: it asks `gh' for issues and
# writes what comes back.  It interprets no field and makes no decision -- the
# knowledge of what GitHub calls things lives in agent-river-gh.el, in Elisp,
# under test.
#
# The one thing it does beyond moving bytes is *split*: the spool's unit is one
# thing, so one issue is one file.  That has to happen before the spool, or
# the delivery and everything read out of it stop being single-valued.  The
# split is `gh --jq', which is bundled with gh -- no external jq.
#
# Usage:  agent-river-gh.sh [DIRECTORY]
#
# Run it from cron, a systemd timer, or `agent-river-gh-mode'.  It is the same
# program either way, which is the point: an Emacs that is not running must
# not be a reason for an issue to go unseen.
#
# Environment:
#   AGENT_RIVER_SPOOL      where issues are delivered
#   AGENT_RIVER_GH_STATE   where the watermark is kept
#   AGENT_RIVER_GH_LIMIT   how many issues to ask for (default 50)
#   AGENT_RIVER_GH_SINCE   first-run lookback, a gh search date (default 1 day)
#   AGENT_RIVER_GH_RESCAN  non-empty: ignore the watermark for this one run

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
# AGENT_RIVER_GH_RESCAN ignores the watermark for one run, and the reason is
# on the Emacs side: what the watermark protects is a *delivery* being made
# twice, and what consumes a delivery is now an artifact table that does not
# survive a restart.  Incrementally polled, a restarted Emacs would show an
# empty map until somebody touched an issue on GitHub.  So the first poll
# after the mode is switched on asks wide, and every poll after it is
# incremental again -- which is also why the mark is still stamped below.
if [ -r "$mark" ] && [ -z "${AGENT_RIVER_GH_RESCAN:-}" ]; then
  since=$(cat "$mark")
else
  # GNU spells it `-d', BSD spells it `-v', and which one is here decides
  # what the *documented* default means.  Falling straight through to the
  # epoch is not a graceful degradation of "one day": it asks for every open
  # issue the repository has ever had, gets `limit' of them in whatever order
  # the search felt like, and delivers those.
  yesterday=$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || echo "1970-01-01T00:00:00Z")
  since=${AGENT_RIVER_GH_SINCE:-$yesterday}
fi

# `>=' rather than `>', and the watermark is the time of the run rather than
# the newest issue seen.  Both over-fetch a little, and over-fetching is free:
# an issue already on record is recognised by its key, so a repeat costs one
# deleted file.  Missing an issue costs an issue.
#
# The answer goes to a file first, rather than straight down a pipe, because
# the watermark may only move once the query is known to have *worked*.  A
# pipeline exits with the status of its right-hand side, and a `while' whose
# body never runs exits 0 -- so an expired token, a rate limit or a dropped
# network read exactly like a quiet hour, and the mark would be stamped over
# every issue the outage hid.  That is the one failure here that does not
# degrade to a no-op: every other step loses nothing, this one loses issues
# permanently, because the next run asks about a window that has passed.
answer=$(mktemp 2>/dev/null) || exit 0
if ! gh issue list --state open --limit "$limit" \
     --search "updated:>=$since" \
     --json number,title,updatedAt,author,labels,state,url,body \
     --jq '.[]' > "$answer" 2>/dev/null; then
  rm -f "$answer"
  exit 0
fi

while IFS= read -r issue; do
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
done < "$answer"

count=$(wc -l < "$answer" | tr -d ' ')
rm -f "$answer"

# A truncated run has not seen the window either.  There is no way to tell a
# full page from a truncated one apart from its size, so a run that came back
# at the limit keeps the old mark and the next one asks again -- the same
# over-fetch the header describes, and free for the same reason.  Advancing
# the mark to the oldest issue seen would be tighter and would mean reading
# gh's output, which is the one thing this script does not do.
[ "$count" -lt "$limit" ] || exit 0

# Only after a query that was answered and was not cut short: a failed or
# truncated run must not move the watermark past issues it never looked at.
printf '%s' "$now" > "$mark"
