function gadget:GetInfo()
    return {
        name    = "Market Respawn",
        desc    = "Commanders respawn; the war never ends",
        author  = "bar-market-war",
        layer   = 1,
        enabled = true,
    }
end

if not gadgetHandler:IsSyncedCode() then return end

-- Tuning (mirror config/war.env)
local RESPAWN_FRAMES = 45 * 30      -- RESPAWN_COOLDOWN_SEC * simfps
local SURGE_FRAMES   = 60 * 30      -- RESPAWN_SURGE_SEC * simfps
local SURGE_MULT     = 3            -- RESPAWN_SURGE_MULT

local startPos     = {}             -- teamID -> {x,y,z}
local respawnQueue = {}             -- {frame=..., teamID=..., defName=...}
local isCommander  = {}             -- unitDefID -> defName

function gadget:Initialize()
    GG.MarketWar = GG.MarketWar or {}
    GG.MarketWar.surge = GG.MarketWar.surge or {}
    for udid, ud in pairs(UnitDefs) do
        if ud.customParams and ud.customParams.iscommander then
            isCommander[udid] = ud.name
        end
    end
end

local function rememberStartPositions()
    for _, teamID in ipairs(Spring.GetTeamList()) do
        if not startPos[teamID] then
            -- fall back to the commander's spawn location
            for _, uid in ipairs(Spring.GetTeamUnits(teamID)) do
                if isCommander[Spring.GetUnitDefID(uid)] then
                    local x, y, z = Spring.GetUnitPosition(uid)
                    startPos[teamID] = { x = x, y = y, z = z }
                end
            end
        end
    end
end

function gadget:GameStart()
    for _, teamID in ipairs(Spring.GetTeamList()) do
        local x, y, z = Spring.GetTeamStartPosition(teamID)
        if x and x > 0 then
            startPos[teamID] = { x = x, y = y, z = z }
        end
    end
    rememberStartPositions()
end

function gadget:UnitDestroyed(unitID, unitDefID, unitTeam)
    local defName = isCommander[unitDefID]
    if not defName then return end
    -- ignore if this team still has another commander alive
    for _, uid in ipairs(Spring.GetTeamUnits(unitTeam)) do
        if uid ~= unitID and isCommander[Spring.GetUnitDefID(uid)] then
            return
        end
    end
    local f = Spring.GetGameFrame()
    respawnQueue[#respawnQueue + 1] = { frame = f + RESPAWN_FRAMES, teamID = unitTeam, defName = defName }
    GG.MarketWar.surge[unitTeam] = { untilFrame = f + RESPAWN_FRAMES + SURGE_FRAMES, mult = SURGE_MULT }
    Spring.SetGameRulesParam("mkt_liq" .. unitTeam, f + RESPAWN_FRAMES)   -- HUD: liquidation banner + countdown
    Spring.Echo(string.format("MKTWAR: commander down (team %d) — respawn in %ds with %dx surge",
        unitTeam, RESPAWN_FRAMES / 30, SURGE_MULT))
end

function gadget:GameFrame(f)
    for i = #respawnQueue, 1, -1 do
        local r = respawnQueue[i]
        if f >= r.frame then
            local p = startPos[r.teamID]
            if not p then
                table.remove(respawnQueue, i)
            else
                local y = Spring.GetGroundHeight(p.x, p.z)
                local uid = Spring.CreateUnit(r.defName, p.x, y, p.z, 0, r.teamID)
                if uid then
                    Spring.SpawnCEG("commanderspawn", p.x, y, p.z)
                    Spring.SetGameRulesParam("mkt_liq" .. r.teamID, 0)
                    Spring.Echo(string.format("MKTWAR: commander respawned (team %d) at %.0f,%.0f", r.teamID, p.x, p.z))
                    table.remove(respawnQueue, i)
                else
                    -- spawn blocked (e.g. wreckage on the spot); retry shortly
                    r.frame = f + 90
                    Spring.Echo(string.format("MKTWAR: respawn blocked (team %d), retrying", r.teamID))
                end
            end
        end
    end
end
