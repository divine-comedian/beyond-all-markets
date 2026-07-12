function gadget:GetInfo()
    return {
        name    = "Market Reinforcements",
        desc    = "Price flips rescue the underdog; whale volume deploys armies",
        author  = "bar-market-war",
        layer   = 2,
        enabled = true,
    }
end

if not gadgetHandler:IsSyncedCode() then return end

-- Tuning (mirror config/war.env)
local FLIP_PCT          = 0.05        -- 1-minute move (%) that counts as a flip
local FLIP_HOLD_SEC     = 30          -- flip must hold this long
local FLIP_COOLDOWN_SEC = 120
local FLIP_BASE_SQUAD   = 8           -- units per FLIP_PCT step
local FLIP_MAX_SQUAD    = 32
local DOMINANCE_RATIO   = 1.5         -- unit-count ratio that defines the underdog
local DOMINANCE_MIN     = 10          -- dominant side needs at least this many units
local WHALE_BTC         = 0.5         -- 1s bucket that triggers a whale deploy
local WHALE_PER_STEP    = 4           -- units per WHALE_BTC step
local WHALE_MAX         = 24
local WHALE_COOLDOWN_SEC = 30         -- per side

-- Fixed T1 squads (team 0 = Armada, team 1 = Cortex; see gen-startscript.sh)
local SQUADS = {
    [0] = { "armpw", "armpw", "armpw", "armrock", "armstump" },
    [1] = { "corak", "corak", "corak", "corstorm", "corraid" },
}

local priceHist = {}                  -- rolling 60 x 1s samples
local flipHold  = 0
local lastFlipDrop = -math.huge
local lastWhale = { [0] = -math.huge, [1] = -math.huge }

local function squadFor(teamID, n)
    local list, out = SQUADS[teamID], {}
    for i = 1, n do out[i] = list[(i - 1) % #list + 1] end
    return out
end

local function spawnSquad(teamID, n, kind, f)
    local sp = GG.MarketWar.startPos and GG.MarketWar.startPos[teamID]
    if not sp then return end
    local enemy = GG.MarketWar.startPos[1 - teamID]
    local spawned = 0
    for _, defName in ipairs(squadFor(teamID, n)) do
        local x = sp.x + math.random(-160, 160)
        local z = sp.z + math.random(-160, 160)
        local y = Spring.GetGroundHeight(x, z)
        local uid = Spring.CreateUnit(defName, x, y, z, 0, teamID)
        if uid then
            spawned = spawned + 1
            if enemy then
                Spring.GiveOrderToUnit(uid, CMD.FIGHT,
                    { enemy.x, Spring.GetGroundHeight(enemy.x, enemy.z), enemy.z }, 0)
            end
        end
    end
    if spawned > 0 then
        Spring.SetGameRulesParam("mkt_drop_frame", f)
        Spring.SetGameRulesParam("mkt_drop_team", teamID)
        Spring.SetGameRulesParam("mkt_drop_n", spawned)
        Spring.SetGameRulesParam("mkt_drop_kind", kind)
        Spring.Echo(string.format("MKTWAR-DROP kind=%d team=%d n=%d", kind, teamID, spawned))
    end
end

local function checkFlip(f)
    priceHist[#priceHist + 1] = GG.MarketWar.price or 0
    if #priceHist > 60 then table.remove(priceHist, 1) end
    if #priceHist < 2 or priceHist[1] <= 0 then return end
    local pct60 = (priceHist[#priceHist] - priceHist[1]) / priceHist[1] * 100

    local c0 = Spring.GetTeamUnitCount(0) or 0
    local c1 = Spring.GetTeamUnitCount(1) or 0
    local underdog
    if c0 >= DOMINANCE_MIN and c0 >= c1 * DOMINANCE_RATIO then underdog = 1 end
    if c1 >= DOMINANCE_MIN and c1 >= c0 * DOMINANCE_RATIO then underdog = 0 end
    if not underdog then flipHold = 0; return end

    -- rising price favors team 0 (BTC); falling favors team 1 (USD)
    local favored = pct60 >= 0 and 0 or 1
    if favored == underdog and math.abs(pct60) >= FLIP_PCT then
        flipHold = flipHold + 1
    else
        flipHold = 0
        return
    end

    if flipHold >= FLIP_HOLD_SEC and f - lastFlipDrop >= FLIP_COOLDOWN_SEC * 30 then
        local steps = math.floor(math.abs(pct60) / FLIP_PCT)
        local n = math.min(FLIP_MAX_SQUAD, FLIP_BASE_SQUAD * steps)
        lastFlipDrop = f
        flipHold = 0
        spawnSquad(underdog, n, 1, f)
    end
end

local function checkWhale(f)
    local rates = { [0] = GG.MarketWar.buyRate or 0, [1] = GG.MarketWar.sellRate or 0 }
    for teamID = 0, 1 do
        if rates[teamID] >= WHALE_BTC and f - lastWhale[teamID] >= WHALE_COOLDOWN_SEC * 30 then
            local n = math.min(WHALE_MAX, WHALE_PER_STEP * math.floor(rates[teamID] / WHALE_BTC))
            lastWhale[teamID] = f
            spawnSquad(teamID, n, 2, f)
        end
    end
end

function gadget:GameFrame(f)
    if f % 30 ~= 0 then return end
    if GG.MarketWar.roundActive == false then flipHold = 0; return end
    checkFlip(f)
    checkWhale(f)
end
