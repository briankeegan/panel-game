# Replay corpus — archive layout & tooling

Notes + scripts for mining the public legacy replay archive (the Phase-2
behavior-cloning training data for the player-bots). **Read-only, public data.**
Verified working 2026-06-14.

## Archive location & layout

Base: `https://panelattack.com/replays/v049/`  (`v049` = engine version)

Apache-style directory index, nested:

```
v049/ <year>/ <MM>/ <DD>/ <P1>-vs-<P2>/ <replay>.json
                                         (24+ .json files per matchup folder)
```

- Folders are dated: `2026/06/14/`.
- Each leaf is a **matchup folder** `Aleixo2-vs-Dyalon/` — name encodes BOTH players.
- Files are small **input replays** (ReplayV3 JSON, 2–27 KB, compressed input strings →
  deterministic re-simulation gives `(board state → action)` pairs).

## Filename metadata (free, no need to open the file)

```
v049-2026-06-14-15-24-12-Aleixo2-L10-Dyalon-L10-VScasual-P1wins.json
└┬─┘ └────┬────────┘ └──┬───┘ └──┬──┘ └──┬──┘ └─┬──┘
ver       timestamp     P1+level  P2+level  type   winner
```

- `L10` = player level (skill signal → difficulty tiers / filtering).
- `VScasual` = match type. `P1wins`/`P2wins` = outcome (clone winning play / weight by it).

## Stable user IDs live INSIDE the replay JSON

Names can change; the per-account server id is stable. In the JSON:

```
metadata.stacks[i].name      -> display name
metadata.stacks[i].publicId  -> STABLE user id   <-- index per-player datasets by THIS
metadata.winnerId            -> publicId of winner
metadata.gameId              -> server game id
```

## Throttling caveat

Production rate-limits rapid sequential requests: **crawl one month at a time.**
Back-to-back multi-month loops return empty responses. June (fetched first) was the
reliable sample; April/May need separate, gentler passes (or a background crawl).

## Scripts

- **`build_index.py <YYYY> <MM> [MM ...]`** — the main one. Builds a full stable
  `name -> publicId` map for the archive into `player_index.tsv` (one replay per
  matchup yields both ids; skips matchups where both players are already known).
  **Resumable** (reloads + appends) and **paced** (`PACE=0.35` env, run in
  background). After it runs, every lookup is an instant grep:
  `grep -i forky player_index.tsv`. This is the Phase-2 lookup table.
- `list_players.sh <YYYY> <MM>` — quick: unique player names for one month (no ids).
- `player_id.sh <name> [YYYY] [MM]` — quick single lookup: first replay involving
  `<name>`; prints each stack's `name -> publicId`. Default month 2026/06.

`player_index.tsv` is generated data (untracked).

## Corpus scope (training data)

- **Key by `publicId`** (account id), but keep display names (filenames retain them;
  one account can have many names — e.g. `935` = `chaos952` / `chaos952_FT1` /
  `259soahc` reversed). Id merges them; name is for labeling the bot.
- **Filter: 1v1 at level 10 only** — `gather.py` keeps a replay only if it has
  exactly 2 stacks and both are level 10 (authoritative `metadata.stacks[].level`,
  not the filename). Drops team/FFA and off-level games.
- Gather everything matching that filter now; finer filtering (wins-only, opponent
  strength) is deferred to training time.

## Confirmed findings (2026-06-14)

| asked-for | archive name | publicId |
|-----------|--------------|----------|
| chaos     | `chaos952`   | **935**  |
| musichael | not in June sample (169 players) — confirm spelling or check Apr/May |
| forky     | not in June sample — confirm spelling or check Apr/May |

June sample: 602 matchup folders, 169 unique players.
