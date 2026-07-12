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

local isCommander = {}      -- unitDefID -> true
local commanders  = {}      -- teamID -> unitID
local pulses      = {}      -- {team, metal, vol, born (os.clock)}
local prevLiq     = { [0] = 0, [1] = 0 }
local liqFlash    = { [0] = 0, [1] = 0 }   -- os.clock of the death moment
local PULSE_LIFE  = 1.6
local FLASH_LIFE  = 3.0
local TEAMNAME    = { [0] = "BTC", [1] = "USD" }
local TEAMCOL     -- set below after color tables

local function getP(name)
    return Spring.GetGameRulesParam(name) or 0
end

local function logScale(v)
    return math.min(1, math.log(1 + v) / math.log(1 + VOL_CAP))
end

function widget:Initialize()
    TEAMCOL = { [0] = BTC, [1] = USD }
    for udid, ud in pairs(UnitDefs) do
        if ud.customParams and ud.customParams.iscommander then
            isCommander[udid] = true
        end
    end
end

local function refreshCommanders()
    for team = 0, 1 do
        local uid = commanders[team]
        if not (uid and Spring.ValidUnitID(uid) and not Spring.GetUnitIsDead(uid)) then
            commanders[team] = nil
            for _, u in ipairs(Spring.GetTeamUnits(team)) do
                if isCommander[Spring.GetUnitDefID(u)] then
                    commanders[team] = u
                    break
                end
            end
        end
    end
end

function widget:GameFrame(f)
    if f % 30 ~= 0 or f == lastSampledFrame then return end
    lastSampledFrame = f
    prevPrice = lastPrice
    lastPrice = getP("mkt_price")
    local buy, sell = getP("mkt_buy"), getP("mkt_sell")
    tape[#tape + 1] = { buy = buy, sell = sell }
    if #tape > TAPE_LEN then table.remove(tape, 1) end

    refreshCommanders()
    local now = os.clock()
    pulses[#pulses + 1] = { team = 0, metal = getP("mkt_m0"), vol = buy,  born = now }
    pulses[#pulses + 1] = { team = 1, metal = getP("mkt_m1"), vol = sell, born = now }

    -- liquidation edge detection
    for team = 0, 1 do
        local liq = getP("mkt_liq" .. team)
        if liq > 0 and prevLiq[team] == 0 then
            liqFlash[team] = now
        end
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
            local uid = commanders[p.team]
            if uid and Spring.ValidUnitID(uid) then
                local x, y, z = Spring.GetUnitPosition(uid)
                if x then
                    local c = TEAMCOL[p.team]
                    local grow = age / PULSE_LIFE
                    local radius = (40 + 220 * logScale(p.vol)) * (0.3 + 0.7 * grow)
                    gl.Color(c[1], c[2], c[3], 0.65 * (1 - grow))
                    gl.LineWidth(2.5)
                    gl.DrawGroundCircle(x, y, z, radius, 32)
                    gl.LineWidth(1.0)
                end
            end
        end
    end
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

    -- rising income text above each commander
    local now = os.clock()
    for _, p in ipairs(pulses) do
        local uid = commanders[p.team]
        if uid and Spring.ValidUnitID(uid) and p.metal >= 1 then
            local wx, wy, wz = Spring.GetUnitPosition(uid)
            if wx then
                local sx, sy, sz = Spring.WorldToScreenCoords(wx, wy + 60, wz)
                if sz and sz < 1 then    -- in front of the camera
                    local age = (now - p.born) / PULSE_LIFE
                    local c = TEAMCOL[p.team]
                    gl.Color(c[1], c[2], c[3], 1 - age)
                    local size = (13 + 14 * logScale(p.vol)) * s
                    gl.Text(string.format("+%dm", p.metal), sx, sy + 45 * s * age, size, "co")
                end
            end
        end
    end

    -- liquidation banner: flash on death, then respawn countdown
    local frame = Spring.GetGameFrame()
    local by = vsy * 0.72
    for team = 0, 1 do
        local liq = getP("mkt_liq" .. team)
        if liq > frame then
            local c = TEAMCOL[team]
            local flashAge = now - liqFlash[team]
            if flashAge < FLASH_LIFE then
                local a = 0.5 + 0.5 * math.abs(math.sin(now * 6))
                gl.Color(c[1], c[2], c[3], a)
                gl.Text(TEAMNAME[team] .. " COMMANDER LIQUIDATED", vsx / 2, by, 42 * s, "co")
            end
            local secs = math.ceil((liq - frame) / 30)
            gl.Color(c[1], c[2], c[3], 0.9)
            gl.Text(TEAMNAME[team] .. " reinforcements in " .. secs .. "s", vsx / 2, by - 34 * s, 20 * s, "co")
            by = by - 64 * s
        end
    end
end
