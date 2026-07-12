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
local TRADE_ROWS = 14

local lastPrice, prevPrice = 0, 0
local pctChange, priceDelta = 0, 0
local tickDir, tickAt = 0, -10       -- +1/-1, os.clock of last price change
local lastSampledFrame = -1

local basePos    = {}                -- teamID -> {x,y,z} (fixed start positions)
local pulses     = {}                -- {team, metal, energy, vol, born}
local trades     = {}                -- newest-first {isBuy, qty, price}
local prevLiq    = { [0] = 0, [1] = 0 }
local liqFlash   = { [0] = 0, [1] = 0 }

local function getP(name)
    return Spring.GetGameRulesParam(name) or 0
end

local function logScale(v)
    return math.min(1, math.log(1 + v) / math.log(1 + VOL_CAP))
end

local nTrades = 0
local function OnTrade(isBuy, qty, price)
    nTrades = nTrades + 1
    if DEBUG and nTrades % 20 == 1 then Spring.Echo("MKTWAR-HUD trd#" .. nTrades) end
    table.insert(trades, 1, { isBuy = isBuy == 1, qty = qty, price = price })
    if #trades > TRADE_ROWS then table.remove(trades) end
end

local mapCenter

function widget:Initialize()
    mapCenter = { x = Game.mapSizeX / 2, z = Game.mapSizeZ / 2 }
    -- widget-facing handler proxy injects the owner: 2-arg form (name, value)
    local ok = widgetHandler:RegisterGlobal("MarketWarTrade", OnTrade)
    Spring.Echo("MKTWAR-HUD RegisterGlobal MarketWarTrade => " .. tostring(ok))
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

    local now = os.clock()
    pulses[#pulses + 1] = { team = 0, metal = getP("mkt_m0"), energy = getP("mkt_e0"),
                            vol = getP("mkt_buy"), born = now }
    pulses[#pulses + 1] = { team = 1, metal = getP("mkt_m1"), energy = getP("mkt_e1"),
                            vol = getP("mkt_sell"), born = now }

    for team = 0, 1 do
        local liq = getP("mkt_liq" .. team)
        if liq > 0 and prevLiq[team] == 0 then liqFlash[team] = now end
        prevLiq[team] = liq
    end
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
                -- 1s % moves are ~0.00x% and rendered as 0.00; the dollar
                -- delta is always legible, so lead with that
                local move = string.format("%s$%.1f", priceDelta >= 0 and "+" or "-", math.abs(priceDelta))
                gl.Text(string.format("%s  +%d metal  +%d energy", move, p.metal, p.energy),
                    sx, sy + 70 * s * age, size, "co")
            end
        end
    end

    ---------------------------------------------------------------- trade feed (right, 3/4 up)
    local tw, rh = 250 * s, 19 * s
    local tx = vsx - tw - 12 * s
    local ty = vsy * 0.75
    gl.Color(0, 0, 0, 0.45)
    gl.Rect(tx - 8 * s, ty - TRADE_ROWS * rh - 8 * s, tx + tw, ty + 26 * s)
    gl.Color(1, 1, 1, 0.9)
    gl.Text("LIVE TRADES  BTC/USDT", tx, ty + 8 * s, 14 * s, "o")
    for i, t in ipairs(trades) do
        local c = t.isBuy and BTC or USD
        local alpha = 1 - (i - 1) / TRADE_ROWS * 0.7
        gl.Color(c[1], c[2], c[3], alpha)
        gl.Text(string.format("%s  %8.4f  @ %.1f", t.isBuy and "BUY " or "SELL", t.qty, t.price),
            tx, ty - i * rh, 15 * s, "o")
    end

    ---------------------------------------------------------------- liquidation banner
    local frame = Spring.GetGameFrame()
    local by = vsy * 0.70
    for team = 0, 1 do
        local liq = getP("mkt_liq" .. team)
        if liq > frame then
            local c = TEAMCOL[team]
            if now - liqFlash[team] < FLASH_LIFE then
                gl.Color(c[1], c[2], c[3], 0.5 + 0.5 * math.abs(math.sin(now * 6)))
                gl.Text(TEAMNAME[team] .. " COMMANDER LIQUIDATED", vsx / 2, by, 42 * s, "co")
            end
            local secs = math.ceil((liq - frame) / 30)
            gl.Color(c[1], c[2], c[3], 0.9)
            gl.Text(TEAMNAME[team] .. " reinforcements in " .. secs .. "s", vsx / 2, by - 34 * s, 20 * s, "co")
            by = by - 70 * s
        end
    end
end
