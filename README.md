# BAR Market War

A never-ending 1v1 Beyond All Reason war driven by the live BTC/USD order flow.
Every real Binance trade is reinforcements: taker **buys** feed the **Bulls**
(Armada, team 0) and taker **sells** feed the **Bears** (Cortex, team 1) as
metal/energy income. Two BARbarian AIs fight it out; when a commander dies it
respawns 45s later with a temporary income surge, so the front line swings
forever. `deathmode=neverend` guarantees no game over.

## Quickstart

```bash
scripts/install.sh          # engine (Recoil master CI) + BAR + map + settings
scripts/run-war.sh live     # the war, supervised, forever (synthetic for offline)
```

Stop with `pkill -f run-war.sh; pkill -f spring-headless; pkill -f feedd.py`.

## Watching

The host runs headless at 30fps; rendering happens on the spectator's machine:

```bash
scripts/spectate.sh <host-ip> <your-name> spring    # from any box with the repo
```

Remote friends need UDP `8452` reachable and the same game/map archives
(any BAR install has them; point `--write-dir` at a dir that can see them).

## How it works

```
Binance btcusdt@aggTrade ──ws──> feed/feedd.py ──tcp 127.0.0.1:8642──>
LuaUI widget market_feed.lua (host player only) ──SendLuaRulesMsg──>
synced gadget market_income.lua ──AddTeamResource──> Bulls/Bears economies
```

- `mutator/MarketWar.sdd` — dev-archive mutator on top of BAR (BAR repo untouched):
  - `market_income.lua` — 1s income ticks: `baseline + volume × PER_BTC`, surge-aware, deep storage
  - `market_respawn.lua` — commander respawn + loser surge (the endless part)
  - `market_debug.lua` — heartbeat log line every 10s (`MKTWAR f=...`)
- `feed/feedd.py` — trade bucketing + TCP broadcast (`--synthetic` for offline dev); `pytest feed/tests`
- `scripts/run-war.sh` — supervisor: restarts feedd/engine on crash
- `config/war.env` — every port/team/tuning knob

## Tuning (config/war.env mirrors the gadget constants)

| Knob | Value | Meaning |
|---|---|---|
| `METAL_PER_BTC` | 400 | metal per 1 BTC taker volume, per second |
| `ENERGY_PER_BTC` | 4000 | energy ditto |
| `BASELINE_METAL/ENERGY` | 4 / 40 | per-second floor so a dead market still skirmishes |
| `RESPAWN_COOLDOWN_SEC` | 45 | commander respawn delay |
| `RESPAWN_SURGE_MULT/SEC` | 3 / 60 | loser income surge after respawn |

Quiet market ≈ 0.002-0.01 BTC/s (≈ +1-4 metal/s); a 1 BTC/s burst ≈ +400 metal/s flood.
Edit values in `mutator/.../market_income.lua` + `war.env` together.

## Known constraints

- **Engine must be a Recoil master CI build** (install.sh handles it): all tagged
  releases ≤ 2026.06.11 carry issue #2923 → ~4fps headless sim. Pin a tagged
  release in install.sh once one ships the #2924 fix.
- infolog is unbuffered via `LogFlushLevel=0` — don't remove it, or killed runs
  look hung at load time.
- Graphical client on this box (xrdp/llvmpipe) runs slow; spectate from a real
  GPU machine. iGPU (`render` group) + QuickSync is the Phase 2 on-box stream path.

## Phase 2 (not built)

24/7 stream + webpage: render on the iGPU, NVENC/QuickSync encode → Twitch/YouTube,
page embeds stream beside a live chart fed by the same feedd.
