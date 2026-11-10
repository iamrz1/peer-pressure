#!/usr/bin/env bash
# Check a PR once and say what a babysit run should do next.
#
# Usage: babysit-poll.sh <pr-number> <state-dir> [--as author]
#
# Compares the PR with <state-dir>/state.json and writes <state-dir>/poll.json with
# the details: the new replies, new comments and unresolved threads. Prints
# key=value lines:
#   STATE            OPEN, MERGED or CLOSED
#   ACTION           done (the run is over, see END_REASON), review (the head moved
#                    since the last review), respond (someone replied or commented
#                    since the last check) or idle. With --as author, review does
#                    not exist and fix-ci (CI fails on a head not yet handled) does.
#   END_REASON       empty while the run goes on. Otherwise merged or closed (take no
#                    action), or, for a reviewer: approved (the viewer's latest
#                    verdict is an approval), ready (nothing is needed from the
#                    viewer and the PR can merge) or not-needed (it only waits for
#                    reviewers that are not the viewer or the viewer's teams)
#   HEAD_SHA, LAST_REVIEWED_SHA, VIEWER, AUTHOR
#   CI               passing, failing, pending or none
#   DRAFT, REVIEW_DECISION, MERGEABLE, MERGE_STATE (GitHub's mergeStateStatus)
#   VIEWER_VERDICT   the viewer's latest APPROVED, CHANGES_REQUESTED or DISMISSED review
#   NEEDS_MY_REVIEW  true when the PR still needs a review from the viewer or one of
#                    the viewer's teams. False when the required approvals are in,
#                    or when only other reviewers are missing. When the viewer's
#                    teams cannot be read, any requested team counts as theirs.
#   OPEN_THREADS     unresolved threads, OPEN_OWN_THREADS those the viewer started
#   NEW_REPLIES      replies by others on the viewer's threads since lastSeenAt. With
#                    --as author: comments by others on any unresolved thread
#   APPROVALS, CHANGES_REQUESTED  reviewers whose latest verdict is that one
#   WAITING_ON_AUTHOR  unresolved threads whose last comment is not the viewer's
#   NEW_COMMENTS     comments and reviews by others on the PR since lastSeenAt
#   READY            true when nothing is left to do before a merge. With --as author
#                    it also needs the approvals the repo requires (GitHub's review
#                    decision is APPROVED, or there is no rule and one reviewer
#                    approved), no change request and no thread waiting on the
#                    viewer, and does not need the head reviewed
#   READY_NOTICE     author only: true when READY and this head has not been announced
#                    yet. A reviewer run ends through END_REASON instead
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

view=$(gh pr view "$pr" --json state,isDraft,headRefOid,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,author)

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
      reviewRequests(first: 50) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } } } }
    }
  }
}'
graph=$(gh api graphql -F owner="$owner" -F name="$name" -F number="$pr" -f query="$query")

# The viewer's teams decide whether a requested team review is theirs. Reading them
# needs org access, so a failure is not fatal: the teams are then unknown (null).
teams=null
if [ "$as" = "reviewer" ]; then
  me=$(jq -r '.data.viewer.login // empty' <<<"$graph")
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansions
  teams=$(gh api graphql -F org="$owner" -F me="$me" \
    -f query='query($org: String!, $me: String!) { organization(login: $org) { teams(first: 100, userLogins: [$me]) { nodes { slug } } } }' 2>/dev/null |
    jq -ce '[.data.organization.teams.nodes[].slug]' 2>/dev/null) || teams=null
fi

