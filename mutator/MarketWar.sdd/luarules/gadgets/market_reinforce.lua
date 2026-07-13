function gadget:GetInfo()
    return {
        name    = "Market Reinforcements",
        desc    = "Per-lane: price flips rescue the underdog; whale volume deploys armies",
        author  = "bar-market-war",
        layer   = 2,
        enabled = true,
    }
end

if not gadgetHandler:IsSyncedCode() then return end

-- Tuning (mirror config/war.env)
local FLIP_PCT          = 0.05        -- 1-minute move (%) that counts as a flip
local FLIP_HOLD_SEC     = 30
local FLIP_COOLDOWN_SEC = 120
local FLIP_BASE_SQUAD   = 8
local FLIP_MAX_SQUAD    = 32
local DOMINANCE_RATIO   = 1.5
local DOMINANCE_MIN     = 10
local WHALE_PER_STEP    = 4
local WHALE_MAX         = 24
local WHALE_COOLDOWN_SEC = 30         -- per side

-- Lane pairs; whale = 1s volume bucket that triggers a deploy, in the
-- market's native unit. Flank markets trade chunkier (fewer, bigger prints —
-- measured ~28/min SPX, ~14/min GOLD), so their bars are set lower (~$15k)
-- than BTC's ($32k). ETH parity with BTC (~$32k at ~$3.2k/ETH).
-- lane kind decides squad composition AND spawn point: sea lanes drop ships
-- IN their ocean (per-team deep-water coords from the heightmap), air lanes
-- drop aircraft at base, land lanes drop the mixed ground squad at base.
local PAIRS = {
    { key = "btc",  mkt = "BTC",  asset = 0, usd = 1, whale = 0.5, kind = "land" },
    { key = "spx",  mkt = "SPX",  asset = 2, usd = 3, whale = 2,   kind = "sea" },
    { key = "gold", mkt = "GOLD", asset = 4, usd = 5, whale = 4,   kind = "sea" },
    { key = "eth",  mkt = "ETH",  asset = 6, usd = 7, whale = 10,  kind = "air" },
}

-- Deep-water drop points per sea team (from the map heightmap, ~-40..-70 depth)
local SEA_DROP = {
    [2] = { x = 6394, z = 1639 },   -- SP500, NW ocean
    [3] = { x = 1818, z = 4667 },   -- USD-SP500, NW ocean
    [4] = { x = 10695, z = 9952 },  -- GOLD, SE ocean (base on the SE coastline)
    [5] = { x = 6800, z = 11000 },  -- USD-GOLD, SE ocean (base at south edge)
}

-- Squads by lane kind and faction (assets = Armada, USD = Cortex).
-- Healthy mixes: land = raiders/rockets/arty/tank/radar; sea = patrol boats,
-- corvettes, missile ship, destroyer; air = fighters, bombers, scout.
local SQUADS = {
    land = {
        arm = { "armpw", "armpw", "armrock", "armham", "armstump", "armmark" },
        cor = { "corak", "corak", "corstorm", "corthud", "corraid", "corvoyr" },
    },
    sea = {
        arm = { "armpt", "armpt", "armdecade", "armdecade", "armpship", "armroy" },
        cor = { "corpt", "corpt", "coresupp", "coresupp", "corpship", "corroy" },
    },
    air = {
        arm = { "armfig", "armfig", "armthund", "armthund", "armpeep", "armkam" },
        cor = { "corveng", "corveng", "corshad", "corshad", "corfink", "corbw" },
    },
}
local ASSET_TEAMS = { [0] = true, [2] = true, [4] = true, [6] = true }

