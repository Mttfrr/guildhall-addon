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

--- Does the local player have lead-or-assist on the current group?
---
--- Returns (ok, reason):
---   true,  nil               — leader / assistant in a raid, or party leader,
---                              or solo (no group permissions required)
---   false, "raid-need-lead"  — in a raid but not leader/assistant
---   false, "party-need-lead" — in a party but not the leader
---
--- Used by /gh invite, /gh sortgroups, and any future raid-affecting
--- command. Reason codes are stable; callers map them to localised
--- strings (see Locales/enUS.lua).
function WGS:HasGroupLeadOrAssist()
    if IsInRaid() then
        if UnitIsGroupLeader("player") or UnitIsGroupAssistant("player") then
            return true, nil
        end
        return false, "raid-need-lead"
    end
    if IsInGroup() then
        if UnitIsGroupLeader("player") then return true, nil end
        return false, "party-need-lead"
    end
    return true, nil
end

--- Is the local player an officer-rank-or-higher member of their guild?
--- Top 3 ranks (indices 0/1/2) qualify; rank index 0 is GM.
--- Returns false if not in a guild at all.
function WGS:IsGuildOfficer()
    if not IsInGuild() then return false end
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex ~= nil and rankIndex <= 2
end
