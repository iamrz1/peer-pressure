#!/usr/bin/env bash
# Create a PENDING review on a pull request from a threads JSON file.
#
# Usage: post-pending-review.sh <pr-number> <threads.json> [--dry-run]
#
# threads.json: {"summary": "...", "threads": [{"path", "line", "startLine"?, "body"}]}
#
# The review is never submitted. The user submits it in the GitHub UI. Threads
# whose lines are not part of the diff go into the review body instead, because
# GitHub rejects the whole review when one line is outside the diff.
# Needs gh and jq.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: post-pending-review.sh <pr-number> <threads.json> [--dry-run]" >&2
  exit 2
fi

pr="$1"
threads_file="$2"
dry_run=false
if [ "${3:-}" = "--dry-run" ]; then
  dry_run=true
elif [ -n "${3:-}" ]; then
  echo "post-pending-review.sh: unknown option: $3" >&2
  exit 2
fi

case "$pr" in
  '' | *[!0-9]*)
    echo "post-pending-review.sh: PR number must be digits, got: $pr" >&2
    exit 2
    ;;
esac

jq -e '(.threads | type) == "array"' "$threads_file" >/dev/null ||
  { echo "post-pending-review.sh: $threads_file is not valid threads JSON" >&2; exit 2; }

owner_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
head_sha=$(gh pr view "$pr" --json headRefOid --jq .headRefOid)

# Every new-side line that a review comment may anchor to: "path<TAB>line".
valid_lines=$(gh pr diff "$pr" | awk '
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
')
valid_json=$(jq -Rn '[inputs | split("\t") | {(.[0] + ":" + .[1]): true}] | add // {}' <<<"$valid_lines")

payload=$(jq --arg sha "$head_sha" --argjson valid "$valid_json" '
  def anchored: (.path != null and .line != null and ($valid[(.path + ":" + (.line | tostring))] // false)
    and (.startLine == null or ($valid[(.path + ":" + (.startLine | tostring))] // false)));
  . as $in
  | ([.threads[] | select(anchored)]) as $inline
  | ([.threads[] | select(anchored | not)]) as $loose
  | {
      commit_id: $sha,
      body: (
        [ (($in.summary // "") | select(length > 0)),
          ($loose | map((if .path then "**`" + .path + (if .line then ":" + (.line | tostring) else "" end) + "`**\n\n" else "" end) + .body) | join("\n\n---\n\n") | select(length > 0))
        ] | join("\n\n---\n\n")
      ),
      comments: ($inline | map(
        {path, line, side: "RIGHT", body}
        + (if .startLine != null and .startLine != .line then {start_line: .startLine, start_side: "RIGHT"} else {} end)
      ))
    }
' "$threads_file")

# Safety: a payload with an event would submit the review.
if jq -e 'has("event")' <<<"$payload" >/dev/null; then
  echo "post-pending-review.sh: refusing to submit a review" >&2
  exit 1
fi

inline_count=$(jq '.comments | length' <<<"$payload")
total_count=$(jq '.threads | length' "$threads_file")
echo "PR $owner_repo#$pr: $inline_count inline comments, $((total_count - inline_count)) moved to the review body"

if [ "$dry_run" = true ]; then
  jq -r '(.body | select(length > 0) | "Review body:\n" + .), (.comments[] | "\n\(.path):\(.start_line // .line)-\(.line)\n\(.body)")' <<<"$payload"
  exit 0
fi

if ! response=$(gh api --method POST "repos/$owner_repo/pulls/$pr/reviews" --input - <<<"$payload" 2>&1); then
  echo "$response" >&2
  echo "If you already have a pending review on this PR, submit or delete it in GitHub first." >&2
  exit 1
fi

echo "Pending review created: $(jq -r .html_url <<<"$response")"
echo "It is NOT submitted. Submit it in the GitHub UI when ready."
