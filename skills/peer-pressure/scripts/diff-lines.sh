#!/usr/bin/env bash
# Print the new-side lines of a PR that a review comment may anchor to.
#
# Usage: diff-lines.sh <pr-number>
#
# Prints a JSON object with one key per line, "path:line" -> true. GitHub rejects
# a whole review when one comment sits on a line outside the diff, so callers
# check against this map first. Needs gh and jq.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: diff-lines.sh <pr-number>" >&2
  exit 2
fi

case "$1" in
  '' | *[!0-9]*)
    echo "diff-lines.sh: PR number must be digits, got: $1" >&2
    exit 2
    ;;
esac

gh pr diff "$1" | awk '
  /^diff --git / { in_hunk = 0; path = ""; next }
  !in_hunk && /^\+\+\+ / { if ($0 != "+++ /dev/null") { path = substr($0, 5); sub(/^b\//, "", path) } next }
  /^@@ / {
    in_hunk = 1
    split($0, parts, " ")
    n = substr(parts[3], 2)
    sub(/,.*/, "", n)
    next
  }
  in_hunk && path != "" {
    c = substr($0, 1, 1)
    if (c == "+" || c == " ") { print path "\t" n; n++ }
  }
' | jq -Rn '[inputs | split("\t") | {(.[0] + ":" + .[1]): true}] | add // {}'
