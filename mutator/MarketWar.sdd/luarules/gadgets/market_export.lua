function gadget:GetInfo()
    return {
        name    = "Market War Export",
        desc    = "Periodic compact unit snapshot to infolog, for the web spectator view",
        author  = "market-war",
        layer   = 10,
        enabled = true,
    }
end

-- The web spectator front-end needs live unit state. This is the read-only
-- source of it: every SNAP_SEC seconds, dump every unit as
--   MKTWAR-U <team>,<x>,<z>,<heading>,<class>,<hpFrac>
-- batched BATCH-per-line to keep the echo count sane (a late-game map carries
-- ~2000 units). Coordinates are ints in elmos; hp is 0-99.
--
-- Deliberately infolog rather than a socket: zero new attack surface on the
-- host and it survives an engine restart. The production feed replaces this
-- with a websocket, but the record format stays identical.

if not gadgetHandler:IsSyncedCode() then return end

local SNAP_SEC = 5
local BATCH    = 60

local CLASS = {}   -- unitDefID -> single-char class for the renderer
local function classify(ud)
    if ud.isFactory then return "F" end
    if ud.isBuilding then return ud.weapons and #ud.weapons > 0 and "D" or "B" end
    if ud.customParams and ud.customParams.iscommander then return "C" end
    if ud.canFly then return "A" end
    if ud.minWaterDepth and ud.minWaterDepth > 0 then return "S" end
    if ud.isBuilder then return "W" end
    return "G"
end

function gadget:Initialize()
    for udid, ud in pairs(UnitDefs) do
        CLASS[udid] = classify(ud)
    end
    Spring.Echo("MKTWAR-EXPORT ready: snapshot every " .. SNAP_SEC .. "s")
end

function gadget:GameFrame(f)
    if f % (SNAP_SEC * 30) ~= 0 then return end

    local units = Spring.GetAllUnits()
    Spring.Echo(("MKTWAR-SNAP f=%d n=%d"):format(f, #units))

    local buf, nbuf = {}, 0
    for i = 1, #units do
        local uid = units[i]
        local x, _, z = Spring.GetUnitPosition(uid)
        if x then
            local udid = Spring.GetUnitDefID(uid)
            local hp, mhp = Spring.GetUnitHealth(uid)
            local _, _, _, _, bp = Spring.GetUnitHealth(uid)
            -- heading: 0-65535 -> 0-359 degrees
            local hdg = (Spring.GetUnitHeading(uid) or 0) % 65536
            nbuf = nbuf + 1
            buf[nbuf] = ("%d,%d,%d,%d,%s,%d"):format(
                Spring.GetUnitTeam(uid), x, z,
                math.floor(hdg * 360 / 65536),
                CLASS[udid] or "G",
                math.floor(((hp or 0) / (mhp or 1)) * 99))
            if nbuf == BATCH then
                Spring.Echo("MKTWAR-U " .. table.concat(buf, " "))
                buf, nbuf = {}, 0
            end
        end
    end
    if nbuf > 0 then
        Spring.Echo("MKTWAR-U " .. table.concat(buf, " "))
    end
end
