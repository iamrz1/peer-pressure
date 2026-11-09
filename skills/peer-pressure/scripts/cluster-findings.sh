#!/usr/bin/env bash
# Gate and cluster the findings that reviewers wrote.
#
# Usage: cluster-findings.sh <session-dir> [--per N] [--gap LINES]
#
# Reads findings-<reviewer>[-<chunk>].json, each a JSON array. A finding is
# dropped when it has no known lens, no bar category, no file, no title or
# problem, or an evidence value that is empty or too short to name anything.
# What is left is grouped into clusters: findings in the same file whose lines
# are at most --gap apart (default 10), or findings without a line and with the
# same title. Clusters are written to candidates.json, and in slices of at most
# --per clusters (default 8) to candidates-1.json, candidates-2.json and so on,
# one slice per verifier. Dropped findings and their reasons go to gate.txt.
#
# Prints CLUSTERS, VERIFIERS, FINDINGS, GATED and, when a file could not be
# parsed, UNREADABLE. Needs jq.
set -euo pipefail

usage() {
  echo "usage: cluster-findings.sh <session-dir> [--per N] [--gap LINES]" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
dir="$1"
shift
per=8
gap=10
while [ "$#" -gt 0 ]; do
  case "$1" in
    --per) [ "$#" -ge 2 ] || usage; per="$2"; shift 2 ;;
    --gap) [ "$#" -ge 2 ] || usage; gap="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$per$gap" in '' | *[!0-9]*) usage ;; esac
[ "$per" -gt 0 ] || usage
[ -d "$dir" ] || { echo "cluster-findings.sh: $dir not found" >&2; exit 2; }

shopt -s nullglob
files=("$dir"/findings-*.json)
if [ "${#files[@]}" -eq 0 ]; then
  echo "cluster-findings.sh: no findings-*.json files in $dir" >&2
  exit 3
fi

all=$(mktemp "${TMPDIR:-/tmp}/peer-pressure-findings.XXXXXX")
trap 'rm -f "$all"' EXIT
unreadable=()
readable=()
for f in "${files[@]}"; do
  if jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    readable+=("$f")
  else
    unreadable+=("${f##*/}")
  fi
done
for f in ${readable[@]+"${readable[@]}"}; do
  name=${f##*/findings-}
  name=${name%.json}
  jq --arg r "$name" '[.[] | if type == "object" then . + {reviewer: $r} else {reviewer: $r, invalid: true} end]' "$f"
done | jq -s 'add // []' >"$all"

rm -f "$dir"/candidates.json "$dir"/candidates-*.json

jq -n --slurpfile all "$all" --argjson gap "$gap" --argjson per "$per" --arg dir "$dir" '
  ["correctness", "security", "architecture", "docs", "compatibility", "performance", "maintainability"] as $lenses
  | ["unsound", "regression", "intent", "convention", "docs", "other"] as $bars
  | def text($v): ($v | type) == "string" and (($v | gsub("\\s"; "") | length) > 0);
  def why:
    if (.invalid // false) then "not an object"
    elif (text(.file) | not) then "no file"
    elif (text(.title) | not) or (text(.problem) | not) then "no title or problem"
    elif ((.lens // "") | IN($lenses[]) | not) then "unknown lens"
    elif ((.bar // "") | IN($bars[]) | not) then "no bar category"
    elif (text(.evidence) | not) or ((.evidence | gsub("\\s"; "") | length) < 10) then "no evidence"
    else empty end;
  def norm: .line |= (if type == "number" then . else null end);
  ($all[0] | map({f: ., why: ((. | why) // null)})) as $checked
  | ($checked | map(select(.why == null) | .f | norm)) as $ok
  | ($checked | map(select(.why != null))) as $bad
  | ($ok | group_by(.file) | map(sort_by(.line // -1))) as $groups
  | [ $groups[]
      | reduce .[] as $f ([];
          if length > 0 and (.[-1].last != null) and ($f.line != null) and (($f.line - .[-1].last) <= $gap)
          then .[-1].members += [$f] | .[-1].last = $f.line
          elif length > 0 and ($f.line == null) and (.[-1].last == null)
               and ((.[-1].members[0].title | ascii_downcase) == ($f.title | ascii_downcase))
          then .[-1].members += [$f]
          else . + [{members: [$f], last: $f.line}] end)
      | .[] ] as $clusters
  | ($clusters | to_entries | map(
      .key as $i | .value
      | {id: "C\($i + 1)", file: .members[0].file, line: .members[0].line,
         lenses: ([.members[].lens] | unique), members: .members})) as $cands
  | {
      candidates: $cands,
      gated: ($bad | map("\(.f.reviewer // "?"): \((.f.title // "?") | tostring): \(.why)")),
      findings: ($ok | length)
    }
' >"$dir/.cluster.json"

jq '.candidates' "$dir/.cluster.json" >"$dir/candidates.json"
jq -r '.gated[]' "$dir/.cluster.json" >"$dir/gate.txt"
clusters=$(jq length "$dir/candidates.json")
verifiers=$(( (clusters + per - 1) / per ))
i=1
while [ "$i" -le "$verifiers" ]; do
  jq --argjson i "$i" --argjson per "$per" '.[(($i - 1) * $per):($i * $per)]' "$dir/candidates.json" >"$dir/candidates-$i.json"
  i=$((i + 1))
done

echo "CLUSTERS=$clusters"
echo "VERIFIERS=$verifiers"
echo "FINDINGS=$(jq '.findings' "$dir/.cluster.json")"
echo "GATED=$(jq '.gated | length' "$dir/.cluster.json")"
if [ "${#unreadable[@]}" -gt 0 ]; then
  echo "UNREADABLE=${unreadable[*]}"
fi
rm -f "$dir/.cluster.json"
