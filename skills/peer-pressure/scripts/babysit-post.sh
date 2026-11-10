#!/usr/bin/env bash
# Post a babysit pass: new threads, replies, resolves and an approval.
#
# Usage: babysit-post.sh <pr-number> <actions.json> [--dry-run] [--pending]
#
# actions.json:
#   {"summary": "...",
#    "threads": [{"path", "line", "startLine"?, "body"}],
#    "replies": [{"threadId", "body"}],
#    "resolve": ["<threadId>", ...],
#    "approve": "<short review body>"}
# Every key is optional.
#
# New threads go into a review that is created for this call and submitted as a
# COMMENT review, so they are visible at once. A thread whose line is not in the
# diff goes into the review body instead, because GitHub rejects a comment outside
# the diff. Replies are posted at once as ordinary comments through the REST reply
# endpoint. Resolving a thread takes effect at once.
#
# "approve" submits an APPROVE review. It is skipped when the same call adds
# threads, because a PR that needs comments is not approved. This script never
# requests changes.
#
# GitHub allows one pending review per user and PR. When the viewer already has one
# (their own draft), threads are added to it and it is left pending, replies are
# still posted at once, and an approval is skipped. Nothing the user drafted is ever
# submitted by this script.
#
# With --pending nothing is submitted: threads and replies go into the viewer's
# pending review, which the user submits, and "approve" is skipped.
#
# Prints PENDING_REVIEW, THREADS_ADDED, REPLIES_ADDED, LOOSE, RESOLVED, SUBMITTED,
# APPROVED and FAILED as key=value lines, and exits 1 when FAILED is above 0.
# Needs gh and jq.
set -euo pipefail

usage() {
  echo "usage: babysit-post.sh <pr-number> <actions.json> [--dry-run] [--pending]" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
pr="$1"
actions="$2"
shift 2
dry_run=false
pending=false
for opt in "$@"; do
  case "$opt" in
    --dry-run) dry_run=true ;;
    --pending) pending=true ;;
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
want_approve=$(jq -r 'has("approve")' "$actions")
approve_body=$(jq -r '.approve // ""' "$actions")
n_threads=$(jq length <<<"$threads")
n_replies=$(jq length <<<"$replies")
n_resolve=$(jq length <<<"$resolve")

if [ $((n_threads + n_replies + n_resolve)) -eq 0 ] && [ "$want_approve" != true ]; then
  printf 'PENDING_REVIEW=\nTHREADS_ADDED=0\nREPLIES_ADDED=0\nLOOSE=0\nRESOLVED=0\nSUBMITTED=false\nAPPROVED=false\nFAILED=0\n'
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
  if [ "$n_threads" -gt 0 ]; then
    if [ -n "$review_id" ]; then echo "The pending review $review_id would be extended and left pending."
    elif [ "$pending" = true ]; then echo "A pending review would be created and left pending."
    else echo "A review would be created and submitted as a comment."; fi
  fi
  if [ "$want_approve" = true ]; then
    if [ "$pending" = true ] || [ -n "$review_id" ] || [ "$n_threads" -gt 0 ]; then echo "The approval would be skipped."; else echo "The PR would be approved."; fi
  fi
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
[ "$pending" = false ] || need_review=$((n_threads + n_replies))
created=false
if [ "$need_review" -gt 0 ] && [ -z "$review_id" ]; then
  # shellcheck disable=SC2016
  if out=$(gql "create review" -f query='mutation($pr: ID!) { addPullRequestReview(input: {pullRequestId: $pr}) { pullRequestReview { id } } }' -f pr="$pr_id"); then
    review_id=$(jq -r '.data.addPullRequestReview.pullRequestReview.id' <<<"$out")
    created=true
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

# Submit the review only when this call created it, so a draft the user wrote is
# never published by accident.
submitted=false
if [ "$pending" = false ] && [ "$created" = true ] && [ -n "$review_id" ] && [ $((added + n_loose)) -gt 0 ]; then
  # shellcheck disable=SC2016
  if gql "submit review" -f query='mutation($r: ID!) { submitPullRequestReview(input: {pullRequestReviewId: $r, event: COMMENT}) { pullRequestReview { id } } }' \
    -f r="$review_id" >/dev/null; then submitted=true; else failed=$((failed + 1)); fi
elif [ "$pending" = false ] && [ "$created" = false ] && [ -n "$review_id" ]; then
  echo "babysit-post.sh: the viewer's own pending review is left pending" >&2
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
  if [ "$pending" = false ]; then
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

approved=false
if [ "$want_approve" = true ]; then
  if [ "$pending" = true ] || [ "$n_threads" -gt 0 ] || [ -n "$review_id" ]; then
    echo "babysit-post.sh: approval skipped (pending mode, new threads, or the viewer has a pending review)" >&2
  else
    # shellcheck disable=SC2016
    if gql "approve" -f query='mutation($pr: ID!, $body: String) { addPullRequestReview(input: {pullRequestId: $pr, event: APPROVE, body: $body}) { pullRequestReview { id } } }' \
      -f pr="$pr_id" -f body="$approve_body" >/dev/null; then approved=true; else failed=$((failed + 1)); fi
  fi
fi

printf 'PENDING_REVIEW=%s\nTHREADS_ADDED=%s\nREPLIES_ADDED=%s\nLOOSE=%s\nRESOLVED=%s\nSUBMITTED=%s\nAPPROVED=%s\nFAILED=%s\n' \
  "$review_id" "$added" "$replied" "$n_loose" "$resolved" "$submitted" "$approved" "$failed"
[ "$failed" -eq 0 ] || exit 1
