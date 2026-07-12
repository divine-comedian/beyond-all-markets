function widget:GetInfo()
    return {
        name    = "Market Feed Bridge",
        desc    = "Relays feedd BTC trade ticks into synced state (host only)",
        author  = "bar-market-war",
        date    = "2026",
        license = "MIT",
        layer   = 0,
        enabled = true,
    }
end

-- Only the hosting player's client reads the local feed daemon and relays it
-- into synced code via SendLuaRulesMsg (keeps the sim deterministic).
local FEED_HOST, FEED_PORT = "127.0.0.1", 8642

local client = nil
local retryAt = 0

local function connect()
    local sock = socket.tcp()
    sock:settimeout(0)
    sock:connect(FEED_HOST, FEED_PORT)
    return sock
end

function widget:Initialize()
    if Spring.GetMyPlayerID() ~= 0 then
        widgetHandler:RemoveWidget(self)
        return
    end
    if not socket then
        Spring.Echo("MarketWar: LuaSocket unavailable in LuaUI! Check TCPAllowConnect.")
        widgetHandler:RemoveWidget(self)
        return
    end
    client = connect()
    Spring.Echo("MarketWar: feed bridge connecting to " .. FEED_HOST .. ":" .. FEED_PORT)
end

function widget:Update()
    if not client then
        local now = os.clock()
        if now >= retryAt then
            retryAt = now + 3
            client = connect()
        end
        return
    end
    local data, err = client:receive("*l")
    while data do
        local prefix = data:sub(1, 4)
        if prefix == "mkt:" or prefix == "trd:" then
            Spring.SendLuaRulesMsg(data)
        end
        data, err = client:receive("*l")
    end
    if err == "closed" then
        client = nil
    end
end
