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

local DEBUG = false

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

-- AI watchdog: the synced side flags teams whose CircuitAI instance silently
-- failed (idle solitary commander 60s+); the host issues /aireload for them.
local lastReload = {}   -- teamID -> os.clock of last reload attempt
local nextWatch = 0

local function watchdog()
    local now = os.clock()
    if now < nextWatch then return end
    nextWatch = now + 10
    for teamID = 0, 5 do
        if (Spring.GetGameRulesParam("mkt_stuck" .. teamID) or 0) == 1
            and now - (lastReload[teamID] or -math.huge) > 120 then
            lastReload[teamID] = now
            Spring.Echo("MKTWAR-WATCHDOG reloading stuck AI on team " .. teamID)
            Spring.SendCommands("aireload " .. teamID)
        end
    end
end

function widget:Update()
    watchdog()
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
            if prefix == "trd:" then
                nTrades = (nTrades or 0) + 1
                if DEBUG and nTrades % 20 == 1 then
                    Spring.Echo("MKTWAR-BRIDGE trd#" .. nTrades)
                end
            end
        end
        data, err = client:receive("*l")
    end
    if err == "closed" then
        client = nil
    end
end
