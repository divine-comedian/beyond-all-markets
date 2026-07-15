-- Market War override of BAR's ai_namer.lua (same VFS path shadows the base
-- gadget). BAR's UI reads GameRulesParam 'ainame_<teamID>' for AI display
-- names; the base gadget fills it with random community names. Set our
-- asset names instead.
function gadget:GetInfo()
    return {
        name    = "AI namer",
        desc    = "Market War: AI teams display as lane asset names",
        author  = "bar-market-war",
        date    = "2026",
        license = "GNU GPL, v2 or later",
        layer   = 999,
        enabled = true,
    }
end

if not gadgetHandler:IsSyncedCode() then return end

local ASSET = {
    [0] = "SOL",  [1] = "USD-SOL",
    [2] = "SP500", [3] = "USD-SP500",
    [4] = "GOLD", [5] = "USD-GOLD",
    [6] = "BAM",  [7] = "USD-BAM",
}

function gadget:Initialize()
    for _, teamID in ipairs(Spring.GetTeamList()) do
        local isAI = select(4, Spring.GetTeamInfo(teamID, false))
        if isAI and ASSET[teamID] then
            Spring.SetGameRulesParam('ainame_' .. teamID, ASSET[teamID])
        end
    end
    gadgetHandler:RemoveGadget(self)
end
