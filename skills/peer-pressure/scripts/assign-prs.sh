#!/usr/bin/env bash
# Give each finding of a whole-stack review to the PR that owns its line.
#
# Usage: assign-prs.sh <session-dir> [--split]
#
# Without a flag: reads stack.json, pr-<number>/input.txt and scored.json, and
# adds a "pr" field to every finding. The owner of a line is the topmost PR that
# added it. A line a PR did not add is traced down through that PR's hunks to
# where it was before the PR, then checked against the PR below. A finding on a
# line no PR added gets "pr": null and stays in the stack summary only.
#
# With --split: after build-report.sh, writes pr-<number>/scored.json (only that
# PR's findings), runs build-report.sh there and prints one stats line per PR.
# Needs jq and awk.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ ! -r "$1/stack.json" ] || [ ! -r "$1/scored.json" ]; then
  echo "usage: assign-prs.sh <session-dir> [--split] (needs stack.json and scored.json)" >&2
  exit 2
fi
dir="$1"
here=$(cd "$(dirname "$0")" && pwd)
prs=$(jq -r 'map(.number) | reverse | .[]' "$dir/stack.json")

if [ "${2:-}" = "--split" ]; then
  [ -r "$dir/triage.json" ] || echo '[]' >"$dir/triage.json"
  for n in $prs; do
    mkdir -p "$dir/pr-$n"
    jq --argjson n "$n" '.findings |= map(select(.pr == $n))' "$dir/scored.json" >"$dir/pr-$n/scored.json"
    cp "$dir/triage.json" "$dir/pr-$n/triage.json"
    echo "PR #$n: $("$here/build-report.sh" "$dir/pr-$n")"
  done
  exit 0
fi

# One JSON record per hunk (h), added line (a) and context line (c) of a diff.
hunks() {
  awk '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    /^diff --git / { f = $0; sub(/.* b\//, "", f); f = esc(f); inh = 0; next }
    /^@@ / {
      match($0, /-[0-9]+(,[0-9]+)?/); o = substr($0, RSTART + 1, RLENGTH - 1); split(o, oa, ",")
      match($0, /\+[0-9]+(,[0-9]+)?/); n = substr($0, RSTART + 1, RLENGTH - 1); split(n, na, ",")
      os = oa[1]; ol = (oa[2] == "" ? 1 : oa[2]); ns = na[1]; nl = (na[2] == "" ? 1 : na[2])
      printf "{\"f\":\"%s\",\"t\":\"h\",\"ns\":%d,\"nl\":%d,\"os\":%d,\"ol\":%d}\n", f, ns, nl, os, ol
      oln = os; nln = ns; inh = 1; next
    }
    inh && /^\+/ { printf "{\"f\":\"%s\",\"t\":\"a\",\"n\":%d}\n", f, nln; nln++; next }
    inh && /^-/ { oln++; next }
    inh && /^ / { printf "{\"f\":\"%s\",\"t\":\"c\",\"n\":%d,\"o\":%d}\n", f, nln, oln; nln++; oln++; next }
  ' "$1"
}

layers=$(mktemp "${TMPDIR:-/tmp}/peer-pressure-layers.XXXXXX")
trap 'rm -f "$layers"' EXIT
for n in $prs; do
  [ -r "$dir/pr-$n/input.txt" ] || { echo "assign-prs.sh: $dir/pr-$n/input.txt not found" >&2; exit 2; }
  hunks "$dir/pr-$n/input.txt" | jq -s --argjson pr "$n" '{pr: $pr, recs: .}'
done | jq -s . >"$layers"

tmp="$dir/scored.json.tmp"
jq --slurpfile layers "$layers" '
  # Owner of a line of the top-most state. Layers run from the top PR down.
  def own($ls; $file; $l):
    if ($ls | length) == 0 then null
    else
      ($ls[0].recs | map(select(.f == $file))) as $r
      | if ($r | any(.t == "a" and .n == $l)) then $ls[0].pr
        else
          (($r | map(select(.t == "c" and .n == $l)) | .[0].o) // null) as $old
          | own($ls[1:]; $file;
              (if $old != null then $old
               else $l - ($r | map(select(.t == "h" and (if .nl == 0 then .ns < $l else (.ns + .nl - 1) < $l end)) | .nl - .ol) | add // 0)
               end))
        end
    end;
  def top_touching($ls; $file):
    ([$ls[] | select(.recs | any(.f == $file)) | .pr] | .[0]) // null;
  .findings |= map(. + {pr: (if .line == null then top_touching($layers[0]; .file) else own($layers[0]; .file; .line) end)})
' "$dir/scored.json" >"$tmp"
mv "$tmp" "$dir/scored.json"
jq -r '[.findings[] | .pr // "none"] | group_by(.) | map("\(.[0]): \(length)") | join(", ")' "$dir/scored.json" | sed 's/^/findings per PR: /'
