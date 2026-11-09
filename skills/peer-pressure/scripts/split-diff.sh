#!/usr/bin/env bash
# Split the input into chunks that one reviewer can read.
#
# Usage: split-diff.sh <session-dir> [--limit BYTES]
#
# Reads <session-dir>/input.txt. When it fits the limit (default 200000 bytes,
# about 50k tokens) it is the only chunk and nothing is written. Otherwise the
# input is cut at file boundaries ("diff --git" or "=== path ===" headers) into
# chunk-1.txt, chunk-2.txt and so on. A file over the limit is cut inside the
# file: at hunk boundaries in a diff, at line boundaries in a file listing, with
# the file header repeated in each part. A single hunk over the limit stays whole.
#
# Prints CHUNKS=<n> and one CHUNK_<i>=<path> line per chunk.
set -euo pipefail

usage() {
  echo "usage: split-diff.sh <session-dir> [--limit BYTES]" >&2
  exit 2
}

limit=200000
case "$#" in
  1) ;;
  3) [ "$2" = "--limit" ] || usage; limit="$3" ;;
  *) usage ;;
esac
dir="$1"
input="$dir/input.txt"
[ -r "$input" ] || { echo "split-diff.sh: $input not found" >&2; exit 2; }
case "$limit" in '' | *[!0-9]* | 0) usage ;; esac

size=$(wc -c <"$input" | tr -d ' ')
if [ "$size" -le "$limit" ]; then
  echo "CHUNKS=1"
  echo "CHUNK_1=$input"
  exit 0
fi

rm -f "$dir"/chunk-*.txt
LC_ALL=C awk -v limit="$limit" -v dir="$dir" '
function emit(text, size) {
  if (n == 0) {
    n = 1
  } else if (cur > 0 && cur + size > limit) {
    close(dir "/chunk-" n ".txt")
    n++
    cur = 0
  }
  printf "%s", text >> (dir "/chunk-" n ".txt")
  cur += size
}

# Write the lines of one file section, splitting it when it is over the limit.
function flush(   i, j, k, total, text, he, hdr, hsize, part, psize, unit, usize, is_diff) {
  if (cnt == 0) return
  total = 0
  text = ""
  for (i = 1; i <= cnt; i++) {
    text = text L[i] "\n"
    total += length(L[i]) + 1
  }
  if (total <= limit) {
    emit(text, total)
    cnt = 0
    return
  }
  is_diff = (L[1] ~ /^diff --git /)
  he = 1
  if (is_diff) {
    for (he = 1; he <= cnt && L[he] !~ /^@@ /; he++) { }
    he--
  }
  hdr = ""
  hsize = 0
  for (i = 1; i <= he; i++) {
    hdr = hdr L[i] "\n"
    hsize += length(L[i]) + 1
  }
  part = ""
  psize = 0
  i = he + 1
  while (i <= cnt) {
    # One unit is a whole hunk in a diff, a single line in a file listing.
    j = i + 1
    if (is_diff) {
      while (j <= cnt && L[j] !~ /^@@ /) j++
    }
    unit = ""
    usize = 0
    for (k = i; k < j; k++) {
      unit = unit L[k] "\n"
      usize += length(L[k]) + 1
    }
    if (psize > 0 && hsize + psize + usize > limit) {
      emit(hdr part, hsize + psize)
      part = ""
      psize = 0
    }
    part = part unit
    psize += usize
    i = j
  }
  if (psize > 0) emit(hdr part, hsize + psize)
  cnt = 0
}

/^diff --git / || /^=== .* ===$/ { flush() }
{ L[++cnt] = $0 }
END { flush() }
' "$input"

chunks=$(find "$dir" -maxdepth 1 -name 'chunk-*.txt' | wc -l | tr -d ' ')
echo "CHUNKS=$chunks"
i=1
while [ "$i" -le "$chunks" ]; do
  echo "CHUNK_$i=$dir/chunk-$i.txt"
  i=$((i + 1))
done
