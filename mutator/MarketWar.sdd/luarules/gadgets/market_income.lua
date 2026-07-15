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

-- TRUE comeback (MW v12): boost the side being pushed back RIGHT NOW.
-- The old rally was keyed to price momentum, so a market selloff just
-- amplified whichever side the market favored — overnight data (2026-07-15,
-- ~31 rounds) showed USD/Bears winning ~68% of rounds every lane. Replaced:
-- the boost is now keyed to the live ARMY-STRENGTH deficit per lane. Whoever
-- is weaker on the field out-produces to claw back. Boost-only by design —
-- the leading side is never docked, so no economy shrinks under the AI. Fed
-- through the same EMA as income so it ramps smoothly. (mirror config/war.env)
local COMEBACK_COEF   = 1.0    -- mult = 1 + COEF * (e^(deficit/SCALE) - 1)
local COMEBACK_SCALE  = 0.5    -- army deficit per e-fold (deficit .5 -> ~2.7x, capped)
local COMEBACK_MAX    = 4      -- income multiplier ceiling
local COMEBACK_MIN_ARMY = 1500 -- army-value floor before the boost engages (dormant at spawn)

-- deficit in 0..1 = (strong-weak)/(strong+weak); boost applies to the weaker side only.
local function comebackTarget(deficit)
    if deficit <= 0 then return 1 end
    return math.min(COMEBACK_MAX, 1 + COMEBACK_COEF * (math.exp(deficit / COMEBACK_SCALE) - 1))
end

if gadgetHandler:IsSyncedCode() then
    ----------------------------------------------------------------- SYNCED
    GG.MarketWar = GG.MarketWar or {}
    GG.MarketWar.surge = GG.MarketWar.surge or {}
    GG.MarketWar.rates = {}   -- mkt -> {buy, sell} (raw, per last tick)
    GG.MarketWar.price = {}   -- mkt -> price
    GG.MarketWar.army  = {}   -- teamID -> live army metal value (mobile combat only)

    -- army-value = sum of metalCost over a team's MOBILE COMBAT units (speed>0,
    -- not a builder) — tracks fighting strength, not economy. Cache per def.
    local armyCost = {}       -- unitDefID -> metalCost (0 = not counted)
    for udid, ud in pairs(UnitDefs) do
        armyCost[udid] = (ud.speed and ud.speed > 0 and not ud.isBuilder)
            and (ud.metalCost or 0) or 0
    end

    local pending = {}        -- mkt -> {buy, sell, price}
    local smooth  = {}        -- mkt -> {buy, sell}
    local rally   = {}        -- mkt -> {asset, usd} smoothed comeback multipliers
    for mkt in pairs(PAIRS) do
        pending[mkt] = { buy = 0, sell = 0, price = 0 }
        smooth[mkt]  = { buy = 0, sell = 0 }
        rally[mkt]   = { asset = 1, usd = 1 }
        GG.MarketWar.rates[mkt] = { buy = 0, sell = 0 }
        GG.MarketWar.price[mkt] = 0
    end

    local function armyValue(teamID)
        local sum = 0
        for _, uid in ipairs(Spring.GetTeamUnits(teamID) or {}) do
            sum = sum + armyCost[Spring.GetUnitDefID(uid)]
        end
        return sum
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
            -- TRUE comeback: boost the side that is weaker on the field now.
            local aArmy = armyValue(pr.asset)
            local uArmy = armyValue(pr.usd)
            GG.MarketWar.army[pr.asset] = aArmy
            GG.MarketWar.army[pr.usd]   = uArmy
            local aTarget, uTarget = 1, 1
            local strong = (aArmy > uArmy) and aArmy or uArmy
            if strong >= COMEBACK_MIN_ARMY then
                local weak = (aArmy < uArmy) and aArmy or uArmy
                local deficit = (strong - weak) / (strong + weak)   -- strong+weak > 0 here
                local boost = comebackTarget(deficit)
                if aArmy < uArmy then aTarget = boost
                elseif uArmy < aArmy then uTarget = boost end
            end
            local rl = rally[mkt]
            rl.asset = rl.asset + (aTarget - rl.asset) * SMOOTH_ALPHA
            rl.usd   = rl.usd   + (uTarget - rl.usd)   * SMOOTH_ALPHA
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
            Spring.SetGameRulesParam("mkt_army" .. pr.asset, aArmy)
            Spring.SetGameRulesParam("mkt_army" .. pr.usd, uArmy)
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
