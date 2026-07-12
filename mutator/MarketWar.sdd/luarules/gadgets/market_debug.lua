function gadget:GetInfo()
    return {
        name    = "Market War Heartbeat",
        desc    = "Logs sim frame + team stats every 10s (spike diagnostics)",
        author  = "bar-market-war",
        layer   = 0,
        enabled = true,
    }
end

if not gadgetHandler:IsSyncedCode() then return end

function gadget:GameFrame(f)
    if f % 300 ~= 0 then return end
    local units0 = #Spring.GetTeamUnits(0)
    local units1 = #Spring.GetTeamUnits(1)
    local m0 = Spring.GetTeamResources(0, "metal")
    local m1 = Spring.GetTeamResources(1, "metal")
    local mw = GG.MarketWar or {}
    Spring.Echo(string.format(
        "MKTWAR f=%d bulls_units=%d bears_units=%d bulls_metal=%.0f bears_metal=%.0f buy=%.4f sell=%.4f px=%.1f ai0=%s ai1=%s",
        f, units0, units1, m0 or 0, m1 or 0, mw.buyRate or 0, mw.sellRate or 0, mw.price or 0,
        tostring(Spring.GetGameRulesParam("ainame_0")), tostring(Spring.GetGameRulesParam("ainame_1"))))
end
