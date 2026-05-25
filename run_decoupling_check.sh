#!/usr/bin/env zsh
#
# Static cross-domain reference check.
#
# Enforces the structural-decoupling contract documented in
# docs/ARCHITECTURE.md:
#
#   * Snapshot pipeline (client/src/network/Display*) may NOT reference
#     engine internals (Match:, Stack:run, engine.stacks). Visuals are
#     a downstream consumer of state, not a participant in it.
#
#   * Engine (common/engine/) may NOT reference snapshot-pipeline
#     identifiers (displayHistory* flags, DisplayClientStack,
#     DisplayEventCapture). Engine sim is rendering-agnostic.
#
# A line may opt out with the marker "-- DECOUPLING-OK: <reason>" at
# the end of the line. Use sparingly and justify in the reason.
#
# Exit code 0 = clean. Non-zero = at least one violation.

set -e

cd "$(dirname "$0")"

violations=0

check() {
  local label="$1"
  local glob="$2"
  local pattern="$3"
  local hits
  hits=$(grep -rnE "$pattern" $glob 2>/dev/null | grep -v "DECOUPLING-OK" || true)
  if [[ -n "$hits" ]]; then
    echo
    echo "VIOLATION: $label"
    echo "$hits"
    violations=$((violations + $(echo "$hits" | wc -l | tr -d ' ')))
  fi
}

# ---------------------------------------------------------------------
# Snapshot pipeline cannot reach into the engine.
# ---------------------------------------------------------------------

check \
  "client/src/network/Display* references Match: methods" \
  "client/src/network/Display*" \
  '\b(Match|ClientMatch):\w'

check \
  "client/src/network/Display* references Stack:run / Stack:simulate" \
  "client/src/network/Display*" \
  '\bStack:(run|simulate|saveForRollback|rollbackToFrame)\b'

check \
  "client/src/network/Display* iterates engine.stacks" \
  "client/src/network/Display*" \
  '\bengine\.stacks\b'

# ---------------------------------------------------------------------
# Engine cannot reach into the snapshot pipeline.
# ---------------------------------------------------------------------

check \
  "common/engine/ references displayHistory* flags" \
  "common/engine/" \
  '\bdisplayHistory(Active|Enabled)\b'

check \
  "common/engine/ references snapshot-pipeline class names" \
  "common/engine/" \
  '\b(DisplayClientStack|DisplayEventCapture|DisplaySnapshot)\b'

# ---------------------------------------------------------------------

echo
if [[ $violations -eq 0 ]]; then
  echo "decoupling check: OK"
  exit 0
else
  echo "decoupling check: $violations violation(s)"
  echo
  echo "Either refactor the offending lines to respect the boundary,"
  echo "or annotate with '-- DECOUPLING-OK: <reason>' if the cross-"
  echo "domain reference is genuinely required and intentional."
  exit 1
fi
