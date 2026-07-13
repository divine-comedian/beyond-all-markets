function gadget:GetInfo()
    return {
        name    = "Market Rounds",
        desc    = "Per-lane rounds: commander death scores and resets only that pair",
        author  = "bar-market-war",
        layer   = 1,
        enabled = true,
    }
end

if not gadgetHandler:IsSyncedCode() then return end

-- Tuning (mirror config/war.env)
local INTERMISSION_FRAMES = 10 * 30
local CATACLYSM_DELAY     = 30        -- 1s after the kill before the wipe
local START_METAL         = 1000
local START_ENERGY        = 1000
local NUKE_CEGS = { "nuclearexplosion", "advanced-nuke", "commander-blast" }

-- Lane pairs (mirror market_income.lua / gen-startscript.sh)
local PAIRS = {
    { key = "btc",  asset = 0, usd = 1 },
    { key = "spx",  asset = 2, usd = 3 },
    { key = "gold", asset = 4, usd = 5 },
    { key = "eth",  asset = 6, usd = 7 },
}
local teamPair = {}   -- teamID -> pair
for _, pr in ipairs(PAIRS) do
    teamPair[pr.asset], teamPair[pr.usd] = pr, pr
end

local startPos     = {}   -- teamID -> {x,y,z}
local isCommander  = {}   -- unitDefID -> defName
local commanderDef = {}   -- teamID -> defName
local isFactory    = {}   -- unitDefID -> true

-- Production insurance: a commander can survive a round reset, wander off
-- and build eco forever without ever rebuilding unit production (seen live:
-- SP500 retreated inland where no shipyard placement exists and all its land
-- factories are banned). If a team has NO factory for 120s mid-round, the
-- game plants the lane-appropriate one and the AI adopts it.
local INSURANCE_FRAMES = 120 * 30
local SEA_DROP = {   -- deep water per sea team (mirror market_conveyor.lua)
    [2] = { x = 6394, z = 1639 },
    [3] = { x = 1818, z = 4667 },
    [4] = { x = 9832, z = 7117 },
    [5] = { x = 6800, z = 11000 },
}
local INSURE_DEF = {  -- teamID -> factory unitdef name
    [0] = "armlab", [1] = "corlab",     -- BTC: ground
    [2] = "armsy",  [3] = "corsy",      -- SP500: naval
    [4] = "armsy",  [5] = "corsy",      -- GOLD: naval
    [6] = "armap",  [7] = "corap",      -- ETH: air
}
local noFactorySince = {}   -- teamID -> frame

function gadget:Initialize()
    GG.MarketWar = GG.MarketWar or {}
    GG.MarketWar.surge = GG.MarketWar.surge or {}
    GG.MarketWar.roundActive = {}   -- pair key -> bool
    for udid, ud in pairs(UnitDefs) do
        if ud.customParams and ud.customParams.iscommander then
            isCommander[udid] = ud.name
        end
        if ud.isFactory then isFactory[udid] = true end
    end
    for _, pr in ipairs(PAIRS) do
        pr.wins = { [pr.asset] = 0, [pr.usd] = 0 }
        pr.round = 1
        pr.active = true
        GG.MarketWar.roundActive[pr.key] = true
        Spring.SetGameRulesParam("mkt_wins" .. pr.asset, 0)
        Spring.SetGameRulesParam("mkt_wins" .. pr.usd, 0)
        Spring.SetGameRulesParam("mkt_round_" .. pr.key, 1)
        Spring.SetGameRulesParam("mkt_intermission_" .. pr.key, 0)
    end
end

function gadget:GameStart()
    for _, teamID in ipairs(Spring.GetTeamList()) do
        local x, y, z = Spring.GetTeamStartPosition(teamID)
        if x and x > 0 then startPos[teamID] = { x = x, y = y, z = z } end
        for _, uid in ipairs(Spring.GetTeamUnits(teamID)) do
            local defName = isCommander[Spring.GetUnitDefID(uid)]
            if defName then
                commanderDef[teamID] = defName
                if not startPos[teamID] then
                    local x2, y2, z2 = Spring.GetUnitPosition(uid)
                    startPos[teamID] = { x = x2, y = y2, z = z2 }
                end
            end
        end
    end
    GG.MarketWar.startPos = startPos
end

local function nukeVisual(p)
    local y = Spring.GetGroundHeight(p.x, p.z)
    for _, ceg in ipairs(NUKE_CEGS) do
        Spring.SpawnCEG(ceg, p.x, y + 40, p.z)
    end
end

