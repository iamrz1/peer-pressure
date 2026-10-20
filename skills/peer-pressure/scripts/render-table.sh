#!/usr/bin/env bash
# Draw the issues section of the summary as a fixed-width table.
#
# Usage: render-table.sh <session-dir> [--width N]
#
# Reads report.json and, when present, prior.json. Prints the counts line, the
# table inside a text fence, the legend, and a short list for findings that need
# a closer look. The text wraps to the total width N (default 140, or the
# PEER_PRESSURE_WIDTH environment variable) and a line separates each issue. The
# width cannot be detected from a script, so pass --width to match the terminal.
#
# prior.json is optional: [{"id": "F2", "login": "alice", "resolved": false,
# "dismiss": false}]. A finding with a prior comment gets a marker at the end of
# its Review cell. A finding with "dismiss": true is left out. Needs jq.
set -euo pipefail

usage() {
  echo "usage: render-table.sh <session-dir> [--width N]" >&2
  exit 2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  usage
fi
dir="$1"
width="${PEER_PRESSURE_WIDTH:-140}"
if [ "$#" -gt 1 ]; then
  if [ "$2" != "--width" ] || [ "$#" -ne 3 ]; then
    usage
  fi
  width="$3"
fi
case "$width" in
  '' | *[!0-9]*)
    echo "render-table.sh: width must be a number, got: $width" >&2
    exit 2
    ;;
esac
[ -r "$dir/report.json" ] || { echo "render-table.sh: $dir/report.json not found" >&2; exit 2; }

prior="$dir/prior.json"
if [ ! -r "$prior" ] || ! jq -e 'type == "array"' "$prior" >/dev/null 2>&1; then
  prior=$(mktemp "${TMPDIR:-/tmp}/peer-pressure-prior.XXXXXX")
  trap 'rm -f "$prior"' EXIT
  echo '[]' >"$prior"
fi

