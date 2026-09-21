#!/bin/sh
# agent-river-gh.sh -- deliver recently updated GitHub issues and pull
# requests to the spool.
#
# The pull half of agent-river-spool.el's third direction.  Like
# agent-river-hook.sh it is deliberately thin: it asks `gh' for objects and
# writes what comes back.  It interprets no field and makes no decision -- the
# knowledge of what GitHub calls things lives in agent-river-gh.el, in Elisp,
# under test.
#
# The one thing it does beyond moving bytes is *split*: the spool's unit is one
# thing, so one issue is one file.  That has to happen before the spool, or
# the delivery and everything read out of it stop being single-valued.  The
# split is `gh --jq', which is bundled with gh -- no external jq.
#
# It names which query an answer came out of, in `source', and that is the
# whole of what it knows about the difference between an issue and a pull
# request.  Naming the command it ran is not interpreting a field: the
# alternative is a reader guessing the kind from the shape of what it was
# handed, and guessing a thing's domain from its spelling is the mistake this
# package refuses everywhere else.
#
# Usage:  agent-river-gh.sh [DIRECTORY]
#
# Run it from cron, a systemd timer, or `agent-river-gh-mode'.  It is the same
# program either way, which is the point: an Emacs that is not running must
# not be a reason for an issue to go unseen.
#
# It writes one line to stdout per kind that did not come back whole, and
# nothing else ever.  That is the exception to "every step degrades to a
# no-op", and the reason is that holding the mark is invisible from the other
# side: the window then grows without bound and the whole issue set is
# re-delivered every interval for as long as the Emacs runs.  One kind failing
# while another answers is the case that hides it -- deliveries keep arriving,
# so the poll looks healthy.  `agent-river-gh--poll-1' logs the line into the
# HUD; under cron the same line is the mail, which for a failure that is not
# transient is the point rather than the cost.
#
# Three ways not to come back whole, and every one of them holds the mark, so
# every one of them says so.  The query *failed*.  The query came back at the
# `limit', so the window was not seen to its end -- which is a permanent stall
# rather than a retry, since the next run asks the same window and is cut short
# the same way, and the operator's levers are AGENT_RIVER_GH_LIMIT and a
# narrower AGENT_RIVER_GH_KINDS.  Or the answer could not be *written*: a full
# filesystem or a spool whose permissions changed, which as far as the mark is
# concerned is a query that was not answered.
#
# Both queries go through GitHub's *search* endpoint, because of `--search'.
# Its secondary limit is much tighter than the REST one -- roughly 30 requests
# a minute -- and this is two requests per repository per poll.  A couple of
# dozen repositories on one tick can brush it, and a rate-limited query is a
# failed query: it holds the watermark and now says so.
#
# Environment:
#   AGENT_RIVER_SPOOL      where deliveries are written
#   AGENT_RIVER_GH_STATE   where the watermark is kept
#   AGENT_RIVER_GH_LIMIT   how many of each to ask for (default 50)
#   AGENT_RIVER_GH_SINCE   first-run lookback, a gh search date (default 1 day)
#   AGENT_RIVER_GH_RESCAN  non-empty: ignore the watermark for this one run
#   AGENT_RIVER_GH_KINDS   what to ask for: `issue', `pr', or both (default both)
#   AGENT_RIVER_GH_SEARCH  extra qualifiers appended to every query (default none)

set -eu

dir=${1:-$PWD}
cd "$dir" 2>/dev/null || exit 0

xdg=${XDG_STATE_HOME:-$HOME/.local/state}
spool=${AGENT_RIVER_SPOOL:-$xdg/agent-river/spool}
state=${AGENT_RIVER_GH_STATE:-$xdg/agent-river/gh}
limit=${AGENT_RIVER_GH_LIMIT:-50}
kinds=${AGENT_RIVER_GH_KINDS:-"issue pr"}
# Shares the one `since' window rather than opening a query of its own: the
# qualifier decides *which* objects within the window are worth asking about,
# `since' decides how far back the window reaches, and asking twice would
# double the request count per repository per poll -- against a secondary
# rate limit already tight enough to be worth a comment of its own above.
# Empty by default, which asks about every object rather than a narrower
# question nobody posed.
search=${AGENT_RIVER_GH_SEARCH:-}

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

# What to ask for, and what to call the answer.  Two tables rather than one
# because they are read at different moments -- the fields go to `gh', the
# source name goes into the file -- and because a pull request's extra fields
# are rejected outright by `gh issue list', so there is no shared list to
# narrow from.  The source names are the keys of `agent-river-gh--domains',
# which is where they are turned back into a domain.
fields_for() {
  case $1 in
    issue) printf '%s' 'number,title,updatedAt,author,labels,state,url,body' ;;
    pr) printf '%s%s' 'number,title,updatedAt,author,labels,state,url,body,' \
                      'isDraft,headRefName,baseRefName,isCrossRepository,reviewDecision' ;;
    *) return 1 ;;
  esac
}

source_for() {
  case $1 in
    issue) printf '%s' 'gh' ;;
    pr) printf '%s' 'gh-pr' ;;
    *) return 1 ;;
  esac
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
# the newest object seen.  Both over-fetch a little, and over-fetching is
# free: an issue already on record is recognised by its key, so a repeat costs
# one deleted file.  Missing an issue costs an issue.
#
# One mark for the repository rather than one per kind, because what the mark
# records is the moment before which this repository has been asked about
# *completely* -- so every query shares the one `since', and a kind that could
# not be asked or came back cut short holds the mark for all of them.  Loose
# in one direction only: the kinds that did answer are asked again next run,
# which costs their deleted files.
complete=1
asked=0

