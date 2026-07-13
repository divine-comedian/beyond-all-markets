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

function gadget:GameFrame(f)
    if f % 300 ~= 0 then return end
    for _, teamID in ipairs(TEAMS) do
        -- a solitary idle commander for 60s+ means the CircuitAI instance
        -- silently failed (observed init race with 6 concurrent instances)
        local units = Spring.GetTeamUnits(teamID)
        local stuck = false
        if #units == 1 and units[1] then
            local cmds = Spring.GetUnitCommandCount and Spring.GetUnitCommandCount(units[1]) or 0
            if cmds == 0 then stuck = true end
        end
        if stuck then
            stuckSince[teamID] = stuckSince[teamID] or f
        else
            stuckSince[teamID] = nil
        end
        Spring.SetGameRulesParam("mkt_stuck" .. teamID,
            (stuck and f - stuckSince[teamID] >= 60 * 30) and 1 or 0)
    end
end
