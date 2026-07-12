function gadget:GetInfo()
    return {
        name    = "Market Income",
        desc    = "BTC taker buy/sell volume feeds Bulls/Bears income",
        author  = "bar-market-war",
        layer   = 0,
        enabled = true,
    }
end

local DEBUG = false

-- Tuning (mirror config/war.env; live flow is ~0.001-0.05 BTC/s quiet, ~1+ spike)
local BULLS_TEAM, BEARS_TEAM = 0, 1
local METAL_PER_BTC   = 400
local ENERGY_PER_BTC  = 4000
local BASELINE_METAL  = 6
local BASELINE_ENERGY = 60
local FEED_HOST, FEED_PORT = "127.0.0.1", 8642

-- CircuitAI plans tiers/production off measured income rates; raw market
-- buckets (zero for minutes, then a burst) make its planner flap. Income is
-- granted through an EMA (~20s effective) so the AI sees a stable economy.
-- HUD flow bars and reinforcement triggers keep reading the RAW rates.
local SMOOTH_ALPHA = 1 / 20

if gadgetHandler:IsSyncedCode() then
    ----------------------------------------------------------------- SYNCED
    local pendingBuy, pendingSell, price = 0, 0, 0
    local smoothBuy, smoothSell = 0, 0
    GG.MarketWar = GG.MarketWar or {}
    GG.MarketWar.buyRate, GG.MarketWar.sellRate, GG.MarketWar.price = 0, 0, 0
    GG.MarketWar.surge = GG.MarketWar.surge or {}

    function gadget:GameStart()
        -- deep storage: market bursts bank instead of overflowing the
        -- default 1100 cap (verified overflow in end-to-end test)
        for _, teamID in ipairs({ BULLS_TEAM, BEARS_TEAM }) do
            Spring.SetTeamResource(teamID, "ms", 100000)
            Spring.SetTeamResource(teamID, "es", 1000000)
        end
    end

    function gadget:RecvLuaMsg(msg, playerID)
        local b, s, p = msg:match("^mkt:([%d%.]+):([%d%.]+):([%d%.]+)$")
        if b then
            if playerID ~= 0 then return true end   -- only the hosting player feeds
            pendingBuy  = pendingBuy  + tonumber(b)
            pendingSell = pendingSell + tonumber(s)
            price = tonumber(p)
            return true
        end
        -- individual trades, relayed to every client's UI for the trade feed
        local side, q, tp, venue = msg:match("^trd:([BS]):([%d%.]+):([%d%.]+):(%u+)$")
        if side then
            if playerID ~= 0 then return true end
            nTrades = (nTrades or 0) + 1
            if DEBUG and nTrades % 20 == 1 then Spring.Echo("MKTWAR-SYNC trd#" .. nTrades) end
            SendToUnsynced("mkt_trd", side == "B" and 1 or 0, tonumber(q), tonumber(tp), venue)
            return true
        end
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
        smoothBuy  = smoothBuy  + (pendingBuy  - smoothBuy)  * SMOOTH_ALPHA
        smoothSell = smoothSell + (pendingSell - smoothSell) * SMOOTH_ALPHA
        local m0 = (BASELINE_METAL  + smoothBuy  * METAL_PER_BTC)  * bm
        local e0 = (BASELINE_ENERGY + smoothBuy  * ENERGY_PER_BTC) * bm
        local m1 = (BASELINE_METAL  + smoothSell * METAL_PER_BTC)  * sm
        local e1 = (BASELINE_ENERGY + smoothSell * ENERGY_PER_BTC) * sm
        Spring.AddTeamResource(BULLS_TEAM, "metal",  m0)
        Spring.AddTeamResource(BULLS_TEAM, "energy", e0)
        Spring.AddTeamResource(BEARS_TEAM, "metal",  m1)
        Spring.AddTeamResource(BEARS_TEAM, "energy", e1)
        -- publish for spectator HUD widgets (synced -> unsynced on every client)
        Spring.SetGameRulesParam("mkt_price", price)
        Spring.SetGameRulesParam("mkt_buy",   pendingBuy)
        Spring.SetGameRulesParam("mkt_sell",  pendingSell)
        Spring.SetGameRulesParam("mkt_m0", m0)
        Spring.SetGameRulesParam("mkt_e0", e0)
        Spring.SetGameRulesParam("mkt_m1", m1)
        Spring.SetGameRulesParam("mkt_e1", e1)
        Spring.SetGameRulesParam("mkt_surge0", bm)
        Spring.SetGameRulesParam("mkt_surge1", sm)
        GG.MarketWar.buyRate, GG.MarketWar.sellRate, GG.MarketWar.price = pendingBuy, pendingSell, price
        pendingBuy, pendingSell = 0, 0
    end
else
    --------------------------------------------------------------- UNSYNCED
    -- Hand relayed trades to the HUD widget (registered global MarketWarTrade).
    -- The feed->game bridge itself lives in luaui/widgets/market_feed.lua:
    -- LuaSocket is only exposed to LuaUI, not to unsynced gadgets.
    local nTrades = 0
    local function RecvTrade(_, isBuy, qty, tradePrice, venue)
        nTrades = nTrades + 1
        if DEBUG and nTrades % 20 == 1 then
            Spring.Echo("MKTWAR-UNSYNC trd#" .. nTrades .. " luaui=" .. tostring(Script.LuaUI("MarketWarTrade")))
        end
        if Script.LuaUI("MarketWarTrade") then
            Script.LuaUI.MarketWarTrade(isBuy, qty, tradePrice, venue)
        end
    end

    function gadget:Initialize()
        gadgetHandler:AddSyncAction("mkt_trd", RecvTrade)
    end

    function gadget:Shutdown()
        gadgetHandler:RemoveSyncAction("mkt_trd")
    end
end
