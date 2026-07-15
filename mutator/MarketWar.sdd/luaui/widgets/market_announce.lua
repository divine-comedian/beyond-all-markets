function widget:GetInfo()
    return {
        name    = "Market Announce",
        desc    = "On-stream BAM trade ticker + whale/flip banners (host/rendered client)",
        author  = "bar-market-war",
        date    = "2026",
        license = "MIT",
        layer   = 0,
        enabled = true,
    }
end

-- The host engine IS the streamed one (cloud Option-B), so widget-drawn text
-- lands on the public stream — here that is the point. Gate to player 0 (the
-- rendered/hosting client) like market_feed.
local ROW_LIFE   = 6      -- ticker row seconds
local BANNER_LIFE = 5
local ASSET_TEAM, USD_TEAM = 6, 7

local vsx, vsy = Spring.GetViewGeometry()
local banner = nil          -- { text=, color=, born= }
local prevDropF = 0

function widget:Initialize()
    if Spring.GetMyPlayerID() ~= 0 then
        widgetHandler:RemoveWidget(self)
    end
end

function widget:ViewResize(x, y) vsx, vsy = x, y end

local function pollBanner()
    local dropF = Spring.GetGameRulesParam("mkt_drop_frame") or 0
    if dropF <= 0 or dropF == prevDropF then return end
    prevDropF = dropF
    local team = Spring.GetGameRulesParam("mkt_drop_team") or -1
    if team ~= ASSET_TEAM and team ~= USD_TEAM then return end   -- BAM lane only
    local kind = Spring.GetGameRulesParam("mkt_drop_kind") or 0
    local n = Spring.GetGameRulesParam("mkt_drop_n") or 0
    local side = (team == ASSET_TEAM) and "BUY" or "SELL"
    if kind == 2 then
        banner = { text = string.format("WHALE %s  —  %d units deployed", side, n),
                   color = (team == ASSET_TEAM) and { 0.3, 1, 0.4, 1 } or { 1, 0.4, 0.3, 1 },
                   born = os.clock() }
    elseif kind == 1 then
        banner = { text = "BAM FLIP  —  momentum reversal, underdog reinforced",
                   color = { 1, 0.9, 0.3, 1 }, born = os.clock() }
    end   -- kind 3 (comeback) stays unannounced
end

function widget:Update() pollBanner() end

function widget:DrawScreen()
    local now = os.clock()
    local font = gl.Text and true
    if not font then return end
    -- Ticker: newest-first rows, bottom-left, fading out.
    local ticker = WG and WG.BAMTicker
    if ticker then
        local y = 120
        for _, r in ipairs(ticker) do
            local age = now - (r.at or 0)
            if age <= ROW_LIFE then
                local a = 1 - age / ROW_LIFE
                if r.side == "B" then
                    gl.Color(0.3, 1, 0.4, a)
                    gl.Text(string.format("\238\130\165 BUY  %.2f SOL  %s", r.sol or 0, r.addr or "?"),
                        24, y, 16, "o")
                else
                    gl.Color(1, 0.4, 0.3, a)
                    gl.Text(string.format("\238\130\166 SELL %.2f SOL  %s", r.sol or 0, r.addr or "?"),
                        24, y, 16, "o")
                end
                y = y - 20
            end
        end
        gl.Color(1, 1, 1, 1)
    end
    -- Banner: centered near the top, fading out.
    if banner then
        local age = now - banner.born
        if age <= BANNER_LIFE then
            local a = 1 - age / BANNER_LIFE
            local c = banner.color
            gl.Color(c[1], c[2], c[3], a)
            gl.Text(banner.text, vsx * 0.5, vsy * 0.86, 28, "ocn")
            gl.Color(1, 1, 1, 1)
        else
            banner = nil
        end
    end
end
