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

local SWEEP_FRAMES = 5 * 30    -- push cadence: recalled units are re-pushed within 5s — forward progress must dominate the AI tug-of-war
local BASE_RADIUS  = 1100      -- "parked near base" cylinder
local GARRISON     = 8         -- units left home per team
local PUSH_MAX     = 30        -- cap per sweep so pushes read as waves

-- Lane pairs and push targets (sea lanes aim at the enemy's naval water,
-- land/air lanes at the enemy base; mirrors market_reinforce.lua)
local SEA_DROP = {
    [2] = { x = 6394, z = 1639 },   -- SP500, NW ocean
    [3] = { x = 1818, z = 4667 },   -- USD-SP500, NW ocean
    [4] = { x = 10695, z = 9952 },  -- GOLD, SE ocean (base on the E coastline)
    [5] = { x = 6800, z = 11000 },  -- USD-GOLD, SE ocean (base at south edge)
}
local PAIRS = {
    { key = "btc",  asset = 0, usd = 1 },
    { key = "spx",  asset = 2, usd = 3 },
    { key = "gold", asset = 4, usd = 5 },
    { key = "eth",  asset = 6, usd = 7 },
}

local isCommander = {}
local isPushable  = {}   -- unitDefID -> true for mobile armed non-builder units
local isBomber    = {}   -- unitDefID -> true for aircraft with bomb/torpedo drops
local isAirScout  = {}   -- unitDefID -> true for unarmed fast aircraft (peep/fink)

function gadget:Initialize()
    for udid, ud in pairs(UnitDefs) do
        if ud.customParams and ud.customParams.iscommander then
            isCommander[udid] = true
        elseif not ud.isBuilder and not ud.isFactory and ud.speed and ud.speed > 0
            and ud.weapons and #ud.weapons > 0 then
            isPushable[udid] = true
        end
        if ud.canFly and ud.speed and ud.speed > 0 and not ud.isBuilder then
            if ud.weapons and #ud.weapons > 0 then
                for _, w in ipairs(ud.weapons) do
                    local wd = WeaponDefs[w.weaponDef]
                    if wd and (wd.type == "AircraftBomb" or wd.type == "TorpedoLauncher") then
                        isBomber[udid] = true
                    end
                end
            elseif not ud.isTransport then
                isAirScout[udid] = true
            end
        end
    end
end

local CMD_FIGHT, CMD_GUARD, CMD_WAIT, CMD_PATROL, CMD_ATTACK = CMD.FIGHT, CMD.GUARD, CMD.WAIT, CMD.PATROL, CMD.ATTACK
local CMD_MOVE, CMD_STOP = CMD.MOVE, CMD.STOP

-- Anti-recall (naval): pushing harder does not win the tug-of-war — the AI
-- issues a fresh recall the instant our FIGHT lands, so fleets sail out, turn
-- around, sail back, forever (seen live on both flank lanes; reads as
-- turtling). The referee vetoes the recall instead: once a sea unit has been
-- committed to the front, the AI may still ATTACK and micro with it, but any
-- order that moves it BACK toward its own base is refused. Commitment lapses
-- after 4 min so a genuinely reorganizing fleet is never frozen forever.
local SEA_TEAMS   = { [2] = true, [3] = true, [4] = true, [5] = true }
local COMMIT_TTL  = 240 * 30
local committed   = {}   -- unitID -> {frame, homeX, homeZ}

function gadget:AllowCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, _, _, _, _, fromLua)
    if fromLua then return true end            -- our own referee orders
    if not SEA_TEAMS[unitTeam] then return true end
    local c = committed[unitID]
    if not c then return true end
    if Spring.GetGameFrame() - c.frame > COMMIT_TTL then
        committed[unitID] = nil
        return true
    end
    if cmdID == CMD_ATTACK then return true end   -- fighting is always allowed
    if cmdID == CMD_STOP or cmdID == CMD_WAIT or cmdID == CMD_GUARD then
        return false                              -- park orders = turtling
    end
    if cmdID == CMD_MOVE or cmdID == CMD_FIGHT or cmdID == CMD_PATROL then
        local tx, tz = cmdParams[1], cmdParams[3]
        if not (tx and tz) then return true end
        local x, _, z = Spring.GetUnitPosition(unitID)
        if not x then return true end
        local dNow = (x - c.homeX) ^ 2 + (z - c.homeZ) ^ 2
        local dTgt = (tx - c.homeX) ^ 2 + (tz - c.homeZ) ^ 2
        if dTgt < dNow * 0.81 then return false end   -- >10% closer to home = a recall
    end
    return true
