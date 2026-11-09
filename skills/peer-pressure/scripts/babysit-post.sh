#!/usr/bin/env bash
# Add findings and replies to the viewer's pending review, and resolve threads.
#
# Usage: babysit-post.sh <pr-number> <actions.json> [--dry-run] [--replies-now]
#
# actions.json:
#   {"summary": "...",
#    "threads": [{"path", "line", "startLine"?, "body"}],
#    "replies": [{"threadId", "body"}],
#    "resolve": ["<threadId>", ...]}
# Every key is optional.
#
# New threads and replies go into the viewer's pending review on the PR. It is
# created when there is none and reused when there is, because GitHub allows one
# pending review per user and PR. A thread whose line is not in the diff goes into
# the review body instead, because GitHub rejects a comment outside the diff.
# Resolving a thread takes effect at once, as GitHub has no pending state for it.
#
# With --replies-now the replies are posted at once as ordinary comments through the
# REST reply endpoint, and are not put into the pending review. Without it nothing
# a reply says is visible to others until the user submits the review.
#
# This script never submits a review. It only calls the mutations listed in the
# `gql` calls below. Prints PENDING_REVIEW, THREADS_ADDED, REPLIES_ADDED, LOOSE,
# RESOLVED and FAILED as key=value lines, and exits 1 when FAILED is above 0.
# Needs gh and jq.
set -euo pipefail

usage() {
  echo "usage: babysit-post.sh <pr-number> <actions.json> [--dry-run] [--replies-now]" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
pr="$1"
actions="$2"
shift 2
dry_run=false
replies_now=false
for opt in "$@"; do
  case "$opt" in
    --dry-run) dry_run=true ;;
    --replies-now) replies_now=true ;;
    *) usage ;;
  esac
done
case "$pr" in '' | *[!0-9]*) echo "babysit-post.sh: PR number must be digits, got: $pr" >&2; exit 2 ;; esac
jq -e 'type == "object"' "$actions" >/dev/null 2>&1 ||
  { echo "babysit-post.sh: $actions is not a JSON object" >&2; exit 2; }

threads=$(jq -c '.threads // []' "$actions")
replies=$(jq -c '.replies // []' "$actions")
resolve=$(jq -c '.resolve // []' "$actions")
summary=$(jq -r '.summary // ""' "$actions")
n_threads=$(jq length <<<"$threads")
n_replies=$(jq length <<<"$replies")
n_resolve=$(jq length <<<"$resolve")

if [ $((n_threads + n_replies + n_resolve)) -eq 0 ]; then
  printf 'PENDING_REVIEW=\nTHREADS_ADDED=0\nREPLIES_ADDED=0\nLOOSE=0\nRESOLVED=0\nFAILED=0\n'
  exit 0
fi

here=$(dirname "${BASH_SOURCE[0]}")
owner_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
owner="${owner_repo%%/*}"
name="${owner_repo##*/}"

# shellcheck disable=SC2016 # GraphQL variables, not shell expansions
lookup='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      reviews(states: PENDING, first: 1) { nodes { id body } }
    }
  }
}'
found=$(gh api graphql -F owner="$owner" -F name="$name" -F number="$pr" -f query="$lookup")
pr_id=$(jq -r '.data.repository.pullRequest.id' <<<"$found")
review_id=$(jq -r '.data.repository.pullRequest.reviews.nodes[0].id // empty' <<<"$found")
review_body=$(jq -r '.data.repository.pullRequest.reviews.nodes[0].body // ""' <<<"$found")

