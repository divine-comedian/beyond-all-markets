function gadget:GetInfo()
    return {
        name    = "Market War Stuck Detector",
        desc    = "Flags silently-failed AI instances for the host watchdog",
        author  = "bar-market-war",
        layer   = 0,
        enabled = true,
    }
end

-- NO logging in this gadget: synced code runs on every client, and any
-- Echo/Log here lands on spectators' consoles over the HUD. Heartbeat
-- telemetry lives in market_feed.lua (host player only, headless).

if not gadgetHandler:IsSyncedCode() then return end

local TEAMS = { 0, 1, 2, 3, 4, 5, 6, 7 }
local stuckSince = {}   -- teamID -> frame the stuck pattern was first seen
local isCommander, isFactory = {}, {}
local lastBank = {}     -- teamID -> {m, frame} for pegged-bank detection

function gadget:Initialize()
    for udid, ud in pairs(UnitDefs) do
        if ud.customParams and ud.customParams.iscommander then isCommander[udid] = true end
        if ud.isFactory then isFactory[udid] = true end
    end
end

function gadget:GameFrame(f)
    if f % 300 ~= 0 then return end
    for _, teamID in ipairs(TEAMS) do
        -- catatonia = the team's commander is order-less AND it owns no
        -- factory, sustained 60s. Unit COUNT is irrelevant: drops/conveyor
        -- keep handing limp teams units, which masked the old ==1 check
        -- after round resets. A healthy AI always tasks its commander or
        -- has production standing.
        local stuck = false
        local hasFactory, commIdle = false, false
        for _, uid in ipairs(Spring.GetTeamUnits(teamID)) do
            local defID = Spring.GetUnitDefID(uid)
            if isFactory[defID] then hasFactory = true; break end
            if isCommander[defID] then
                local cmds = Spring.GetUnitCommandCount and Spring.GetUnitCommandCount(uid) or 0
                commIdle = (cmds == 0)
            end
        end
        stuck = commIdle and not hasFactory
        -- busy-limp: the AI runs errands but spends NOTHING — bank frozen to
        -- the metal (insurance factories get ignored by broken instances;
        -- seen live: banks pegged at exactly 4059 for minutes). A healthy
        -- team's bank always moves.
        local m = Spring.GetTeamResources(teamID, "metal") or 0
        local lb = lastBank[teamID]
        if lb and m > 2000 and math.abs(m - lb.m) < 1 then
            stuck = true
        end
        lastBank[teamID] = { m = m, frame = f }
        if stuck then
            stuckSince[teamID] = stuckSince[teamID] or f
        else
            stuckSince[teamID] = nil
        end
        Spring.SetGameRulesParam("mkt_stuck" .. teamID,
            (stuck and f - stuckSince[teamID] >= 60 * 30) and 1 or 0)
    end
end
