#!/usr/bin/env bash
# Runs beside a lobby bot (usage: live_loop.sh BOT_STEP_PID): puts the games it has finished on the stats page, with their replays, when a SET is over
# -- the other player has left and the bot is back in the lobby ("set over:" in the bot's log) -- and never at the cost of a game:
#   - not between the games of a set: it waits for the set to close (a set that runs longer than CAP seconds is published between two games);
#   - publishes are at least MINGAP apart (GitHub Pages rebuilds on every push and is meant for about 10 a hour);
#   - it never STARTS while a game is on or a set is open, it runs at the lowest priority on the last CPU core only, and if a game starts while it
#     is working (someone challenges the bot in the lobby) it is PAUSED (SIGSTOP) until that game is over: the upload waits for the game;
#   - it stops with the bot's step. Everything it prints goes to the step's log, prefixed [publish]. It never touches the bot.
parent=${1:?usage: live_loop.sh PID}
log="${LOG:-$GITHUB_WORKSPACE/bot-prod-smoke.log}"
POLL=${POLL:-15}; MINGAP=${MINGAP:-360}; CAP=${CAP:-3600}; WATCH=${WATCH:-2}; STUCK=${STUCK:-900}
count() { local n; n=$(grep -c "$1" "$log" 2>/dev/null); echo "${n:-0}"; }
lastS=0; lastO=0; lastSets=0; startedAt=0; inSet=0
# a game is on from "match starting" to "match over"; a set is open from its first game to "set over:" (a game that never reports its end
# counts for STUCK seconds, not for ever)
refresh() { local s sets; s=$(count "match starting"); lastO=$(count "match over —"); sets=$(count "set over:")
  if [ "$s" -gt "$lastS" ]; then startedAt=$(date +%s); inSet=1; fi
  if [ "$sets" -gt "$lastSets" ]; then inSet=0; fi
  lastS=$s; lastSets=$sets; }
busy() { [ "$lastS" -gt "$lastO" ] && [ $(( $(date +%s) - startedAt )) -lt "$STUCK" ]; }
cmd() {
  if [ -n "${PUBLISH_CMD:-}" ]; then echo "$PUBLISH_CMD"; return; fi
  local pin=""; if command -v taskset >/dev/null 2>&1 && [ "$(nproc)" -gt 1 ]; then pin="taskset -c $(( $(nproc) - 1 ))"; fi
  echo "nice -n 19 $pin bash \"$GITHUB_WORKSPACE/dashboard/live_publish.sh\""
}
publish() {
  local out pid paused=0; out=$(mktemp)
  setsid bash -c "$(cmd)" >"$out" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    refresh
    if busy; then
      if [ "$paused" = 0 ]; then kill -STOP -- "-$pid" 2>/dev/null; paused=1; echo "[publish] a game started: the upload waits for it"; fi
    elif [ "$paused" = 1 ]; then kill -CONT -- "-$pid" 2>/dev/null; paused=0; echo "[publish] the game is over: the upload goes on"; fi
    if ! kill -0 "$parent" 2>/dev/null; then kill -CONT -- "-$pid" 2>/dev/null; kill -TERM -- "-$pid" 2>/dev/null; break; fi
    sleep "$WATCH"
  done
  [ "$paused" = 1 ] && kill -CONT -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null; sed -u 's/^/[publish] /' < "$out"; rm -f "$out"
}
seenGames=0; seenSets=0; pending=0; pendingSince=0; lastPub=$(date +%s)
while kill -0 "$parent" 2>/dev/null; do
  sleep "$POLL"
  refresh; t=$(date +%s)
  if [ "$lastO" -gt "$seenGames" ]; then seenGames=$lastO; pending=1; [ "$pendingSince" -gt 0 ] || pendingSince=$t; fi
  [ "$pending" = 1 ] || continue
  busy && continue                                   # never while a game is on
  # in the lobby (the set is over) and not within MINGAP of the last publish; or a set that has gone on for CAP seconds, between two games
  if { [ "$inSet" = 0 ] && [ $((t - lastPub)) -ge "$MINGAP" ]; } || { [ $((t - pendingSince)) -ge "$CAP" ] && [ $((t - lastPub)) -ge "$MINGAP" ]; }; then
    echo "[publish] $lastO games finished so far; $([ "$inSet" = 0 ] && echo 'the set is over' || echo "a long set, $((t - pendingSince)) s"); the last publish $((t - lastPub)) s ago"
    publish
    pending=0; pendingSince=0; lastPub=$(date +%s)
  fi
done
