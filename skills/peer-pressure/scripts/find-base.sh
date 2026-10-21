#!/usr/bin/env bash
# Find what the current branch should be reviewed against, also when it sits on
# top of another branch (a stacked PR).
#
# Usage: find-base.sh [--base <ref>]
#
# Prints BASE, MERGE_BASE, STACKED, PARENT_PR and REASON as key=value lines.
# Review the change with: git diff "$MERGE_BASE". The order of checks is:
#   1. --base <ref>, when given
#   2. the base branch of the open PR for this branch (needs gh, skipped if it fails)
#   3. the closest local or remote branch that is an ancestor of HEAD and is
#      nearer than the default branch
#   4. the default branch
# STACKED is true when the base is not the default branch. PARENT_PR is the open
# PR of the base branch, or empty.
set -euo pipefail

explicit=""
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--base" ] || [ -z "$2" ]; then
    echo "usage: find-base.sh [--base <ref>]" >&2
    exit 2
  fi
  explicit="$2"
fi

default=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null || true)
if [ -z "$default" ] || [ "$default" = "origin/HEAD" ]; then
  if git rev-parse --verify -q origin/main >/dev/null; then default="origin/main"; else default="main"; fi
fi
git rev-parse --verify -q "$default" >/dev/null || { echo "find-base.sh: default branch $default not found" >&2; exit 2; }
current=$(git branch --show-current)

# Prefer the remote copy of a branch name, since the local copy may be stale.
resolve() {
  if git rev-parse --verify -q "origin/$1" >/dev/null; then echo "origin/$1"
  elif git rev-parse --verify -q "$1" >/dev/null; then echo "$1"
  fi
}

base=""
reason=""
if [ -n "$explicit" ]; then
  git rev-parse --verify -q "$explicit" >/dev/null || { echo "find-base.sh: $explicit is not a known ref" >&2; exit 2; }
  base="$explicit"
  reason="given with --base"
fi

if [ -z "$base" ] && command -v gh >/dev/null 2>&1; then
  pr_base=$(gh pr view --json baseRefName --jq .baseRefName 2>/dev/null || true)
  if [ -n "$pr_base" ]; then
    resolved=$(resolve "$pr_base")
    if [ -n "$resolved" ]; then
      base="$resolved"
      reason="base branch of the open PR"
    fi
  fi
fi

if [ -z "$base" ]; then
  best_count=$(git rev-list --count "$(git merge-base HEAD "$default")..HEAD")
  while IFS= read -r ref; do
    short="${ref#origin/}"
    case "$short" in "$current" | HEAD | "${default#origin/}") continue ;; esac
    git merge-base --is-ancestor "$ref" HEAD 2>/dev/null || continue
    count=$(git rev-list --count "$ref..HEAD")
    if [ "$count" -gt 0 ] && [ "$count" -lt "$best_count" ]; then
      best_count="$count"
      base="$ref"
      reason="closest branch below this one, $count commits behind HEAD"
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin)
fi

if [ -z "$base" ]; then
  base="$default"
  reason="default branch"
fi

merge_base=$(git merge-base HEAD "$base")
stacked=false
if [ "$base" != "$default" ] && [ "$merge_base" != "$(git merge-base HEAD "$default")" ]; then
  stacked=true
fi

parent_pr=""
if [ "$stacked" = true ] && command -v gh >/dev/null 2>&1; then
  parent_pr=$(gh pr list --head "${base#origin/}" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)
fi

printf 'BASE=%s\nMERGE_BASE=%s\nSTACKED=%s\nPARENT_PR=%s\nREASON=%s\n' "$base" "$merge_base" "$stacked" "$parent_pr" "$reason"