end

function gadget:UnitDestroyed(unitID)
    committed[unitID] = nil
end

-- Commander shepherd: broken/reloaded AI instances leave commanders standing
-- idle for long stretches (worst on air/sea lanes). An idle commander is
-- ordered to GUARD its nearest factory — permanent nanolathe assist that
-- speeds production and burns banked metal.
local function shepherd(teamID)
    for _, uid in ipairs(Spring.GetTeamUnits(teamID)) do
        if isCommander[Spring.GetUnitDefID(uid)] then
            local cmds = Spring.GetUnitCommands(uid, 1)
            if not cmds or #cmds == 0 then
                local cx, _, cz = Spring.GetUnitPosition(uid)
                local best, bestD
                for _, fid in ipairs(Spring.GetTeamUnits(teamID)) do
                    local ud = UnitDefs[Spring.GetUnitDefID(fid)]
                    if ud and ud.isFactory then
                        local fx, _, fz = Spring.GetUnitPosition(fid)
                        local d = (fx - cx) ^ 2 + (fz - cz) ^ 2
                        if not bestD or d < bestD then best, bestD = fid, d end
                    end
                end
                if best then
                    Spring.GiveOrderToUnit(uid, CMD_GUARD, { best }, 0)
                end
            end
            break
        end
    end
end

local function parked(uid)
    -- parked = no orders, or loitering orders (guard/wait/patrol). Units the
    -- AI is actively moving/attacking with are left alone.
    local cmds = Spring.GetUnitCommands(uid, 1)
    if not cmds or #cmds == 0 then return true end
    local id = cmds[1].id
    return id == CMD_GUARD or id == CMD_WAIT or id == CMD_PATROL
end

-- v3 "lane ownership": the base-zone-only sweep lost a tug-of-war — our
-- push carried units OUT of the zone, the AI recalled them mid-journey
-- (outside our reach), they returned, repeat. Ground/sea combat units are
-- now monitored EVERYWHERE: idle, loitering in formation, or heading AWAY
-- from the front gets re-ordered, unless actively fighting (enemy within
-- 700) or one of the 8 garrison units nearest home. Air lanes keep the
-- parked-at-base rule (sorties already work; returning flights must not be
-- bounced).
local AIR_TEAMS = { [6] = true, [7] = true }

-- Factory foreman: production must not depend on AI sanity. Any factory
-- whose build queue sits empty across two sweeps gets a small batch of
-- lane-appropriate units queued by the game (broken instances ignore even
-- gifted factories — seen live on USD-GOLD/USD-SP500).
local SQUADS = {
    land = { arm = { "armpw", "armrock", "armham", "armstump" },
             cor = { "corak", "corstorm", "corthud", "corraid" } },
    sea  = { arm = { "armpt", "armdecade", "armpship", "armroy" },
             cor = { "corpt", "coresupp", "corpship", "corroy" } },
    -- air: bomber-heavy — the raid loop above turns every idle bomber into
    -- base pressure; fighters escort, one scout slot keeps the fog lifted
    air  = { arm = { "armfig", "armthund", "armthund", "armpeep" },
             cor = { "corveng", "corshad", "corshad", "corfink" } },
}
local ASSET_TEAMS = { [0] = true, [2] = true, [4] = true, [6] = true }
local TEAM_KIND = { [0] = "land", [1] = "land", [2] = "sea", [3] = "sea",
                    [4] = "sea", [5] = "sea", [6] = "air", [7] = "air" }
local emptySince = {}   -- factory unitID -> first frame seen with empty queue

