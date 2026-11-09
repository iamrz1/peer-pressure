#!/usr/bin/env bash
# Collect the input of one babysit review pass: what changed since the last review.
#
# Usage: babysit-delta.sh <pr-number> <state-dir> <session-dir>
#
# Runs pr-context.sh, so <session-dir> gets pr-meta.json and prior-review.md as
# usual. Then input.txt becomes the diff between lastReviewedSha and the current
# head, cut down to the files that the PR itself changes, so a merge of the base
# branch into the PR does not bring in the base's own changes. The whole PR diff is
# kept as full.txt. Prints the lines of pr-context.sh and:
#   DELTA     incremental, full or none
#   FROM_SHA  the commit the delta starts at (empty for full)
#   REASON    why it is not incremental: first-pass, force-pushed, unchanged (the head
#             did not move) or base-only (only files outside the PR changed)
# `none` means there is nothing new to review and input.txt is empty. Needs gh and jq.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: babysit-delta.sh <pr-number> <state-dir> <session-dir>" >&2
  exit 2
fi

pr="$1"
dir="$2"
session="$3"
here=$(dirname "${BASH_SOURCE[0]}")

context=$("$here/pr-context.sh" "$pr" "$session")
echo "$context"
head_sha=$(sed -n 's/^HEAD_SHA=//p' <<<"$context")
owner_repo=$(sed -n 's/^OWNER_REPO=//p' <<<"$context")
last=$("$here/babysit-state.sh" "$dir" get lastReviewedSha)

cp "$session/input.txt" "$session/full.txt"

emit() {
  printf 'DELTA=%s\nFROM_SHA=%s\nREASON=%s\n' "$1" "$2" "$3"
  exit 0
}

[ -n "$last" ] || emit full "" first-pass
if [ "$last" = "$head_sha" ]; then
  : >"$session/input.txt"
  emit none "$last" unchanged
fi

if ! gh api "repos/$owner_repo/compare/$last...$head_sha" -H "Accept: application/vnd.github.diff" >"$session/delta.raw" 2>/dev/null ||
  [ ! -s "$session/delta.raw" ]; then
  emit full "" force-pushed
fi

gh pr view "$pr" --json files --jq '.files[].path' >"$session/pr-files.txt"
awk -v list="$session/pr-files.txt" '
  BEGIN { while ((getline line < list) > 0) keep[line] = 1 }
  /^diff --git / { path = $0; sub(/^diff --git a\/.* b\//, "", path); show = (path in keep) }
  show { print }
' "$session/delta.raw" >"$session/input.txt"

if [ ! -s "$session/input.txt" ]; then
  emit none "$last" base-only
fi
emit incremental "$last" ""
