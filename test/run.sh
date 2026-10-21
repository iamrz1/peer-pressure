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
check "removed auth line is high stakes" stakes "$(route removed-auth reason)"
check "removed migration line is high stakes" stakes "$(route removed-migration reason)"
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

"$scripts/pr-context.sh" 1 "$tmp/plain" >"$tmp/plain.out"
check "a PR on the default branch is not stacked" "STACKED=false" "$(grep ^STACKED "$tmp/plain.out")"
GH_STUB_BASE=feat/a GH_STUB_PARENT=7 "$scripts/pr-context.sh" 1 "$tmp/stack" >"$tmp/stack.out"
check "a PR on another branch is stacked" "STACKED=true" "$(grep ^STACKED "$tmp/stack.out")"
check "the parent PR is reported" "PARENT_PR=7" "$(grep ^PARENT_PR "$tmp/stack.out")"
check "the base branch is reported" "BASE_REF=feat/a" "$(grep ^BASE_REF "$tmp/stack.out")"

repo="$tmp/repo"
git init -q -b main "$repo"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.com "$@"; }
commit() { echo "$1" >>"$repo/f.txt"; g add f.txt; g commit -q -m "$1"; }
commit one
g checkout -q -b feat/a
commit two
commit three
sha_a=$(g rev-parse HEAD)
g checkout -q -b feat/b
commit four
found() { local key="$1"; shift; (cd "$repo" && GH_STUB_NOPR=1 "$scripts/find-base.sh" "$@" | sed -n "s/^$key=//p"); }
check "a branch on another branch uses it as the base" feat/a "$(found BASE)"
check "that is a stacked change" true "$(found STACKED)"
check "the diff starts at the parent tip" "$sha_a" "$(found MERGE_BASE)"
check "--base overrides the guess" "main false" "$(found BASE --base main) $(found STACKED --base main)"
check "an open PR decides the base" "feat/a 7" "$(cd "$repo" && GH_STUB_BASE=feat/a GH_STUB_PARENT=7 "$scripts/find-base.sh" | sed -n 's/^BASE=//p;s/^PARENT_PR=//p' | paste -sd' ' -)"
g checkout -q feat/a
check "a branch on the default branch is not stacked" "main false" "$(found BASE) $(found STACKED)"
if (cd "$repo" && "$scripts/find-base.sh" --base nope 2>/dev/null); then
  check "an unknown --base is rejected" fail ok
else
  check "an unknown --base is rejected" 2 "$?"
fi

export GH_STUB_STACK="$root/test/fixtures/stack.json"
for start in 11 12 13; do
  "$scripts/find-stack.sh" "$start" "$tmp/stack-$start" >"$tmp/stack-$start.out"
  check "the stack is found from PR $start" "STACK_PRS=11 12 13" "$(grep ^STACK_PRS "$tmp/stack-$start.out")"
done
check "stack.json runs bottom to top" "first third" "$(jq -r '[first.title, last.title] | join(" ")' "$tmp/stack-12/stack.json")"
"$scripts/stack-context.sh" "$tmp/stack-12" >"$tmp/stack-ctx.out"
check "stack context reports the top PR" "TIP_PR=13" "$(grep ^TIP_PR "$tmp/stack-ctx.out")"
check "stack context reports the bottom base" "BASE_REF=main" "$(grep ^BASE_REF "$tmp/stack-ctx.out")"
check "every PR gets its own directory" "3" "$(find "$tmp/stack-12" -type d -name 'pr-*' | wc -l | tr -d ' ')"
check "pr-meta.json lists every PR" 3 "$(jq length "$tmp/stack-12/pr-meta.json")"
check "combined input is written" 1 "$(test -s "$tmp/stack-12/input.txt" && echo 1)"
unset GH_STUB_STACK

sd="$tmp/assign"
mkdir -p "$sd/pr-11" "$sd/pr-12"
echo '[{"number":11,"title":"bottom"},{"number":12,"title":"top"}]' >"$sd/stack.json"
cat >"$sd/pr-11/input.txt" <<'DIFF'
diff --git a/pkg/a.go b/pkg/a.go
new file mode 100644
--- /dev/null
+++ b/pkg/a.go
@@ -0,0 +1,5 @@
+l1
+l2
+l3
+l4
+l5
DIFF
cat >"$sd/pr-12/input.txt" <<'DIFF'
diff --git a/pkg/a.go b/pkg/a.go
--- a/pkg/a.go
+++ b/pkg/a.go
@@ -1,5 +1,7 @@
 l1
 l2