local function foreman(teamID, f)
    local kind = TEAM_KIND[teamID]
    if not kind then return end
    local squad = SQUADS[kind][ASSET_TEAMS[teamID] and "arm" or "cor"]
    for _, uid in ipairs(Spring.GetTeamUnits(teamID)) do
        local ud = UnitDefs[Spring.GetUnitDefID(uid)]
        if ud and ud.isFactory then
            local q = Spring.GetFactoryCommands(uid, 1)
            if q and #q > 0 then
                emptySince[uid] = nil
            elseif not emptySince[uid] then
                emptySince[uid] = f
            elseif f - emptySince[uid] >= SWEEP_FRAMES then
                emptySince[uid] = nil
                for i = 1, 3 do
                    local bd = UnitDefNames[squad[math.random(#squad)]]
                    if bd and ud.buildOptions then
                        -- only queue what this factory can actually build
                        for _, bo in ipairs(ud.buildOptions) do
                            if bo == bd.id then
                                Spring.GiveOrderToUnit(uid, -bd.id, {}, 0)
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Mid-lane funnel: engine pathing routes each side's shortest path along a
-- different coast of the isthmus, and under fog (+jammers) the two streams
-- pass each other unseen. Ground units are routed VIA the choke point so
-- the armies meet head-on in the middle.
local FUNNEL = { [0] = { x = 6100, z = 6150 }, [1] = { x = 6100, z = 6150 } }

local function pushTeam(teamID, enemyTeam, enemyPoint, f)
    local base = GG.MarketWar.startPos and GG.MarketWar.startPos[teamID]
    if not (base and enemyPoint) then return end
    local ordered = 0
    local ey = Spring.GetGroundHeight(enemyPoint.x, enemyPoint.z)
    local funnel = FUNNEL[teamID]

    -- AIR RAID: fight-move only engages what's in LOS, and nothing scouts
    -- for the bombers — they arrived blind over fog, circled, went home
    -- (seen live on both ETH sides). The referee runs the air campaign:
    -- idle scouts PATROL the enemy base (lifting fog for everyone), idle
    -- bombers ground-attack the coordinates of a live enemy factory — a
    -- position strike needs no sighting, so the air base dies even unseen.
    if AIR_TEAMS[teamID] then
        -- target priority: enemy factory (kill production), else the enemy
        -- COMMANDER — bombing the airbase forever never ENDS a round, and the
        -- ETH lane went 0-for-11 rounds while both sides razed each other's
        -- factories. Only a commander kill scores, so once the enemy has no
        -- production left, the bombers go for the head.
        local fx, fz, comm
        for _, uid in ipairs(Spring.GetTeamUnits(enemyTeam)) do
            local udid = Spring.GetUnitDefID(uid)
            local ud = UnitDefs[udid]
            if ud and ud.isFactory and not fx then
                fx, _, fz = Spring.GetUnitPosition(uid)
            elseif isCommander[udid] then
                comm = uid
            end
        end
        local tgtID   -- unit-locked attack (tracks a moving commander)
        if not fx and comm then tgtID = comm end
        for _, uid in ipairs(Spring.GetTeamUnits(teamID)) do
            local udid = Spring.GetUnitDefID(uid)
            if isBomber[udid] or isAirScout[udid] then
                local cmds = Spring.GetUnitCommands(uid, 1)
                if not cmds or #cmds == 0 then
                    if isBomber[udid] then
                        if tgtID then
                            Spring.GiveOrderToUnit(uid, CMD_ATTACK, { tgtID }, 0)
                        else
                            -- position strike: needs no line of sight, so a
                            -- fogged factory still gets bombed
                            local tx = (fx or enemyPoint.x) + math.random(-100, 100)
                            local tz = (fz or enemyPoint.z) + math.random(-100, 100)
                            Spring.GiveOrderToUnit(uid, CMD_ATTACK,
                                { tx, Spring.GetGroundHeight(tx, tz), tz }, 0)
                        end
                        ordered = ordered + 1
                    else
                        local px = enemyPoint.x + math.random(-400, 400)
                        local pz = enemyPoint.z + math.random(-400, 400)
                        Spring.GiveOrderToUnit(uid, CMD_PATROL,
                            { px, Spring.GetGroundHeight(px, pz), pz }, 0)
                    end
                end
            end
        end
    end
    local function sendToFront(uid)
        if SEA_TEAMS[teamID] then
            -- commit: from here on, AI recalls toward home are vetoed
            committed[uid] = { frame = f, homeX = base.x, homeZ = base.z }
        end
        if funnel then
            local wx = funnel.x + math.random(-250, 250)
            local wz = funnel.z + math.random(-250, 250)
            Spring.GiveOrderToUnit(uid, CMD_FIGHT,
                { wx, Spring.GetGroundHeight(wx, wz), wz }, 0)
            Spring.GiveOrderToUnit(uid, CMD_FIGHT, {
                enemyPoint.x + math.random(-200, 200), ey,
                enemyPoint.z + math.random(-200, 200) }, { "shift" })
        else
            Spring.GiveOrderToUnit(uid, CMD_FIGHT, {
                enemyPoint.x + math.random(-200, 200), ey,
                enemyPoint.z + math.random(-200, 200) }, 0)
        end
        ordered = ordered + 1
    end

    if false then   -- MKTWAR: air lanes now use lane-ownership too (below) —
        -- ETH and USD-ETH must hunt EACH OTHER, not fly cover for allies;
        -- rounds in the air lane should resolve like every other lane
    else
        local pushables = {}
        for _, uid in ipairs(Spring.GetTeamUnits(teamID)) do
            -- bombers are raid-managed above: a FIGHT push here would bounce
            -- them out of attack runs and rearm trips
            if isPushable[Spring.GetUnitDefID(uid)] and not isBomber[Spring.GetUnitDefID(uid)] then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then
                    pushables[#pushables + 1] = {
                        uid = uid,
                        homeDist = math.sqrt((x - base.x) ^ 2 + (z - base.z) ^ 2),
                        x = x, z = z,
                    }
                end
            end
        end
        table.sort(pushables, function(a, b) return a.homeDist < b.homeDist end)
        for i = GARRISON + 1, #pushables do
            if ordered >= PUSH_MAX then break end
            local u = pushables[i]
            -- in combat: leave the micro alone (aircraft check wider)
            if not Spring.GetUnitNearestEnemy(u.uid, AIR_TEAMS[teamID] and 1100 or 700, true) then
                local dx, dz = enemyPoint.x - u.x, enemyPoint.z - u.z
                local dist = math.sqrt(dx * dx + dz * dz)
                local vx, _, vz = Spring.GetUnitVelocity(u.uid)
                local speed = math.sqrt((vx or 0) ^ 2 + (vz or 0) ^ 2)
                local cmds = Spring.GetUnitCommands(u.uid, 1)
                local idle = not cmds or #cmds == 0
                if dist > 900 then
                    local dot = ((vx or 0) * dx + (vz or 0) * dz) / math.max(dist, 1)
                    if idle
                        or dot < -0.3            -- clearly heading AWAY from the front
                        or (speed < 0.2 and dist > 1500) then  -- loitering formation mid-lane
                        sendToFront(u.uid)
                    end
                elseif idle or speed < 0.2 then
                    -- HUNTER: arrived at the front but passive — fight-move
                    -- never engages what it can't see, so units wander around
                    -- enemy troops and commanders. Explicit ATTACK on the
                    -- nearest enemy, or a fresh sweep hop if none in range.
                    local foe = Spring.GetUnitNearestEnemy(u.uid, 2500, true)
                    if foe then
                        Spring.GiveOrderToUnit(u.uid, CMD_ATTACK, { foe }, 0)
                        ordered = ordered + 1
                    elseif idle then
                        sendToFront(u.uid)
                    end
                end
            end
        end
    end

    if ordered > 0 then
        Spring.SetGameRulesParam("mkt_push_frame", f)
        Spring.SetGameRulesParam("mkt_push_team", teamID)
        Spring.SetGameRulesParam("mkt_push_n", ordered)
    end
end

function gadget:GameFrame(f)
    if f % SWEEP_FRAMES ~= 0 then return end
    local active = GG.MarketWar.roundActive or {}
    for _, pr in ipairs(PAIRS) do
        if active[pr.key] ~= false then
            local aTgt = SEA_DROP[pr.usd]   or (GG.MarketWar.startPos and GG.MarketWar.startPos[pr.usd])
            local uTgt = SEA_DROP[pr.asset] or (GG.MarketWar.startPos and GG.MarketWar.startPos[pr.asset])
            pushTeam(pr.asset, pr.usd,   aTgt, f)
            pushTeam(pr.usd,   pr.asset, uTgt, f)
            foreman(pr.asset, f)
            foreman(pr.usd, f)
            shepherd(pr.asset)
            shepherd(pr.usd)
        end
    end
end
