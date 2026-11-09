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
check "stats count labels" "1 critical, 1 warnings, 1 suggestions" "$stats"
check "findings follow input file order" "F2 F4 F1" "$(jq -r '[.findings[].id] | join(" ")' "$session/scored.json")"
check "findings are numbered after sorting" "1 2 3" "$(jq -r '[.findings[].n] | join(" ")' "$session/scored.json")"
check "score is the sum of lens scores" 5 "$(jq '.findings[0].score' "$session/scored.json")"
check "label comes from the highest score" "critical warning" "$(jq -r '[.findings[0].label, .findings[2].label] | join(" ")' "$session/scored.json")"
check "a high sum does not beat the highest score" suggestion "$(jq -r '.findings[1].label' "$session/scored.json")"
check "confidence passes through, medium by default" "high medium" "$(jq -r '[.findings[0].confidence, .findings[1].confidence] | join(" ")' "$session/scored.json")"

"$scripts/build-report.sh" "$session" >"$tmp/report.out"
check "urgency joins by id" "insist author" "$(jq -r '[.findings[0].urgency, .findings[2].urgency] | join(" ")' "$session/report.json")"
check "unknown urgency is blanked" "" "$(jq -r '.findings[1].urgency' "$session/report.json")"
check "blocking urgency means not ready" false "$(jq '.ready' "$session/report.json")"
check "synthesis lists findings outside the drift section" 2 "$(grep -c '^### ' "$session/synthesis.md")"
check "synthesis carries evidence" "**Evidence:** pkg/a.go:2 discards the error from Flush." "$(grep -m1 '^\*\*Evidence' "$session/synthesis.md")"
check "synthesis carries sources" "Sources: correctness, architecture" "$(grep -m1 '^Sources:' "$session/synthesis.md")"
check "docs-only warnings become drift items" 1 "$(grep -c 'Sources: docs)' "$session/synthesis.md")"
held=$("$scripts/build-report.sh" "$session" --min-urgency ask)
check "min-urgency holds back the lower urgency findings" "1 held back" "$(sed -E 's/.*, ([0-9]+ held back)$/\1/' <<<"$held")"
check "held back findings leave the report" "insist" "$(jq -r '.findings[0].urgency' "$session/report.json")"
check "findings without urgency stay" 2 "$(jq '.findings | length' "$session/report.json")"
if "$scripts/build-report.sh" "$session" --min-urgency bogus 2>/dev/null; then check "min-urgency rejects an unknown level" fail ok; else check "min-urgency rejects an unknown level" 2 "$?"; fi

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
check "a finding is scored from its own lens scores" "1 critical, 0 warnings, 0 suggestions" "$("$scripts/score-findings.sh" "$quick")"
check "the lens scores are summed" 4 "$(jq '.findings[0].score' "$quick/scored.json")"

empty="$tmp/empty"
mkdir -p "$empty"
cp "$root/test/fixtures/session/input.txt" "$empty/"
echo '[]' >"$empty/merged.json"
check "an empty merge scores to zero findings" "0 critical, 0 warnings, 0 suggestions" "$("$scripts/score-findings.sh" "$empty")"
"$scripts/build-report.sh" "$empty" >/dev/null
check "an empty report is ready to merge" true "$(jq '.ready' "$empty/report.json")"
check "an empty report renders no table" "No issues found." "$("$scripts/render-table.sh" "$empty")"
echo '{"not":"an array"}' >"$empty/merged.json"
if "$scripts/score-findings.sh" "$empty" 2>/dev/null; then
  check "invalid merged.json is rejected" fail ok
else
  check "invalid merged.json is rejected" 2 "$?"
fi

sp="$tmp/split"
mkdir -p "$sp"
{
  for i in 1 2 3; do
    printf 'diff --git a/f%s.go b/f%s.go\n--- a/f%s.go\n+++ b/f%s.go\n@@ -1,2 +1,2 @@\n' "$i" "$i" "$i" "$i"
    for j in $(seq 1 40); do echo "+line $i $j padding padding padding"; done
  done
} >"$sp/input.txt"
check "a small input is one chunk" "CHUNKS=1" "$("$scripts/split-diff.sh" "$sp" | sed -n 1p)"
check "a one-chunk input is used as it is" "CHUNK_1=$sp/input.txt" "$("$scripts/split-diff.sh" "$sp" | sed -n 2p)"
"$scripts/split-diff.sh" "$sp" --limit 2500 >"$tmp/split.out"
check "a larger input is cut at file boundaries" "CHUNKS=3" "$(sed -n 1p "$tmp/split.out")"
check "each chunk holds one whole file" "1 1 1" "$(for c in "$sp"/chunk-*.txt; do grep -c '^diff --git' "$c"; done | paste -sd' ' -)"
check "no line is lost when splitting" 120 "$(cat "$sp"/chunk-*.txt | grep -c '^+line')"

