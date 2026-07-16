function widget:GetInfo()
    return {
        name    = "Market War Director",
        desc    = "Autonomous broadcast camera: tracks real combat, glides through the front, sweeps the macro view",
        author  = "market-war",
        date    = "2026-07",
        layer   = 0,
        enabled = true,
    }
end

-- The stream has no human at the controls, so this widget IS the camera operator.
-- It scores where opposing units actually MEET AND FIRE (not where bases cluster),
-- parks and glides through those fights, and periodically sweeps the macro view.
-- Camera-only + unsynced: cannot affect the simulation.

--=========================== tuning knobs ============================
local GRID         = 24        -- interest-grid cells per axis (~512 elmo cells)
local DECAY        = 0.90      -- heat retained per decay tick
local DECAY_SEC    = 0.5
local SAMPLE_SEC   = 1.0       -- unit-position resample interval

-- Heat sources. The camera should chase COMBAT, so damage + "contested" cells
-- (where 2+ allyteams overlap = a front line) dominate; raw presence is a whisper.
local DMG_W        = 0.05      -- heat per point of weapon damage dealt (shots landing)
local UNIT_W       = 0.12      -- heat per unit just being somewhere
local CONTEST_MULT = 7.0       -- multiplier for a cell holding units of 2+ allyteams
local CMDR_SPIKE   = 2500      -- commander death: a spike, but not so big it dominates
local DEPLOY_W     = 18        -- per-unit spawn burst (whale/reinforcement drops)

-- Overhead ("ta") camera: `height` = zoom, `angle` = tilt (0 ~ top-down, higher = toward
-- the horizon). Combat is oblique for depth; the macro sweep is flatter to read the board.
local COMBAT_H     = 1850
local LANE_H       = 3800      -- lower for the sea-lane pans so the boats read
local MACRO_H      = 8415      -- ~10% wider; HUD stays ON here so the price tickers show
local TILT_OBLIQUE = 0.58      -- combat: 3D depth
local TILT_HORIZON = 0.90      -- travel / sweep: low, looking across the field to the horizon
local TILT_FLAT    = 0.16      -- macro: mostly top-down so the whole map reads

-- Shot lengths (seconds). Macro/lane linger so the price tickers render and land.
local DWELL_CMB_MIN = 7
local DWELL_CMB_MAX = 14
local DWELL_TRAVEL  = 14
local DWELL_MACRO   = 19       -- +5s: the macro shows the whole price board, let it read
local DWELL_LANE    = 14       -- +5s: lane pans show that lane's ticker
local GLIDE         = 1.6      -- smooth transition seconds for a cut-in
local CUT           = 0.0      -- hard cut
local COVER_EVERY   = 5        -- a lane coverage shot every N shots
local BEAUTY_EVERY  = 7        -- a HUD-off macro sweep every N shots
local SPIKE_MULT    = 2.8      -- a new hotspot must beat the current by this to interrupt
local DEBUG         = false
--=====================================================================

local mapX, mapZ = Game.mapSizeX, Game.mapSizeZ
local cellX = mapX / GRID
local cellZ = mapZ / GRID
local heat = {}                     -- heat[gx*GRID+gz] = number

-- Each lane is a PAN: the camera glides along the battle axis between the pair's
-- bases. The sea lanes (SP500/GOLD) glide right over the water where the boats fight.
local LANES = {
    { name = "SOL",   ax = 2200, az = 11750, bx = 10150, bz = 600 },   -- corners (air) — BAM<->SOL swap
    { name = "SP500", ax = 1150, az = 5400,  bx = 7400,  bz = 1200 },  -- NW sea
    { name = "GOLD",  ax = 5740, az = 12000, bx = 11600, bz = 5000 },  -- SE sea
    { name = "BAM",   ax = 4600, az = 7400,  bx = 7600,  bz = 4900 },  -- isthmus (land) — BAM<->SOL swap
}
local MACRO = { x = mapX * 0.5, z = mapZ * 0.5 }

-- Grand traversal sweeps: long diagonal glides across the whole map, rotating which
-- corners/edges each time, for cinematic establishing movement at a low horizon angle.
local SWEEPS = {
    { 2000, 2000, 10288, 10288 },   -- NW -> SE
    { 10288, 2000, 2000, 10288 },   -- NE -> SW
    { 10288, 10288, 2000, 2000 },   -- SE -> NW
    { 2000, 10288, 10288, 2000 },   -- SW -> NE
    { 1600, 6144, 10688, 6144 },    -- W  -> E
    { 6144, 1600, 6144, 10688 },    -- N  -> S
}
local SWEEP_H     = 5200          -- higher than a combat dive so the sweep shows ground going by
local DWELL_SWEEP = 17

