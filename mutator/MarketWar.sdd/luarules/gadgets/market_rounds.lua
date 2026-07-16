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
    { key = "sol",  asset = 0, usd = 1 },
    { key = "spx",  asset = 2, usd = 3 },
    { key = "gold", asset = 4, usd = 5 },
    { key = "bam",  asset = 6, usd = 7 },
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
-- factories are banned). If a team has NO factory for 30s mid-round, the
-- game plants the lane-appropriate one and the AI adopts it.
local INSURANCE_FRAMES = 30 * 30   -- MKTWAR: was 45s — commanders still idled too long after losing production
local SEA_DROP = {   -- deep water per sea team (mirror market_conveyor.lua)
    [2] = { x = 6394, z = 1639 },
    [3] = { x = 1818, z = 4667 },
    [4] = { x = 10695, z = 9952 },  -- SE coastline
    [5] = { x = 6800, z = 11000 },
}
local INSURE_DEF = {  -- teamID -> factory unitdef name (BAM<->SOL swapped)
    [0] = "armap",  [1] = "corap",      -- SOL: air (back lane)
    [2] = "armsy",  [3] = "corsy",      -- SP500: naval
    [4] = "armsy",  [5] = "corsy",      -- GOLD: naval
    [6] = "armlab", [7] = "corlab",     -- BAM: ground (mid frontline)
}
local noFactorySince = {}   -- teamID -> frame
local insurePos             -- forward declaration (defined below)

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

function endRound(pr, winner)
    pr.active = false
    GG.MarketWar.roundActive[pr.key] = false
    pr.wins[winner] = pr.wins[winner] + 1
    local f = Spring.GetGameFrame()
    pr.pendingWipe  = f + CATACLYSM_DELAY
    pr.pendingSpawn = f + INTERMISSION_FRAMES
    Spring.SetGameRulesParam("mkt_wins" .. winner, pr.wins[winner])
    Spring.SetGameRulesParam("mkt_roundwinner_" .. pr.key, winner)
    Spring.SetGameRulesParam("mkt_intermission_" .. pr.key, pr.pendingSpawn)
    Spring.Log("MKTWAR", "info", string.format("ROUND %s: round %d to team %d (%d-%d)",
        pr.key, pr.round, winner, pr.wins[pr.asset], pr.wins[pr.usd]))
end

-- Mercy rule: sea lanes (and any unreachable-commander case) can deadlock —
-- a fled inland commander cannot be killed by a navy, so the round would
-- never resolve. One side at <=2 units vs >=25 for 3 continuous minutes is
-- a decided round: score it, nuke it, reset it. Referee logic only — no AI
-- unit is ever touched.
local MERCY_FRAMES = 180 * 30
local mercySince = {}   -- pair key -> frame the lopsided state started

local function checkMercy(f)
    for _, pr in ipairs(PAIRS) do
        if pr.active then
            local ca = Spring.GetTeamUnitCount(pr.asset) or 0
            local cu = Spring.GetTeamUnitCount(pr.usd) or 0
            local winner
            if ca <= 2 and cu >= 25 then winner = pr.usd end
            if cu <= 2 and ca >= 25 then winner = pr.asset end
            if winner then
                mercySince[pr.key] = mercySince[pr.key] or f
                if f - mercySince[pr.key] >= MERCY_FRAMES then
                    mercySince[pr.key] = nil
                    Spring.Log("MKTWAR", "info", "MERCY " .. pr.key .. " decided for team " .. winner)
                    endRound(pr, winner)
                end
            else
                mercySince[pr.key] = nil
            end
        else
            mercySince[pr.key] = nil
        end
    end
end

