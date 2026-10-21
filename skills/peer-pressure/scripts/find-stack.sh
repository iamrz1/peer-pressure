#!/usr/bin/env bash
# Find the stack of open PRs that a PR belongs to.
#
# Usage: find-stack.sh <pr-number> <session-dir>
#
# Walks down through each PR's base branch until it reaches the default branch,
# and up through PRs that use the head branch as their base. Writes stack.json
# (bottom to top: number, title, headRefName, baseRefName) and prints
# STACK_SIZE, STACK_PRS (space separated, bottom to top) and CURRENT_PR as
# key=value lines. A stack of one means the PR is not stacked. Needs gh and jq.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: find-stack.sh <pr-number> <session-dir>" >&2
  exit 2
fi
pr="$1"
dir="$2"
case "$pr" in
  '' | *[!0-9]*)
    echo "find-stack.sh: PR number must be digits, got: $pr" >&2
    exit 2
    ;;
esac
mkdir -p "$dir"

fields=number,title,headRefName,baseRefName
default=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
current=$(gh pr view "$pr" --json "$fields")

stack=$(jq -c '[.]' <<<"$current")

node="$current"
for _ in $(seq 1 25); do
  base=$(jq -r .baseRefName <<<"$node")
  [ "$base" = "$default" ] && break
  parent=$(gh pr list --head "$base" --state open --json "$fields" | jq -c '.[0] // empty')
  [ -n "$parent" ] || break
  stack=$(jq -c --argjson p "$parent" '[$p] + .' <<<"$stack")
  node="$parent"
done

node="$current"
for _ in $(seq 1 25); do
  head=$(jq -r .headRefName <<<"$node")
  children=$(gh pr list --base "$head" --state open --json "$fields")
  child=$(jq -c '.[0] // empty' <<<"$children")
  [ -n "$child" ] || break
  if [ "$(jq length <<<"$children")" -gt 1 ]; then
    echo "find-stack.sh: $head has $(jq length <<<"$children") PRs on top of it, following #$(jq -r .number <<<"$child")" >&2
  fi
  stack=$(jq -c --argjson c "$child" '. + [$c]' <<<"$stack")
  node="$child"
done

jq . <<<"$stack" >"$dir/stack.json"
printf 'STACK_SIZE=%s\nSTACK_PRS=%s\nCURRENT_PR=%s\n' \
  "$(jq length "$dir/stack.json")" "$(jq -r 'map(.number) | join(" ")' "$dir/stack.json")" "$pr"
