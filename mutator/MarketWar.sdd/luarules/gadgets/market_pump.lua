function gadget:GetInfo()
    return {
        name    = "Market Pump",
        desc    = "BAM pump.fun windowed net-order-flow spawns: each 3s the heavier side of the tape deploys a log-scaled, tier-gated squad, capped by a standing-army ceiling",
        author  = "bar-market-war",
        layer   = 3,
        enabled = true,
    }
end

if not gadgetHandler:IsSyncedCode() then return end

-- Tuning (mirror config/war.env). Buys -> team 6 (BAM/Armada), sells -> team 7
-- (USD-BAM/Cortex). We accumulate per-side SOL volume over a window, then spawn
-- for the NET-heavier side only: a pump floods the bulls and starves the bears,
-- a dump flips it. The log-compressed count + army cap keep a hot mint from
-- swamping the map (per-trade insta-spawn hit 93% of all units, 2026-07-15) and
-- keep a fresh low-volume token from being a ghost lane (same curve, both ends).
local ENABLED          = true
local WINDOW_SEC       = 3
local VOL_SCALE        = 1.0    -- V0
local COUNT_K          = 4
local MAX_PER_WINDOW   = 20
local ARMY_CAP         = 150    -- per-team total units; skip spawning above this
local TIER2_VOL        = 2      -- window V_net (SOL) to start mixing T2
local TIER3_VOL        = 20     -- window V_net (SOL) to start mixing T3

local ASSET_TEAM, USD_TEAM = 6, 7

-- Full roster minus naval/hover. T1 names mirror market_reinforce (validated
-- live); T2/T3 verified present in the installed game archive. Composition is
-- symmetric per side: fighter + bomber + raider/rocket/arty/tank.
local UNITS = {
    arm = {
        t1 = { "armpw", "armrock", "armham", "armstump", "armfig", "armthund" },
        t2 = { "armfido", "armbull", "armmav", "armzeus" },
        t3 = { "armbanth" },
    },
    cor = {
        t1 = { "corak", "corstorm", "corthud", "corraid", "corveng", "corshad" },
        t2 = { "corsumo", "correap", "corcat" },
        t3 = { "corkorg" },
    },
}

local LOG2 = math.log(2)
local function facOf(team) return team == ASSET_TEAM and "arm" or "cor" end

-- V_net -> unit count (log-compressed, capped).
local function countFor(vnet)
    if vnet <= 0 then return 0 end
    local n = math.floor(COUNT_K * (math.log(1 + vnet / VOL_SCALE) / LOG2) + 0.5)
    if n > MAX_PER_WINDOW then n = MAX_PER_WINDOW end
    return n
end

-- n units for a faction, tier mix gated on the window's aggregate V_net (NOT a
-- single trade): quiet window = all T1; busy = mix T2; whale window = some T3.
local function pickUnits(fac, n, vnet)
    local u = UNITS[fac]
    local out = {}
    for i = 1, n do
        local r = math.random()
        if vnet >= TIER3_VOL and r < 0.12 then
            out[i] = u.t3[math.random(#u.t3)]
        elseif vnet >= TIER2_VOL and r < 0.35 then
            out[i] = u.t2[math.random(#u.t2)]
        else
            out[i] = u.t1[math.random(#u.t1)]
        end
    end
    return out
end

-- Per-side SOL volume accumulated within the current window.
local accum = { [ASSET_TEAM] = 0, [USD_TEAM] = 0 }

local function resetAccum()
    accum[ASSET_TEAM] = 0
    accum[USD_TEAM] = 0
end

function gadget:RecvLuaMsg(msg, playerID)
    local side, sol = msg:match("^bam:([BS]):([%d%.]+):")
    if not side then return end
    if playerID ~= 0 then return true end
    if not ENABLED then return true end
    local active = (GG.MarketWar and GG.MarketWar.roundActive) or {}
    if active.bam == false then return true end
    local team = (side == "B") and ASSET_TEAM or USD_TEAM
    accum[team] = accum[team] + (tonumber(sol) or 0)
    return true
end

local function spawnSquad(team, names)
    local sp = GG.MarketWar and GG.MarketWar.startPos and GG.MarketWar.startPos[team]
    if not sp then return 0 end
    local enemyTeam = (team == ASSET_TEAM) and USD_TEAM or ASSET_TEAM
    local enemy = GG.MarketWar.startPos[enemyTeam]
    local spawned = 0
    for _, name in ipairs(names) do
        local x = sp.x + math.random(-160, 160)
        local z = sp.z + math.random(-160, 160)
        local y = Spring.GetGroundHeight(x, z)
        local uid = Spring.CreateUnit(name, x, y, z, 0, team)
        if uid then
            spawned = spawned + 1
            if enemy then
                Spring.GiveOrderToUnit(uid, CMD.FIGHT,
                    { enemy.x, Spring.GetGroundHeight(enemy.x, enemy.z), enemy.z }, 0)
            end
        end
    end
    return spawned
end

function gadget:GameFrame(f)
    if f % (WINDOW_SEC * 30) ~= 0 then return end   -- once per window

    local active = (GG.MarketWar and GG.MarketWar.roundActive) or {}
    if active.bam == false then
        -- BAM round is between rounds: drop pending flow so a fresh round can't
        -- inherit pre-existing pressure.
        resetAccum()
        return
    end

    local buy, sell = accum[ASSET_TEAM], accum[USD_TEAM]
    resetAccum()

    local vnet = math.abs(buy - sell)
    if vnet <= 0 then return end
    local winner = (buy >= sell) and ASSET_TEAM or USD_TEAM

    -- Standing-army cap: total team units (AI-built + income + prior pump).
    if Spring.GetTeamUnitCount(winner) >= ARMY_CAP then
        -- Spring.Log (infolog only), NOT Spring.Echo: in the streamed cloud host
        -- the host engine IS the broadcast, so Echo would paint telemetry
        -- on-screen. Log keeps it off the stream; census/web tooling still reads
        -- it from infolog. (Matches market_reinforce's MKTWAR channel.)
        Spring.Log("MKTWAR", "info", string.format(
            "MKTWAR-PUMP f=%d win=%d vnet=%.3f CAPPED(units=%d>=%d)",
            f, winner, vnet, Spring.GetTeamUnitCount(winner), ARMY_CAP))
        return
    end

    local n = countFor(vnet)
    if n == 0 then return end
    local got = spawnSquad(winner, pickUnits(facOf(winner), n, vnet))
    Spring.Log("MKTWAR", "info", string.format(
        "MKTWAR-PUMP f=%d win=%d buy=%.3f sell=%.3f vnet=%.3f n=%d spawned=%d units=%d",
        f, winner, buy, sell, vnet, n, got, Spring.GetTeamUnitCount(winner)))
end
