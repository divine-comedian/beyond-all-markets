function widget:GetInfo()
    return {
        name    = "Market War HUD",
        desc    = "Center price, base labels, income pulses, live trade feed",
        author  = "bar-market-war",
        date    = "2026",
        license = "MIT",
        layer   = 100,
        enabled = true,
    }
end

local DEBUG = false
local BUILD = "MW v5"

-- Team identity (match the start script)
local BTC = { 0.97, 0.58, 0.10 }      -- team 0, fed by taker buys
local USD = { 0.30, 0.69, 0.31 }      -- team 1, fed by taker sells
local UP  = { 0.20, 0.90, 0.30 }      -- price up flash
local DOWN = { 0.95, 0.20, 0.20 }     -- price down flash
local WHITE = { 0.95, 0.95, 0.95 }
local TEAMNAME = { [0] = "BTC", [1] = "USD" }
local TEAMCOL  = { [0] = BTC, [1] = USD }

local VOL_CAP    = 5                  -- BTC/s for a full-scale pulse
local PULSE_LIFE = 2.2
local FLASH_LIFE = 3.0
local WHALE_ROWS = 5
local WHALE_MIN  = 0.10               -- BTC; prints this size get listed

local lastPrice, prevPrice = 0, 0
local pctChange, priceDelta = 0, 0
local tickDir, tickAt = 0, -10       -- +1/-1, os.clock of last price change
local lastSampledFrame = -1

local basePos    = {}                -- teamID -> {x,y,z} (fixed start positions)
local pulses     = {}                -- {team, metal, energy, vol, born}
local whales     = {}                -- newest-first {isBuy, qty, price, venue}
local tape       = {}                -- rolling per-second {buy, sell} for flow bars
local priceHist  = {}                -- rolling per-second price for 1m %
local interFlash = 0                 -- os.clock when the intermission banner appeared
local prevInter  = 0
local prevDropF  = 0                 -- last seen mkt_drop_frame
local dropAt     = -10               -- os.clock of last reinforcement drop

local function getP(name)
    return Spring.GetGameRulesParam(name) or 0
end

local function logScale(v)
    return math.min(1, math.log(1 + v) / math.log(1 + VOL_CAP))
end

local nTrades = 0
local function OnTrade(isBuy, qty, price, venue)
    nTrades = nTrades + 1
    if DEBUG and nTrades % 20 == 1 then Spring.Echo("MKTWAR-HUD trd#" .. nTrades) end
    if qty >= WHALE_MIN then
        table.insert(whales, 1, { isBuy = isBuy == 1, qty = qty, price = price, venue = venue or "?" })
        if #whales > WHALE_ROWS then table.remove(whales) end
    end
end

local mapCenter

function widget:Initialize()
    mapCenter = { x = Game.mapSizeX / 2, z = Game.mapSizeZ / 2 }
    -- widget-facing handler proxy injects the owner: 2-arg form (name, value)
    local ok = widgetHandler:RegisterGlobal("MarketWarTrade", OnTrade)
    Spring.Echo("MKTWAR-HUD BUILD " .. BUILD .. " RegisterGlobal MarketWarTrade => " .. tostring(ok))
    -- force team colors on this client; BAR's auto-color otherwise repaints
    Spring.SetTeamColor(0, BTC[1], BTC[2], BTC[3])
    Spring.SetTeamColor(1, USD[1], USD[2], USD[3])
end

function widget:Shutdown()
    widgetHandler:DeregisterGlobal("MarketWarTrade")
end

local function refreshBases()
    for team = 0, 1 do
        if not basePos[team] then
            local x, y, z = Spring.GetTeamStartPosition(team)
            if x and x > 0 then basePos[team] = { x = x, y = y, z = z } end
        end
    end
end

