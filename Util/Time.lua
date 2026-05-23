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
