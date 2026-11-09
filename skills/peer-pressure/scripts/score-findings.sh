#!/usr/bin/env bash
# Score the findings that survived verification.
#
# Usage: score-findings.sh <session-dir>
#
# Reads merged.json, where each finding carries its own lens scores in "scores"
# (the verifier or the quick reviewer wrote them). The score is the sum of the
# lens scores, and the label comes from the highest single score: 3 is critical,
# 2 is warning, anything lower is suggestion. A sum alone would let a style nit
# that every lens mentions outrank a data-loss bug that only one lens sees.
#
# Writes scored.json, ordered by file in the order of input.txt and then by line,
# and prints a stats line. Needs jq.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: score-findings.sh <session-dir>" >&2
  exit 2
fi
dir="$1"

merged="$dir/merged.json"
[ -r "$merged" ] || { echo "score-findings.sh: $merged not found" >&2; exit 2; }
jq -e 'type == "array" and all(.[]; (.id | type) == "string" and (.file | type) == "string")' "$merged" >/dev/null ||
  { echo "score-findings.sh: $merged is not a JSON array of findings with id and file" >&2; exit 2; }

# Paths in the order they appear in the input: diff headers or "=== path ===" headers.
order=$({
  awk '
    /^diff --git / { p = $0; sub(/^diff --git a\/.* b\//, "", p); print p; next }
    /^=== .* ===$/ { p = $0; sub(/^=== /, "", p); sub(/ ===$/, "", p); print p }
  ' "$dir/input.txt" 2>/dev/null || true
} | jq -R . | jq -s .)

jq -n \
  --slurpfile merged "$merged" \
  --argjson order "$order" '
  def clamp: (try tonumber catch 0) | floor | if . < 0 then 0 elif . > 3 then 3 else . end;
  def band($top): if $top >= 3 then "critical" elif $top == 2 then "warning" else "suggestion" end;
  ["correctness", "security", "architecture", "docs", "compatibility", "performance", "maintainability"] as $all_lenses
  | [ $merged[0][]
      | . as $x
      | (($x.scores // {}) | map_values(clamp)) as $b
      | ([$b[]] | add // 0) as $sum
      | ([$b[]] | max // 0) as $top
      | $x + {
          breakdown: $b,
          score: $sum,
          label: band($top),
          confidence: ($x.confidence // "medium")
        }
      | del(.scores)
    ]
  | sort_by(. as $f | [($order | index($f.file)) // 100000, ($f.line // 0)])
  | to_entries
  | map(.value + {n: (.key + 1)}) as $findings
  | {lenses: $all_lenses, findings: $findings, dropped: []}
' >"$dir/scored.json"

jq -r '
  (.findings | map(select(.label == "critical")) | length) as $c
  | (.findings | map(select(.label == "warning")) | length) as $w
  | (.findings | map(select(.label == "suggestion")) | length) as $s
  | "\($c) critical, \($w) warnings, \($s) suggestions"
' "$dir/scored.json"
