---@type GuildHall
local WGS = GuildHall

-- Identity + timestamp helpers. GetPlayerKey is cached per-session because
-- UnitFullName/GetNormalizedRealmName don't change after PLAYER_ENTERING_WORLD.

local cachedPlayerKey

function WGS:GetPlayerKey()
    if cachedPlayerKey then return cachedPlayerKey end
    local name, realm = UnitFullName("player")
    local key = self:NormalizeFullName(name, realm)
    if key then
        cachedPlayerKey = key
        return cachedPlayerKey
    end
    -- Defensive fallback for the (impossible-in-practice) case where the
    -- player has no name. Don't cache — let the next call retry once
    -- PLAYER_ENTERING_WORLD has actually populated the unit info.
    return "Unknown-" .. (GetNormalizedRealmName() or "")
end

function WGS:GetTimestamp()
    return time()
end

-- Compact relative-time formatter: "never" / "just now" / "42s ago" /
-- "3m ago" / "5h ago" / "2d ago". The single source for every ago-style
-- read-out (Sync tab status line, /gh diag, /gh interop) — previously
-- three near-identical copies that could drift.
function WGS:FormatRelativeTime(ts)
    ts = tonumber(ts)
    if not ts or ts <= 0 then return "never" end
    local now = (time and time()) or 0
    local delta = now - ts
    if delta < 0 then return "just now" end
    if delta < 60 then return delta .. "s ago" end
    if delta < 3600 then return math.floor(delta / 60) .. "m ago" end
    if delta < 86400 then return math.floor(delta / 3600) .. "h ago" end
    return math.floor(delta / 86400) .. "d ago"
end
