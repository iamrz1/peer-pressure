#!/usr/bin/env bash
# Check a PR once and say what a babysit run should do next.
#
# Usage: babysit-poll.sh <pr-number> <state-dir>
#
# Compares the PR with <state-dir>/state.json and writes <state-dir>/poll.json with
# the details: the new replies, new comments and unresolved threads. Prints
# key=value lines:
#   STATE            OPEN, MERGED or CLOSED
#   ACTION           done (merged or closed), review (the head moved since the last
#                    review), respond (someone replied or commented since the last
#                    check) or idle
#   HEAD_SHA, LAST_REVIEWED_SHA, VIEWER, AUTHOR
#   CI               passing, failing, pending or none
#   DRAFT, REVIEW_DECISION, MERGEABLE
#   OPEN_THREADS     unresolved threads, OPEN_OWN_THREADS those the viewer started
#   NEW_REPLIES      replies by others on the viewer's threads since lastSeenAt
#   NEW_COMMENTS     comments and reviews by others on the PR since lastSeenAt
#   READY            true when nothing is left to do before a merge
#   READY_NOTICE     true when READY and this head has not been announced yet
#   POLLED_AT        the time the check started. Store it as lastSeenAt once the
#                    new activity is handled.
# Bots are ignored. Never changes the PR or the state. Needs gh and jq.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: babysit-poll.sh <pr-number> <state-dir>" >&2
  exit 2
fi

pr="$1"
dir="$2"
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

jq -n --argjson view "$view" --argjson graph "$graph" --slurpfile st "$dir/state.json" --arg now "$polled_at" '
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
  | ([$own[] | . as $t | .comments.nodes[] | human | select(.createdAt > $seen)
       | {threadId: $t.id, path: $t.path, line: $t.line, author: .author.login, body: (.body | .[0:600]), createdAt}]) as $replies
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
     elif $head != $last then "review"
     elif ($replies | length) + ($comments | length) > 0 then "respond"
     else "idle" end) as $action
  | (($st_ == "OPEN") and ($view.isDraft | not) and ($ci == "passing" or $ci == "none")
     and (($view.reviewDecision // "") != "CHANGES_REQUESTED") and (($view.mergeable // "") != "CONFLICTING")
     and ($open | length) == 0 and $head == $last) as $ready
  | {
      polledAt: $now, state: $st_, action: $action, headSha: $head, lastReviewedSha: $last,
      viewer: $me, author: ($view.author.login // ""), ci: $ci, draft: $view.isDraft,
      reviewDecision: ($view.reviewDecision // ""), mergeable: ($view.mergeable // ""),
      openThreads: ($open | length), openOwnThreads: ($own | length),
      newReplies: $replies, newComments: $comments,
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
  "READY=\(.ready)", "READY_NOTICE=\(.readyNotice)", "POLLED_AT=\(.polledAt)"
' "$dir/poll.json"
