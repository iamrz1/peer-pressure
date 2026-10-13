#!/usr/bin/env bash
# Offline tests for the skill scripts. Uses a stubbed gh from test/stubs.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
scripts="$root/skills/peer-pressure/scripts"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/peer-pressure-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

export PATH="$root/test/stubs:$PATH"
export GH_STUB_DIFF="$root/test/fixtures/pr.diff"
export GH_STUB_THREADS="$root/test/fixtures/graphql-threads.json"
export GH_STUB_LOG="$tmp/gh.log"

fail=0
check() {
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1: expected '$2', got '$3'"
    fail=1
  else
    echo "ok:   $1"
  fi
}

route() { "$scripts/route-diff.sh" "$root/test/fixtures/$1.diff" | sed -n "s/^$2=//p"; }

check "small diff is quick" quick "$(route small decision)"
check "auth path is high stakes" stakes "$(route stakes reason)"
check "generated lines are discounted" 0 "$(route generated effective_logic_lines)"
check "large diff is full" effective-size "$(route large reason)"
check "import-only change counts 0" 0 "$(route imports effective_logic_lines)"

: >"$GH_STUB_LOG"
"$scripts/post-pending-review.sh" 1 "$root/test/fixtures/threads.json" >"$tmp/post.out"
payload=$(tail -n +2 "$GH_STUB_LOG")
check "payload has no event" false "$(jq 'has("event")' <<<"$payload")"
check "one inline comment stays inline" 1 "$(jq '.comments | length' <<<"$payload")"
check "inline comment anchors the range" "11-12" "$(jq -r '.comments[0] | "\(.start_line)-\(.line)"' <<<"$payload")"
check "outside-diff findings go to the body" 2 "$(jq -r '.body' <<<"$payload" | grep -c '^\*\*`pkg/')"
check "summary is first in the body" "Looks fine overall." "$(jq -r '.body' <<<"$payload" | head -1)"
check "payload uses the head sha" abc123 "$(jq -r .commit_id <<<"$payload")"

"$scripts/pr-context.sh" 1 "$tmp/session" >"$tmp/ctx.out"
check "pr-context reports the repo" OWNER_REPO=octo/demo "$(grep ^OWNER_REPO "$tmp/ctx.out")"
check "prior review lists resolved threads" 1 "$(grep -c 'pkg/a.go:11 \[resolved\]' "$tmp/session/prior-review.md")"

if ! "$scripts/post-pending-review.sh" abc "$root/test/fixtures/threads.json" 2>/dev/null; then
  check "non-numeric PR number is rejected" ok ok
else
  check "non-numeric PR number is rejected" ok accepted
fi

exit "$fail"