jq -n --argjson view "$view" --argjson graph "$graph" --slurpfile st "$dir/state.json" --arg now "$polled_at" --arg as "$as" --argjson teams "$teams" '
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
  | ([$p.reviews.nodes[] | select((.author.login // "") == $me and (.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED")))]
      | sort_by(.submittedAt) | last // {} | .state // "") as $mine
  | ([$p.reviews.nodes[] | select((.author.login // "") == $me and .state != "PENDING")] | length > 0) as $iReviewed
  | (($p.reviewRequests.nodes // []) | map(.requestedReviewer // {})) as $reqs
  | ([$reqs[] | select(.__typename == "User") | .login]) as $reqUsers
  | ([$reqs[] | select(.__typename == "Team") | .slug]) as $reqTeams
  | (($reqUsers | index($me)) != null) as $reqMe
  | (if $teams == null then ($reqTeams | length) > 0
     else ([$reqTeams[] | select(. as $s | $teams | index($s) != null)] | length) > 0 end) as $reqMyTeam
  | ($view.reviewDecision // "") as $rd
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
  | (($view.mergeStateStatus // "") | IN("BLOCKED", "DIRTY", "DRAFT") | not) as $mergeable
  | (($st_ == "OPEN") and ($view.isDraft | not) and ($ci == "passing" or $ci == "none") and $mergeable
     and ($rd != "CHANGES_REQUESTED") and (($view.mergeable // "") != "CONFLICTING")
     and (if $as == "author" then ($rd == "APPROVED" or ($rd == "" and $approvals >= 1)) and $changes == 0 and ($waiting | length) == 0
          else ($open | length) == 0 and $head == $last end)) as $ready
  | (if $rd == "APPROVED" then false
     elif $rd == "CHANGES_REQUESTED" then true
     elif $rd == "REVIEW_REQUIRED" then ($reqMe or $reqMyTeam or $iReviewed or (($reqUsers | length) + ($reqTeams | length)) == 0)
     else $approvals == 0 end) as $needsMine
  | (if $st_ == "MERGED" then "merged"
     elif $st_ != "OPEN" then "closed"
     elif $as == "author" then ""
     elif $mine == "APPROVED" then "approved"
     elif ($needsMine | not) and $ready and $rd != "REVIEW_REQUIRED" then "ready"
     elif ($needsMine | not) and $rd == "REVIEW_REQUIRED" then "not-needed"
     else "" end) as $final
  | (if $final != "" then "done"
     elif $as == "author" then
       (if ($replies | length) + ($comments | length) > 0 then "respond"
        elif $ci == "failing" and $head != ($state.ciHandledSha // "") then "fix-ci"
        else "idle" end)
     elif $head != $last then "review"
     elif ($replies | length) + ($comments | length) > 0 then "respond"
     else "idle" end) as $action
  | {
      polledAt: $now, state: $st_, action: $action, headSha: $head, lastReviewedSha: $last,
      viewer: $me, author: ($view.author.login // ""), ci: $ci, draft: $view.isDraft,
      reviewDecision: $rd, mergeable: ($view.mergeable // ""), mergeState: ($view.mergeStateStatus // ""),
      viewerVerdict: $mine, needsMyReview: $needsMine, endReason: $final,
      openThreads: ($open | length), openOwnThreads: ($own | length),
      newReplies: $replies, newComments: $comments,
      approvals: $approvals, changesRequested: $changes, waitingOnAuthor: ($waiting | length),
      waitingThreads: [$waiting[] | {threadId: .id, path, line, comments: [.comments.nodes[-5:][] | {author: .author.login, body: (.body | .[0:600])}]}],
      ready: $ready, readyNotice: ($ready and $as == "author" and (($state.readyNotifiedSha // "") != $head)),
      ownThreads: [$own[] | {threadId: .id, path, line, firstComment: (.comments.nodes[0].body | .[0:300])}]
    }
' >"$dir/poll.json"

jq -r '
  "STATE=\(.state)", "ACTION=\(.action)", "END_REASON=\(.endReason)", "HEAD_SHA=\(.headSha)", "LAST_REVIEWED_SHA=\(.lastReviewedSha)",
  "VIEWER=\(.viewer)", "AUTHOR=\(.author)", "CI=\(.ci)", "DRAFT=\(.draft)",
  "REVIEW_DECISION=\(.reviewDecision)", "MERGEABLE=\(.mergeable)", "MERGE_STATE=\(.mergeState)",
  "VIEWER_VERDICT=\(.viewerVerdict)", "NEEDS_MY_REVIEW=\(.needsMyReview)",
  "OPEN_THREADS=\(.openThreads)", "OPEN_OWN_THREADS=\(.openOwnThreads)",
  "NEW_REPLIES=\(.newReplies | length)", "NEW_COMMENTS=\(.newComments | length)",
  "APPROVALS=\(.approvals)", "CHANGES_REQUESTED=\(.changesRequested)", "WAITING_ON_AUTHOR=\(.waitingOnAuthor)",
  "READY=\(.ready)", "READY_NOTICE=\(.readyNotice)", "POLLED_AT=\(.polledAt)"
' "$dir/poll.json"
