#!/usr/bin/env bash
# Check a PR once and say what a babysit run should do next.
#
# Usage: babysit-poll.sh <pr-number> <state-dir> [--as author]
#
# Compares the PR with <state-dir>/state.json and writes <state-dir>/poll.json with
# the details: the new replies, new comments and unresolved threads. Prints
# key=value lines:
#   STATE            OPEN, MERGED or CLOSED
#   ACTION           done (merged or closed), review (the head moved since the last
#                    review), respond (someone replied or commented since the last
#                    check) or idle. With --as author, review does not exist and
#                    fix-ci (CI fails on a head not yet handled) does.
#   HEAD_SHA, LAST_REVIEWED_SHA, VIEWER, AUTHOR
#   CI               passing, failing, pending or none
#   DRAFT, REVIEW_DECISION, MERGEABLE
#   OPEN_THREADS     unresolved threads, OPEN_OWN_THREADS those the viewer started
#   NEW_REPLIES      replies by others on the viewer's threads since lastSeenAt. With
#                    --as author: comments by others on any unresolved thread
#   APPROVALS, CHANGES_REQUESTED  reviewers whose latest verdict is that one
#   WAITING_ON_AUTHOR  unresolved threads whose last comment is not the viewer's
#   NEW_COMMENTS     comments and reviews by others on the PR since lastSeenAt
#   READY            true when nothing is left to do before a merge. With --as author
#                    it also needs an approval, no change request and no thread
#                    waiting on the viewer, and does not need the head reviewed
#   READY_NOTICE     true when READY and this head has not been announced yet
#   POLLED_AT        the time the check started. Store it as lastSeenAt once the
#                    new activity is handled.
# --as author is for the author of the PR: the viewer is the author, the head moves
# because of the viewer's own pushes, and a failing CI is a job to do. The state
# keys it reads are lastSeenAt, readyNotifiedSha and ciHandledSha.
# Bots are ignored. Never changes the PR or the state. Needs gh and jq.
set -euo pipefail

usage() {
  echo "usage: babysit-poll.sh <pr-number> <state-dir> [--as author]" >&2
  exit 2
}

{ [ "$#" -eq 2 ] || { [ "$#" -eq 4 ] && [ "$3" = "--as" ] && [ "$4" = "author" ]; }; } || usage
pr="$1"
dir="$2"
as="reviewer"
[ "$#" -eq 4 ] && as="author"
case "$pr" in
  '' | *[!0-9]*)
    echo "babysit-poll.sh: PR number must be digits, got: $pr" >&2
    exit 2
    ;;
esac
[ -r "$dir/state.json" ] || { echo "babysit-poll.sh: no state in $dir, run babysit-state.sh init first" >&2; exit 2; }

polled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
owner_repo=$(jq -r '.ownerRepo // empty' "$dir/state.json")
[ -n "$owner_repo" ] || owner_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
owner="${owner_repo%%/*}"
name="${owner_repo##*/}"

view=$(gh pr view "$pr" --json state,isDraft,headRefOid,mergeable,reviewDecision,statusCheckRollup,author)

# shellcheck disable=SC2016 # GraphQL variables, not shell expansions
query='
query($owner: String!, $name: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          path
          line
          comments(first: 50) { nodes { author { login } body createdAt } }
        }
      }
      comments(last: 50) { nodes { author { login } body createdAt } }
      reviews(last: 50) { nodes { author { login } state submittedAt } }
    }
  }
}'
graph=$(gh api graphql -F owner="$owner" -F name="$name" -F number="$pr" -f query="$query")

