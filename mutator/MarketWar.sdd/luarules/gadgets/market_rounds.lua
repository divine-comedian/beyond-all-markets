function gadget:GetInfo()
    return {
        name    = "Market Rounds",
        desc    = "Commander death ends the round: score, wipe, respawn",
        author  = "bar-market-war",
        layer   = 1,
        enabled = true,
    }
end

if not gadgetHandler:IsSyncedCode() then return end

-- Tuning (mirror config/war.env)
local INTERMISSION_FRAMES = 10 * 30   -- ROUND_INTERMISSION_SEC * simfps
local CATACLYSM_DELAY     = 30        -- 1s after the kill before the wipe
local START_METAL         = 1000
local START_ENERGY        = 1000
-- CEG names tried at both bases for the nuke visual; unknown names no-op
local NUKE_CEGS = { "nuclearexplosion", "advanced-nuke", "commander-blast" }

local startPos    = {}                -- teamID -> {x,y,z}
local isCommander = {}                -- unitDefID -> defName
local commanderDef = {}               -- teamID -> defName (for respawn)
local wins        = { [0] = 0, [1] = 0 }
local round       = 1
local roundActive = true
local pendingWipe, pendingSpawn      -- frames

function gadget:Initialize()
    GG.MarketWar = GG.MarketWar or {}
    GG.MarketWar.surge = GG.MarketWar.surge or {}   -- income gadget reads this; rounds never set it
    GG.MarketWar.roundActive = true
    for udid, ud in pairs(UnitDefs) do
        if ud.customParams and ud.customParams.iscommander then
            isCommander[udid] = ud.name
        end
    end
    Spring.SetGameRulesParam("mkt_wins0", 0)
    Spring.SetGameRulesParam("mkt_wins1", 0)
    Spring.SetGameRulesParam("mkt_round", round)
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
    if not roundActive then return end
    local defName = isCommander[unitDefID]
    if not defName then return end
    for _, uid in ipairs(Spring.GetTeamUnits(unitTeam)) do
        if uid ~= unitID and isCommander[Spring.GetUnitDefID(uid)] then
            return   -- team still has a commander; not a round end
        end
    end
    local killer = 1 - unitTeam            -- two-team war
    roundActive = false
    GG.MarketWar.roundActive = false
    wins[killer] = wins[killer] + 1
    local f = Spring.GetGameFrame()
    pendingWipe  = f + CATACLYSM_DELAY
    pendingSpawn = f + INTERMISSION_FRAMES
    Spring.SetGameRulesParam("mkt_wins" .. killer, wins[killer])
    Spring.SetGameRulesParam("mkt_roundwinner", killer)
    Spring.SetGameRulesParam("mkt_intermission", pendingSpawn)
    Spring.Echo(string.format("MKTWAR-ROUND round %d to team %d (score %d-%d)",
        round, killer, wins[0], wins[1]))
end

local function wipeField()
    for teamID, p in pairs(startPos) do nukeVisual(p) end
    for _, uid in ipairs(Spring.GetAllUnits()) do
        Spring.DestroyUnit(uid, true, false)   -- selfd=true: death explosions everywhere
    end
end

local function startRound()
    round = round + 1
    for teamID, p in pairs(startPos) do
        local defName = commanderDef[teamID]
        if defName then
            local y = Spring.GetGroundHeight(p.x, p.z)
            local uid = Spring.CreateUnit(defName, p.x, y, p.z, 0, teamID)
            if uid then
                Spring.SpawnCEG("commanderspawn", p.x, y, p.z)
            else
                -- blocked (wreck field); nudge and retry once next second
                pendingSpawn = Spring.GetGameFrame() + 30
                return
            end
        end
        Spring.SetTeamResource(teamID, "m", START_METAL)
        Spring.SetTeamResource(teamID, "e", START_ENERGY)
    end
    roundActive = true
    GG.MarketWar.roundActive = true
    pendingSpawn = nil
    Spring.SetGameRulesParam("mkt_round", round)
    Spring.SetGameRulesParam("mkt_intermission", 0)
    Spring.Echo(string.format("MKTWAR-ROUND round %d begins (score %d-%d)", round, wins[0], wins[1]))
end

function gadget:GameFrame(f)
    if pendingWipe and f >= pendingWipe then
        pendingWipe = nil
        wipeField()
    end
    if pendingSpawn and f >= pendingSpawn then
        startRound()
    end
end
