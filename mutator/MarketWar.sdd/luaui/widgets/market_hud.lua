function widget:GetInfo()
    return {
        name    = "Market War HUD",
        desc    = "Live BTC/USD price, trade tape, and per-side income overlay",
        author  = "bar-market-war",
        date    = "2026",
        license = "MIT",
        layer   = 100,
        enabled = true,
    }
end

-- Colors (match team RgbColor in the start script)
local BTC = { 0.97, 0.58, 0.10 }
local USD = { 0.30, 0.69, 0.31 }
local WHITE = { 1, 1, 1 }
local DIM   = { 0.75, 0.75, 0.75 }

local TAPE_LEN  = 90        -- seconds of history in the tape
local VOL_CAP   = 5         -- BTC/s that fills a full bar (log-scaled)

local tape = {}             -- ring of {buy, sell}
local lastPrice, prevPrice = 0, 0
local lastSampledFrame = -1

local function getP(name)
    return Spring.GetGameRulesParam(name) or 0
end

local function logScale(v)
    return math.min(1, math.log(1 + v) / math.log(1 + VOL_CAP))
end

function widget:GameFrame(f)
    if f % 30 ~= 0 or f == lastSampledFrame then return end
    lastSampledFrame = f
    prevPrice = lastPrice
    lastPrice = getP("mkt_price")
    tape[#tape + 1] = { buy = getP("mkt_buy"), sell = getP("mkt_sell") }
    if #tape > TAPE_LEN then table.remove(tape, 1) end
end

local function text(str, x, y, size, color, opts)
    gl.Color(color[1], color[2], color[3], 1)
    gl.Text(str, x, y, size, opts or "o")
end

function widget:DrawScreen()
    local vsx, vsy = Spring.GetViewGeometry()
    local s = vsy / 1080                     -- scale with resolution
    local W, H = 560 * s, 150 * s
    local x0 = (vsx - W) / 2
    local y0 = vsy - H - 8 * s

    -- panel
    gl.Color(0, 0, 0, 0.55)
    gl.Rect(x0, y0, x0 + W, y0 + H)

    -- price, colored by direction
    local price = lastPrice
    local pcol = WHITE
    if price > prevPrice then pcol = BTC
    elseif price < prevPrice then pcol = USD end
    text(string.format("BTC/USD  $%.1f", price), x0 + W / 2, y0 + H - 30 * s, 26 * s, pcol, "co")

    -- trade tape: buys up (orange), sells down (green) around a midline
    local tapeH  = 44 * s
    local midY   = y0 + 62 * s
    local colW   = (W - 24 * s) / TAPE_LEN
    gl.Color(1, 1, 1, 0.15)
    gl.Rect(x0 + 12 * s, midY - 0.5, x0 + W - 12 * s, midY + 0.5)
    for i, t in ipairs(tape) do
        local cx = x0 + 12 * s + (i - 1) * colW
        local bh = logScale(t.buy)  * tapeH
        local sh = logScale(t.sell) * tapeH
        if bh > 0.5 then
            gl.Color(BTC[1], BTC[2], BTC[3], 0.9)
            gl.Rect(cx, midY, cx + colW - 1, midY + bh)
        end
        if sh > 0.5 then
            gl.Color(USD[1], USD[2], USD[3], 0.9)
            gl.Rect(cx, midY - sh, cx + colW - 1, midY)
        end
    end

    -- per-side income readouts
    local m0, e0 = getP("mkt_m0"), getP("mkt_e0")
    local m1, e1 = getP("mkt_m1"), getP("mkt_e1")
    local buy, sell = getP("mkt_buy"), getP("mkt_sell")
    local surge0, surge1 = getP("mkt_surge0"), getP("mkt_surge1")

    local yInfo = y0 + 8 * s
    text(string.format("BTC  buy %.3f  +%dm +%de%s", buy, m0, e0,
        surge0 > 1 and ("  SURGE x" .. surge0) or ""),
        x0 + 14 * s, yInfo, 15 * s, BTC, "o")
    text(string.format("%ssell %.3f  +%dm +%de  USD", surge1 > 1 and ("x" .. surge1 .. " SURGE  ") or "",
        sell, m1, e1),
        x0 + W - 14 * s, yInfo, 15 * s, USD, "ro")
end
