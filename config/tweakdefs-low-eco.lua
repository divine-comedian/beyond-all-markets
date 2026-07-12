-- low-eco experiment v2: keep every resource-producing structure BUILDABLE but
-- cut its output by 90%, so the market stays the primary income while
-- CircuitAI keeps its natural build/expand behavior. v1 (stripping build
-- options entirely) made BARbarIAn go limp — its planning revolves around eco
-- expansion targets (mex spots), and removing them stalled build AND attack
-- logic, especially after round resets.
--
-- Applied via the `tweakdefs` modoption in gen-startscript.sh (base64url —
-- BAR's decoder drops bytes on '+'/'/'), executed after unitdefs_post.
-- Property-based (no name lists): survives BAR unit renames/additions.
-- Mobile units exempt (commanders keep their innate make).

local SCALE = 0.10

local function scale(v)
    return math.floor((tonumber(v) * SCALE) * 1000 + 0.5) / 1000
end

local nScaled = 0
for name, ud in pairs(UnitDefs) do
    local spd = tonumber(ud.speed) or tonumber(ud.maxvelocity) or 0
    if spd == 0 then
        local touched = false
        if (tonumber(ud.extractsmetal) or 0) > 0 then
            ud.extractsmetal = scale(ud.extractsmetal); touched = true
        end
        if (tonumber(ud.windgenerator) or 0) > 0 then
            ud.windgenerator = scale(ud.windgenerator); touched = true
        end
        if (tonumber(ud.tidalgenerator) or 0) > 0 then
            ud.tidalgenerator = scale(ud.tidalgenerator); touched = true
        end
        if (tonumber(ud.energymake) or 0) >= 15 then
            ud.energymake = scale(ud.energymake); touched = true
        end
        if (tonumber(ud.energyupkeep) or 0) <= -15 then
            ud.energyupkeep = scale(ud.energyupkeep); touched = true
        end
        if (tonumber(ud.metalmake) or 0) > 0 then
            ud.metalmake = scale(ud.metalmake); touched = true
        end
        local cp = ud.customparams
        if cp and cp.energyconv_capacity ~= nil then
            cp.energyconv_capacity = scale(cp.energyconv_capacity); touched = true
        end
        if touched then nScaled = nScaled + 1 end
    end
end

-- Commanders: 2x health, 1.5x weapon damage — a T1 squad shouldn't delete a
-- commander minutes into a round; commander kills should end CONTESTED rounds.
local nComm = 0
for name, ud in pairs(UnitDefs) do
    local cp = ud.customparams
    if cp and cp.iscommander then
        if ud.health then ud.health = tonumber(ud.health) * 2 end
        if ud.maxdamage then ud.maxdamage = tonumber(ud.maxdamage) * 2 end
        if ud.weapondefs then
            for _, wd in pairs(ud.weapondefs) do
                if type(wd) == "table" and type(wd.damage) == "table" then
                    for k, v in pairs(wd.damage) do
                        if tonumber(v) then wd.damage[k] = tonumber(v) * 1.5 end
                    end
                end
            end
        end
        nComm = nComm + 1
    end
end

Spring.Echo("MKTWAR-LOWECO producer structures scaled to " .. (SCALE * 100) .. "% output: " .. nScaled
    .. " | commanders buffed (2x hp, 1.5x dmg): " .. nComm)
