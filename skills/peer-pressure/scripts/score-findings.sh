#!/usr/bin/env bash
# Combine merged findings with validator votes into scored findings.
#
# Usage: score-findings.sh <session-dir> [--quick]
#
# Full pipeline: reads merged.json and votes-<perspective>.jsonl. A finding is
# kept when more validators kept it (confirmed or plausible) than dropped it. A
# tie drops it. A "disproved" vote always drops. A "trivial" vote drops only when
# it comes from a lens that found the issue, because a lens that does not care
# about an issue is not a reason to discard it. The score is the sum of the lens scores
# from the validators that kept it, and the label comes from the highest single
# score: 3 is critical, 2 is warning, anything lower is suggestion.
#
# --quick: there are no validators. Reads merged.json only, where each finding
# carries its own lens scores in "scores".
#
# Writes scored.json, ordered by file in the order of input.txt and then by line,
# and prints a stats line. Needs jq.
set -euo pipefail

usage() {
  echo "usage: score-findings.sh <session-dir> [--quick]" >&2
  exit 2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
fi
dir="$1"
quick=false
if [ "${2:-}" = "--quick" ]; then
  quick=true
elif [ -n "${2:-}" ]; then
  usage
fi

merged="$dir/merged.json"
[ -r "$merged" ] || { echo "score-findings.sh: $merged not found" >&2; exit 2; }
jq -e 'type == "array" and all(.[]; (.id | type) == "string" and (.file | type) == "string")' "$merged" >/dev/null ||
  { echo "score-findings.sh: $merged is not a JSON array of findings with id and file" >&2; exit 2; }

votes_file=$(mktemp "${TMPDIR:-/tmp}/peer-pressure-votes.XXXXXX")
trap 'rm -f "$votes_file"' EXIT

if [ "$quick" = true ]; then
  echo '[]' >"$votes_file"
else
  shopt -s nullglob
  files=("$dir"/votes-*.jsonl)
  if [ "${#files[@]}" -eq 0 ]; then
    echo "score-findings.sh: no votes-*.jsonl files in $dir" >&2
    exit 3
  fi
  for f in "${files[@]}"; do
    p=${f##*/votes-}
    p=${p%.jsonl}
    # Lines that are not valid JSON objects with an id are skipped.
    jq -R --arg p "$p" 'fromjson? | select(type == "object" and (.id | type) == "string") | . + {perspective: $p}' "$f"
  done | jq -s . >"$votes_file"
  if [ "$(jq length "$votes_file")" -eq 0 ]; then
    echo "score-findings.sh: the validators wrote no readable votes" >&2
    exit 3
  fi
fi

# Paths in the order they appear in the input: diff headers or "=== path ===" headers.
order=$({
  awk '
    /^diff --git / { p = $0; sub(/^diff --git a\/.* b\//, "", p); print p; next }
    /^=== .* ===$/ { p = $0; sub(/^=== /, "", p); sub(/ ===$/, "", p); print p }
  ' "$dir/input.txt" 2>/dev/null || true
} | jq -R . | jq -s .)

jq -n \
  --slurpfile merged "$merged" \
  --slurpfile votes "$votes_file" \
  --argjson order "$order" \
  --argjson quick "$quick" '
  def clamp: (try tonumber catch 0) | floor | if . < 0 then 0 elif . > 3 then 3 else . end;
  def band($top): if $top >= 3 then "critical" elif $top == 2 then "warning" else "suggestion" end;
  ["correctness", "security", "architecture", "docs", "compatibility", "performance", "maintainability"] as $all_lenses
  | ($votes[0]) as $V
  | [ $merged[0][]
      | . as $x
      | ($V | map(select(.id == $x.id))) as $vs
      | ($vs | map(select(.verdict == "confirmed" or .verdict == "plausible"))) as $keep
      | ($vs | map(select(.verdict == "disproved"
                          or (.verdict == "trivial" and ((. as $v | ($x.sources // []) | index($v.perspective)) != null))))) as $drop
      | (if $quick
           then (($x.scores // {}) | map_values(clamp))
           else ($keep | map({(.perspective): (.score // 0 | clamp)}) | add // {})
         end) as $b
      | ([$b[]] | add // 0) as $sum
      | ([$b[]] | max // 0) as $top
      | $x + {
          breakdown: $b,
          score: $sum,
          label: band($top),
          confidence: (if $quick then "medium"
                       elif (($vs | map(select(.verdict == "confirmed")) | length) * 2) > ($vs | length) then "high"
                       else "medium" end),
          votes: {keep: ($keep | length), drop: ($drop | length)},
          kept: (if $quick then true else (($keep | length) > ($drop | length)) end)
        }
      | del(.scores)
    ] as $scored
  | ($scored | map(select(.kept))
      | sort_by(. as $f | [($order | index($f.file)) // 100000, ($f.line // 0)])
      | to_entries
      | map(.value + {n: (.key + 1)} | del(.kept))) as $kept
  | {
      lenses: (if $quick then $all_lenses else ($V | map(.perspective) | unique) end),
      findings: $kept,
      dropped: ($scored | map(select(.kept | not)) | map({id, title, file, line, votes}))
    }
' >"$dir/scored.json"

jq -r '
  (.findings | map(select(.label == "critical")) | length) as $c
  | (.findings | map(select(.label == "warning")) | length) as $w
  | (.findings | map(select(.label == "suggestion")) | length) as $s
  | "\($c) critical, \($w) warnings, \($s) suggestions, \(.dropped | length) dropped"
' "$dir/scored.json"
