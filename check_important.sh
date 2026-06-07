#!/bin/zsh
# check_important.sh — scan a gathered_logs snapshot for "important things"
# we want eyes on after every deploy-pull. Auto-invoked at the end of
# gather_logs.sh, so every `zsh deploy.sh` surfaces these before restarting
# the server. Also runnable standalone against any snapshot.
#
# Usage:
#   zsh check_important.sh [<gathered_logs_dir>]
#     <dir>  a gathered_logs/<ts>_<commit>/ directory.
#            Defaults to the most recent one.
#
# EXTENDING: add a row to the CHECKS array below. Each row is
#   name|severity|egrep-pattern|description
# That's the whole contract — drop in a pattern for the next thing you want
# flagged on pull and it shows up automatically. (Computed/numeric summaries,
# like the finalize-timing one at the bottom, are added as small awk blocks.)
#
# Never fatal: the checker must not block a deploy, so it always exits 0.

set -uo pipefail
cd "$(dirname "$0")"

DIR="${1:-}"
if [[ -z "$DIR" ]]; then
  DIR=$(ls -dt gathered_logs/*/ 2>/dev/null | head -1)
fi
if [[ -z "$DIR" || ! -d "$DIR" ]]; then
  echo "check_important: no gathered_logs dir found (looked for: ${1:-gathered_logs/*/})" >&2
  exit 0
fi

# Scan the prod journal + any server-side .log files in the snapshot.
scan() { grep -rhE "$1" "$DIR" --include='*.log' --include='journal.log' 2>/dev/null; }

echo ""
echo "==> check_important: scanning ${DIR}"

# ---- Registry of important patterns. Add rows freely. -----------------------
#   name | severity | egrep-pattern | description
CHECKS=(
  "winner-mismatch|WARN|\[WINNER-MISMATCH\]|Local getWinners disagreed with the server's authoritative winner (logged client-side)"
)
# -----------------------------------------------------------------------------

found_any=0
for row in "${CHECKS[@]}"; do
  name="${row%%|*}";  rest="${row#*|}"
  sev="${rest%%|*}";  rest="${rest#*|}"
  pat="${rest%%|*}";  desc="${rest#*|}"
  matches=$(scan "$pat" || true)
  count=$(printf '%s' "$matches" | grep -c . || true)
  if [[ "$count" -gt 0 ]]; then
    found_any=1
    echo ""
    echo "  [$sev] $name — ${count} hit(s)"
    echo "         $desc"
    printf '%s\n' "$matches" | head -3 | sed 's/^/         · /'
  fi
done

if [[ "$found_any" -eq 0 ]]; then
  echo "    nothing important flagged."
fi
echo ""
exit 0
