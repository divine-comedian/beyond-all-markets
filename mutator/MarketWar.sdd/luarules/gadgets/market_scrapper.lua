function gadget:GetInfo()
    return {
        name    = "Market Naval Scrapper",
        desc    = "Drops a naval reclaimer per sea team each minute to clear ocean wrecks; ocean scrap yields 90% less metal so it never becomes the primary econ",
        author  = "bar-market-war",
        layer   = 3,
        enabled = true,
    }
end

if not gadgetHandler:IsSyncedCode() then return end

-- Ship wrecks pile up on the ocean floor in the SP500/GOLD sea lanes because the
-- AI never sends anything to reclaim water features. Two-part fix:
--   1. Once a minute, drop one construction ship per sea team at that team's deep-
--      water point and set it area-reclaiming the surrounding ocean (capped so the
--      scrappers don't pile up). Con ships are excluded from army value
--      (market_income.lua counts !isBuilder), so this does NOT feed the comeback.
--   2. Scale OCEAN wreck metal to SCRAP_YIELD at feature creation. This deliberately
--      keeps scrapping a housekeeping bonus, not the main metal source (income stays
--      market-driven). Scoped by GROUND depth so the land lane (SOL) is untouched.

-- Tuning (mirror config/war.env)
local DROP_PERIOD_SEC = 60     -- one scrapper per sea team per minute
local MAX_ALIVE       = 6      -- live scrappers kept per team (avoid a pileup)
local RECLAIM_RADIUS  = 900    -- area-reclaim radius around the sea drop point
local SCRAP_YIELD     = 0.10   -- ocean wrecks give 10% metal (reclaim reduced 90%)
local SEA_DEPTH       = -15    -- ground height below this = "ocean" (deep water)

-- Deep-water points per sea team (mirror market_reinforce / market_conveyor)
local SEA_DROP = {
    [2] = { x = 6394, z = 1639 },   -- SP500, NW ocean
    [3] = { x = 1818, z = 4667 },   -- USD-SP500, NW ocean
    [4] = { x = 10695, z = 9952 },  -- GOLD, SE ocean
    [5] = { x = 6800, z = 11000 },  -- USD-GOLD, SE ocean
}
local SEA_TEAMS   = { 2, 3, 4, 5 }
local ASSET_TEAMS = { [0] = true, [2] = true, [4] = true, [6] = true }
-- assets = Armada, USD = Cortex; construction ships float and reclaim water wrecks
local SCRAP_UNIT  = { arm = "armcs", cor = "corcs" }

-- Which round key covers each sea team (skip drops while that lane is between rounds)
local LANE_OF = { [2] = "spx", [3] = "spx", [4] = "gold", [5] = "gold" }

local alive = {}   -- teamID -> { [unitID] = true }

local function unitName(teamID)
    return ASSET_TEAMS[teamID] and SCRAP_UNIT.arm or SCRAP_UNIT.cor
end

local function orderReclaim(uid, teamID)
    local sp = SEA_DROP[teamID]
    if not sp then return end
    local y = Spring.GetGroundHeight(sp.x, sp.z)
    -- area reclaim ({x,y,z,radius}) makes it hunt every wreck in its ocean
    Spring.GiveOrderToUnit(uid, CMD.RECLAIM, { sp.x, y, sp.z, RECLAIM_RADIUS }, 0)
end

local function spawnScrapper(teamID, f)
    local sp = SEA_DROP[teamID]
    if not sp then return false end
    local x = sp.x + math.random(-200, 200)
    local z = sp.z + math.random(-200, 200)
    local y = Spring.GetGroundHeight(x, z)
    local uid = Spring.CreateUnit(unitName(teamID), x, y, z, 0, teamID)
    if uid then
        alive[teamID][uid] = true
        orderReclaim(uid, teamID)
        return true
    end
    return false
end

function gadget:Initialize()
    for _, teamID in ipairs(SEA_TEAMS) do alive[teamID] = {} end
end

function gadget:UnitDestroyed(uid, udid, teamID)
    if alive[teamID] then alive[teamID][uid] = nil end
end

function gadget:GameFrame(f)
    if f == 0 or f % (DROP_PERIOD_SEC * 30) ~= 0 then return end
    local active = (GG.MarketWar and GG.MarketWar.roundActive) or {}
    local spawned = 0
    for _, teamID in ipairs(SEA_TEAMS) do
        if active[LANE_OF[teamID]] ~= false then
            -- re-task the survivors and count them (dropping stale IDs)
            local n = 0
            for uid in pairs(alive[teamID]) do
                if Spring.ValidUnitID(uid) and not Spring.GetUnitIsDead(uid) then
                    n = n + 1
                    orderReclaim(uid, teamID)
                else
                    alive[teamID][uid] = nil
                end
            end
            if n < MAX_ALIVE and spawnScrapper(teamID, f) then
                spawned = spawned + 1
            end
        end
    end
    -- One telemetry line per tick (once/min): spawn total + per-team live
    -- scrapper counts. MUST be Spring.Log (infolog only), NOT Spring.Echo —
    -- in the Option-B cloud host the host engine IS the streamed one, so Echo
    -- paints the public broadcast. Log keeps it off-screen; infolog/web tooling
    -- still picks it up.
    local function nalive(t)
        local n = 0
        for _ in pairs(alive[t]) do n = n + 1 end
        return n
    end
    Spring.Log("MKTWAR", "info", string.format("MKTWAR-SCRAP f=%d spawned=%d alive=%d/%d/%d/%d",
        f, spawned, nalive(2), nalive(3), nalive(4), nalive(5)))
end

-- Ocean scrap pays out 90% less so reclaim stays a bonus, not the econ. Scoped to
-- deep water (ground depth) so land-lane wrecks and map metal spots are untouched.
function gadget:FeatureCreated(featureID)
    local x, _, z = Spring.GetFeaturePosition(featureID)
    if not x then return end
    if Spring.GetGroundHeight(x, z) > SEA_DEPTH then return end
    local m, e = Spring.GetFeatureResources(featureID)
    if m and m > 0 then
        Spring.SetFeatureResources(featureID, m * SCRAP_YIELD, e)
    end
end
