function gadget:GetInfo()
    return {
        name    = "Market Pump",
        desc    = "BAM pump.fun per-trade insta-spawn: each buy/sell deploys a size-tiered squad for its side",
        author  = "bar-market-war",
        layer   = 3,
        enabled = true,
    }
end

if not gadgetHandler:IsSyncedCode() then return end

-- Tuning (mirror config/war.env). Buys -> team 6 (BAM/Armada), sells -> team 7
-- (USD-BAM/Cortex). solAmount sets tier AND count; a per-second budget + capped
-- queue keep a memecoin frenzy from lag-spiking the sim.
local ENABLED           = true
local MAX_SPAWN_PER_SEC = 8
local QUEUE_CAP         = 60
local T1, T2, T3, T4    = 0.5, 2, 10, 50   -- solAmount cut points

local ASSET_TEAM, USD_TEAM = 6, 7

-- Full roster minus naval/hover. T1 names mirror market_reinforce (validated
-- live); T2/T3 verified present in the installed game archive.
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

local function facOf(team) return team == ASSET_TEAM and "arm" or "cor" end

-- solAmount -> list of unit defNames (size-tiered).
local function pickUnits(fac, sol)
    local u = UNITS[fac]
    local out = {}
    if sol < T1 then
        out[1] = u.t1[math.random(#u.t1)]
    elseif sol < T2 then
        for i = 1, 3 do out[i] = u.t1[math.random(#u.t1)] end
    elseif sol < T3 then
        for i = 1, 6 do out[i] = u.t1[math.random(#u.t1)] end
        out[7] = u.t2[math.random(#u.t2)]
    elseif sol < T4 then
        for i = 1, 3 do out[i] = u.t2[math.random(#u.t2)] end
    else
        local n = math.min(2, 1 + math.floor((sol - T4) / T4))
        for i = 1, n do out[i] = u.t3[math.random(#u.t3)] end
    end
    return out
end

local queue = { [ASSET_TEAM] = {}, [USD_TEAM] = {} }

local function enqueue(team, sol)
    local q = queue[team]
    for _, name in ipairs(pickUnits(facOf(team), sol)) do
        q[#q + 1] = name
        if #q > QUEUE_CAP then table.remove(q, 1) end   -- drop oldest on overflow
    end
    return #q
end

function gadget:RecvLuaMsg(msg, playerID)
    local side, sol = msg:match("^bam:([BS]):([%d%.]+):")
    if not side then return end
    if playerID ~= 0 then return true end
    if not ENABLED then return true end
    local active = (GG.MarketWar and GG.MarketWar.roundActive) or {}
    if active.bam == false then return true end
    local team = (side == "B") and ASSET_TEAM or USD_TEAM
    local depth = enqueue(team, tonumber(sol))
    Spring.Echo(string.format("MKTWAR-PUMP recv side=%s sol=%s team=%d queued=%d",
        side, sol, team, depth))
    return true
end

local function drain(team)
    local q = queue[team]
    if #q == 0 then return 0 end
    local sp = GG.MarketWar and GG.MarketWar.startPos and GG.MarketWar.startPos[team]
    if not sp then return 0 end
    local enemyTeam = (team == ASSET_TEAM) and USD_TEAM or ASSET_TEAM
    local enemy = GG.MarketWar.startPos[enemyTeam]
    local n = math.min(MAX_SPAWN_PER_SEC, #q)
    local spawned = 0
    for _ = 1, n do
        local name = table.remove(q, 1)
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
    if f % 30 ~= 0 then return end            -- once per second
    local active = (GG.MarketWar and GG.MarketWar.roundActive) or {}
    if active.bam == false then
        -- BAM round is between rounds: drop stale queued trades so a fresh
        -- round can't inherit a pre-existing army from the last one.
        queue[ASSET_TEAM] = {}
        queue[USD_TEAM] = {}
        return
    end
    local a = drain(ASSET_TEAM)
    local u = drain(USD_TEAM)
    if a > 0 or u > 0 then
        Spring.Echo(string.format("MKTWAR-PUMP f=%d spawned a=%d u=%d q=%d/%d",
            f, a, u, #queue[ASSET_TEAM], #queue[USD_TEAM]))
    end
end
