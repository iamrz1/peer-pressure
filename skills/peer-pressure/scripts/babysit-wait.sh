#!/usr/bin/env bash
# Wait until a babysit run has something to do.
#
# Usage: babysit-wait.sh <pr-number> <state-dir> [--interval SECONDS] [--max SECONDS] [--as author]
#
# Runs babysit-poll.sh every --interval seconds (default 60) until the PR is merged
# or closed, the head moved, someone replied or commented, or the PR became ready
# and that has not been announced. Gives up after --max seconds (default 1800).
# Prints the last poll output and a WAIT line: changed, timeout or error. Five
# polls in a row that fail (network, auth) end the wait with WAIT=error and exit 1.
# --as author is passed to babysit-poll.sh. Never changes the PR or the state. Needs gh and jq.
set -euo pipefail

usage() {
  echo "usage: babysit-wait.sh <pr-number> <state-dir> [--interval SECONDS] [--max SECONDS] [--as author]" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
pr="$1"
dir="$2"
shift 2
interval=60
max=1800
poll_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --interval) [ "$#" -ge 2 ] || usage; interval="$2"; shift 2 ;;
    --max) [ "$#" -ge 2 ] || usage; max="$2"; shift 2 ;;
    --as) { [ "$#" -ge 2 ] && [ "$2" = "author" ]; } || usage; poll_args=(--as author); shift 2 ;;
    *) usage ;;
  esac
done
case "$interval$max" in '' | *[!0-9]*) usage ;; esac

poll="$(dirname "${BASH_SOURCE[0]}")/babysit-poll.sh"
started=$(date +%s)
failures=0
while true; do
  if out=$("$poll" "$pr" "$dir" ${poll_args[@]+"${poll_args[@]}"} 2>&1); then
    failures=0
    action=$(sed -n 's/^ACTION=//p' <<<"$out")
    notice=$(sed -n 's/^READY_NOTICE=//p' <<<"$out")
    if [ "$action" != "idle" ] || [ "$notice" = "true" ]; then
      echo "$out"
      echo "WAIT=changed"
      exit 0
    fi
  else
    failures=$((failures + 1))
    if [ "$failures" -ge 5 ]; then
      echo "$out" >&2
      echo "WAIT=error"
      exit 1
    fi
  fi
  if [ $(($(date +%s) - started)) -ge "$max" ]; then
    [ -n "${out:-}" ] && echo "$out"
    echo "WAIT=timeout"
    exit 0
  fi
  sleep "$interval"
done
