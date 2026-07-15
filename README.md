# BAR Market War

A never-ending Beyond All Reason war driven by live market order flow, four
lanes on one map: **SOL/USD** (mid, Binance+Coinbase), **SP500/USD** (north,
Hyperliquid xyz:SP500), **GOLD/USD** (south, Hyperliquid xyz:GOLD + PAXG) and
**BAM/USD** (back, a pump.fun memecoin). Taker **buys** feed the asset team
(Armada), taker **sells** feed its USD opponent (Cortex); assets and USDs
form two alliance blocks. The BAM lane runs hotter than the rest: every buy
or sell insta-spawns a size-tiered squad live from the stream audience's own
trades, on top of the same income/round rules. Eight BARbarIAn AIs fight; a
commander kill scores that lane's round, nukes both its bases, and respawns
the pair fresh. `deathmode=neverend` guarantees no game over.

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
Binance solusdt@aggTrade / pumpdev subscribeTokenTrade ──ws──> feed/feedd.py ──tcp 127.0.0.1:8642──>
LuaUI widget market_feed.lua (host player only) ──SendLuaRulesMsg──>
synced gadget market_income.lua ──AddTeamResource──> Bulls/Bears economies
```

- `mutator/MarketWar.sdd` — dev-archive mutator on top of BAR (BAR repo untouched):
  - `market_income.lua` — 1s income ticks: `baseline + volume × per-lane multiplier`, deep storage
  - `market_rounds.lua` — commander death = scored round end: nuke both bases, wipe all units, respawn fresh (session scoreboard)
  - `market_reinforce.lua` — market events spawn units directly: sustained price flip rescues the field underdog; per-lane whale buckets (SOL 180, SPX 2, GOLD 4, BAM 20) deploy squads for their side
  - `market_pump.lua` — BAM lane: each pump.fun buy/sell insta-spawns a size-tiered squad for its side (buys→BAM, sells→USD-BAM), flood-guarded
  - `market_scrapper.lua` — drops one naval reclaimer per sea team each minute (capped) to clear ocean wrecks; ocean scrap yields 90% less metal so reclaim stays a bonus, not the econ
  - `market_debug.lua` — heartbeat log line every 10s (`MKTWAR f=...`)
  - Widgets: `market_feed.lua` bridges feedd into synced state (now also relays the `bam:` line and fills `WG.BAMTicker`); `market_announce.lua` — on-stream BAM trade ticker + whale/flip banners
- `feed/feedd.py` — trade bucketing + TCP broadcast (`--synthetic` for offline dev); `pytest feed/tests`
- `scripts/run-war.sh` — supervisor: restarts feedd/engine on crash
- `config/war.env` — every port/team/tuning knob

## Tuning (config/war.env mirrors the gadget constants)

| Knob | Value | Meaning |
|---|---|---|
| `METAL_PER_BTC` / `ENERGY_PER_BTC` | 400 / 4000 | legacy per-volume knobs; superseded by the per-lane `m`/`e` multipliers hardcoded in `market_income.lua`'s `PAIRS` table (SOL 1.2/12, SPX 47/470, GOLD 25/250, BAM 1.5/15) |
| `BASELINE_METAL/ENERGY` | 6 / 60 | per-second floor so a dead market still skirmishes |
| `LOW_ECO` | 1 | eco structures buildable at 10% output via `tweakdefs` (v1 stripped them entirely — made BARbarIAn go limp); market income stays primary |
| `ROUND_INTERMISSION_SEC` | 10 | pause between commander kill and fresh spawn |
| `FLIP_DROP_PCT/HOLD/COOLDOWN` | 0.05% / 30s / 120s | sustained 1-min flip against the dominant side drops underdog reinforcements (BAM overrides to 2.0%; 0.05% is memecoin noise) |
| `WHALE_SPAWN_BTC` | 0.5 | legacy fallback; per-lane whale bar is hardcoded in `market_reinforce.lua`'s `PAIRS` table (SOL 180, SPX 2, GOLD 4, BAM 20) |
| `COMEBACK_COEF/SCALE/MAX` | 1.0 / 0.5 / 4 | true comeback: income boost for the side losing the fight (live army deficit), exponential and boost-only |
| `COMEBACK_DROP_RATIO/HOLD/COOLDOWN` | 2.0 / 4s / 45s | army-deficit reinforcement drops for the behind side |
| `SCRAP_DROP_PERIOD_SEC` / `SCRAP_MAX_ALIVE` | 60s / 6 | naval scrapper cadence and per-team cap |
| `SCRAP_YIELD` / `SCRAP_SEA_DEPTH` | 0.10 / -15 | ocean wreck metal multiplier (−90%) and the deep-water cutoff it applies below |
| `WHALE_SPAWN_SOL` / `WHALE_SPAWN_BAM` | 180 / 20 | SOL lane whale bar (~$32k parity) / BAM announced-whale bar (SOL notional) |
| `PUMP_MAX_SPAWN_PER_SEC` / `PUMP_QUEUE_CAP` | 8 / 60 | BAM per-trade spawn budget and queue cap (flood guard) |
| `PUMP_TIER1..4` | 0.5/2/10/50 | solAmount cut points → spawn size & unit tier |
| `BAM_MINT` / `PUMP_WS_URL` | (mint) / pumpdev.io | pump.fun token + PumpDev trade websocket; empty mint → `feedd --bam-proxy` |

GOLD is the thinnest lane, so `feed/feedd.py` aggregates the most gold venues: Hyperliquid
`xyz:GOLD` (price owner) + Binance PAXG/XAUT (USDT+USDC) + Bybit XAUT + Coinbase PAXG — all
1 token = 1 troy oz, folded in as volume without rescale.

SOL/USD is priced off Binance `solusdt` (price owner) with Coinbase `SOL-USD` folded in as
extra volume. BAM/USD has no order book — `feed/feedd.py` subscribes to PumpDev's
`subscribeTokenTrade` on the BAM mint and uses each trade's `solAmount` as volume and
`marketCapSol` as the price signal. Before the token is minted, `feedd --bam-proxy` adopts
a live hot pump.fun mint as a stand-in so the lane isn't dead on `BAM_MINT=""`.

Each lane's per-unit multiplier is sized to its instrument (SOL 1.2 metal/unit vs GOLD's
25 and SPX's 47, since 1 SOL is worth far less than 1 oz of gold or one SP500 contract),
so quiet flow barely nudges a lane's income while crossing its whale bar (SOL 180, SPX 2,
GOLD 4, BAM 20) both spikes it and drops an instant squad in `market_reinforce.lua`.
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
