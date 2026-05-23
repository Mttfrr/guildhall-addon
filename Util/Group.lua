---@type GuildHall
local WGS = GuildHall

-- Group-state helpers used across UI/* and Modules/*. Centralised here
-- so the addon's idea of "what group are we in / how do we address it"
-- changes in one place when WoW adds a new group type (e.g. delves
-- introduced new group categories that don't fit raid/party). Cheap
-- wrappers — no caching needed since the underlying APIs are O(1).

--- Return the addon-message / chat channel for the current group:
---   "RAID"  if in a raid
---   "PARTY" if in a non-raid group
---   nil     if solo
function WGS:GetGroupChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

--- Are we in any group at all (raid or party)?
function WGS:IsInAnyGroup()
    if IsInRaid() then return true end
    if IsInGroup() then return true end
    return false
end
