function widget:GetInfo()
    return {
        name    = "Market Feed Bridge",
        desc    = "Relays feedd SOL/BAM trade ticks into synced state (host only)",
        author  = "bar-market-war",
        date    = "2026",
        license = "MIT",
        layer   = 0,
        enabled = true,
    }
end

local DEBUG = false

-- Telemetry goes to the host infolog via Spring.Log, NOT Spring.Echo. The
-- original code assumed the host was a separate headless engine so Echo never
-- reached a spectator's screen — but in the Option-B cloud setup the host
-- engine IS the one being rendered/streamed, so Echo painted the public
-- stream's console. Spring.Log("MKTWAR", ...) stays in the infolog only
-- (verified: the gadgets' Spring.Log lines never appear on the rendered frame).
local function tlog(msg) Spring.Log("MKTWAR", "info", msg) end

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
        tlog("MarketWar: LuaSocket unavailable in LuaUI! Check TCPAllowConnect.")
        widgetHandler:RemoveWidget(self)
        return
    end
    client = connect()
    tlog("MarketWar: feed bridge connecting to " .. FEED_HOST .. ":" .. FEED_PORT)
end

-- AI watchdog: the synced side flags teams whose CircuitAI instance silently
-- failed (idle solitary commander 60s+); the host issues /aireload for them.
local lastReload = {}   -- teamID -> os.clock of last reload attempt
local nextWatch = 0

local pendingReload = {} -- teamID -> game frame to reload at
local pendingReport = {} -- teamID -> game frame to report recovery at
local LANE_TEAMS = { sol = {0, 1}, spx = {2, 3}, gold = {4, 5}, bam = {6, 7} }

-- called from eventLog when a round end is detected (the intermission param
-- change — a signal PROVEN to fire; the old mkt_reset param path never did)
function scheduleReactivation(laneKey)
    local gf = Spring.GetGameFrame()
    for _, teamID in ipairs(LANE_TEAMS[laneKey] or {}) do
        -- intermission 10s + 30s settle after respawn
        pendingReload[teamID] = gf + 40 * 30
        pendingReport[teamID] = gf + 170 * 30
    end
end

local function watchdog()
    local now = os.clock()
    local gf = Spring.GetGameFrame()
    -- proactive reactivation: EVERY round reset reloads both pair AIs after
    -- their commanders respawn. Post-reset CircuitAI instances run in a
    -- busy-but-broken state (eco errands, no production, ignore gifted
    -- factories) that only a fresh init reliably clears.
    for teamID = 0, 7 do
        if pendingReload[teamID] and gf >= pendingReload[teamID] then
            pendingReload[teamID] = nil
            tlog("MKTWAR-REACTIVATE post-reset aireload team " .. teamID)
            Spring.SendCommands("aireload " .. teamID)
        end
        if pendingReport[teamID] and gf >= pendingReport[teamID] then
            pendingReport[teamID] = nil
            tlog(string.format("MKTWAR-RECOVERY team=%d units=%d metal=%.0f (170s after round end)",
                teamID, Spring.GetTeamUnitCount(teamID) or 0,
                Spring.GetTeamResources(teamID, "metal") or -1))
        end
    end
    if now < nextWatch then return end
    nextWatch = now + 10
    for teamID = 0, 7 do
        if (Spring.GetGameRulesParam("mkt_stuck" .. teamID) or 0) == 1
            and now - (lastReload[teamID] or -math.huge) > 120 then
            lastReload[teamID] = now
            tlog("MKTWAR-WATCHDOG reloading stuck AI on team " .. teamID)
            Spring.SendCommands("aireload " .. teamID)
        end
    end
end

-- Heartbeat telemetry: this widget only exists on the hosting player's
-- (headless) engine, so Echo goes to the host infolog and NEVER to a
-- spectator's on-screen console.
local LANES_HB = {
    { key = "SOL",  asset = 0, usd = 1 },
    { key = "SPX",  asset = 2, usd = 3 },
    { key = "GOLD", asset = 4, usd = 5 },
    { key = "BAM",  asset = 6, usd = 7 },
}
local lastHeartbeat = -1
local prevDrop = 0
local prevInter = {}
local prevPush = 0

-- Event telemetry (host infolog only): synced gadgets can't log without
-- painting spectator consoles, so the host watches the rules params instead.
local function eventLog()
    local dropF = Spring.GetGameRulesParam("mkt_drop_frame") or 0
    if dropF > 0 and dropF ~= prevDrop then
        prevDrop = dropF
        tlog(string.format("MKTWAR-DROP f=%d team=%d n=%d kind=%d", dropF,
            Spring.GetGameRulesParam("mkt_drop_team") or -1,
            Spring.GetGameRulesParam("mkt_drop_n") or 0,
            Spring.GetGameRulesParam("mkt_drop_kind") or 0))
    end
    local insF = Spring.GetGameRulesParam("mkt_insure_frame") or 0
    if insF > 0 and insF ~= (prevInsure or 0) then
        prevInsure = insF
        tlog(string.format("MKTWAR-INSURE f=%d team=%d (factory planted)", insF,
            Spring.GetGameRulesParam("mkt_insure_team") or -1))
    end
    local pushF = Spring.GetGameRulesParam("mkt_push_frame") or 0
    if pushF > 0 and pushF ~= prevPush then
        prevPush = pushF
        tlog(string.format("MKTWAR-PUSH f=%d team=%d n=%d", pushF,
            Spring.GetGameRulesParam("mkt_push_team") or -1,
            Spring.GetGameRulesParam("mkt_push_n") or 0))
    end
    for _, l in ipairs({ "sol", "spx", "gold", "bam" }) do
        local inter = Spring.GetGameRulesParam("mkt_intermission_" .. l) or 0
        if inter > 0 and inter ~= prevInter[l] then
            prevInter[l] = inter
            scheduleReactivation(l)
            tlog(string.format("MKTWAR-ROUND %s to team %d (wins now a=%d u=%d)", l,
                Spring.GetGameRulesParam("mkt_roundwinner_" .. l) or -1,
                Spring.GetGameRulesParam("mkt_wins" .. ({sol=0,spx=2,gold=4,bam=6})[l]) or 0,
                Spring.GetGameRulesParam("mkt_wins" .. ({sol=1,spx=3,gold=5,bam=7})[l]) or 0))
        end
    end
end

local function heartbeat()
    local f = Spring.GetGameFrame()
    if f - lastHeartbeat < 300 then return end
    lastHeartbeat = f
    local parts = { "MKTWAR f=" .. f }
    for _, l in ipairs(LANES_HB) do
        local lk = l.key:lower()
        -- ra/ru = comeback-rally income multipliers (5m relative strength)
        parts[#parts + 1] = string.format("%s a=%d/u=%d am=%.0f um=%.0f b=%.4f s=%.4f px=%.1f r=%.2f/%.2f%s%s",
            l.key,
            Spring.GetTeamUnitCount(l.asset) or 0, Spring.GetTeamUnitCount(l.usd) or 0,
            Spring.GetTeamResources(l.asset, "metal") or 0,
            Spring.GetTeamResources(l.usd, "metal") or 0,
            Spring.GetGameRulesParam("mkt_buy_" .. lk) or 0,
            Spring.GetGameRulesParam("mkt_sell_" .. lk) or 0,
            Spring.GetGameRulesParam("mkt_price_" .. lk) or 0,
            Spring.GetGameRulesParam("mkt_rally" .. l.asset) or 1,
            Spring.GetGameRulesParam("mkt_rally" .. l.usd) or 1,
            (Spring.GetGameRulesParam("mkt_stuck" .. l.asset) or 0) == 1 and " STUCK-a" or "",
            (Spring.GetGameRulesParam("mkt_stuck" .. l.usd) or 0) == 1 and " STUCK-u" or "")
    end
    tlog(table.concat(parts, " | "))
end

function widget:Update()
    watchdog()
    heartbeat()
    eventLog()
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
                    tlog("MKTWAR-BRIDGE trd#" .. nTrades)
                end
            end
        end
        data, err = client:receive("*l")
    end
    if err == "closed" then
        client = nil
    end
end
