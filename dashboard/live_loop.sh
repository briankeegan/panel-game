#!/usr/bin/env bash
# Runs beside a lobby bot (usage: live_loop.sh BOT_STEP_PID): puts the games it has finished on the stats page, with their replays, AFTER EVERY
# GAME -- set or no set -- and never at the cost of a game:
#   - publishes are at least MINGAP (60 s) apart: games that finish close together go up in one publish. (It used to wait for the set to end,
#     or an hour, with publishes 6 minutes apart: a 30-minute set against one player put nothing on the page, and a handover then cut the
#     publish off. The page is served from the Cloudflare copy, and a newer copy request cancels an older one, so a publish a game is fine.)
#   - the bot's run does one last publish of its own after the bot leaves (bot-prod-smoke-test.yml), so a handover loses no game;
#   - it runs on the last CPU only, in the IDLE scheduling class (chrt -i 0): it gets only CPU time nothing else wants, so it never takes a
#     cycle from the game client (CPU 0) or Gambit's own thread, and shares only with Gambit's workers, which are in that class too. So it
#     need not wait for a game: between two games of a set there are 1-3 s (q54's 20-game set), and a publish that had to wait for a gap
#     (it used to: never start during a game, paused when one began) put nothing on the page until the set ended;
#   - it stops with the bot's step. Everything it prints goes to the step's log, prefixed [publish]. It never touches the bot.
parent=${1:?usage: live_loop.sh PID}
log="${LOG:-$GITHUB_WORKSPACE/bot-prod-smoke.log}"
POLL=${POLL:-15}; MINGAP=${MINGAP:-60}; CAP=${CAP:-3600}; WATCH=${WATCH:-2}; STUCK=${STUCK:-900}
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
  local idle=""; if command -v chrt >/dev/null 2>&1; then idle="chrt -i 0"; fi
  echo "$idle nice -n 19 $pin bash \"$GITHUB_WORKSPACE/dashboard/live_publish.sh\""
}
# A publish's lines go out AS THEY COME (they used to wait for it to finish, so a publish that never finished said nothing at all), and one
# that runs past PUBLISH_MAX (30 min) is stopped and said so: the next publish makes every game again, so nothing is lost by stopping it,
# while a stuck one would hold back every game after it for the rest of the run (r76, Nov 27: three games, nothing published, nothing said).
PUBLISH_MAX=${PUBLISH_MAX:-1800}
publish() {
  local pid t0; t0=$(date +%s)
  setsid bash -c "$(cmd)" > >(sed -u 's/^/[publish] /') 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ! kill -0 "$parent" 2>/dev/null; then kill -TERM -- "-$pid" 2>/dev/null; break; fi
    if [ $(( $(date +%s) - t0 )) -ge "$PUBLISH_MAX" ]; then
      echo "[publish] STUCK: still running after $PUBLISH_MAX s -- stopped; the next publish makes every game again"
      kill -TERM -- "-$pid" 2>/dev/null; sleep 5; kill -KILL -- "-$pid" 2>/dev/null; break
    fi
    sleep "$WATCH"
  done
  wait "$pid" 2>/dev/null
}
seenGames=0; seenSets=0; pending=0; pendingSince=0; lastPub=$(date +%s)
while kill -0 "$parent" 2>/dev/null; do
  sleep "$POLL"
  refresh; t=$(date +%s)
  if [ "$lastO" -gt "$seenGames" ]; then seenGames=$lastO; pending=1; [ "$pendingSince" -gt 0 ] || pendingSince=$t; fi
  [ "$pending" = 1 ] || continue
  # a game has finished since the last publish, and the last publish was MINGAP ago or more (a game on now does not hold it back: idle class)
  if [ $((t - lastPub)) -ge "$MINGAP" ]; then
    echo "[publish] $lastO games finished so far; $([ "$inSet" = 0 ] && echo 'the set is over' || echo 'between two games of a set'); the last publish $((t - lastPub)) s ago"
    publish
    pending=0; pendingSince=0; lastPub=$(date +%s)
  fi
done