# `set -f' because `$kinds' is left unquoted deliberately -- field splitting is
# how a list arrives through one environment variable -- and unquoted means
# pathname expansion too.  `AGENT_RIVER_GH_KINDS=*' would otherwise iterate the
# filenames in the checkout: every one fails `fields_for' and is skipped, so
# the effect today is only that the run asks nothing, but that is now the
# `asked' case below rather than nothing at all, and a configuration value that
# reads the working directory is a surprise whatever it goes on to do.
set -f

for kind in $kinds; do
  # An unknown kind is a typo in somebody's configuration, and the mark is not
  # held for it *on its own account*: there is no window being missed, because
  # nothing will ever ask about one.  Emacs rejects it before it gets here --
  # see `agent-river-gh--kinds' -- so this is the cron path saying no quietly,
  # which is what every other step in this script does too.  What that
  # reasoning does not cover is every kind being rejected, which is the
  # `asked' guard below.
  fields=$(fields_for "$kind") || continue
  src=$(source_for "$kind") || continue

  # The answer goes to a file first, rather than straight down a pipe, because
  # the watermark may only move once the query is known to have *worked*.  A
  # pipeline exits with the status of its right-hand side, and a `while' whose
  # body never runs exits 0 -- so an expired token, a rate limit or a dropped
  # network read exactly like a quiet hour, and the mark would be stamped over
  # every issue the outage hid.  That is the one failure here that does not
  # degrade to a no-op: every other step loses nothing, this one loses issues
  # permanently, because the next run asks about a window that has passed.
  answer=$(mktemp 2>/dev/null) || { complete=0; continue; }
  # `--state all', not `open'.  Asked for the open ones alone, a pull request
  # that merges simply stops being delivered: `:gone' is never set, and the
  # record sits in the domain section -- the queue of what nobody has picked
  # up -- for ever, which is precisely what that section exists not to show.
  # Pull requests close far faster than issues do, so this is the kind that
  # made it worth fixing.  It costs no extra request, which a second query for
  # what has closed would, and the reader already folds `closed' and `merged'
  # into `:gone'; what arrives is bounded by the window either way, so it is
  # what *ended* since the last poll rather than every closed thing there is.
  asked=1
  if ! gh "$kind" list --state all --limit "$limit" \
       --search "updated:>=$since${search:+ $search}" --json "$fields" \
       --jq '.[]' > "$answer" 2>/dev/null; then
    printf 'river-gh: %s query failed in %s\n' "$kind" "$repo"
    rm -f "$answer"
    complete=0
    continue
  fi

  # Per kind rather than per object, because a spool that cannot be written
  # cannot be written fifty times and fifty lines would bury the one that
  # matters.
  wrote=1

  while IFS= read -r object; do
    [ -n "$object" ] || continue
    # Every branch where a delivery does not land clears `complete'.  It used
    # to clear none of them, so a spool at mode 500 -- or a full filesystem --
    # delivered nothing, exited 0, said nothing, and stamped the mark over
    # every object in the window.  That is the `asked' failure in a different
    # branch: there nothing was queried, here nothing was written, and the
    # mark means neither.  AGENTS.md records the same incident one directory
    # over, with `failed/' at mode 500.
    if ! tmp=$(mktemp "$spool/gh.XXXXXXXX" 2>/dev/null); then
      wrote=0
      complete=0
      continue
    fi
    # Built where the watcher does not look -- only `.json' is taken in -- and
    # renamed into place, so the file is never visible half written.
    #
    # `object' rather than `issue' or `pr': the kind is already said once, in
    # the field whose job is saying how to read this, and a second account of
    # it in the nesting is one the two could disagree about.
    if printf '{"source":%s,"repo":%s,"cwd":%s,"object":%s}' \
         "$(quote "$src")" "$(quote "$repo")" "$(quote "$PWD")" "$object" \
         > "$tmp" && mv "$tmp" "$tmp.json"; then
      :
    else
      rm -f "$tmp"
      wrote=0
      complete=0
    fi
  done < "$answer"

  count=$(wc -l < "$answer" | tr -d ' ')
  rm -f "$answer"

  [ "$wrote" -eq 1 ] || \
    printf 'river-gh: %s deliveries could not be written in %s\n' "$kind" "$repo"

  # A truncated run has not seen the window either.  There is no way to tell a
  # full page from a truncated one apart from its size, so a run that came
  # back at the limit keeps the old mark and the next one asks again -- the
  # same over-fetch the header describes, and free for the same reason.
  # Advancing the mark to the oldest object seen would be tighter and would
  # mean reading gh's output, which is the one thing this script does not do.
  #
  # And it *says so*, which is the half the report channel was missing: a `gh'
  # that fails announces itself, a `gh' that came back at the limit did not,
  # and asking for every state rather than the open ones alone made the second
  # far likelier -- the close rate multiplies the objects in a window, and for
  # pull requests that rate is most of them.  A held mark grows the window,
  # which returns more objects, which makes the next truncation likelier: the
  # runway into the stall is short and it was silent.
  if [ "$count" -ge "$limit" ]; then
    printf 'river-gh: %s came back at the limit of %s in %s\n' \
      "$kind" "$limit" "$repo"
    complete=0
  fi
done

set +f

# At least one query ran, *and* all of them answered within the limit.  The
# first half is not pedantry: `complete' starts at 1 and an unknown kind is
# skipped without clearing it, so a run whose every kind was a typo asked
# GitHub nothing and then stamped the mark at the moment of the run -- after
# which the next correctly configured run asks `updated:>=<that moment>' and
# everything before it is missed permanently.  A typo in a crontab is exactly
# that, and a typo by definition gets fixed later, so the damage is done in the
# window between the two.  Asking nothing has to read as not having looked.
[ "$asked" -eq 1 ] || exit 0
[ "$complete" -eq 1 ] || exit 0

printf '%s' "$now" > "$mark"