-- Game-UI clutter to strip for a clean broadcast (the market HUD widgets stay).
local NOISE = {
    "Sensor Ranges LOS", "Sensor Ranges Radar", "Sensor Ranges Radar Preview",
    "Sensor Ranges Sonar", "Sensor Ranges Jammer", "LOS colors", "LOS View",
    "Metalspots", "Geothermalspots", "Reclaim Field Highlight", "ReclaimInfo",
    "Attack Range GL4", "Defense Range GL4", "EMP + decloak range",
    "Ghost Radar GL4", "Nano range on transport", "Resurrection Halos GL4",
    "Unit Energy Icons", "Unit Fire State Icons", "Unit Idle Builder Icons",
    "Unit Repeat Icons", "Unit Wait Icons", "Self-Destruct Icons",
    "Rank Icons GL4", "Commander Name Tags", "Highlight Commander Wrecks",
    "Overview Camera Keep Position", "Overview Camera TAB hold & release",
    "Camera Remember", "Lockcamera",
    "Cursor",     -- hide the on-screen mouse cursor for a clean broadcast
}
local noiseApplied = false

local active     = false
local dwell      = 0
local shotTime   = 0
local shotCount  = 0
local curTarget  = nil          -- {x,z,heat}
local hudHidden  = false
local travel     = nil          -- {sx,sz,ex,ez} while a traveling shot is in progress
local curAngle   = TILT_OBLIQUE
local decayAcc, sampleAcc = 0, 0

local spEcho          = Spring.Echo
local GetGroundHeight = Spring.GetGroundHeight
local GetAllUnits     = Spring.GetAllUnits
local GetUnitPosition = Spring.GetUnitPosition
local GetUnitAllyTeam = Spring.GetUnitAllyTeam
local SetCameraState  = Spring.SetCameraState
local GetCameraState  = Spring.GetCameraState
local SendCommands    = Spring.SendCommands
local UnitDefs_       = UnitDefs

local function cellOf(x, z)
    local gx = math.floor(x / cellX); local gz = math.floor(z / cellZ)
    if gx < 0 then gx = 0 elseif gx >= GRID then gx = GRID - 1 end
    if gz < 0 then gz = 0 elseif gz >= GRID then gz = GRID - 1 end
    return gx * GRID + gz
end

local function addHeat(x, z, amount)
    local k = cellOf(x, z)
    heat[k] = (heat[k] or 0) + amount
end

-- Hottest cell + a centroid pull toward hot neighbours so framing centers the brawl.
local function hotspotAround(bestK, bestV)
    local gx = math.floor(bestK / GRID); local gz = bestK % GRID
    local sx, sz, sw = 0, 0, 0
    for dx = -1, 1 do for dz = -1, 1 do
        local nx, nz = gx + dx, gz + dz
        if nx >= 0 and nx < GRID and nz >= 0 and nz < GRID then
            local v = heat[nx * GRID + nz]
            if v then
                sx = sx + (nx + 0.5) * cellX * v
                sz = sz + (nz + 0.5) * cellZ * v
                sw = sw + v
            end
        end
    end end
    if sw <= 0 then return nil end
    return { x = sx / sw, z = sz / sw, heat = bestV }
end

local function hottest()
    local bestK, bestV = nil, 0
    for k, v in pairs(heat) do if v > bestV then bestV, bestK = v, k end end
    if not bestK or bestV < 2 then return nil end
    return hotspotAround(bestK, bestV)
end