function widget:GameFrame(f)
    if f % 30 ~= 0 or f == lastSampledFrame then return end
    lastSampledFrame = f
    prevPrice = lastPrice
    lastPrice = getP("mkt_price")
    if prevPrice > 0 and lastPrice ~= prevPrice then
        pctChange = (lastPrice - prevPrice) / prevPrice * 100
        priceDelta = lastPrice - prevPrice
        tickDir = lastPrice > prevPrice and 1 or -1
        tickAt = os.clock()
    else
        pctChange, priceDelta = 0, 0
    end

    refreshBases()
    -- re-assert colors periodically in case BAR's color logic repaints
    if f % 300 == 0 then
        Spring.SetTeamColor(0, BTC[1], BTC[2], BTC[3])
        Spring.SetTeamColor(1, USD[1], USD[2], USD[3])
    end

    tape[#tape + 1] = { buy = getP("mkt_buy"), sell = getP("mkt_sell") }
    if #tape > 10 then table.remove(tape, 1) end
    priceHist[#priceHist + 1] = lastPrice
    if #priceHist > 60 then table.remove(priceHist, 1) end

    local now = os.clock()
    pulses[#pulses + 1] = { team = 0, metal = getP("mkt_m0"), energy = getP("mkt_e0"),
                            vol = getP("mkt_buy"), born = now }
    pulses[#pulses + 1] = { team = 1, metal = getP("mkt_m1"), energy = getP("mkt_e1"),
                            vol = getP("mkt_sell"), born = now }

    local inter = getP("mkt_intermission")
    if inter > 0 and prevInter == 0 then interFlash = now end
    prevInter = inter

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
    if sz and sz < 1 then return sx, sy end
    return nil
end

function widget:DrawScreen()
    local vsx, vsy = Spring.GetViewGeometry()
    local s = vsy / 1080
    local now = os.clock()

    ---------------------------------------------------------------- price at map center
    -- world-anchored: sits over the middle of the battlefield, not the screen
    local gy = Spring.GetGroundHeight(mapCenter.x, mapCenter.z) or 0
    local px, py, pz = Spring.WorldToScreenCoords(mapCenter.x, gy + 500, mapCenter.z)
    if pz and pz < 1 then
        local flash = math.max(0, 1 - (now - tickAt) / 0.8)
        local base = WHITE
        local target = tickDir > 0 and UP or DOWN
        local pc = {
            base[1] + (target[1] - base[1]) * flash,
            base[2] + (target[2] - base[2]) * flash,
            base[3] + (target[3] - base[3]) * flash,
        }
        gl.Color(pc[1], pc[2], pc[3], 0.55 + 0.45 * flash)
        gl.Text(string.format("$%.1f", lastPrice), px, py + 40 * s, 72 * s, "co")
        gl.Color(pc[1], pc[2], pc[3], 0.55 + 0.45 * flash)
        gl.Text(string.format("%s$%.1f  (%+.3f%%)", priceDelta >= 0 and "+" or "-",
            math.abs(priceDelta), pctChange), px, py + 8 * s, 24 * s, "co")
        -- per-side income summary under the price
        local surge0, surge1 = getP("mkt_surge0"), getP("mkt_surge1")
        gl.Color(BTC[1], BTC[2], BTC[3], 0.9)
        gl.Text(string.format("BTC +%dm +%de%s", getP("mkt_m0"), getP("mkt_e0"),
            surge0 > 1 and " SURGE" or ""), px - 10 * s, py - 22 * s, 16 * s, "ro")
        gl.Color(USD[1], USD[2], USD[3], 0.9)
        gl.Text(string.format("USD +%dm +%de%s", getP("mkt_m1"), getP("mkt_e1"),
            surge1 > 1 and " SURGE" or ""), px + 10 * s, py - 22 * s, 16 * s, "o")
    end

    ---------------------------------------------------------------- base labels + pulses
    for team = 0, 1 do
        local bp = basePos[team]
        if bp then
            local sx, sy = screenPos(bp, 120)
            if sx then
                local c = TEAMCOL[team]
                gl.Color(c[1], c[2], c[3], 1)
                gl.Text(TEAMNAME[team], sx, sy, 40 * s, "co")
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
                local size = (36 + 30 * logScale(p.vol)) * s
                -- 1s %% is ~0.00; a rolling 1-minute %% is legible.
                -- Team-relative sign: Bears (team 1) profit when price falls,
                -- so their pulse shows the inverse of the market move.
                local pct60 = 0
                if #priceHist > 1 and priceHist[1] > 0 then
                    pct60 = (lastPrice - priceHist[1]) / priceHist[1] * 100
                end
                if p.team == 1 then pct60 = -pct60 end
                gl.Text(string.format("%+.3f%%  +%d metal  +%d energy", pct60, p.metal, p.energy),
                    sx, sy + 70 * s * age, size, "co")
            end
        end
    end

    ---------------------------------------------------------------- order flow (right, 3/4 up)
    local tw = 280 * s
    local tx = vsx - tw - 14 * s
    local ty = vsy * 0.75
    local buy10, sell10 = 0, 0
    for _, t in ipairs(tape) do buy10 = buy10 + t.buy; sell10 = sell10 + t.sell end
    local total = buy10 + sell10
    local panelH = (70 + WHALE_ROWS * 22 + 30) * s
    gl.Color(0, 0, 0, 0.5)
    gl.Rect(tx - 10 * s, ty - panelH, tx + tw, ty + 26 * s)
    gl.Color(1, 1, 1, 0.95)
    gl.Text("ORDER FLOW  last 10s", tx, ty + 8 * s, 15 * s, "o")

    local barW, barH = tw - 20 * s, 16 * s
    local function flowBar(y, vol, c, label)
        local frac = total > 0 and vol / total or 0
        gl.Color(c[1], c[2], c[3], 0.25)
        gl.Rect(tx, y, tx + barW, y + barH)
        gl.Color(c[1], c[2], c[3], 0.95)
        gl.Rect(tx, y, tx + barW * frac, y + barH)
        gl.Color(1, 1, 1, 1)
        gl.Text(string.format("%s %.3f BTC", label, vol), tx + 4 * s, y + 3 * s, 13 * s, "o")
    end
    flowBar(ty - 24 * s, buy10, BTC, "BUY ")
    flowBar(ty - 46 * s, sell10, USD, "SELL")

    gl.Color(1, 1, 1, 0.8)
    gl.Text("WHALE PRINTS  (>= " .. WHALE_MIN .. " BTC)", tx, ty - 70 * s, 13 * s, "o")
    for i, t in ipairs(whales) do
        local c = t.isBuy and BTC or USD
        gl.Color(c[1], c[2], c[3], 1 - (i - 1) * 0.12)
        gl.Text(string.format("%s %.3f @ %.0f  %s", t.isBuy and "BUY " or "SELL", t.qty, t.price, t.venue),
            tx, ty - (70 + i * 22) * s, 16 * s, "o")
    end

    -- build tag (version check: stale packs won't show this)
    gl.Color(1, 1, 1, 0.5)
    gl.Text(BUILD, vsx - 8 * s, 8 * s, 12 * s, "ro")

    ---------------------------------------------------------------- scoreboard (session wins)
    local w0, w1 = getP("mkt_wins0"), getP("mkt_wins1")
    local roundNo = getP("mkt_round")
    gl.Color(BTC[1], BTC[2], BTC[3], 0.95)
    gl.Text(string.format("BTC %d", w0), vsx / 2 - 60 * s, vsy - 40 * s, 30 * s, "ro")
    gl.Color(1, 1, 1, 0.9)
    gl.Text("—", vsx / 2, vsy - 40 * s, 30 * s, "co")
    gl.Color(USD[1], USD[2], USD[3], 0.95)
    gl.Text(string.format("%d USD", w1), vsx / 2 + 60 * s, vsy - 40 * s, 30 * s, "o")
    gl.Color(1, 1, 1, 0.6)
    gl.Text("ROUND " .. math.max(1, roundNo), vsx / 2, vsy - 64 * s, 15 * s, "co")

    ---------------------------------------------------------------- round intermission banner
    local frame = Spring.GetGameFrame()
    local inter = getP("mkt_intermission")
    if inter > frame then
        local winner = getP("mkt_roundwinner")
        local c = TEAMCOL[winner] or WHITE
        gl.Color(c[1], c[2], c[3], 0.5 + 0.5 * math.abs(math.sin(now * 6)))
        gl.Text("ROUND TO " .. (TEAMNAME[winner] or "?"), vsx / 2, vsy * 0.70, 46 * s, "co")
        gl.Color(1, 1, 1, 0.9)
        gl.Text("next round in " .. math.ceil((inter - frame) / 30) .. "s",
            vsx / 2, vsy * 0.70 - 40 * s, 20 * s, "co")
    end

    ---------------------------------------------------------------- reinforcement drop banner
    if now - dropAt < 4 then
        local dTeam = getP("mkt_drop_team")
        local c = TEAMCOL[dTeam] or WHITE
        local label = getP("mkt_drop_kind") == 2 and "WHALE DEPLOY" or "MARKET FLIP"
        gl.Color(c[1], c[2], c[3], 0.6 + 0.4 * math.abs(math.sin(now * 4)))
        gl.Text(string.format("%s — %s +%d", label, TEAMNAME[dTeam] or "?", getP("mkt_drop_n")),
            vsx / 2, vsy * 0.62, 30 * s, "co")
    end
end
