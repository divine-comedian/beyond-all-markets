function gadget:GetInfo()
    return {
        name    = "Market Income",
        desc    = "Per-market taker flow feeds three asset/USD lane economies",
        author  = "bar-market-war",
        layer   = 0,
        enabled = true,
    }
end

local DEBUG = false

-- Pairs: market -> {asset team, usd team, metal/energy per volume unit, whale threshold}
-- Multipliers are notional-normalized (~0.00625 metal per USD): 1 BTC ~ $64k,
-- 1 GOLD contract = 1 oz ~ $4.1k, 1 SP500 contract ~ $7.6k.
local PAIRS = {
    BTC  = { asset = 0, usd = 1, m = 400, e = 4000 },
    SPX  = { asset = 2, usd = 3, m = 47,  e = 470 },
    GOLD = { asset = 4, usd = 5, m = 25,  e = 250 },
    ETH  = { asset = 6, usd = 7, m = 11,  e = 110 },   -- ETH ~$1.8k (live-checked), not $3.2k
}
local BASELINE_METAL  = 6
local BASELINE_ENERGY = 60

-- CircuitAI plans tiers/production off measured income rates; raw market
-- buckets (zero for minutes, then a burst) make its planner flap. Income is
-- granted through an EMA (~20s effective) so the AI sees a stable economy.
-- HUD flow bars and reinforcement triggers keep reading the RAW rates.
local SMOOTH_ALPHA = 1 / 20

-- Comeback rally (MW v11): relative strength over a rolling 5m window.
-- A side whose market moved ITS way in the last 5m (price up = asset team,
-- price down = USD team) earns an income boost that grows exponentially with
-- the size of the move — flat market = ~nothing, violent comeback = a flood.
-- Boost-only by design: the opposing side is never docked, so no economy
-- ever shrinks under the AI's feet. Applied through the same EMA as income.
local RALLY_WINDOW = 300   -- seconds of price history (5m)
local RALLY_SCALE  = 0.5   -- % move per e-fold: 0.25%≈1.3x, 0.5%≈1.9x, 1%≈4.2x
local RALLY_COEF   = 0.5   -- mult = 1 + COEF * (e^(gain/SCALE) - 1)
local RALLY_MAX    = 8     -- multiplier ceiling

local function rallyTarget(gainPct)
    if gainPct <= 0 then return 1 end
    return math.min(RALLY_MAX, 1 + RALLY_COEF * (math.exp(gainPct / RALLY_SCALE) - 1))
end

