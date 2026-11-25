#!/usr/bin/env bash
# THE 24 GAMES, DISPATCHED: gambit-24.yml on main, with the profile, the bot and the panel-game branch given. Prints the run's id, when it
# started and when it should be done (Eastern time; the median length of the last five runs that finished), then with `wait` waits for it and
# prints when it finished and the run's summary.
#
#   bash run24.sh [PROFILE] [wait]     PROFILE relative to games/the-game/ai/eval (default survivor-profiles/gambit-finish.json)
# Env: GC_BOT (gambit), GC_PANEL_REF (claude/newsey-game-ask-qa8u5e), GC_REF (the GameCreator ref played: main).
set -u
REPO=briankeegan/GameCreator WF=gambit-24.yml
PROFILE=${1:-survivor-profiles/gambit-finish.json} WAIT=${2:-}
edt() { TZ=America/New_York date -d "@$1" '+%H:%M ET'; }
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for n in 1 2 3 4; do
  gh api -X POST repos/$REPO/actions/workflows/$WF/dispatches -f ref=${GC_REF:-main} -f "inputs[profile]=$PROFILE" \
    -f "inputs[bot]=${GC_BOT:-gambit}" -f "inputs[panel_ref]=${GC_PANEL_REF:-claude/newsey-game-ask-qa8u5e}" >/dev/null && break
  sleep $((2 ** n))
done
R=""
for n in $(seq 1 40); do
  R=$(gh api "repos/$REPO/actions/workflows/$WF/runs?per_page=5" --jq ".workflow_runs[] | select(.created_at >= \"$T0\") | .id" 2>/dev/null | tail -1)
  [ -n "$R" ] && break
  sleep 5
done
[ -n "$R" ] || { echo "run24: no run started"; exit 1; }
START=$(date -d "$(gh api repos/$REPO/actions/runs/$R --jq .run_started_at)" +%s)
# (how long a run takes: the median of the last five that finished)
LEN=$(gh api "repos/$REPO/actions/workflows/$WF/runs?status=success&per_page=5" --jq '.workflow_runs[] | ((.updated_at | fromdate) - (.run_started_at | fromdate))' | sort -n | awk '{a[NR]=$1} END {print NR ? a[int((NR+1)/2)] : 540}')
echo "run $R ($PROFILE, ${GC_BOT:-gambit}) started $(edt $START), expected done $(edt $((START + LEN)))"
[ "$WAIT" = wait ] || exit 0
until [ "$(gh api repos/$REPO/actions/runs/$R --jq .status)" = completed ]; do sleep 30; done
echo "run $R $(gh api repos/$REPO/actions/runs/$R --jq .conclusion), started $(edt $START), finished $(edt $(date +%s))"
J=$(gh api "repos/$REPO/actions/runs/$R/jobs?per_page=50" --jq '.jobs[] | select(.name=="report") | .id')
gh api repos/$REPO/check-runs/$J/annotations --jq '.[] | .message' | grep -v "Node.js 20\|ubuntu-latest"
