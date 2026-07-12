-- Market War override of BAR's ai_namer.lua (same VFS path shadows the base
-- game's gadget): BAR randomly renames AI teams from community name pools,
-- which clobbers the BTC/USD names set in the start script. Keep the names.
function gadget:GetInfo()
    return {
        name    = "AI namer",
        desc    = "Market War: AIs keep their start-script names (BTC/USD)",
        author  = "bar-market-war",
        date    = "2026",
        license = "GNU GPL, v2 or later",
        layer   = 999,
        enabled = true,
    }
end
-- intentionally no renaming