if gadgetHandler:IsSyncedCode() then
    ----------------------------------------------------------------- SYNCED
    GG.MarketWar = GG.MarketWar or {}
    GG.MarketWar.surge = GG.MarketWar.surge or {}
    GG.MarketWar.rates = {}   -- mkt -> {buy, sell} (raw, per last tick)
    GG.MarketWar.price = {}   -- mkt -> price

    local pending = {}        -- mkt -> {buy, sell, price}
    local smooth  = {}        -- mkt -> {buy, sell}
    local hist    = {}        -- mkt -> rolling 1s prices (RALLY_WINDOW deep)
    local rally   = {}        -- mkt -> {asset, usd} smoothed multipliers
    for mkt in pairs(PAIRS) do
        pending[mkt] = { buy = 0, sell = 0, price = 0 }
        smooth[mkt]  = { buy = 0, sell = 0 }
        hist[mkt]    = {}
        rally[mkt]   = { asset = 1, usd = 1 }
        GG.MarketWar.rates[mkt] = { buy = 0, sell = 0 }
        GG.MarketWar.price[mkt] = 0
    end

    function gadget:GameStart()
        -- deep storage: market bursts bank instead of overflowing the default cap
        for _, p in pairs(PAIRS) do
            for _, teamID in ipairs({ p.asset, p.usd }) do
                Spring.SetTeamResource(teamID, "ms", 100000)
                Spring.SetTeamResource(teamID, "es", 1000000)
            end
        end
    end

    function gadget:RecvLuaMsg(msg, playerID)
        -- v2 bucket lines only; legacy numeric lines fall through harmlessly
        local mkt, b, s, p = msg:match("^mkt:(%u+):([%d%.]+):([%d%.]+):([%d%.]+)$")
        if mkt then
            if playerID ~= 0 then return true end   -- only the hosting player feeds
            local pd = pending[mkt]
            if pd then
                pd.buy  = pd.buy  + tonumber(b)
                pd.sell = pd.sell + tonumber(s)
                pd.price = tonumber(p)
            end
            return true
        end
        -- v2 trades, relayed to every client's UI for the trade feed
        local tmkt, side, q, tp, venue = msg:match("^trd:(%u+):([BS]):([%d%.]+):([%d%.]+):(%u+)$")
        if tmkt then
            if playerID ~= 0 then return true end
            if PAIRS[tmkt] then
                SendToUnsynced("mkt_trd", side == "B" and 1 or 0, tonumber(q), tonumber(tp), venue, tmkt)
            end
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
        for mkt, pr in pairs(PAIRS) do
            local pd, sm = pending[mkt], smooth[mkt]
            sm.buy  = sm.buy  + (pd.buy  - sm.buy)  * SMOOTH_ALPHA
            sm.sell = sm.sell + (pd.sell - sm.sell) * SMOOTH_ALPHA
            local h = hist[mkt]
            if pd.price > 0 then
                h[#h + 1] = pd.price
                if #h > RALLY_WINDOW then table.remove(h, 1) end
            end
            local pct = 0
            if #h > 1 and h[1] > 0 then pct = (h[#h] - h[1]) / h[1] * 100 end
            local rl = rally[mkt]
            rl.asset = rl.asset + (rallyTarget(pct)  - rl.asset) * SMOOTH_ALPHA
            rl.usd   = rl.usd   + (rallyTarget(-pct) - rl.usd)   * SMOOTH_ALPHA
            local am = (BASELINE_METAL  + sm.buy  * pr.m) * surgeMult(pr.asset) * rl.asset
            local ae = (BASELINE_ENERGY + sm.buy  * pr.e) * surgeMult(pr.asset) * rl.asset
            local um = (BASELINE_METAL  + sm.sell * pr.m) * surgeMult(pr.usd) * rl.usd
            local ue = (BASELINE_ENERGY + sm.sell * pr.e) * surgeMult(pr.usd) * rl.usd
            Spring.AddTeamResource(pr.asset, "metal",  am)
            Spring.AddTeamResource(pr.asset, "energy", ae)
            Spring.AddTeamResource(pr.usd,   "metal",  um)
            Spring.AddTeamResource(pr.usd,   "energy", ue)
            local lk = mkt:lower()
            Spring.SetGameRulesParam("mkt_price_" .. lk, pd.price)
            Spring.SetGameRulesParam("mkt_buy_" .. lk,   pd.buy)
            Spring.SetGameRulesParam("mkt_sell_" .. lk,  pd.sell)
            Spring.SetGameRulesParam("mkt_m" .. pr.asset, am)
            Spring.SetGameRulesParam("mkt_e" .. pr.asset, ae)
            Spring.SetGameRulesParam("mkt_m" .. pr.usd, um)
            Spring.SetGameRulesParam("mkt_e" .. pr.usd, ue)
            Spring.SetGameRulesParam("mkt_rally" .. pr.asset, rl.asset)
            Spring.SetGameRulesParam("mkt_rally" .. pr.usd, rl.usd)
            GG.MarketWar.rates[mkt].buy  = pd.buy
            GG.MarketWar.rates[mkt].sell = pd.sell
            GG.MarketWar.price[mkt] = pd.price
            pd.buy, pd.sell = 0, 0
        end
    end
else
    --------------------------------------------------------------- UNSYNCED
    -- Hand relayed trades to the HUD widget (registered global MarketWarTrade).
    local function RecvTrade(_, isBuy, qty, tradePrice, venue, mkt)
        if Script.LuaUI("MarketWarTrade") then
            Script.LuaUI.MarketWarTrade(isBuy, qty, tradePrice, venue, mkt)
        end
    end

    function gadget:Initialize()
        gadgetHandler:AddSyncAction("mkt_trd", RecvTrade)
    end

    function gadget:Shutdown()
        gadgetHandler:RemoveSyncAction("mkt_trd")
    end
end
