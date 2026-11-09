Logs of bot runs whose own artifact never got uploaded (the runner was taken away before "Upload log" ran).
`<run id>/bot-prod-smoke.log` is the bot's output taken from that run's job log. The stats update copies each one into
`stats-pulled/<run id>/` before it looks for a downloadable artifact, so the run is ingested like any other (once: runs.json
remembers it). 42536735661 is Ranmaru_p70_CPU (2026-11-08 23:46 to 02:27 UTC, 36 games).