jq -r --argjson width "$width" --slurpfile prior "$prior" '
  # Display width of one code point: emoji and CJK take two columns, joiners none.
  def cw:
    if . >= 127744 or . == 9889 or (. >= 11904 and . <= 42191) or (. >= 44032 and . <= 55203)
       or (. >= 63744 and . <= 64255) or (. >= 65072 and . <= 65131) or (. >= 65280 and . <= 65376)
       or (. >= 65504 and . <= 65510) then 2
    elif (. >= 8203 and . <= 8207) or . == 65039 or (. >= 768 and . <= 879) then 0
    else 1 end;
  def dw: explode | map(cw) | add // 0;
  def pad($w): . + (if $w > dw then " " * ($w - dw) else "" end);

  # Cut a long word into chunks that fit the width.
  def chunks($w):
    explode
    | reduce .[] as $c ({out: [], cur: [], n: 0};
        ($c | cw) as $k
        | if (.n + $k) > $w and (.cur | length) > 0
          then .out += [.cur] | .cur = [$c] | .n = $k
          else .cur += [$c] | .n += $k end)
    | (.out + (if (.cur | length) > 0 then [.cur] else [] end))
    | map(implode);

  # Greedy word wrap. A word may also break after a slash, so paths wrap by folder.
  def wrap($w):
    ( split(" ") | map(select(length > 0))
      | map([scan("[^/]*/|[^/]+")] | to_entries | map({t: .value, glue: (.key > 0)}))
      | add // [] ) as $toks
    | reduce $toks[] as $tk ({lines: [], cur: ""};
        (if .cur == "" then "" elif $tk.glue then "" else " " end) as $sep
        | if ((.cur + $sep + $tk.t) | dw) <= $w then .cur += $sep + $tk.t
          else
            (if .cur != "" then .lines += [.cur] else . end)
            | if ($tk.t | dw) <= $w then .cur = $tk.t
              else ($tk.t | chunks($w)) as $parts
                   | .lines += $parts[:-1] | .cur = $parts[-1] end
          end)
    | (.lines + (if .cur != "" then [.cur] else [] end))
    | if length == 0 then [""] else . end;

  def urgency_label:
    {insist: "Insist", ask: "Ask", author: "Up to author", optional: "Optional"}[.] // "-";
  def sev_emoji: {critical: "🔴", warning: "🟡", suggestion: "🔵"}[.] // "";
  def icon: {correctness: "🐛", security: "🔒", performance: "⚡", architecture: "📐",
             compatibility: "🔌", maintainability: "🧹", docs: "📚"}[.] // "";
  def order: ["correctness", "security", "performance", "architecture", "compatibility", "maintainability", "docs"];
  def icons: (.sources // []) as $s | [order[] | select(. as $o | $s | index($o))] | .[:2] | map(icon) | join(" ");
  def plain: gsub("`"; "") | gsub("[\r\n]+"; " ");

  . as $r
  | ($prior[0]) as $P
  | ($r.findings
      | map(. as $f | . + {mark: (($P | map(select(.id == $f.id)) | .[0]) // null)})
      | map(select((.mark.dismiss // false) | not))
      | to_entries | map(.value + {n: (.key + 1)})) as $F
  | if ($F | length) == 0 then "No issues found."
    else
      # Cell text per finding.
      ($F | map(
         {
           n: (.n | tostring),
           file: (.file + (if .line then ":" + (.line | tostring) else "" end)),
           sev: ((.label | sev_emoji) + " (" + (.score | tostring) + ")"),
           urg: (.urgency | urgency_label),
           review: (([icons] | map(select(length > 0)) | join(" ")) as $i
                    | (if $i != "" then $i + " " else "" end)
                      + ([.problem, .impact] | map(select(. != null and . != "")) | join(" ") | plain)
                      + (if .mark != null
                           then " (@" + (.mark.login // "unknown") + (if (.mark.resolved // false) then ", resolved" else "" end) + ")"
                           else "" end)),
           fix: ((.fix // "") | plain)
         })) as $cells
      # Column widths.
      | ($cells | map(.n | dw) | max) as $wn
      | ([($cells | map(.sev | dw) | max), 3] | max) as $wsev
      | ([($cells | map(.urg | split(" ") | map(dw) | max) | max), 7] | max) as $wurg
      | ($cells | map(.file | dw) | max) as $filenat
      | ([[$filenat, (($width * 22 / 100) | floor)] | min, 16] | max) as $wfile
      | ($width - ($wn + $wsev + $wurg + $wfile) - 19) as $rest
      | ([($rest * 60 / 100) | floor, 20] | max) as $wrev
      | ([$rest - $wrev, 14] | max) as $wfix
      | ([$wn, $wfile, $wsev, $wurg, $wrev, $wfix]) as $w
      | def hline($l; $m; $r): $l + ([$w[] | "─" * (. + 2)] | join($m)) + $r;
        def line($cols): "│ " + ([range(0; 6) as $i | $cols[$i] | pad($w[$i])] | join(" │ ")) + " │";
        def block($c):
          [($c.n | wrap($wn)), ($c.file | wrap($wfile)), ($c.sev | wrap($wsev)), ($c.urg | wrap($wurg)),
           ($c.review | wrap($wrev)), ($c.fix | wrap($wfix))] as $cols
          | ([$cols[] | length] | max) as $h
          | [range(0; $h) as $k | line([$cols[] | .[$k] // ""])];
        ($F | map(select(.label == "critical")) | length) as $crit
      | ($F | map(select(.label == "warning")) | length) as $warn
      | ($F | map(select(.label == "suggestion")) | length) as $sugg
      | ($F | map(select(.urgency == "insist")) | length) as $insist
      | (if ($F | map(select(.urgency != "")) | length) > 0 then $insist == 0 else $crit == 0 end) as $ready
      | ([ (if $crit > 0 then "**🔴 \($crit) critical**" else empty end),
           (if $warn > 0 then "**🟡 \($warn) \(if $warn == 1 then "warning" else "warnings" end)**" else empty end),
           (if $sugg > 0 then "**🔵 \($sugg) \(if $sugg == 1 then "suggestion" else "suggestions" end)**" else empty end),
           (if $ready then "✅ *ready to merge*" else "🚫 *not ready to merge*" end) ] | join(" · ")) as $counts
      | ([order[] | select(. as $o | $F | any(.sources // [] | index($o)))] | map(icon + " " + .) | join("  ")) as $icon_legend
      | [ $counts, "",
          "```text",
          hline("┌"; "┬"; "┐"),
          line(["#", "File", "Sev", "Urgency", "Review", "Fix"]),
          hline("├"; "┼"; "┤"),
          ($cells | to_entries | map(
             (block(.value)[]),
             (if .key < (($cells | length) - 1) then hline("├"; "┼"; "┤") else empty end)
           )[]),
          hline("└"; "┴"; "┘"),
          "```",
          "",
          "🔴 critical  🟡 warning  🔵 suggestion  |  " + $icon_legend,
          "The number in brackets is the sum of the lens scores, each from 0 to 3.",
          ( [ $F[] | select(.urgency == "insist" and (.reason // "") != "")
              | "**\(.n). \(.file | split("/") | .[-1])" + (if .line then ":\(.line)" else "" end) + "**\n" + .reason ]
            | if length > 0 then ("", (join("\n\n"))) else empty end )
        ]
      | join("\n")
    end
' "$dir/report.json"