big="$tmp/split-big"
mkdir -p "$big"
{
  printf 'diff --git a/big.go b/big.go\n--- a/big.go\n+++ b/big.go\n'
  for h in 1 2 3 4; do
    echo "@@ -$h,1 +$h,1 @@"
    for j in $(seq 1 25); do echo "+hunk $h line $j padding padding"; done
  done
} >"$big/input.txt"
"$scripts/split-diff.sh" "$big" --limit 1500 >/dev/null
check "a large file is cut at hunk boundaries" "1 1 1 1" "$(for c in "$big"/chunk-*.txt; do grep -c '^@@' "$c"; done | paste -sd' ' -)"
check "every part repeats the file header" 4 "$(cat "$big"/chunk-*.txt | grep -c '^diff --git a/big.go')"
check "no chunk is over the limit" 0 "$(for c in "$big"/chunk-*.txt; do [ "$(wc -c <"$c" | tr -d ' ')" -gt 1500 ] && echo over; done | wc -l | tr -d ' ')"
check "no line is lost when splitting a file" 100 "$(cat "$big"/chunk-*.txt | grep -c '^+hunk')"
if "$scripts/split-diff.sh" "$sp" --limit abc 2>/dev/null; then
  check "a non-numeric limit is rejected" fail ok
else
  check "a non-numeric limit is rejected" 2 "$?"
fi

cl="$tmp/cluster"
mkdir -p "$cl"
cp "$root/test/fixtures/session/input.txt" "$cl/"
f() { printf '{"title":"%s","file":"%s","line":%s,"lens":"%s","bar":"%s","evidence":"%s","problem":"p","impact":"i","fix":"f","score":2}' "$1" "$2" "$3" "$4" "$5" "$6"; }
{
  echo "["
  f "Flush error dropped" pkg/a.go 2 correctness unsound "pkg/a.go:2 discards the error"
  echo ","
  f "Rename helper" pkg/a.go 5 maintainability convention "helper name differs from pkg/b.go:9"
  echo ","
  f "Far away problem" pkg/a.go 40 security unsound "pkg/a.go:40 reads input unchecked"
  echo ","
  f "Stale README claim" README.md null docs docs "README row 3 says close flushes"
  echo ","
  f "No evidence given" pkg/a.go 60 correctness unsound ""
  echo "]"
} >"$cl/findings-behavior-1.json"
{
  echo "["
  f "stale readme claim" README.md null docs docs "README row 3 says close flushes"
  echo ","
  f "Wrong category" pkg/a.go 70 correctness style "something long enough here"
  echo ","
  f "Unknown lens" pkg/a.go 80 taste unsound "something long enough here"
  echo ","
  f "Fits no category" pkg/b.go 3 maintainability other "pkg/b.go:3 does X where pkg/c.go:9 does Y"
  echo "]"
} >"$cl/findings-structure-1.json"
echo '{broken' >"$cl/findings-contracts-1.json"
"$scripts/cluster-findings.sh" "$cl" --per 2 >"$tmp/cluster.out"
check "findings are clustered by file and nearby lines" "CLUSTERS=4" "$(grep ^CLUSTERS "$tmp/cluster.out")"
check "findings with no evidence, category or lens are gated" "GATED=3" "$(grep ^GATED "$tmp/cluster.out")"
check "an unreadable findings file is reported" "UNREADABLE=findings-contracts-1.json" "$(grep ^UNREADABLE "$tmp/cluster.out")"
check "one verifier per slice of clusters" "VERIFIERS=2" "$(grep ^VERIFIERS "$tmp/cluster.out")"
check "the last slice holds the rest" 2 "$(jq length "$cl/candidates-2.json")"
check "an other-tagged finding reaches the verifier" "Fits no category" "$(jq -r '[.[] | select(.file == "pkg/b.go")][0].members[0].title' "$cl/candidates.json")"
check "nearby lines share a cluster" "2" "$(jq '[.[] | select(.file == "pkg/a.go")][0].members | length' "$cl/candidates.json")"
check "lines far apart are separate clusters" "2 1" "$(jq -r '[.[] | select(.file == "pkg/a.go")] | map(.members | length) | map(tostring) | join(" ")' "$cl/candidates.json")"
check "findings without a line cluster by title" "2" "$(jq '[.[] | select(.file == "README.md")][0].members | length' "$cl/candidates.json")"
check "a cluster lists its lenses" "correctness maintainability" "$(jq -r '[.[] | select(.line == 2)][0].lenses | join(" ")' "$cl/candidates.json")"
check "gate.txt says why" 1 "$(grep -c 'no evidence' "$cl/gate.txt")"
rm -f "$cl/findings-behavior-1.json" "$cl/findings-structure-1.json" "$cl/findings-contracts-1.json"
if "$scripts/cluster-findings.sh" "$cl" 2>/dev/null; then
  check "no findings files is an error" fail ok
