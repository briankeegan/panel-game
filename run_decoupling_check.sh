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
# Architectural: Match:run body itself must be rendering-agnostic.
# is_local / pauseNonLocalSimulation are only allowed in the SCHEDULING
# decision (Match:shouldRun, Match:updateClock) — which Match:run
# delegates to via method calls — not in Match:run's own body. The
# extraction script below pulls just the Match:run body and greps it.
# ---------------------------------------------------------------------

check_match_run_body() {
  local matchFile="common/engine/Match.lua"
  if [[ ! -f "$matchFile" ]]; then return; fi
  # Extract lines starting at "^function Match:run" up to the next
  # top-level "^function" or "^end" (matching ends of the function block).
  # The Match:run function is one self-contained `function ... end`
  # block; awk pulls it out.
  local body
  body=$(awk '
    /^function Match:run/ { in_fn = 1; depth = 1; print; next }
    in_fn {
      # depth-track function/end pairs would be more robust, but
      # Match:run does not declare nested functions — a simple
      # "next top-level function" marker is sufficient.
      if (/^function /) { exit }
      print
    }
  ' "$matchFile")
  if [[ -z "$body" ]]; then return; fi

  # Forbidden in the Match:run body: direct reads of stack rendering
  # state. Allowed: method calls (shouldRun / updateClock / etc) that
  # themselves consult those fields.
  local forbidden
  forbidden=$(echo "$body" | grep -nE '\b(stack\.is_local|self\.pauseNonLocalSimulation)\b' || true)
  if [[ -n "$forbidden" ]]; then
    echo
    echo "VIOLATION: Match:run body consults rendering / scheduling state directly"
    echo "  (allowed only inside Match:shouldRun / Match:updateClock — call those, don't inline)"
    echo "$forbidden"
    violations=$((violations + $(echo "$forbidden" | wc -l | tr -d ' ')))
  fi
}

check_match_run_body

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