jq -n --argjson view "$view" --argjson graph "$graph" --slurpfile st "$dir/state.json" --arg now "$polled_at" --arg as "$as" '
  $st[0] as $state
  | ($graph.data.viewer.login // "") as $me
  | ($graph.data.repository.pullRequest) as $p
  | ($state.lastSeenAt // "") as $seen
  | def human: select((.author.login // "") != $me and ((.author.login // "") | endswith("[bot]") | not));
    def checks: ($view.statusCheckRollup // []);
    def failed: ((.conclusion // .state // "") | IN("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"));
    def running: (((.status // "") != "" and .status != "COMPLETED") or ((.state // "") | IN("PENDING", "EXPECTED")));
  ([$p.reviewThreads.nodes[] | select(.isResolved | not)]) as $open
  | ([$open[] | select((.comments.nodes[0].author.login // "") == $me)]) as $own
  | ([(if $as == "author" then $open[] else $own[] end) | . as $t | .comments.nodes[] | human | select(.createdAt > $seen)
       | {threadId: $t.id, path: $t.path, line: $t.line, author: .author.login, body: (.body | .[0:600]), createdAt}]) as $replies
  | ([$open[] | select((.comments.nodes | last | .author.login // "") != $me)]) as $waiting
  | ([$p.reviews.nodes[] | human | select(.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED"))]
      | group_by(.author.login) | map(sort_by(.submittedAt) | last)) as $verdicts
  | ($verdicts | map(select(.state == "APPROVED")) | length) as $approvals
  | ($verdicts | map(select(.state == "CHANGES_REQUESTED")) | length) as $changes
  | ([($p.comments.nodes[] | human | select(.createdAt > $seen) | {author: .author.login, body: (.body | .[0:600]), createdAt}),
      ($p.reviews.nodes[] | human | select((.submittedAt // "") > $seen and .state != "PENDING") | {author: .author.login, body: ("review " + .state), createdAt: .submittedAt})]) as $comments
  | (if (checks | length) == 0 then "none"
     elif (checks | map(select(failed)) | length) > 0 then "failing"
     elif (checks | map(select(running)) | length) > 0 then "pending"
     else "passing" end) as $ci
  | ($view.state) as $st_
  | ($view.headRefOid) as $head
  | ($state.lastReviewedSha // "") as $last
  | (if $st_ != "OPEN" then "done"
     elif $as == "author" then
       (if ($replies | length) + ($comments | length) > 0 then "respond"
        elif $ci == "failing" and $head != ($state.ciHandledSha // "") then "fix-ci"
        else "idle" end)
     elif $head != $last then "review"
     elif ($replies | length) + ($comments | length) > 0 then "respond"
     else "idle" end) as $action
  | (($st_ == "OPEN") and ($view.isDraft | not) and ($ci == "passing" or $ci == "none")
     and (($view.reviewDecision // "") != "CHANGES_REQUESTED") and (($view.mergeable // "") != "CONFLICTING")
     and (if $as == "author" then $approvals >= 1 and $changes == 0 and ($waiting | length) == 0
          else ($open | length) == 0 and $head == $last end)) as $ready
  | {
      polledAt: $now, state: $st_, action: $action, headSha: $head, lastReviewedSha: $last,
      viewer: $me, author: ($view.author.login // ""), ci: $ci, draft: $view.isDraft,
      reviewDecision: ($view.reviewDecision // ""), mergeable: ($view.mergeable // ""),
      openThreads: ($open | length), openOwnThreads: ($own | length),
      newReplies: $replies, newComments: $comments,
      approvals: $approvals, changesRequested: $changes, waitingOnAuthor: ($waiting | length),
      waitingThreads: [$waiting[] | {threadId: .id, path, line, comments: [.comments.nodes[-5:][] | {author: .author.login, body: (.body | .[0:600])}]}],
      ready: $ready, readyNotice: ($ready and (($state.readyNotifiedSha // "") != $head)),
      ownThreads: [$own[] | {threadId: .id, path, line, firstComment: (.comments.nodes[0].body | .[0:300])}]
    }
' >"$dir/poll.json"

jq -r '
  "STATE=\(.state)", "ACTION=\(.action)", "HEAD_SHA=\(.headSha)", "LAST_REVIEWED_SHA=\(.lastReviewedSha)",
  "VIEWER=\(.viewer)", "AUTHOR=\(.author)", "CI=\(.ci)", "DRAFT=\(.draft)",
  "REVIEW_DECISION=\(.reviewDecision)", "MERGEABLE=\(.mergeable)",
  "OPEN_THREADS=\(.openThreads)", "OPEN_OWN_THREADS=\(.openOwnThreads)",
  "NEW_REPLIES=\(.newReplies | length)", "NEW_COMMENTS=\(.newComments | length)",
  "APPROVALS=\(.approvals)", "CHANGES_REQUESTED=\(.changesRequested)", "WAITING_ON_AUTHOR=\(.waitingOnAuthor)",
  "READY=\(.ready)", "READY_NOTICE=\(.readyNotice)", "POLLED_AT=\(.polledAt)"
' "$dir/poll.json"