else
  check "no findings files is an error" 3 "$?"
fi

ap="$tmp/verdicts"
mkdir -p "$ap"
cp "$root/test/fixtures/session/input.txt" "$ap/"
cat >"$ap/candidates.json" <<'JSON'
[{"id":"C1","file":"README.md"},{"id":"C2","file":"README.md"},{"id":"C3","file":"pkg/a.go"},{"id":"C4","file":"pkg/a.go"}]
JSON
cat >"$ap/verdicts-1.json" <<'JSON'
[
  {"id":"C1","verdict":"plausible","confidence":"high","argument":"README row 3 shows it","title":"Stale claim","file":"README.md","line":3,"sources":["docs"],"problem":"p","impact":"i","fix":"f","evidence":"e","scores":{"docs":1},"urgency":"bogus","reason":"r"},
  {"id":"C2","verdict":"plausible","confidence":"low","argument":"unknown","note":"could not check"},
  {"id":"C3","verdict":"confirmed","title":"Flush error dropped","file":"pkg/a.go","line":2,"sources":["correctness"],"problem":"p","impact":"i","fix":"f","evidence":"e","scores":{"correctness":3},"urgency":"insist","reason":"data loss"},
  {"id":"C3.2","verdict":"nit","note":"taste"},
  {"id":"C3.3","verdict":"confirmed","title":"No scores","file":"pkg/a.go","line":3,"sources":["correctness"],"problem":"p","impact":"i","fix":"f"}
]
JSON
check "verdicts are counted" "4 candidates: 2 kept, 1 nit, 0 disproved, 1 not sure enough, 1 malformed, 1 unverified" "$("$scripts/apply-verdicts.sh" "$ap")"
check "survivors are numbered in cluster order" "F1 F2" "$(jq -r '[.[].id] | join(" ")' "$ap/merged.json")"
check "a confirmed verdict is high confidence" "medium high" "$(jq -r '[.[].confidence] | join(" ")' "$ap/merged.json")"
check "urgency goes to triage, an unknown value is dropped" '[{"id":"F2","urgency":"insist","reason":"data loss"}]' "$(jq -c . "$ap/triage.json")"
check "the survivors score as findings" "1 critical, 0 warnings, 1 suggestions" "$("$scripts/score-findings.sh" "$ap")"
echo '[{"id":"C1","verdict":"plausible","confidence":"high","title":"t","file":"a","sources":["docs"],"problem":"p","impact":"i","fix":"f","scores":{"docs":1}}]' >"$ap/verdicts-1.json"
check "plausible without an argument is dropped" "0" "$("$scripts/apply-verdicts.sh" "$ap" >/dev/null; jq length "$ap/merged.json")"
echo 'not json' >"$ap/verdicts-1.json"
check "an unreadable verdicts file leaves clusters unverified" "4 candidates: 0 kept, 0 nit, 0 disproved, 0 not sure enough, 0 malformed, 4 unverified" "$("$scripts/apply-verdicts.sh" "$ap" 2>/dev/null)"