+NEW1
+NEW2
 l3
 l4
 l5
DIFF
finding() { printf '{"id":"%s","n":1,"title":"t","file":"%s","line":%s,"sources":["correctness"],"problem":"p","impact":"i","fix":"f","label":"warning","score":2}' "$1" "$2" "$3"; }
echo "{\"lenses\":[\"correctness\"],\"dropped\":[],\"findings\":[$(finding F1 pkg/a.go 3),$(finding F2 pkg/a.go 6),$(finding F3 pkg/a.go 2),$(finding F4 pkg/b.go 9),$(finding F5 pkg/a.go null)]}" >"$sd/scored.json"
"$scripts/assign-prs.sh" "$sd" >/dev/null
check "a line added by the top PR goes to it" 12 "$(jq '.findings[0].pr' "$sd/scored.json")"
check "a line shifted by the top PR goes to the lower one" 11 "$(jq '.findings[1].pr' "$sd/scored.json")"
check "a line before the top PR's hunk goes to the lower one" 11 "$(jq '.findings[2].pr' "$sd/scored.json")"
check "a line no PR touched has no owner" null "$(jq '.findings[3].pr' "$sd/scored.json")"
check "a finding without a line goes to the top PR touching the file" 12 "$(jq '.findings[4].pr' "$sd/scored.json")"
"$scripts/assign-prs.sh" "$sd" --split >"$tmp/split.out"
check "PR 12 gets its two findings" 2 "$(jq '.findings | length' "$sd/pr-12/scored.json")"
check "PR 11 gets its two findings" 2 "$(jq '.findings | length' "$sd/pr-11/scored.json")"
check "each PR gets a synthesis" 2 "$(grep -c '^### ' "$sd/pr-12/synthesis.md")"

table_width() {
  python3 -I -c '
import sys, unicodedata
def dw(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else (0 if unicodedata.combining(c) or c in "\u200b\ufe0f" else 1) for c in s)
print(sorted({dw(l.rstrip("\n")) for l in sys.stdin if l[:1] in "┌│├└"}))'
}
"$scripts/build-report.sh" "$sd" >/dev/null
check "a stack review marks the PR in the file cell" 1 "$("$scripts/render-table.sh" "$sd" --width 140 | grep -c '#12 pkg/a.go:3')"
check "the table keeps its width with the PR marker" "[140]" "$("$scripts/render-table.sh" "$sd" --width 140 | table_width)"

