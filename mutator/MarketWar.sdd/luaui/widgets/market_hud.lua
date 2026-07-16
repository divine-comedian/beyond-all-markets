function widget:GetInfo()
    return {
        name    = "Market War HUD",
        desc    = "Three lane tickers, per-pair scoreboards, multi-market flow + trades",
        author  = "bar-market-war",
        date    = "2026",
        license = "MIT",
        layer   = 100,
        enabled = true,
    }
end

local BUILD = "MW v12"

-- Teams (match gen-startscript.sh)
local TEAMNAME = {
    [0] = "BTC",  [1] = "USD-BTC",
    [2] = "SP500", [3] = "USD-SP500",
    [4] = "GOLD", [5] = "USD-GOLD",
    [6] = "ETH",  [7] = "USD-ETH",
}
local TEAMCOL = {
    [0] = { 0.97, 0.58, 0.10 }, [1] = { 0.30, 0.69, 0.31 },
    [2] = { 0.25, 0.55, 0.95 }, [3] = { 0.15, 0.85, 0.60 },
    [4] = { 0.95, 0.80, 0.15 }, [5] = { 0.60, 0.85, 0.25 },
    [6] = { 0.62, 0.40, 0.95 }, [7] = { 0.20, 0.60, 0.35 },
}
local UP    = { 0.20, 0.90, 0.30 }
local DOWN  = { 0.95, 0.20, 0.20 }
local WHITE = { 0.95, 0.95, 0.95 }

-- Lanes: ticker anchored at the midpoint between the pair's bases, nudged
-- toward the lane's corner (ox/oz are fractions of map size) so the three
-- tickers spread apart instead of crowding the center
-- Tickers sit at FIXED, on-lane positions (tx,tz in elmos), one per quadrant so they
-- spread out and never get shoved off-map by base-relative offset math. ETH is the air
-- lane spanning NE<->SW, so it shows a ticker in each of those two quadrants (tx2,tz2).
local LANES = {
    { key = "spx",  mkt = "SPX",  asset = 2, usd = 3, label = "SP500", tx = 4275, tz = 3300 },
    { key = "btc",  mkt = "BTC",  asset = 0, usd = 1, label = "BTC",   tx = 6100, tz = 6150 },
    { key = "gold", mkt = "GOLD", asset = 4, usd = 5, label = "GOLD",  tx = 8670, tz = 8500 },
    { key = "eth",  mkt = "ETH",  asset = 6, usd = 7, label = "ETH",   tx = 9200, tz = 2800, tx2 = 2800, tz2 = 9200 },
}

local VOL_CAP    = 5                  -- full-scale pulse (BTC-equivalent notional units)
local PULSE_LIFE = 2.2
local WHALE_ROWS = 6
local WHALE_MIN  = { BTC = 0.10, SPX = 0.8, GOLD = 1.6, ETH = 2.0 }   -- ~$6.4k notional each

local basePos   = {}                  -- teamID -> {x,y,z}
local pulses    = {}                  -- {team, metal, energy, vol, born}
local whales    = {}                  -- newest-first {isBuy, qty, price, venue, mkt}
local tape      = {}                  -- mkt -> rolling per-second {buy, sell}
local lastSampledFrame = -1
local interFlash = {}                 -- lane key -> os.clock intermission started
local prevInter  = {}
local prevDropF  = 0
local dropAt     = -10

local function getP(name)
    return Spring.GetGameRulesParam(name) or 0
end

local function logScale(v)
    return math.min(1, math.log(1 + v) / math.log(1 + VOL_CAP))
end

local function OnTrade(isBuy, qty, price, venue, mkt)
    mkt = mkt or "BTC"
    if qty >= (WHALE_MIN[mkt] or 0.1) then
        table.insert(whales, 1, { isBuy = isBuy == 1, qty = qty, price = price,
                                  venue = venue or "?", mkt = mkt })
        if #whales > WHALE_ROWS then table.remove(whales) end
    end
end

function widget:Initialize()
    for _, l in ipairs(LANES) do
        l.hist = {}          -- rolling per-second price for 1m %
        l.lastPrice = 0
        l.tickDir, l.tickAt = 0, -10
        tape[l.mkt] = {}
        interFlash[l.key], prevInter[l.key] = 0, 0
    end
    local ok = widgetHandler:RegisterGlobal("MarketWarTrade", OnTrade)
    Spring.Echo("MKTWAR-HUD BUILD " .. BUILD .. " RegisterGlobal MarketWarTrade => " .. tostring(ok))
    for t, c in pairs(TEAMCOL) do
        Spring.SetTeamColor(t, c[1], c[2], c[3])
    end