# babysit: state, poll, wait, delta and post
bf="$root/test/fixtures/babysit"
bs="$tmp/babysit"
"$scripts/babysit-state.sh" "$bs" init 14 octo/demo
"$scripts/babysit-state.sh" "$bs" init 99 other/x
check "init keeps an existing state" 14 "$("$scripts/babysit-state.sh" "$bs" get pr)"
"$scripts/babysit-state.sh" "$bs" set lastReviewedSha=1234567890123456789012345678901234567890 pass=3 readyNotifiedSha=null lastSeenAt=2026-11-09T09:30:00Z
check "a long digit string stays a string" string "$(jq -r '.lastReviewedSha | type' "$bs/state.json")"
check "a short number becomes a number" number "$(jq -r '.pass | type' "$bs/state.json")"
check "a missing key prints nothing" "" "$("$scripts/babysit-state.sh" "$bs" get nope)"
if "$scripts/babysit-state.sh" "$bs" set oops 2>/dev/null; then check "set needs key=value" fail ok; else check "set needs key=value" 2 "$?"; fi

export GH_STUB_VIEW="$bf/view-open.json"
export GH_STUB_THREADS="$bf/poll-open-thread.json"
pv() { "$scripts/babysit-poll.sh" 14 "$bs" | sed -n "s/^$1=//p"; }
check "a new head asks for a review" review "$(pv ACTION)"
"$scripts/babysit-state.sh" "$bs" set lastReviewedSha=abc123
check "a reply on our thread asks for a response" respond "$(pv ACTION)"
check "only a human reply on our thread counts" "1" "$(pv NEW_REPLIES)"
check "a comment on the PR counts, our own and bots do not" "1" "$(pv NEW_COMMENTS)"
check "the viewer is found" rezoan "$(pv VIEWER)"
check "unresolved threads are counted" "1 1" "$(pv OPEN_THREADS) $(pv OPEN_OWN_THREADS)"
check "an open thread blocks ready" false "$(pv READY)"
"$scripts/babysit-state.sh" "$bs" set lastSeenAt=2026-11-09T14:00:00Z
check "nothing new is idle" idle "$(pv ACTION)"
check "poll.json lists the new replies" 0 "$(jq '.newReplies | length' "$bs/poll.json")"
export GH_STUB_THREADS="$bf/poll-clean.json"
check "all threads resolved, CI passing and reviewed is ready" "true true" "$(pv READY) $(pv READY_NOTICE)"
"$scripts/babysit-state.sh" "$bs" set readyNotifiedSha=abc123
check "ready is announced once per head" "true false" "$(pv READY) $(pv READY_NOTICE)"
export GH_STUB_VIEW="$bf/view-failing.json"
check "failing CI is not ready" "failing false" "$(pv CI) $(pv READY)"
export GH_STUB_VIEW="$bf/view-pending.json"
check "running CI is pending" pending "$(pv CI)"
export GH_STUB_VIEW="$bf/view-merged.json"
check "a merged PR is done" "MERGED done" "$(pv STATE) $(pv ACTION)"
export GH_STUB_VIEW="$bf/view-open.json"

wo=$("$scripts/babysit-wait.sh" 14 "$bs" --interval 0 --max 0)
check "wait gives up after the maximum" WAIT=timeout "$(tail -1 <<<"$wo")"
"$scripts/babysit-state.sh" "$bs" set lastReviewedSha=old111
wo=$("$scripts/babysit-wait.sh" 14 "$bs" --interval 0 --max 0)
check "wait returns when the head moves" WAIT=changed "$(tail -1 <<<"$wo")"
"$scripts/babysit-state.sh" "$bs" set lastReviewedSha=abc123
if "$scripts/babysit-wait.sh" 14 "$bs" --interval x 2>/dev/null; then check "wait rejects a bad interval" fail ok; else check "wait rejects a bad interval" 2 "$?"; fi