session="$tmp/scoring"
mkdir -p "$session"
cp "$root"/test/fixtures/session/* "$session"/
stats=$("$scripts/score-findings.sh" "$session")
check "stats count labels and drops" "1 critical, 1 warnings, 1 suggestions, 1 dropped" "$stats"
check "findings follow input file order" "F2 F4 F1" "$(jq -r '[.findings[].id] | join(" ")' "$session/scored.json")"
check "findings are numbered after sorting" "1 2 3" "$(jq -r '[.findings[].n] | join(" ")' "$session/scored.json")"
check "score is the sum of lens scores" 5 "$(jq '.findings[0].score' "$session/scored.json")"
check "label comes from the highest score" "critical warning" "$(jq -r '[.findings[0].label, .findings[2].label] | join(" ")' "$session/scored.json")"
check "a high sum does not beat the highest score" suggestion "$(jq -r '.findings[1].label' "$session/scored.json")"
check "scores of disproving validators are ignored" 2 "$(jq '.findings[1].score' "$session/scored.json")"
check "majority drop removes a finding" F3 "$(jq -r '.dropped[0].id' "$session/scored.json")"
check "unreadable vote lines are skipped" 3 "$(jq '[.findings[].votes.keep] | max' "$session/scored.json")"
check "trivial from a lens that did not find it is no drop vote" 0 "$(jq '.findings[] | select(.id == "F4") | .votes.drop' "$session/scored.json")"
check "all-confirm gives high confidence" high "$(jq -r '.findings[0].confidence' "$session/scored.json")"

"$scripts/build-report.sh" "$session" >"$tmp/report.out"
check "urgency joins by id" "insist author" "$(jq -r '[.findings[0].urgency, .findings[2].urgency] | join(" ")' "$session/report.json")"
check "unknown urgency is blanked" "" "$(jq -r '.findings[1].urgency' "$session/report.json")"
check "blocking urgency means not ready" false "$(jq '.ready' "$session/report.json")"
check "synthesis lists findings outside the drift section" 2 "$(grep -c '^### ' "$session/synthesis.md")"
check "synthesis carries sources" "Sources: correctness, architecture" "$(grep -m1 '^Sources:' "$session/synthesis.md")"
check "docs-only warnings become drift items" 1 "$(grep -c 'Sources: docs)' "$session/synthesis.md")"

rm "$session/triage.json"
"$scripts/build-report.sh" "$session" >/dev/null
check "without triage a critical finding blocks" false "$(jq '.ready' "$session/report.json")"

jq '[.[] | select(.id != "F2")]' "$session/merged.json" >"$session/m.json" && mv "$session/m.json" "$session/merged.json"
"$scripts/score-findings.sh" "$session" >/dev/null
"$scripts/build-report.sh" "$session" >/dev/null
check "without triage and criticals the change is ready" true "$(jq '.ready' "$session/report.json")"

cp "$root/test/fixtures/session/triage.json" "$session/triage.json"
"$scripts/build-report.sh" "$session" >/dev/null
for w in 100 140; do
  check "table is exactly $w wide" "[$w]" "$("$scripts/render-table.sh" "$session" --width "$w" | table_width)"
done
rendered=$("$scripts/render-table.sh" "$session" --width 120)
check "counts line is first" '**🟡 1 warning** · **🔵 1 suggestion** · ✅ *ready to merge*' "$(head -1 <<<"$rendered")"
check "a divider under the header and between the two rows" 2 "$(grep -c '^├' <<<"$rendered")"
check "score is in brackets" 1 "$(grep -c '🟡 (3)' <<<"$rendered")"
check "urgency label is readable" 1 "$(grep -c 'Up to' <<<"$rendered")"
echo '[{"id":"F1","login":"alice","resolved":true,"dismiss":false},{"id":"F4","login":"bob","dismiss":true}]' >"$session/prior.json"
rendered=$("$scripts/render-table.sh" "$session" --width 220)
check "prior comment marks the row" 1 "$(grep -c '(@alice, resolved)' <<<"$rendered")"
check "dismissed finding is left out" 0 "$(grep -c 'Rename helper\|Vague name' <<<"$rendered")"
rm "$session/prior.json"
if "$scripts/render-table.sh" "$session" --width abc 2>/dev/null; then
  check "non-numeric width is rejected" fail ok
else
  check "non-numeric width is rejected" 2 "$?"
fi

quick="$tmp/quick"
mkdir -p "$quick"
cp "$root/test/fixtures/session/input.txt" "$quick/"
echo '[{"id":"F1","title":"t","file":"pkg/a.go","line":2,"sources":["security"],"scores":{"security":3,"correctness":1}}]' >"$quick/merged.json"
check "quick mode scores without validators" "1 critical, 0 warnings, 0 suggestions, 0 dropped" "$("$scripts/score-findings.sh" "$quick" --quick)"
check "quick mode sums its own scores" 4 "$(jq '.findings[0].score' "$quick/scored.json")"

empty="$tmp/empty"
mkdir -p "$empty"
cp "$root/test/fixtures/session/input.txt" "$empty/"
echo '[]' >"$empty/merged.json"
if "$scripts/score-findings.sh" "$empty" 2>/dev/null; then
  check "missing votes are an error" fail ok
else
  check "missing votes are an error" 3 "$?"
fi
check "an empty merge scores to zero findings" "0 critical, 0 warnings, 0 suggestions, 0 dropped" "$("$scripts/score-findings.sh" "$empty" --quick)"
"$scripts/build-report.sh" "$empty" >/dev/null
check "an empty report is ready to merge" true "$(jq '.ready' "$empty/report.json")"
check "an empty report renders no table" "No issues found." "$("$scripts/render-table.sh" "$empty")"
echo '{"not":"an array"}' >"$empty/merged.json"
if "$scripts/score-findings.sh" "$empty" --quick 2>/dev/null; then
  check "invalid merged.json is rejected" fail ok
else
  check "invalid merged.json is rejected" 2 "$?"
fi

exit "$fail"