valid_json=$("$here/diff-lines.sh" "$pr")
anchored=$(jq -c --argjson valid "$valid_json" '
  [.[] | select(.path != null and .line != null and ($valid[(.path + ":" + (.line | tostring))] // false)
                and (.startLine == null or ($valid[(.path + ":" + (.startLine | tostring))] // false)))]' <<<"$threads")
loose=$(jq -c --argjson valid "$valid_json" '
  [.[] | select((.path != null and .line != null and ($valid[(.path + ":" + (.line | tostring))] // false)
                 and (.startLine == null or ($valid[(.path + ":" + (.startLine | tostring))] // false))) | not)]' <<<"$threads")
n_inline=$(jq length <<<"$anchored")
n_loose=$(jq length <<<"$loose")

new_body=$(jq -rn --arg old "$review_body" --arg s "$summary" --argjson loose "$loose" '
  [ ($old | select(length > 0)),
    ($s | select(length > 0)),
    ($loose | map((if .path then "**`" + .path + (if .line then ":" + (.line | tostring) else "" end) + "`**\n\n" else "" end) + .body)
      | join("\n\n---\n\n") | select(length > 0))
  ] | join("\n\n---\n\n")')

echo "PR $owner_repo#$pr: $n_inline inline threads, $n_loose in the review body, $n_replies replies, $n_resolve to resolve"
if [ "$dry_run" = true ]; then
  [ -z "$review_id" ] && echo "A pending review would be created." || echo "The pending review $review_id would be extended."
  jq -r '.[] | "\n+ \(.path):\(.line)\n\(.body)"' <<<"$anchored"
  jq -r '.[] | "\n> reply on \(.threadId)\n\(.body)"' <<<"$replies"
  jq -r '.[] | "\nresolve \(.)"' <<<"$resolve"
  [ -n "$new_body" ] && printf '\nReview body:\n%s\n' "$new_body"
  exit 0
fi

failed=0
# gql <label> <args...>: one GraphQL call. A failure is counted, not fatal, so that the
# rest of the actions still happen. Prints the response on success.
gql() {
  local label="$1"
  shift
  if ! gh api graphql "$@" 2>&1; then
    echo "babysit-post.sh: $label failed" >&2
    return 1
  fi
}

need_review=$n_threads
[ "$replies_now" = true ] || need_review=$((n_threads + n_replies))
if [ "$need_review" -gt 0 ] && [ -z "$review_id" ]; then
  # shellcheck disable=SC2016
  if out=$(gql "create review" -f query='mutation($pr: ID!) { addPullRequestReview(input: {pullRequestId: $pr}) { pullRequestReview { id } } }' -f pr="$pr_id"); then
    review_id=$(jq -r '.data.addPullRequestReview.pullRequestReview.id' <<<"$out")
  else
    failed=$((failed + 1))
  fi
fi

added=0
replied=0
if [ -n "$review_id" ]; then
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    # shellcheck disable=SC2016 # GraphQL variables, not shell expansions
    args=(-f query='mutation($r: ID!, $path: String!, $body: String!, $line: Int!, $start: Int) { addPullRequestReviewThread(input: {pullRequestReviewId: $r, path: $path, body: $body, line: $line, side: RIGHT, startLine: $start, startSide: RIGHT}) { thread { id } } }'
      -f r="$review_id" -f path="$(jq -r .path <<<"$t")" -f body="$(jq -r .body <<<"$t")" -F line="$(jq -r .line <<<"$t")")
    start=$(jq -r 'if .startLine != null and .startLine != .line then .startLine else empty end' <<<"$t")
    [ -n "$start" ] && args+=(-F start="$start")
    if gql "add thread" "${args[@]}" >/dev/null; then added=$((added + 1)); else failed=$((failed + 1)); fi
  done < <(jq -c '.[]' <<<"$anchored")

  if [ -n "$new_body" ] && [ "$new_body" != "$review_body" ]; then
    # shellcheck disable=SC2016
    gql "update review body" -f query='mutation($r: ID!, $body: String!) { updatePullRequestReview(input: {pullRequestReviewId: $r, body: $body}) { pullRequestReview { id } } }' \
      -f r="$review_id" -f body="$new_body" >/dev/null || failed=$((failed + 1))
  fi
fi

# reply_now <thread-id> <body>: a reply that is visible at once. The REST endpoint
# replies to the root comment of the thread, so that comment's id is looked up first.
reply_now() {
  local cid
  # shellcheck disable=SC2016
  cid=$(gql "find thread" -f query='query($t: ID!) { node(id: $t) { ... on PullRequestReviewThread { comments(first: 1) { nodes { fullDatabaseId } } } } }' -f t="$1" |
    jq -r '.data.node.comments.nodes[0].fullDatabaseId // empty') || return 1
  [ -n "$cid" ] || { echo "babysit-post.sh: thread $1 not found" >&2; return 1; }
  jq -n --arg b "$2" '{body: $b}' | gh api --method POST "repos/$owner_repo/pulls/$pr/comments/$cid/replies" --input - >/dev/null
}

while IFS= read -r r; do
  [ -n "$r" ] || continue
  tid=$(jq -r .threadId <<<"$r")
  body=$(jq -r .body <<<"$r")
  if [ "$replies_now" = true ]; then
    if reply_now "$tid" "$body"; then replied=$((replied + 1)); else failed=$((failed + 1)); fi
  elif [ -n "$review_id" ]; then
    # shellcheck disable=SC2016
    if gql "reply" -f query='mutation($r: ID!, $t: ID!, $body: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewId: $r, pullRequestReviewThreadId: $t, body: $body}) { comment { id } } }' \
      -f r="$review_id" -f t="$tid" -f body="$body" >/dev/null; then replied=$((replied + 1)); else failed=$((failed + 1)); fi
  else
    failed=$((failed + 1))
  fi
done < <(jq -c '.[]' <<<"$replies")

resolved=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  # shellcheck disable=SC2016
  if gql "resolve" -f query='mutation($t: ID!) { resolveReviewThread(input: {threadId: $t}) { thread { id } } }' -f t="$id" >/dev/null; then
    resolved=$((resolved + 1))
  else
    failed=$((failed + 1))
  fi
done < <(jq -r '.[]' <<<"$resolve")

printf 'PENDING_REVIEW=%s\nTHREADS_ADDED=%s\nREPLIES_ADDED=%s\nLOOSE=%s\nRESOLVED=%s\nFAILED=%s\n' \
  "$review_id" "$added" "$replied" "$n_loose" "$resolved" "$failed"
[ "$failed" -eq 0 ] || exit 1
