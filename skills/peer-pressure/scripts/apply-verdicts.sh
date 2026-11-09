#!/usr/bin/env bash
# Turn the verifier verdicts into the findings that survive.
#
# Usage: apply-verdicts.sh <session-dir>
#
# Reads candidates.json and verdicts-*.json. A finding survives when its
# verdict is "confirmed", or "plausible" with high confidence and an argument.
# "nit", "disproved" and "plausible" with any other confidence are dropped. A
# surviving finding that lacks a title, file, problem, impact, fix, lens list or
# a score above 0 is dropped as malformed. A cluster with no verdict at all is
# dropped as unverified: a claim nobody checked is not reported.
#
# Writes merged.json (the survivors, numbered F1, F2, ... in cluster order),
# triage.json (the urgency of each survivor) and prints a stats line. Needs jq.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -r "$1/candidates.json" ]; then
  echo "usage: apply-verdicts.sh <session-dir> (needs candidates.json)" >&2
  exit 2
fi
dir="$1"

shopt -s nullglob
files=("$dir"/verdicts-*.json)

all=$(mktemp "${TMPDIR:-/tmp}/peer-pressure-verdicts.XXXXXX")
trap 'rm -f "$all"' EXIT
for f in "${files[@]}"; do
  if jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    jq '[.[] | select(type == "object" and (.id | type) == "string")]' "$f"
  else
    echo "apply-verdicts.sh: ${f##*/} is not a JSON array, ignoring it" >&2
  fi
done | jq -s 'add // []' >"$all"

jq -n --slurpfile cands "$dir/candidates.json" --slurpfile verdicts "$all" '
  def base: split(".")[0];
  def subid: (split(".") | if length > 1 then (.[1] | tonumber? // 0) else 0 end);
  def text($v): ($v | type) == "string" and (($v | gsub("\\s"; "") | length) > 0);
  def scored: (.scores // {}) | (type == "object") and any(.[]; type == "number" and . > 0);
  def wellformed:
    text(.title) and text(.file) and text(.problem) and text(.impact) and text(.fix)
    and ((.sources // []) | (type == "array") and length > 0) and scored;
  def keeps: .verdict == "confirmed" or (.verdict == "plausible" and .confidence == "high" and text(.argument));

  ($cands[0] | map(.id)) as $ids
  | ($cands[0] | map({key: .id, value: .}) | from_entries) as $byid
  | ($verdicts[0] | map(select(.id | base | IN($ids[])))) as $vs
  | ($ids | map(. as $c | select(($vs | map(select(.id | base == $c)) | length) == 0))) as $missing
  | ($vs | sort_by([(.id | base | ltrimstr("C") | tonumber), (.id | subid)])) as $sorted
  | ($sorted | map(select(keeps))) as $kept
  | ($kept | map(select(wellformed))) as $good
  | ($kept | length - ($good | length)) as $malformed
  | ($sorted | map(select(keeps | not))) as $out
  | ($good | to_entries | map(.key as $i | .value | {
      id: "F\($i + 1)", title, file, line: (.line // null), sources, problem, impact, fix,
      evidence: (.evidence // ""), scores,
      confidence: (if .verdict == "confirmed" then "high" else "medium" end),
      urgency: (if (.urgency // "") | IN("insist", "ask", "author", "optional") then .urgency else "" end),
      reason: (.reason // "")
    })) as $F
  | {
      merged: ($F | map(del(.urgency, .reason))),
      triage: ($F | map(select(.urgency != "") | {id, urgency, reason})),
      stats: {
        clusters: ($ids | length),
        kept: ($F | length),
        nit: ($out | map(select(.verdict == "nit")) | length),
        disproved: ($out | map(select(.verdict == "disproved")) | length),
        unsure: ($out | map(select(.verdict == "plausible")) | length),
        malformed: $malformed,
        unverified: ($missing | length)
      }
    }
' >"$dir/.verdicts.json"

jq '.merged' "$dir/.verdicts.json" >"$dir/merged.json"
jq '.triage' "$dir/.verdicts.json" >"$dir/triage.json"
jq -r '.stats | "\(.clusters) candidates: \(.kept) kept, \(.nit) nit, \(.disproved) disproved, \(.unsure) not sure enough, \(.malformed) malformed, \(.unverified) unverified"' "$dir/.verdicts.json"
rm -f "$dir/.verdicts.json"
