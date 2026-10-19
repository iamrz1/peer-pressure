#!/usr/bin/env bash
# Join scored findings with the triage decision and write the report files.
#
# Usage: build-report.sh <session-dir>
#
# Reads scored.json and, when present, triage.json. Writes report.json (read by
# the summary step) and synthesis.md (read by the planner and the formatter), then
# prints a stats line. Without a usable triage.json the urgency stays empty and
# the merge verdict falls back to "any critical finding blocks". Needs jq.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -r "$1/scored.json" ]; then
  echo "usage: build-report.sh <session-dir> (needs scored.json)" >&2
  exit 2
fi

dir="$1"
triage="$dir/triage.json"
if [ ! -r "$triage" ]; then
  triage=$(mktemp "${TMPDIR:-/tmp}/peer-pressure-triage.XXXXXX")
  trap 'rm -f "$triage"' EXIT
  echo '[]' >"$triage"
elif ! jq -e 'type == "array"' "$triage" >/dev/null 2>&1; then
  echo "build-report.sh: triage.json is not a JSON array, ignoring it" >&2
  triage=$(mktemp "${TMPDIR:-/tmp}/peer-pressure-triage.XXXXXX")
  trap 'rm -f "$triage"' EXIT
  echo '[]' >"$triage"
fi

jq --slurpfile t "$triage" '
  ($t[0]) as $T
  | .findings |= map(
      . as $f
      | (($T | map(select(.id == $f.id)) | .[0]) // {}) as $u
      | . + {
          urgency: (if (($u.urgency // "") | IN("insist", "ask", "author", "optional")) then $u.urgency else "" end),
          reason: ($u.reason // "")
        })
  | (.findings) as $F
  | ($F | map(select(.urgency != "")) | length) as $triaged
  | ($F | map(select(.urgency == "insist")) | length) as $blocking
  | ($F | map(select(.label == "critical")) | length) as $critical
  | . + {
      stats: {
        critical: $critical,
        warning: ($F | map(select(.label == "warning")) | length),
        suggestion: ($F | map(select(.label == "suggestion")) | length),
        insist: $blocking,
        triaged: $triaged
      },
      ready: (if $triaged > 0 then $blocking == 0 else $critical == 0 end)
    }
' "$dir/scored.json" >"$dir/report.json"

jq -r --arg today "$(date +%Y-%m-%d)" '
  def where: "\(.file)\(if .line then ":\(.line)" else "" end)";
  def drift: .label != "critical" and ((.sources // []) == ["docs"]);
  def block:
    "### \(.title)\n**File:** \(where)\n**Severity:** \(.label)\n**Score:** \(.score)\n"
    + (if .urgency != "" then "**Urgency:** \(.urgency)\n" else "" end)
    + "**What is wrong:** \(.problem // "")\n**Impact:** \(.impact // "")\n**Recommended change:** \(.fix // "")\n"
    + "Sources: \((.sources // []) | join(", "))\n";
  def section($title; $items):
    "## \($title)\n\n" + (if ($items | length) > 0 then ($items | map(block) | join("\n")) else "None.\n" end) + "\n";

  .findings as $F
  | ($F | map(select(.label == "critical"))) as $crit
  | ($F | map(select(.label == "warning" and (drift | not)))) as $warn
  | ($F | map(select(.label == "suggestion" and (drift | not)))) as $sugg
  | ($F | map(select(drift))) as $docs
  | ($F | map(select((.sources // []) | length >= 2))) as $agree
  | (.lenses - ([$F[].sources // [] | .[]] | unique)) as $clean
  | "# Code Review Synthesis (\($today))\n\n"
    + "## Overall Assessment\n"
    + "\($F | length) issues: \(.stats.critical) critical, \(.stats.warning) warnings, \(.stats.suggestion) suggestions. "
    + (if .ready then "Ready to merge." else "Not ready to merge." end) + "\n\n"
    + section("Critical Issues (must fix before merge)"; $crit)
    + section("Warnings (should fix)"; $warn)
    + section("Suggestions (nice to have)"; $sugg)
    + (if ($docs | length) > 0
         then "## Documentation Drift\n"
              + ($docs | map("- [ ] \((.fix // .title) | rtrimstr(".")) in `\(where)` (Sources: docs)") | join("\n")) + "\n\n"
         else "" end)
    + (if ($agree | length) > 0
         then "## Points of Agreement\n"
              + ($agree | map("- \(.title) (\(.sources | join(", ")))") | join("\n")) + "\n\n"
         else "" end)
    + "## What Looks Good\n"
    + (if ($clean | length) > 0 then "No issues from: \($clean | join(", ")).\n" else "Every lens found something to report.\n" end)
' "$dir/report.json" >"$dir/synthesis.md"

jq -r '"\(.stats.critical) critical, \(.stats.warning) warnings, \(.stats.suggestion) suggestions, \(.stats.insist) insist"' "$dir/report.json"