function gadget:UnitDestroyed(unitID, unitDefID, unitTeam)
    local pr = teamPair[unitTeam]
    if not pr or not pr.active then return end
    -- start the insurance clock the moment the LAST factory dies, not at the
    -- next poll — the poll-start version left commanders idle for 30-50s
    if isFactory[unitDefID] and INSURE_DEF[unitTeam] and not noFactorySince[unitTeam] then
        local stillHas = false
        for _, uid in ipairs(Spring.GetTeamUnits(unitTeam)) do
            if uid ~= unitID and isFactory[Spring.GetUnitDefID(uid)] then
                stillHas = true; break
            end
        end
        if not stillHas then
            noFactorySince[unitTeam] = Spring.GetGameFrame()
        end
    end
    local defName = isCommander[unitDefID]
    if not defName then return end
    for _, uid in ipairs(Spring.GetTeamUnits(unitTeam)) do
        if uid ~= unitID and isCommander[Spring.GetUnitDefID(uid)] then
            return   -- team still has a commander; not a round end
        end
    end
    -- lane semantics: the pair OPPONENT scores, whoever landed the kill
    local killer = (unitTeam == pr.asset) and pr.usd or pr.asset
    endRound(pr, killer)
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
                -- FIRST priority: unit production. Order the fresh commander
                -- to build the lane factory before the AI does anything else.
                local fdef = UnitDefNames[INSURE_DEF[teamID] or ""]
                if fdef then
                    local fx, fz = insurePos(teamID)
                    if fx then
                        Spring.GiveOrderToUnit(uid, -fdef.id,
                            { fx, Spring.GetGroundHeight(fx, fz), fz, 0 }, 0)
                    end
                end
                -- signal the host: this team was just reset (proactive aireload)
                Spring.SetGameRulesParam("mkt_reset" .. teamID, Spring.GetGameFrame())
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

function insurePos(teamID)   -- assigns the forward-declared local
    -- anchor at the commander's CURRENT position — rebuilt production should
    -- appear where the fight moved, not at the long-abandoned start area
    local anchor = startPos[teamID]
    for _, uid in ipairs(Spring.GetTeamUnits(teamID)) do
        if isCommander[Spring.GetUnitDefID(uid)] then
            local cx, _, cz = Spring.GetUnitPosition(uid)
            if cx then anchor = { x = cx, z = cz } end
            break
        end
    end
    if not anchor then return end
    local drop = SEA_DROP[teamID]
    if not drop then
        -- land/air: one lab footprint away so the plant never sits on the commander
        return math.max(64, math.min(Game.mapSizeX - 64, anchor.x + 128)),
               math.max(64, math.min(Game.mapSizeZ - 64, anchor.z + 128))
    end
    -- naval: first OPEN deep water walking from the commander toward the drop.
    -- "open" = the spot AND a ring around it are deep, so the shipyard never lands
    -- against one of the SE sea islands (the respawn-on-island bug: probe found
    -- isolated land at ~(9000,8000) and (9500,9500) in team-4's water).
    local RING = 320
    local function openWater(x, z)
        if Spring.GetGroundHeight(x, z) >= -12 then return false end
        if Spring.GetGroundHeight(x + RING, z) >= -14 then return false end
        if Spring.GetGroundHeight(x - RING, z) >= -14 then return false end
        if Spring.GetGroundHeight(x, z + RING) >= -14 then return false end
        if Spring.GetGroundHeight(x, z - RING) >= -14 then return false end
        return true
    end
    for t = 0, 1, 0.02 do
        local x = anchor.x + (drop.x - anchor.x) * t
        local z = anchor.z + (drop.z - anchor.z) * t
        if openWater(x, z) then
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
                -- persistent enforcement: while factory-less, re-order the
                -- commander to build the lane factory every check (survives
                -- AI re-tasking, reloads, and wander-off eco shenanigans)
                for _, uid in ipairs(Spring.GetTeamUnits(teamID)) do
                    if isCommander[Spring.GetUnitDefID(uid)] then
                        local fdef = UnitDefNames[defName]
                        local fx, fz = insurePos(teamID)
                        if fdef and fx then
                            -- anti-thrash: skip if this build is already the
                            -- commander's current order (re-issuing restarts
                            -- pathing -> stop-start stutter)
                            local cur = Spring.GetUnitCommands(uid, 1)
                            if not (cur and cur[1] and cur[1].id == -fdef.id) then
                                Spring.GiveOrderToUnit(uid, -fdef.id,
                                    { fx, Spring.GetGroundHeight(fx, fz), fz, 0 }, 0)
                            end
                        end
                        break
                    end
                end
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
    if f % 150 == 0 then checkInsurance(f) end   -- 5s: keep the 30s promise honest
    if f % 300 == 0 then checkMercy(f) end
end