dl="$tmp/delta"
mkdir -p "$dl"
export GH_STUB_THREADS="$root/test/fixtures/graphql-threads.json"
export GH_STUB_FILES="pkg/a.go"
export GH_STUB_COMPARE="$bf/compare.diff"
"$scripts/babysit-state.sh" "$bs" set lastReviewedSha=null
check "the first pass reviews the whole PR" "full first-pass" "$("$scripts/babysit-delta.sh" 14 "$bs" "$dl" | sed -nE 's/^(DELTA|REASON)=//p' | paste -sd' ' -)"
check "the first pass keeps the whole diff" "$(wc -c <"$GH_STUB_DIFF" | tr -d ' ')" "$(wc -c <"$dl/input.txt" | tr -d ' ')"
"$scripts/babysit-state.sh" "$bs" set lastReviewedSha=old111
check "later passes review the delta" "incremental old111" "$("$scripts/babysit-delta.sh" 14 "$bs" "$dl" | sed -nE 's/^(DELTA|FROM_SHA)=//p' | paste -sd' ' -)"
check "the delta keeps the PR's own files" "1" "$(grep -c '^diff --git' "$dl/input.txt")"
check "the delta drops files the PR does not change" "0" "$(grep -c 'vendor/base.go' "$dl/input.txt")"
check "the whole diff is kept as full.txt" "pkg/a.go" "$(sed -n 's/^diff --git a\/\(.*\) b\/.*/\1/p' "$dl/full.txt" | head -1)"
export GH_STUB_COMPARE="$bf/compare-base-only.diff"
check "a delta of base changes only is nothing to review" "none base-only" "$("$scripts/babysit-delta.sh" 14 "$bs" "$dl" | sed -nE 's/^(DELTA|REASON)=//p' | paste -sd' ' -)"
check "input is empty then" "0" "$(wc -c <"$dl/input.txt" | tr -d ' ')"
"$scripts/babysit-state.sh" "$bs" set lastReviewedSha=abc123
check "an unmoved head is nothing to review" "none unchanged" "$("$scripts/babysit-delta.sh" 14 "$bs" "$dl" | sed -nE 's/^(DELTA|REASON)=//p' | paste -sd' ' -)"
"$scripts/babysit-state.sh" "$bs" set lastReviewedSha=old111
export GH_STUB_COMPARE_FAIL=1
check "a failed compare falls back to the whole PR" "full force-pushed" "$("$scripts/babysit-delta.sh" 14 "$bs" "$dl" | sed -nE 's/^(DELTA|REASON)=//p' | paste -sd' ' -)"
unset GH_STUB_COMPARE_FAIL GH_STUB_COMPARE GH_STUB_FILES

: >"$GH_STUB_LOG"
export GH_STUB_THREADS="$bf/post-lookup.json"
dry=$("$scripts/babysit-post.sh" 14 "$bf/actions.json" --dry-run)
check "dry run counts the actions" "PR octo/demo#14: 1 inline threads, 1 in the review body, 1 replies, 1 to resolve" "$(head -1 <<<"$dry")"
check "dry run changes nothing" 0 "$(grep -c mutation "$GH_STUB_LOG" || true)"
"$scripts/babysit-post.sh" 14 "$bf/actions.json" >"$tmp/bpost.out"
check "a missing pending review is created" 1 "$(grep -c addPullRequestReview\( "$GH_STUB_LOG" || true)"
check "inline threads, replies, resolves and the body are sent" "1 1 1 1" "$(for m in addPullRequestReviewThread\( addPullRequestReviewThreadReply resolveReviewThread updatePullRequestReview; do grep -c "$m" "$GH_STUB_LOG" || true; done | paste -sd' ' -)"
check "the result is reported" "PRR_new 1 1 1 1 0" "$(sed -n 's/^PENDING_REVIEW=//p;s/^THREADS_ADDED=//p;s/^REPLIES_ADDED=//p;s/^LOOSE=//p;s/^RESOLVED=//p;s/^FAILED=//p' "$tmp/bpost.out" | paste -sd' ' -)"
: >"$GH_STUB_LOG"
export GH_STUB_THREADS="$bf/post-lookup-pending.json"
"$scripts/babysit-post.sh" 14 "$bf/actions.json" >"$tmp/bpost.out"
check "an existing pending review is extended, not created" "0" "$(grep -c addPullRequestReview\( "$GH_STUB_LOG" || true)"
check "the existing review id is used" "PRR_existing" "$(sed -n 's/^PENDING_REVIEW=//p' "$tmp/bpost.out")"
check "the loose thread joins the earlier body" 1 "$(grep -c 'earlier body' "$GH_STUB_LOG" || true)"
check "no review is ever submitted" 0 "$(grep -ci 'submitPullRequestReview\|event' "$GH_STUB_LOG" || true)"
check "the script has no submit call" 0 "$(grep -ci 'submitPullRequestReview' "$scripts/babysit-post.sh" || true)"
echo '{}' >"$tmp/empty-actions.json"
check "no actions do nothing" "0" "$("$scripts/babysit-post.sh" 14 "$tmp/empty-actions.json" | sed -n 's/^THREADS_ADDED=//p')"
unset GH_STUB_VIEW
export GH_STUB_THREADS="$root/test/fixtures/graphql-threads.json"

exit "$fail"
