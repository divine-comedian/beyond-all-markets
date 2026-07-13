# Market War — Development Journal

## 2026-07-13 — Marathon session: 1 lane → 4 lanes, self-healing stack, streaming infra

### Shipped (18 commits, all verified live)
- **Four market lanes**: BTC ground (isthmus), SP500 + GOLD naval (NW/SE oceans),
  ETH air (back corners). Live feeds: Binance (BTC/ETH/PAXG) + Coinbase +
  Hyperliquid xyz:SP500/xyz:GOLD (licensed, keyless, aggressor-side) + Bybit
  (SPYX unit-normalized, XAUT). Notional-normalized income, 20s EMA smoothing.
- **Round system**: per-pair scored rounds, pair-only nuke/wipe/respawn,
  ROUND TRACKER panel. Commanders 2x hp / 1.5x dmg.
- **Market mechanics**: whale deploys (lane-native squads at lane fronts),
  price-flip underdog drops, 15m order-flow window.
- **Self-healing stack** (each layer verified against a live failure):
  watchdog (silent AI init death) → catatonia detector v3 (pegged-bank
  busy-limp) → production insurance (factory planted at 120s→45s staged) →
  factory foreman (empty queues game-filled from bank) → commander shepherd
  (idle commanders guard factories) → PROACTIVE REACTIVATION (both pair AIs
  aireload +40s after every round end; wired to the round signal after the
  mkt_reset param path silently never fired).
  PROVEN 2026-07-13: BTC round → both reloads at +40s → +170s recovery
  reports 13/31 units. ETH cycle same.
- **Anti-turtle**: conveyor v4 (lane ownership, 5s sweeps, front-hunter
  ATTACK orders), isthmus funnel for mid lane (pathing hugged coasts; under
  fog+jammers streams passed unseen), air-vs-air lane ownership.
- **AI config fork** (VFS-shadow of BARb hard profile): fearless targeting,
  market-scale tech gates, 2x defence budget + 14-type defence ladder,
  halved eco appetite (LOW_ECO plants at 10% made stock curve spam solars).
- **Phase-2 streaming infra** (untouched host): stream.sh (Xvfb → spectator
  spring → VAAPI → RTMP, --test mode), setup-stream.sh (needs sudo, not yet
  run), STREAM_* knobs. YouTube key applied for (24h wait).

### Staged for next boot (committed, not yet run)
- Mercy rule: ≤2 vs ≥25 units for 3min = decided round (sea-lane deadlock:
  fled inland commanders are unkillable by navy — seen live on SP500).
- Insurance delay 120s → 45s (BTC sat on a full bank, production dead air).
- GOLD spawn → (11840,10400) SE coastline (user: "much further south");
  naval drop/front → (10695,9952).

### Session-end observations (open items)
1. **USER DIRECTIVE**: stop fighting the AI with order overrides (conveyor/
   tether force-moves) — change the UNDERLYING behavior. Path found:
   CircuitAI's AngelScript layer (engine-master/AI/Skirmish/BARb/stable/
   script/ — main.as, manager/military.as, manager/factory.as; the
   "Script: void AiUnitAdded not found!" infolog lines are unimplemented
   hooks). Next session: MarketWar AngelScript profile — attack commitment
   (no recall), bomber re-targeting, commander discipline, factory-first
   opener programmed into the AI itself.
2. **Air jugular**: bombers fly ~75% to target then return home (engine
   return-to-base default). Directive: "always go for the jugular, play
   aggressive, don't hold back." Fix in AngelScript pass (or re-target
   returning aircraft: fighters → nearest enemy air, bombers → commander).
3. Sea lanes still stutter-advance under the AI-recall tug-of-war (v4 5s
   sweeps mitigate; AngelScript is the real fix). Structural alternative if
   needed: sister army teams (AI-less shadow team per side owns the army;
   AI keeps base/eco/production) — a half-day refactor, held in reserve.
4. Round cadence is slow now (tanky commanders + dense defence): ~15-25min.
   If stream pacing needs faster rounds: commander hp multiplier, or mercy
   thresholds.
5. Busy lanes bank 8-12k metal (income > single-factory throughput):
   foreman batch could scale with bank, or AngelScript factory-count logic.
6. Heartbeat telemetry format: MKTWAR f=N | <LANE> a=X/u=Y am=.. um=..
   b=.. s=.. px=.. — greppable in infolog; events: MKTWAR-{ROUND,DROP,PUSH,
   INSURE,REACTIVATE,RECOVERY,WATCHDOG,MERCY}.

### Final 30-min capture (session close)
- Reactivation cycle PROVEN twice more: ETH + BTC rounds, REACTIVATE both
  teams at +40s, RECOVERY at +170s (BTC: 13/31 units rebuilt).
- The sea-lane deadlock in full bloom: USD-SP500 stacked 358 ships against
  SP500's unkillable inland commander — exactly what the staged mercy rule
  ends. Watchdog reloads (t2 x2, t4 x2) correctly could NOT fix it: reload
  cures broken AI state, not unreachable-commander geometry.
- GOLD showing STUCK-a with ~3950 pegged bank at close (45s insurance +
  mercy + coastline respawn all staged for it).
- Feed at close: SPX $60-320k/min, GOLD 7-12 trades/min, ETH caught a
  24.2-ETH single-second print. All venues healthy.

### Streaming next steps
1. `sudo bash scripts/setup-stream.sh` (user, needs password)
2. `scripts/stream.sh --test` → measure llvmpipe fps; VirtualGL if weak
3. YouTube stream key (~24h) → `STREAM_KEY=... scripts/stream.sh`
4. Later: webpage embedding stream + live chart from feedd; market_director
   camera widget (cut to fights/nukes/whale drops via existing params).
