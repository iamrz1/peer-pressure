#!/usr/bin/env bash
# Read and update the state of a babysit run.
#
# Usage: babysit-state.sh <state-dir> init <pr-number> <owner/repo>
#        babysit-state.sh <state-dir> get <key>
#        babysit-state.sh <state-dir> set <key>=<value> [<key>=<value> ...]
#
# The state is <state-dir>/state.json. `init` creates it and leaves an existing
# one alone, so a restarted run resumes where it stopped. `get` prints the value,
# or nothing when the key is missing or null. In `set`, true and false become
# booleans, null becomes null, up to nine digits become a number, and everything
# else stays a string, so a commit SHA is never turned into a number. Needs jq.
set -euo pipefail

usage() {
  echo "usage: babysit-state.sh <state-dir> init <pr-number> <owner/repo> | get <key> | set <key>=<value>..." >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
dir="$1"
cmd="$2"
shift 2
file="$dir/state.json"

case "$cmd" in
  init)
    [ "$#" -eq 2 ] || usage
    case "$1" in '' | *[!0-9]*) echo "babysit-state.sh: PR number must be digits, got: $1" >&2; exit 2 ;; esac
    mkdir -p "$dir"
    if [ ! -s "$file" ]; then
      jq -n --argjson pr "$1" --arg repo "$2" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
        pr: $pr, ownerRepo: $repo, startedAt: $now, lastSeenAt: $now,
        lastReviewedSha: null, readyNotifiedSha: null, pass: 0, task: null
      }' >"$file"
    fi
    ;;
  get)
    [ "$#" -eq 1 ] || usage
    [ -r "$file" ] || { echo "babysit-state.sh: no state in $dir" >&2; exit 2; }
    jq -r --arg k "$1" '.[$k] // empty' "$file"
    ;;
  set)
    [ "$#" -ge 1 ] || usage
    [ -r "$file" ] || { echo "babysit-state.sh: no state in $dir" >&2; exit 2; }
    for kv in "$@"; do
      case "$kv" in
        ?*=*) ;;
        *) echo "babysit-state.sh: expected key=value, got: $kv" >&2; exit 2 ;;
      esac
      key="${kv%%=*}"
      val="${kv#*=}"
      tmp=$(mktemp "$dir/.state.XXXXXX")
      jq --arg k "$key" --arg v "$val" '
        .[$k] = (if $v == "true" then true
                 elif $v == "false" then false
                 elif $v == "null" then null
                 elif ($v | test("^[0-9]{1,9}$")) then ($v | tonumber)
                 else $v end)
      ' "$file" >"$tmp"
      mv "$tmp" "$file"
    done
    ;;
  *) usage ;;
esac