local function squadFor(pr, teamID, n)
    local list = SQUADS[pr.kind][ASSET_TEAMS[teamID] and "arm" or "cor"]
    local out = {}
    for i = 1, n do out[i] = list[(i - 1) % #list + 1] end
    return out
end

local function spawnSquad(pr, teamID, n, kind, f)
    local sp = (pr.kind == "sea" and SEA_DROP[teamID])
        or (GG.MarketWar.startPos and GG.MarketWar.startPos[teamID])
    if not sp then return end
    local enemyTeam = (teamID == pr.asset) and pr.usd or pr.asset
    local enemy = (pr.kind == "sea" and SEA_DROP[enemyTeam])
        or (GG.MarketWar.startPos and GG.MarketWar.startPos[enemyTeam])
    local scatter = pr.kind == "sea" and 250 or 160
    local spawned = 0
    for _, defName in ipairs(squadFor(pr, teamID, n)) do
        local x = sp.x + math.random(-scatter, scatter)
        local z = sp.z + math.random(-scatter, scatter)
        local y = Spring.GetGroundHeight(x, z)
        local uid = Spring.CreateUnit(defName, x, y, z, 0, teamID)
        if uid then
            spawned = spawned + 1
            if enemy then
                if pr.kind == "land" then
                    -- funnel through the isthmus choke (see market_conveyor)
                    local wx, wz = 6100 + math.random(-250, 250), 6150 + math.random(-250, 250)
                    Spring.GiveOrderToUnit(uid, CMD.FIGHT,
                        { wx, Spring.GetGroundHeight(wx, wz), wz }, 0)
                    Spring.GiveOrderToUnit(uid, CMD.FIGHT,
                        { enemy.x, Spring.GetGroundHeight(enemy.x, enemy.z), enemy.z }, { "shift" })
                else
                    Spring.GiveOrderToUnit(uid, CMD.FIGHT,
                        { enemy.x, Spring.GetGroundHeight(enemy.x, enemy.z), enemy.z }, 0)
                end
            end
        end
    end
    if spawned > 0 then
        Spring.SetGameRulesParam("mkt_drop_frame", f)
        Spring.SetGameRulesParam("mkt_drop_team", teamID)
        Spring.SetGameRulesParam("mkt_drop_n", spawned)
        Spring.SetGameRulesParam("mkt_drop_kind", kind)
        Spring.Log("MKTWAR", "info", string.format("DROP %s kind=%d team=%d n=%d", pr.key, kind, teamID, spawned))
    end
end

local function checkFlip(pr, f)
    local hist = pr.hist
    hist[#hist + 1] = (GG.MarketWar.price and GG.MarketWar.price[pr.mkt]) or 0
    if #hist > 60 then table.remove(hist, 1) end
    if #hist < 2 or hist[1] <= 0 then return end
    local pct60 = (hist[#hist] - hist[1]) / hist[1] * 100

    local ca = Spring.GetTeamUnitCount(pr.asset) or 0
    local cu = Spring.GetTeamUnitCount(pr.usd) or 0
    local underdog
    if ca >= DOMINANCE_MIN and ca >= cu * DOMINANCE_RATIO then underdog = pr.usd end
    if cu >= DOMINANCE_MIN and cu >= ca * DOMINANCE_RATIO then underdog = pr.asset end
    if not underdog then pr.flipHold = 0; return end

    -- rising price favors the asset team; falling favors USD
    local favored = pct60 >= 0 and pr.asset or pr.usd
    if favored == underdog and math.abs(pct60) >= FLIP_PCT then
        pr.flipHold = pr.flipHold + 1
    else
        pr.flipHold = 0
        return
    end

    if pr.flipHold >= FLIP_HOLD_SEC and f - pr.lastFlip >= FLIP_COOLDOWN_SEC * 30 then
        local steps = math.floor(math.abs(pct60) / FLIP_PCT)
        local n = math.min(FLIP_MAX_SQUAD, FLIP_BASE_SQUAD * steps)
        pr.lastFlip = f
        pr.flipHold = 0
        spawnSquad(pr, underdog, n, 1, f)
    end
end

local function checkWhale(pr, f)
    local rates = GG.MarketWar.rates and GG.MarketWar.rates[pr.mkt]
    if not rates then return end
    local vols = { [pr.asset] = rates.buy or 0, [pr.usd] = rates.sell or 0 }
    for teamID, vol in pairs(vols) do
        if vol >= pr.whale and f - pr.lastWhale[teamID] >= WHALE_COOLDOWN_SEC * 30 then
            local n = math.min(WHALE_MAX, WHALE_PER_STEP * math.floor(vol / pr.whale))
            pr.lastWhale[teamID] = f
            spawnSquad(pr, teamID, n, 2, f)
        end
    end
end

function gadget:Initialize()
    for _, pr in ipairs(PAIRS) do
        pr.hist = {}
        pr.flipHold = 0
        pr.lastFlip = -math.huge
        pr.lastWhale = { [pr.asset] = -math.huge, [pr.usd] = -math.huge }
    end
end

function gadget:GameFrame(f)
    if f % 30 ~= 0 then return end
    local active = GG.MarketWar.roundActive or {}
    for _, pr in ipairs(PAIRS) do
        if active[pr.key] == false then
            pr.flipHold = 0
        else
            checkFlip(pr, f)
            checkWhale(pr, f)
        end
    end
end