end

function widget:Shutdown()
    widgetHandler:DeregisterGlobal("MarketWarTrade")
end

local function refreshBases()
    for team = 0, 7 do
        if not basePos[team] then
            local x, y, z = Spring.GetTeamStartPosition(team)
            if x and x > 0 then basePos[team] = { x = x, y = y, z = z } end
        end
    end
end

function widget:GameFrame(f)
    if f % 30 ~= 0 or f == lastSampledFrame then return end
    lastSampledFrame = f
    refreshBases()
    if f % 300 == 0 then
        for t, c in pairs(TEAMCOL) do Spring.SetTeamColor(t, c[1], c[2], c[3]) end
    end

    local now = os.clock()
    for _, l in ipairs(LANES) do
        local price = getP("mkt_price_" .. l.key)
        if l.lastPrice > 0 and price ~= l.lastPrice and price > 0 then
            l.tickDir = price > l.lastPrice and 1 or -1
            l.tickAt = now
        end
        if price > 0 then l.lastPrice = price end
        l.hist[#l.hist + 1] = price
        if #l.hist > 60 then table.remove(l.hist, 1) end

        local buy, sell = getP("mkt_buy_" .. l.key), getP("mkt_sell_" .. l.key)
        local t = tape[l.mkt]
        t[#t + 1] = { buy = buy, sell = sell }
        -- 15 minutes of 1s samples: BAR battles resolve on minutes, not
        -- seconds — the flow bars should show who is winning the MARKET on
        -- a timescale the battlefield can express
        if #t > 900 then table.remove(t, 1) end

        pulses[#pulses + 1] = { team = l.asset, metal = getP("mkt_m" .. l.asset),
                                energy = getP("mkt_e" .. l.asset), vol = buy, born = now, lane = l }
        pulses[#pulses + 1] = { team = l.usd, metal = getP("mkt_m" .. l.usd),
                                energy = getP("mkt_e" .. l.usd), vol = sell, born = now, lane = l }

        local inter = getP("mkt_intermission_" .. l.key)
        if inter > 0 and prevInter[l.key] == 0 then interFlash[l.key] = now end
        prevInter[l.key] = inter
    end

    local dropF = getP("mkt_drop_frame")
    if dropF > 0 and dropF ~= prevDropF then dropAt = now end
    prevDropF = dropF
end

function widget:DrawWorld()
    local now = os.clock()
    for i = #pulses, 1, -1 do
        local p = pulses[i]
        local age = now - p.born
        if age > PULSE_LIFE then
            table.remove(pulses, i)
        else
            local bp = basePos[p.team]
            if bp then
                local c = TEAMCOL[p.team]
                local grow = age / PULSE_LIFE
                local radius = (60 + 320 * logScale(p.vol)) * (0.3 + 0.7 * grow)
                gl.Color(c[1], c[2], c[3], 0.7 * (1 - grow))
                gl.LineWidth(4.0)
                gl.DrawGroundCircle(bp.x, bp.y, bp.z, radius, 40)
                gl.LineWidth(1.0)
            end
        end
    end
end

local function screenPos(bp, dy)
    local sx, sy, sz = Spring.WorldToScreenCoords(bp.x, bp.y + (dy or 0), bp.z)
    -- sz<1 = in front of the camera, but WorldToScreenCoords can still hand
    -- back +-Inf/NaN for sx/sy at degenerate angles (w~0 div0); those pass the
    -- sz gate yet crash gl.Text ("number expected, got +-Inf") and get the whole
    -- HUD widget removed. Reject any non-finite coord.
    if sz and sz < 1
        and sx == sx and sy == sy
        and sx ~= math.huge and sx ~= -math.huge
        and sy ~= math.huge and sy ~= -math.huge then
        return sx, sy
    end
    return nil
end

local function lanePct60(l)
    if #l.hist > 1 and l.hist[1] > 0 and l.hist[#l.hist] > 0 then
        return (l.hist[#l.hist] - l.hist[1]) / l.hist[1] * 100
    end
    return 0
end

function widget:DrawScreen()
    local vsx, vsy = Spring.GetViewGeometry()
    local s = vsy / 1080
    local now = os.clock()
    local frame = Spring.GetGameFrame()

    ---------------------------------------------------------------- lane tickers (world-anchored)
    local function drawTicker(l, mx, mz, size)
        local gy = Spring.GetGroundHeight(mx, mz) or 0
        local px, py, pz = Spring.WorldToScreenCoords(mx, math.max(gy, 0) + 500, mz)
        if not (pz and pz < 1) then return end
        if px ~= px or py ~= py or px == math.huge or px == -math.huge
            or py == math.huge or py == -math.huge then return end
        local flash = math.max(0, 1 - (now - l.tickAt) / 0.8)
        local target = l.tickDir > 0 and UP or DOWN
        local pc = {
            WHITE[1] + (target[1] - WHITE[1]) * flash,
            WHITE[2] + (target[2] - WHITE[2]) * flash,
            WHITE[3] + (target[3] - WHITE[3]) * flash,
        }
        gl.Color(pc[1], pc[2], pc[3], 0.55 + 0.45 * flash)
        gl.Text(string.format("%s $%.1f", l.label, l.lastPrice), px, py + 26 * s, size, "co")
        gl.Text(string.format("%+.3f%% 1m", lanePct60(l)), px, py + 2 * s, 20 * s, "co")
    end

    for _, l in ipairs(LANES) do
        drawTicker(l, l.tx, l.tz, 48 * s)
        if l.tx2 then drawTicker(l, l.tx2, l.tz2, 40 * s) end
    end

    ---------------------------------------------------------------- base labels + income pulses
    for team = 0, 7 do
        local bp = basePos[team]
        if bp then
            local sx, sy = screenPos(bp, 120)
            if sx then
                local c = TEAMCOL[team]
                gl.Color(c[1], c[2], c[3], 1)
                gl.Text(TEAMNAME[team], sx, sy, 32 * s, "co")
                -- comeback rally: exponential 5m relative-strength income boost
                local rally = getP("mkt_rally" .. team)
                if rally > 1.15 then
                    gl.Color(1, 0.85, 0.2, 0.6 + 0.4 * math.abs(math.sin(now * 5)))
                    gl.Text(string.format("RALLY x%.1f", rally), sx, sy + 36 * s, 22 * s, "co")
                end
            end
        end
    end

    for _, p in ipairs(pulses) do
        local bp = basePos[p.team]
        if bp and p.metal >= 1 then
            local sx, sy = screenPos(bp, 60)
            if sx then
                local age = (now - p.born) / PULSE_LIFE
                local c = TEAMCOL[p.team]
                gl.Color(c[1], c[2], c[3], 1 - age)
                local size = (26 + 24 * logScale(p.vol)) * s
                -- team-relative 1m %: USD sides profit when their market falls
                local pct = lanePct60(p.lane)
                if p.team == p.lane.usd then pct = -pct end
                gl.Text(string.format("%+.3f%%  +%d m", pct, p.metal),
                    sx, sy + 70 * s * age, size, "co")
            end
        end
    end

    ---------------------------------------------------------------- round tracker (left panel)
    -- structured panel, plain ASCII only (multibyte glyphs render unreliably
    -- in the default font — suspected cause of the old scoreboard's fragments)
    local rtW = 250 * s
    local rtX = 14 * s
    local rtTop = vsy * 0.48   -- moved down (was 0.78) to clear the minimap
    local rowH = 24 * s
    gl.Color(0, 0, 0, 0.5)
    gl.Rect(rtX - 8 * s, rtTop - (#LANES + 1) * rowH - 8 * s, rtX + rtW, rtTop + 24 * s)
    gl.Color(1, 1, 1, 0.95)
    gl.Text("ROUND TRACKER", rtX, rtTop + 6 * s, 15 * s, "o")
    local ry = rtTop - rowH
    for _, l in ipairs(LANES) do
        local wa, wu = getP("mkt_wins" .. l.asset), getP("mkt_wins" .. l.usd)
        local ca, cu = TEAMCOL[l.asset], TEAMCOL[l.usd]
        gl.Color(ca[1], ca[2], ca[3], 1)
        gl.Text(l.label, rtX, ry, 17 * s, "o")
        gl.Color(ca[1], ca[2], ca[3], 1)
        gl.Text(tostring(wa), rtX + 96 * s, ry, 17 * s, "o")
        gl.Color(1, 1, 1, 0.75)
        gl.Text("-", rtX + 116 * s, ry, 17 * s, "o")
        gl.Color(cu[1], cu[2], cu[3], 1)
        gl.Text(wu .. " USD", rtX + 130 * s, ry, 17 * s, "o")
        local inter = getP("mkt_intermission_" .. l.key)
        gl.Color(1, 1, 1, 0.6)
        if inter > frame then
            gl.Text("reset " .. math.ceil((inter - frame) / 30) .. "s", rtX + 192 * s, ry, 13 * s, "o")
        else
            gl.Text("R" .. math.max(1, getP("mkt_round_" .. l.key)), rtX + 192 * s, ry, 13 * s, "o")
        end
        ry = ry - rowH
    end

    ---------------------------------------------------------------- round intermission banners
    local by = vsy * 0.72
    for _, l in ipairs(LANES) do
        local inter = getP("mkt_intermission_" .. l.key)
        if inter > frame then
            local winner = getP("mkt_roundwinner_" .. l.key)
            local c = TEAMCOL[winner] or WHITE
            gl.Color(c[1], c[2], c[3], 0.5 + 0.5 * math.abs(math.sin(now * 6)))
            gl.Text(l.label .. " ROUND TO " .. (TEAMNAME[winner] or "?"), vsx / 2, by, 38 * s, "co")
            gl.Color(1, 1, 1, 0.9)
            gl.Text("next round in " .. math.ceil((inter - frame) / 30) .. "s",
                vsx / 2, by - 30 * s, 17 * s, "co")
            by = by - 64 * s
        end
    end

    ---------------------------------------------------------------- reinforcement drop banner
    if now - dropAt < 4 then
        local dTeam = getP("mkt_drop_team")
        local c = TEAMCOL[dTeam] or WHITE
        local label = getP("mkt_drop_kind") == 2 and "WHALE DEPLOY" or "MARKET FLIP"
        gl.Color(c[1], c[2], c[3], 0.6 + 0.4 * math.abs(math.sin(now * 4)))
        gl.Text(string.format("%s — %s +%d", label, TEAMNAME[dTeam] or "?", getP("mkt_drop_n")),
            vsx / 2, vsy * 0.62, 28 * s, "co")
    end

    ---------------------------------------------------------------- order flow (right, 3 markets)
    local tw = 300 * s
    local tx = vsx - tw - 14 * s
    local ty = vsy * 0.80
    local rowH = 15 * s
    local panelH = (#LANES * 44 + 26 + WHALE_ROWS * 20 + 34) * s
    gl.Color(0, 0, 0, 0.5)
    gl.Rect(tx - 10 * s, ty - panelH, tx + tw, ty + 24 * s)
    gl.Color(1, 1, 1, 0.95)
    gl.Text("ORDER FLOW  last 15m", tx, ty + 8 * s, 14 * s, "o")

    local y = ty - 18 * s
    for _, l in ipairs(LANES) do
        local buy10, sell10 = 0, 0
        for _, t in ipairs(tape[l.mkt]) do buy10 = buy10 + t.buy; sell10 = sell10 + t.sell end
        local total = buy10 + sell10
        local barW = tw - 20 * s
        local function bar(yy, vol, c, tag)
            local frac = total > 0 and vol / total or 0
            gl.Color(c[1], c[2], c[3], 0.25)
            gl.Rect(tx, yy, tx + barW, yy + rowH)
            gl.Color(c[1], c[2], c[3], 0.95)
            gl.Rect(tx, yy, tx + barW * frac, yy + rowH)
            gl.Color(1, 1, 1, 1)
            gl.Text(string.format("%s %s %.2f", l.label, tag, vol), tx + 4 * s, yy + 2 * s, 11 * s, "o")
        end
        bar(y, buy10, TEAMCOL[l.asset], "BUY ")
        bar(y - (rowH + 3 * s), sell10, TEAMCOL[l.usd], "SELL")
        y = y - 44 * s
    end

    gl.Color(1, 1, 1, 0.8)
    gl.Text("WHALE PRINTS", tx, y - 4 * s, 12 * s, "o")
    for i, t in ipairs(whales) do
        local lane
        for _, l in ipairs(LANES) do if l.mkt == t.mkt then lane = l end end
        local c = lane and TEAMCOL[t.isBuy and lane.asset or lane.usd] or WHITE
        gl.Color(c[1], c[2], c[3], 1 - (i - 1) * 0.11)
        gl.Text(string.format("%s %s %.3f @ %.0f %s", t.isBuy and "BUY " or "SELL", t.mkt, t.qty, t.price, t.venue),
            tx, y - (4 + i * 20) * s, 14 * s, "o")
    end

    -- build tag (version check: stale packs won't show this)
    gl.Color(1, 1, 1, 0.5)
    gl.Text(BUILD, vsx - 8 * s, 8 * s, 12 * s, "ro")
end
