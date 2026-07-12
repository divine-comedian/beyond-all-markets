function gadget:GetInfo()
    return {
        name    = "Market War Heartbeat",
        desc    = "Logs sim frame + team stats every 10s (infolog only, not console)",
        author  = "bar-market-war",
        layer   = 0,
        enabled = true,
    }
end

if not gadgetHandler:IsSyncedCode() then return end

local LANES = {
    { key = "BTC",  asset = 0, usd = 1 },
    { key = "SPX",  asset = 2, usd = 3 },
    { key = "GOLD", asset = 4, usd = 5 },
}

function gadget:Initialize()
    -- unregistered sections default to notice; open ours up so info-level
    -- telemetry reaches the infolog (the console UI only renders notice+)
    pcall(Spring.SetLogSectionFilterLevel, "MKTWAR", "info")
end

local stuckSince = {}   -- teamID -> frame the stuck pattern was first seen

function gadget:GameFrame(f)
    if f % 300 ~= 0 then return end
    local mw = GG.MarketWar or {}
    local parts = { "MKTWAR f=" .. f }
    for _, l in ipairs(LANES) do
        local rates = mw.rates and mw.rates[l.key] or {}
        local price = mw.price and mw.price[l.key] or 0
        parts[#parts + 1] = string.format("%s a=%d/u=%d am=%.0f um=%.0f b=%.4f s=%.4f px=%.1f",
            l.key,
            #Spring.GetTeamUnits(l.asset), #Spring.GetTeamUnits(l.usd),
            Spring.GetTeamResources(l.asset, "metal") or 0,
            Spring.GetTeamResources(l.usd, "metal") or 0,
            rates.buy or 0, rates.sell or 0, price)
        -- stuck detection: a solitary idle commander for 60s+ means the
        -- CircuitAI instance silently failed to start (observed init race
        -- with 6 instances). Publish a flag; the host widget /aireload-s it.
        for _, teamID in ipairs({ l.asset, l.usd }) do
            local units = Spring.GetTeamUnits(teamID)
            local stuck = false
            if #units == 1 and units[1] then
                local cmds = Spring.GetUnitCommandCount and Spring.GetUnitCommandCount(units[1]) or 0
                if cmds == 0 then stuck = true end
            end
            if stuck then
                stuckSince[teamID] = stuckSince[teamID] or f
                local x, _, z = Spring.GetUnitPosition(units[1])
                parts[#parts + 1] = string.format("STUCK t%d unit@(%.0f,%.0f) for=%ds",
                    teamID, x or -1, z or -1, (f - stuckSince[teamID]) / 30)
            else
                stuckSince[teamID] = nil
            end
            Spring.SetGameRulesParam("mkt_stuck" .. teamID,
                (stuck and f - stuckSince[teamID] >= 60 * 30) and 1 or 0)
        end
    end
    -- Spring.Log at info level: recorded in infolog, hidden from the on-screen
    -- console (Spring.Echo would spam the spectator UI over the scoreboard)
    Spring.Log("MKTWAR", "info", table.concat(parts, " | "))
end