-- A second hot region at least minDist from the first (for a traveling shot's endpoint).
local function secondHotspot(first, minDist)
    local bestK, bestV = nil, 0
    local md2 = minDist * minDist
    for k, v in pairs(heat) do
        if v > bestV then
            local gx = math.floor(k / GRID); local gz = k % GRID
            local cx, cz = (gx + 0.5) * cellX, (gz + 0.5) * cellZ
            local ddx, ddz = cx - first.x, cz - first.z
            if (ddx * ddx + ddz * ddz) >= md2 then bestV, bestK = v, k end
        end
    end
    if not bestK or bestV < 2 then return nil end
    return hotspotAround(bestK, bestV)
end

local function setHud(hidden)
    if hidden ~= hudHidden then
        SendCommands("hideinterface")   -- toggles all UI; we track the state
        hudHidden = hidden
    end
end

-- Overhead camera aimed at ground (tx,tz): height = zoom, angle = tilt toward horizon.
local function frameOn(tx, tz, h, angle, trans)
    local ty = GetGroundHeight(tx, tz) or 0
    local cs = GetCameraState()
    cs.name = "ta"
    cs.px, cs.py, cs.pz = tx, ty, tz
    cs.height = h
    cs.angle = angle
    cs.flipped = -1
    cs.dy, cs.dx, cs.dz = -1, 0, 0
    SetCameraState(cs, trans)
    curAngle = angle
end

local function clampX(v) return (v < 400) and 400 or (v > mapX - 400 and mapX - 400 or v) end
local function clampZ(v) return (v < 400) and 400 or (v > mapZ - 400 and mapZ - 400 or v) end

-- pick and execute the next shot
local function nextShot(now, spike)
    shotCount = shotCount + 1
    travel = nil
    local hot = hottest()

    -- macro pan-out: whole map, flat, held long so the price board renders and reads.
    -- HUD stays UP (tickers + order flow visible); only every other macro is a fully
    -- clean HUD-off beauty shot.
    if shotCount % BEAUTY_EVERY == 0 then
        setHud(false)   -- macro KEEPS the HUD so the price tickers/board are visible
        frameOn(MACRO.x, MACRO.z, MACRO_H, TILT_FLAT, GLIDE * 1.8)
        curTarget = { x = MACRO.x, z = MACRO.z, heat = 0 }
        dwell = DWELL_MACRO
        shotTime = now
        return
    end
    setHud(false)

    -- coverage on a lull, or every COVER_EVERY, or when there's no real combat heat
    if (shotCount % COVER_EVERY == 0) or (not hot) then
        local lane = LANES[(math.floor(shotCount / COVER_EVERY) % #LANES) + 1]
        travel = { sx = lane.ax, sz = lane.az, ex = lane.bx, ez = lane.bz, h = LANE_H, dur = DWELL_LANE }
        frameOn(lane.ax, lane.az, LANE_H, TILT_HORIZON, GLIDE)
        curTarget = { x = (lane.ax + lane.bx) / 2, z = (lane.az + lane.bz) / 2, heat = 0 }
        dwell = DWELL_LANE
        shotTime = now
        return
    end

    -- Even shots glide: a grand corner-to-corner sweep, or a hotspot-to-hotspot dolly.
    if shotCount % 2 == 0 then
        if shotCount % 6 == 0 then
            setHud(true)   -- clean, HUD-hidden cinematic sweep across the whole map
            local sw = SWEEPS[(math.floor(shotCount / 6) % #SWEEPS) + 1]
            travel = { sx = sw[1], sz = sw[2], ex = sw[3], ez = sw[4], h = SWEEP_H, dur = DWELL_SWEEP }
            frameOn(sw[1], sw[2], SWEEP_H, TILT_HORIZON, GLIDE)
            curTarget = { x = sw[1], z = sw[2], heat = 0 }
            dwell = DWELL_SWEEP
            shotTime = now
            return
        end
        local second = secondHotspot(hot, cellX * 3)
        if second then
            travel = { sx = hot.x, sz = hot.z, ex = second.x, ez = second.z, h = COMBAT_H, dur = DWELL_TRAVEL }
            frameOn(hot.x, hot.z, COMBAT_H, TILT_HORIZON, GLIDE)
            curTarget = hot
            dwell = DWELL_TRAVEL
            shotTime = now
            return
        end
    end

    -- combat dive: park on the fight, oblique angle, dwell scales with heat
    frameOn(hot.x, hot.z, COMBAT_H, TILT_OBLIQUE, spike and CUT or GLIDE)
    curTarget = hot
    local hb = math.min(hot.heat / 600, 1)
    dwell = DWELL_CMB_MIN + (DWELL_CMB_MAX - DWELL_CMB_MIN) * hb
    shotTime = now
end

function widget:Initialize()
    local spec = select(1, Spring.GetSpectatingState())
    if not spec then
        widgetHandler:RemoveWidget()
        return
    end
    active = true
    Spring.SendCommands("viewta")   -- leave any persisted fps camera for overhead
    nextShot(0, false)
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage)
    if not active or not damage or damage <= 0 then return end
    local x, _, z = GetUnitPosition(unitID)
    if x then addHeat(x, z, damage * DMG_W) end
end

function widget:UnitDestroyed(unitID, unitDefID)
    if not active then return end
    local ud = UnitDefs_[unitDefID]
    if ud and ud.customParams and ud.customParams.iscommander then
        local x, _, z = GetUnitPosition(unitID)
        if x then addHeat(x, z, CMDR_SPIKE) end
    end
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
    if not active then return end
    local x, _, z = GetUnitPosition(unitID)
    if x then addHeat(x, z, DEPLOY_W) end
end

-- Resample unit positions into cells, giving a big bonus to CONTESTED cells (2+
-- allyteams present) — that is where the actual fighting is, not the base clusters.
local function sampleUnits()
    local units = GetAllUnits()
    local cellCount = {}       -- k -> total units
    local cellTeams = {}       -- k -> { [allyTeam]=true } distinct
    for i = 1, #units do
        local id = units[i]
        local x, _, z = GetUnitPosition(id)
        if x then
            local k = cellOf(x, z)
            cellCount[k] = (cellCount[k] or 0) + 1
            local at = GetUnitAllyTeam(id)
            if at then
                local t = cellTeams[k]; if not t then t = {}; cellTeams[k] = t end
                t[at] = true
            end
        end
    end
    for k, n in pairs(cellCount) do
        local distinct = 0
        local t = cellTeams[k]
        if t then for _ in pairs(t) do distinct = distinct + 1 end end
        local add = n * UNIT_W
        if distinct >= 2 then add = add * CONTEST_MULT end   -- front line
        heat[k] = (heat[k] or 0) + add
    end
end

function widget:Update(dt)
    if not active then return end
    self._clock = (self._clock or 0) + dt
    local now = self._clock

    if not noiseApplied and now > 3 then
        noiseApplied = true
        for _, w in ipairs(NOISE) do Spring.SendCommands("luaui disablewidget " .. w) end
        -- shrink the minimap to a small square in the top-left so it stops covering
        -- the round tracker (geometry is x y w h in screen px, bottom-left origin)
        local vsx, vsy = Spring.GetViewGeometry()
        local mm = math.floor(vsy * 0.18)
        Spring.SendCommands(("minimap geometry 6 %d %d %d"):format(vsy - mm - 6, mm, mm))
        -- park the (hidden) mouse at screen center so it can't trigger edge-scroll,
        -- and turn edge-scrolling off so nothing fights the director's camera
        Spring.WarpMouse(math.floor(vsx / 2), math.floor(vsy / 2))
        pcall(Spring.SetConfigFloat, "EdgeMoveWidth", 0)
        pcall(Spring.SetConfigFloat, "EdgeMoveDynamic", 0)
    end

    decayAcc = decayAcc + dt
    if decayAcc >= DECAY_SEC then
        decayAcc = 0
        for k, v in pairs(heat) do
            local nv = v * DECAY
            heat[k] = (nv < 0.5) and nil or nv
        end
    end

    sampleAcc = sampleAcc + dt
    if sampleAcc >= SAMPLE_SEC then sampleAcc = 0; sampleUnits() end

    -- traveling shot: smoothly glide the camera focus from start to end across the dwell
    if travel then
        local frac = (now - shotTime) / travel.dur
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        local e = frac * frac * (3 - 2 * frac)   -- smoothstep ease
        local tx = clampX(travel.sx + (travel.ex - travel.sx) * e)
        local tz = clampZ(travel.sz + (travel.ez - travel.sz) * e)
        frameOn(tx, tz, travel.h, TILT_HORIZON, 0)
    end

    -- shot lifecycle: expire on dwell, or interrupt if a much hotter fight erupts elsewhere
    local elapsed = now - shotTime
    local interrupt = false
    if elapsed > 3 and curTarget and not travel then
        local hot = hottest()
        if hot and hot.heat > (curTarget.heat + 1) * SPIKE_MULT then
            local ddx, ddz = hot.x - curTarget.x, hot.z - curTarget.z
            if (ddx * ddx + ddz * ddz) > (cellX * 2) ^ 2 then interrupt = true end
        end
    end
    if elapsed >= dwell or interrupt then
        nextShot(now, interrupt)
    end
end

function widget:Shutdown()
    setHud(false)   -- never leave the HUD hidden if the director unloads
end
