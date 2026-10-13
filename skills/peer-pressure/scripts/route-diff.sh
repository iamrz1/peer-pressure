#!/usr/bin/env bash
# Decide between the quick (single reviewer) and full (multi-reviewer) pipeline.
#
# Usage: route-diff.sh <diff-file>
#
# Prints key=value lines: decision, reason, effective_logic_lines, logic_files,
# stakes, message. Files are weighted by kind: generated and import-only files
# count 0, config and data 0.25, tests 0.5, everything else 1.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -r "$1" ]; then
  echo "usage: route-diff.sh <diff-file>" >&2
  exit 2
fi

EFFECTIVE_SIZE_THRESHOLD=150
MAX_LOGIC_FILES=10

awk -v threshold="$EFFECTIVE_SIZE_THRESHOLD" -v maxfiles="$MAX_LOGIC_FILES" '
function reset() {
  added = 0; removed = 0; nonimport = 0; generated = 0
  stakes_auth = 0; stakes_migration = 0; stakes_concurrency = 0
  in_hunk = 0; deleted = 0
}

function classify(path,    lower) {
  lower = tolower(path)
  if (lower ~ /(\.pb\.(go|ts|js)|_grpc\.pb\.go|\.connect\.go|_pb2\.py|_pb2_grpc\.py|\.twirp\.go)$/) return "generated"
  if (lower ~ /(^|\/)(go\.sum|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|cargo\.lock|poetry\.lock|gemfile\.lock|bun\.lockb?)$|\.lock$/) return "generated"
  if (lower ~ /((^|\/)__snapshots__\/|\.snap$|\.golden$|(^|\/)testdata\/)/) return "generated"
  if (generated) return "generated"
  if (lower ~ /(_test\.go$|\.spec\.[^\/]+$|\.test\.[^\/]+$|(^|\/)__tests__\/|(^|\/)test\/|(^|\/)spec\/)/) return "test"
  if ((added + removed) > 0 && nonimport == 0) return "mechanical"
  if (lower ~ /\.(json|ya?ml|toml|tf|jsonnet)$/) return "data-config"
  return "logic"
}

function path_stakes(path,    lower, hits) {
  lower = tolower(path)
  hits = ""
  if (lower ~ /(auth|credential|token|secret|password|oauth|crypto|signing)/) hits = hits " auth"
  if (lower ~ /((^|\/)migrations\/|\.sql$)/) hits = hits " migration"
  if (lower ~ /\.proto$/) hits = hits " public-contract"
  return hits
}

function finish(    cat, weight, changed, hits, w) {
  if (path == "") return
  cat = classify(path)
  changed = added + removed
  weight = (cat == "generated" || cat == "mechanical") ? 0 : (cat == "data-config" ? 0.25 : (cat == "test" ? 0.5 : 1))
  effective += changed * weight
  if (cat == "logic") logic_files++
  if (cat == "generated" || cat == "mechanical") discounted += changed
  if (cat == "logic" || cat == "data-config") {
    hits = path_stakes(path)
    if (stakes_auth && hits !~ /auth/) hits = hits " auth"
    if (stakes_migration && hits !~ /migration/) hits = hits " migration"
    if (stakes_concurrency) hits = hits " concurrency"
    n = split(hits, parts, " ")
    for (i = 1; i <= n; i++) if (parts[i] != "" && index(surfaces, parts[i]) == 0) surfaces = surfaces (surfaces == "" ? "" : ", ") parts[i]
  }
}

BEGIN { effective = 0; logic_files = 0; discounted = 0; surfaces = ""; path = ""; reset() }

/^diff --git / {
  finish()
  reset()
  path = ""
  next
}

!in_hunk && /^\+\+\+ / {
  if ($0 == "+++ /dev/null") { deleted = 1 }
  else { path = substr($0, 5); sub(/^b\//, "", path) }
  next
}

!in_hunk && /^--- / {
  from = substr($0, 5); sub(/^a\//, "", from)
  if (path == "") path = from
  next
}

/^@@ / { in_hunk = 1; next }

in_hunk {
  c = substr($0, 1, 1)
  body = substr($0, 2)
  if (c == "+" || c == "-") {
    if (c == "+") added++; else removed++
    if (body !~ /^[ \t]*$/ && body !~ /^[ \t]*(import|from|use|require|#include)([^A-Za-z0-9_]|$)/) nonimport++
    if (c == "+") {
      low = tolower(body)
      if (low ~ /(auth|credential|token|secret|password|oauth|scram|crypto|encrypt|decrypt|signing)/ || body ~ /(^|[^A-Za-z])(TLS|IAM)([^A-Za-z]|$)/) stakes_auth = 1
      if (body ~ /(CREATE INDEX|ALTER TABLE|DROP[^A-Za-z]|invalidateCache|cache\.Invalidate)/) stakes_migration = 1
    }
    if (body ~ /(go func|sync\.|<-|Mutex|WaitGroup|atomic\.)/) stakes_concurrency = 1
  }
  if (c == "+" || c == " ") {
    if (body ~ /(@generated|Code generated .* DO NOT EDIT)/) generated = 1
  }
}

END {
  finish()
  if (surfaces != "") { decision = "full"; reason = "stakes" }
  else if (logic_files > maxfiles) { decision = "full"; reason = "logic-file-count" }
  else if (effective > threshold) { decision = "full"; reason = "effective-size" }
  else { decision = "quick"; reason = "small" }

  rounded = int(effective + 0.5)
  if (decision == "quick") {
    note = discounted > 0 ? sprintf("; %d generated or mechanical lines discounted", discounted) : ""
    msg = sprintf("Small effective change (%d effective logic lines%s). Using the quick review. Use --full to force the full pipeline.", rounded, note)
  } else if (reason == "stakes") {
    msg = sprintf("High-stakes change detected (%s). Using the full review pipeline.", surfaces)
  } else if (reason == "logic-file-count") {
    msg = sprintf("More than %d hand-written files changed. Using the full review pipeline.", maxfiles)
  } else {
    msg = sprintf("Effective change size (%d logic lines) is over the quick-review limit (%d). Using the full review pipeline.", rounded, threshold)
  }

  printf "decision=%s\nreason=%s\neffective_logic_lines=%d\nlogic_files=%d\nstakes=%s\nmessage=%s\n", decision, reason, rounded, logic_files, surfaces, msg
}
' "$1"
