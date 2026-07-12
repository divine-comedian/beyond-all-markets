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
    Spring.Echo(string.format("MKTWAR f=%d bulls_units=%d bears_units=%d", f, units0, units1))
end
