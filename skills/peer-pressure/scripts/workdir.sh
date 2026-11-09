#!/usr/bin/env bash
# Make, update and remove the temporary clone that a long-running loop works in.
#
# Usage: workdir.sh create <pr-number> <owner/repo> <state-dir> [--read-only]
#        workdir.sh sync <state-dir>
#        workdir.sh path <state-dir>
#        workdir.sh remove <state-dir>
#
# `create` clones the repository into a new directory under $TMPDIR (a partial
# clone: the whole history, file contents fetched when read) and checks out the PR.
# Without --read-only it runs `gh pr checkout`, so the clone is on the PR's branch
# with its upstream set and can push. With --read-only it checks out the PR head
# detached, from refs/pull/<n>/head, which also works for a fork. The directory is
# stored as `workdir` in <state-dir>/state.json, which must exist (babysit-state.sh
# init or moi-track.sh init). Prints WORKDIR, BRANCH (empty when detached) and
# HEAD_SHA.
#
# `sync` moves a read-only clone to the current head of the PR and prints HEAD_SHA.
# `path` prints the stored directory when it still exists, and exits 1 when it does not.
#
# `remove` deletes the clone when that cannot lose work: the path must be a
# peer-pressure directory directly under $TMPDIR, the tree must be clean, and no
# commit may be missing from the upstream. Otherwise it keeps the directory. Prints
# REMOVED=<dir>, or KEPT=<dir> and REASON=<why>, and exits 0 either way.
# Needs git, gh and jq.
set -euo pipefail

usage() {
  echo "usage: workdir.sh create <pr> <owner/repo> <state-dir> [--read-only] | sync <state-dir> | path <state-dir> | remove <state-dir>" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
cmd="$1"
shift
here=$(dirname "${BASH_SOURCE[0]}")
state() { "$here/babysit-state.sh" "$@"; }

case "$cmd" in
  create)
    { [ "$#" -eq 3 ] || { [ "$#" -eq 4 ] && [ "$4" = "--read-only" ]; }; } || usage
    pr="$1"
    repo="$2"
    sdir="$3"
    read_only=false
    [ "$#" -eq 4 ] && read_only=true
    case "$pr" in '' | *[!0-9]*) echo "workdir.sh: PR number must be digits, got: $pr" >&2; exit 2 ;; esac
    [ -r "$sdir/state.json" ] || { echo "workdir.sh: no state in $sdir, run init first" >&2; exit 2; }

    dir=$(mktemp -d "${TMPDIR:-/tmp}/peer-pressure-pr$pr.XXXXXX")
    if ! gh repo clone "$repo" "$dir" -- --filter=blob:none -q; then
      rm -rf -- "$dir"
      echo "workdir.sh: could not clone $repo" >&2
      exit 1
    fi
    if [ "$read_only" = true ]; then
      git -C "$dir" fetch -q origin "pull/$pr/head"
      git -C "$dir" checkout -q --detach FETCH_HEAD
    else
      (cd "$dir" && gh pr checkout "$pr" >/dev/null 2>&1) || {
        echo "workdir.sh: could not check out PR $pr in $dir (kept for inspection)" >&2
        exit 1
      }
    fi
    state "$sdir" set "workdir=$dir"
    printf 'WORKDIR=%s\nBRANCH=%s\nHEAD_SHA=%s\n' "$dir" "$(git -C "$dir" branch --show-current)" "$(git -C "$dir" rev-parse HEAD)"
    ;;

  sync)
    [ "$#" -eq 1 ] || usage
    dir=$(state "$1" get workdir)
    pr=$(state "$1" get pr)
    { [ -d "$dir/.git" ] && [ -n "$pr" ]; } || { echo "workdir.sh: no clone or PR in the state of $1" >&2; exit 1; }
    git -C "$dir" fetch -q origin "pull/$pr/head"
    git -C "$dir" checkout -q --detach FETCH_HEAD
    echo "HEAD_SHA=$(git -C "$dir" rev-parse HEAD)"
    ;;

  path)
    [ "$#" -eq 1 ] || usage
    dir=$(state "$1" get workdir)
    [ -d "$dir/.git" ] || exit 1
    echo "$dir"
    ;;

  remove)
    [ "$#" -eq 1 ] || usage
    dir=$(state "$1" get workdir)
    [ -n "$dir" ] || { echo "REMOVED="; exit 0; }
    kept() { printf 'KEPT=%s\nREASON=%s\n' "$dir" "$1"; exit 0; }
    [ -d "$dir" ] || { state "$1" set workdir=null; echo "REMOVED=$dir"; exit 0; }

    tmp_root=$(cd -P "${TMPDIR:-/tmp}" && pwd)
    parent=$(cd -P "$dir/.." && pwd)
    case "$(basename "$dir")" in peer-pressure-pr*) ;; *) kept "not a peer-pressure temporary directory" ;; esac
    [ "$parent" = "$tmp_root" ] || kept "not directly under the temporary directory"
    [ -d "$dir/.git" ] || kept "not a git clone"
    [ -z "$(git -C "$dir" status --porcelain)" ] || kept "it has uncommitted changes"
    if [ -n "$(git -C "$dir" branch --show-current)" ]; then
      upstream=$(git -C "$dir" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || kept "its branch has no upstream, so unpushed work cannot be ruled out"
      [ "$(git -C "$dir" rev-list --count "$upstream..HEAD")" = "0" ] || kept "it has commits that are not pushed"
    fi
    rm -rf -- "$dir"
    state "$1" set workdir=null
    echo "REMOVED=$dir"
    ;;

  *) usage ;;
esac
