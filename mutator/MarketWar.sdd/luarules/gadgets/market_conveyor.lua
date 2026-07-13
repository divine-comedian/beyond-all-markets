function gadget:GetInfo()
    return {
        name    = "Market Conveyor",
        desc    = "Streams parked combat units at the enemy — no turtling",
        author  = "bar-market-war",
        layer   = 3,
        enabled = true,
    }
end

-- CircuitAI's engagement loop approaches, re-evaluates threat as fog lifts,
-- aborts and recalls — config tuning can't remove the recall. So the game
-- streams for it: every sweep, any combat unit parked near its own base
-- beyond a small garrison gets a FIGHT order at the enemy. Drop squads
-- already cross the map this way; this applies the same push to production.

if not gadgetHandler:IsSyncedCode() then return end

local SWEEP_FRAMES = 10 * 30   -- push cadence (fast: our orders must win the tug-of-war vs AI recalls)
local BASE_RADIUS  = 1100      -- "parked near base" cylinder
local GARRISON     = 8         -- units left home per team
local PUSH_MAX     = 20        -- cap per sweep so pushes read as waves

-- Lane pairs and push targets (sea lanes aim at the enemy's naval water,
-- land/air lanes at the enemy base; mirrors market_reinforce.lua)
local SEA_DROP = {
    [2] = { x = 6394, z = 1639 },   -- SP500, NW ocean
    [3] = { x = 1818, z = 4667 },   -- USD-SP500, NW ocean
    [4] = { x = 9832, z = 7117 },   -- GOLD, SE ocean
    [5] = { x = 5813, z = 10633 },  -- USD-GOLD, SE ocean
}
local PAIRS = {
    { key = "btc",  asset = 0, usd = 1 },
    { key = "spx",  asset = 2, usd = 3 },
    { key = "gold", asset = 4, usd = 5 },
    { key = "eth",  asset = 6, usd = 7 },
}

local isCommander = {}
local isPushable  = {}   -- unitDefID -> true for mobile armed non-builder units

function gadget:Initialize()
    for udid, ud in pairs(UnitDefs) do
        if ud.customParams and ud.customParams.iscommander then
            isCommander[udid] = true
        elseif not ud.isBuilder and not ud.isFactory and ud.speed and ud.speed > 0
            and ud.weapons and #ud.weapons > 0 then
            isPushable[udid] = true
        end
    end
end

local CMD_FIGHT, CMD_GUARD, CMD_WAIT, CMD_PATROL = CMD.FIGHT, CMD.GUARD, CMD.WAIT, CMD.PATROL

local function parked(uid)
    -- parked = no orders, or loitering orders (guard/wait/patrol). Units the
    -- AI is actively moving/attacking with are left alone.
    local cmds = Spring.GetUnitCommands(uid, 1)
    if not cmds or #cmds == 0 then return true end
    local id = cmds[1].id
    return id == CMD_GUARD or id == CMD_WAIT or id == CMD_PATROL
end

local function pushTeam(teamID, enemyPoint, f)
    local base = GG.MarketWar.startPos and GG.MarketWar.startPos[teamID]
    if not (base and enemyPoint) then return end
    -- sea teams park their fleet offshore around the shipyard, well beyond
    -- the land-base footprint — sweep a wider circle for them
    local isSea = SEA_DROP[teamID] ~= nil
    local radius = isSea and 2000 or BASE_RADIUS
    local units = Spring.GetUnitsInCylinder(base.x, base.z, radius, teamID)
    local eligible = {}
    for _, uid in ipairs(units) do
        -- sea lanes: CircuitAI holds fleets in ORDERED regroup formations, so
        -- the parked() filter never catches the cluster — push everything in
        -- the base zone regardless of orders. AI recalls just get re-pushed.
        if isPushable[Spring.GetUnitDefID(uid)] and (isSea or parked(uid)) then
            eligible[#eligible + 1] = uid
        end
    end
    local excess = math.min(PUSH_MAX, #eligible - GARRISON)
    if excess < 1 then return end
    local ey = Spring.GetGroundHeight(enemyPoint.x, enemyPoint.z)
    for i = 1, excess do
        local uid = eligible[i]
        Spring.GiveOrderToUnit(uid, CMD_FIGHT, {
            enemyPoint.x + math.random(-200, 200), ey,
            enemyPoint.z + math.random(-200, 200) }, 0)
    end
    Spring.SetGameRulesParam("mkt_push_frame", f)
    Spring.SetGameRulesParam("mkt_push_team", teamID)
    Spring.SetGameRulesParam("mkt_push_n", excess)
end

function gadget:GameFrame(f)
    if f % SWEEP_FRAMES ~= 0 then return end
    local active = GG.MarketWar.roundActive or {}
    for _, pr in ipairs(PAIRS) do
        if active[pr.key] ~= false then
            local aTgt = SEA_DROP[pr.usd]   or (GG.MarketWar.startPos and GG.MarketWar.startPos[pr.usd])
            local uTgt = SEA_DROP[pr.asset] or (GG.MarketWar.startPos and GG.MarketWar.startPos[pr.asset])
            pushTeam(pr.asset, aTgt, f)
            pushTeam(pr.usd,   uTgt, f)
        end
    end
end
