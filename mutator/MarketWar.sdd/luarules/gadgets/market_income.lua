function gadget:GetInfo()
    return {
        name    = "Market Income",
        desc    = "BTC taker buy/sell volume feeds Bulls/Bears income",
        author  = "bar-market-war",
        layer   = 0,
        enabled = true,
    }
end

-- Tuning (mirror config/war.env; live flow is ~0.001-0.05 BTC/s quiet, ~1+ spike)
local BULLS_TEAM, BEARS_TEAM = 0, 1
local METAL_PER_BTC   = 400
local ENERGY_PER_BTC  = 4000
local BASELINE_METAL  = 4
local BASELINE_ENERGY = 40
local FEED_HOST, FEED_PORT = "127.0.0.1", 8642

if gadgetHandler:IsSyncedCode() then
    ----------------------------------------------------------------- SYNCED
    local pendingBuy, pendingSell, price = 0, 0, 0
    GG.MarketWar = GG.MarketWar or {}
    GG.MarketWar.buyRate, GG.MarketWar.sellRate, GG.MarketWar.price = 0, 0, 0
    GG.MarketWar.surge = GG.MarketWar.surge or {}

    function gadget:RecvLuaMsg(msg, playerID)
        local b, s, p = msg:match("^mkt:([%d%.]+):([%d%.]+):([%d%.]+)$")
        if not b then return end
        if playerID ~= 0 then return true end   -- only the hosting player feeds
        pendingBuy  = pendingBuy  + tonumber(b)
        pendingSell = pendingSell + tonumber(s)
        price = tonumber(p)
        return true
    end

    local function surgeMult(teamID)
        local s = GG.MarketWar.surge[teamID]
        if s and Spring.GetGameFrame() < s.untilFrame then return s.mult end
        return 1
    end

    function gadget:GameFrame(f)
        if f % 30 ~= 0 then return end          -- once per second (30 sim fps)
        local bm = surgeMult(BULLS_TEAM)
        local sm = surgeMult(BEARS_TEAM)
        Spring.AddTeamResource(BULLS_TEAM, "metal",  (BASELINE_METAL  + pendingBuy  * METAL_PER_BTC)  * bm)
        Spring.AddTeamResource(BULLS_TEAM, "energy", (BASELINE_ENERGY + pendingBuy  * ENERGY_PER_BTC) * bm)
        Spring.AddTeamResource(BEARS_TEAM, "metal",  (BASELINE_METAL  + pendingSell * METAL_PER_BTC)  * sm)
        Spring.AddTeamResource(BEARS_TEAM, "energy", (BASELINE_ENERGY + pendingSell * ENERGY_PER_BTC) * sm)
        GG.MarketWar.buyRate, GG.MarketWar.sellRate, GG.MarketWar.price = pendingBuy, pendingSell, price
        pendingBuy, pendingSell = 0, 0
    end
end
-- (The feed->game bridge lives in luaui/widgets/market_feed.lua: LuaSocket is
-- only exposed to LuaUI, not to unsynced gadgets.)