function gadget:UnitDestroyed(unitID, unitDefID, unitTeam)
    local pr = teamPair[unitTeam]
    if not pr or not pr.active then return end
    local defName = isCommander[unitDefID]
    if not defName then return end
    for _, uid in ipairs(Spring.GetTeamUnits(unitTeam)) do
        if uid ~= unitID and isCommander[Spring.GetUnitDefID(uid)] then
            return   -- team still has a commander; not a round end
        end
    end
    -- lane semantics: the pair OPPONENT scores, whoever landed the kill
    local killer = (unitTeam == pr.asset) and pr.usd or pr.asset
    pr.active = false
    GG.MarketWar.roundActive[pr.key] = false
    pr.wins[killer] = pr.wins[killer] + 1
    local f = Spring.GetGameFrame()
    pr.pendingWipe  = f + CATACLYSM_DELAY
    pr.pendingSpawn = f + INTERMISSION_FRAMES
    Spring.SetGameRulesParam("mkt_wins" .. killer, pr.wins[killer])
    Spring.SetGameRulesParam("mkt_roundwinner_" .. pr.key, killer)
    Spring.SetGameRulesParam("mkt_intermission_" .. pr.key, pr.pendingSpawn)
    Spring.Log("MKTWAR", "info", string.format("ROUND %s: round %d to team %d (%d-%d)",
        pr.key, pr.round, killer, pr.wins[pr.asset], pr.wins[pr.usd]))
end

local function wipePair(pr)
    for _, teamID in ipairs({ pr.asset, pr.usd }) do
        local p = startPos[teamID]
        if p then nukeVisual(p) end
        for _, uid in ipairs(Spring.GetTeamUnits(teamID)) do
            Spring.DestroyUnit(uid, true, false)
        end
    end
end

local function startRound(pr)
    for _, teamID in ipairs({ pr.asset, pr.usd }) do
        local p, defName = startPos[teamID], commanderDef[teamID]
        if p and defName then
            local y = Spring.GetGroundHeight(p.x, p.z)
            local uid = Spring.CreateUnit(defName, p.x, y, p.z, 0, teamID)
            if uid then
                Spring.SpawnCEG("commanderspawn", p.x, y, p.z)
            else
                pr.pendingSpawn = Spring.GetGameFrame() + 30   -- blocked; retry
                return
            end
        end
        Spring.SetTeamResource(teamID, "m", START_METAL)
        Spring.SetTeamResource(teamID, "e", START_ENERGY)
    end
    pr.round = pr.round + 1
    pr.active = true
    GG.MarketWar.roundActive[pr.key] = true
    pr.pendingSpawn = nil
    Spring.SetGameRulesParam("mkt_round_" .. pr.key, pr.round)
    Spring.SetGameRulesParam("mkt_intermission_" .. pr.key, 0)
    Spring.Log("MKTWAR", "info", string.format("ROUND %s: round %d begins (%d-%d)",
        pr.key, pr.round, pr.wins[pr.asset], pr.wins[pr.usd]))
end

local function insurePos(teamID)
    local base = startPos[teamID]
    if not base then return end
    local drop = SEA_DROP[teamID]
    if not drop then return base.x, base.z end   -- land/air: at base
    -- naval: first comfortably deep water walking from base toward the drop
    for t = 0, 1, 0.02 do
        local x = base.x + (drop.x - base.x) * t
        local z = base.z + (drop.z - base.z) * t
        if Spring.GetGroundHeight(x, z) < -12 then
            return x, z
        end
    end
    return drop.x, drop.z
end

local function checkInsurance(f)
    for teamID, defName in pairs(INSURE_DEF) do
        local pr = teamPair[teamID]
        if pr and pr.active then
            local hasFactory = false
            for _, uid in ipairs(Spring.GetTeamUnits(teamID)) do
                if isFactory[Spring.GetUnitDefID(uid)] then hasFactory = true; break end
            end
            if hasFactory then
                noFactorySince[teamID] = nil
            else
                noFactorySince[teamID] = noFactorySince[teamID] or f
                if f - noFactorySince[teamID] >= INSURANCE_FRAMES then
                    local x, z = insurePos(teamID)
                    if x then
                        local uid = Spring.CreateUnit(defName, x, Spring.GetGroundHeight(x, z), z, 0, teamID)
                        if uid then
                            Spring.SpawnCEG("commanderspawn", x, Spring.GetGroundHeight(x, z), z)
                            Spring.SetGameRulesParam("mkt_insure_frame", f)
                            Spring.SetGameRulesParam("mkt_insure_team", teamID)
                            noFactorySince[teamID] = nil
                        end
                    end
                end
            end
        end
    end
end

function gadget:GameFrame(f)
    for _, pr in ipairs(PAIRS) do
        if pr.pendingWipe and f >= pr.pendingWipe then
            pr.pendingWipe = nil
            wipePair(pr)
        end
        if pr.pendingSpawn and f >= pr.pendingSpawn then
            startRound(pr)
        end
    end
    if f % 300 == 0 then checkInsurance(f) end
end
