---@type GuildHall
local WGS = GuildHall

-- Identity + timestamp helpers. GetPlayerKey is cached per-session because
-- UnitFullName/GetNormalizedRealmName don't change after PLAYER_ENTERING_WORLD.

local cachedPlayerKey

function WGS:GetPlayerKey()
    if cachedPlayerKey then return cachedPlayerKey end
    local name, realm = UnitFullName("player")
    realm = realm or GetNormalizedRealmName() or ""
    if name and name ~= "" and realm ~= "" then
        cachedPlayerKey = name .. "-" .. realm
        return cachedPlayerKey
    end
    return (name or "Unknown") .. "-" .. realm
end

function WGS:GetTimestamp()
    return time()
end
