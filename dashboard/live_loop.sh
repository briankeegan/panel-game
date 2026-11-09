#!/usr/bin/env bash
# Runs beside a lobby bot (usage: live_loop.sh BOT_STEP_PID): puts the games it has finished on the stats page once a set seems over,
# not on a fixed timer. A set is over when no game has finished for QUIET seconds; publishes are at least MINGAP apart (GitHub Pages
# rebuilds the site on every push and is meant for about 10 a hour), and when games never pause it still publishes every CAP seconds.
# Stops when the bot's step ends. Everything it prints goes to the step's log, prefixed [publish]. It never touches the bot.
parent=${1:?usage: live_loop.sh PID}
log="${LOG:-$GITHUB_WORKSPACE/bot-prod-smoke.log}"
POLL=${POLL:-15}; QUIET=${QUIET:-90}; MINGAP=${MINGAP:-360}; CAP=${CAP:-1200}
publish() { if [ -n "${PUBLISH_CMD:-}" ]; then eval "$PUBLISH_CMD"; else nice -n 19 bash "$GITHUB_WORKSPACE/dashboard/live_publish.sh"; fi; }
seen=0; pending=0; lastGame=0; lastPub=$(date +%s)
while kill -0 "$parent" 2>/dev/null; do
  sleep "$POLL"
  n=$(grep -c "match over —" "$log" 2>/dev/null); n=${n:-0}; t=$(date +%s)
  if [ "$n" -gt "$seen" ]; then seen=$n; pending=1; lastGame=$t; fi
  [ "$pending" = 1 ] || continue
  if { [ $((t - lastGame)) -ge "$QUIET" ] && [ $((t - lastPub)) -ge "$MINGAP" ]; } || [ $((t - lastPub)) -ge "$CAP" ]; then
    echo "[publish] $seen games finished so far; the last $((t - lastGame)) s ago, the last publish $((t - lastPub)) s ago"
    publish 2>&1 | sed -u 's/^/[publish] /' || true
    pending=0; lastPub=$(date +%s)
  fi
done
