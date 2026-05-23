---@type GuildHall
local WGS = GuildHall

-- Cross-addon presence detection. Used by the MRT/NSRT bridge modules
-- (Modules/MRTNotes.lua, future MRT attendance + loot bridges) to
-- short-circuit when the other addon isn't loaded — so GuildHall stays
-- a zero-cost dependency for guilds that don't run MRT.
--
-- The cache is per-session: addons loaded after PLAYER_LOGIN through
-- LoadAddOn() are rare enough that we don't bother invalidating; if a
-- bug report says "I /reload after enabling MRT and the bridge doesn't
-- light up", drop the cache and add a SPELLS_CHANGED-equivalent hook.

local presenceCache = {}

--- Is the named addon loaded right now?
---
--- Wraps C_AddOns.IsAddOnLoaded (modern API) with a fallback to the
--- legacy global IsAddOnLoaded for older clients. Result is cached per
--- session to avoid the per-call cost when MRT-bridge hot paths poll
--- repeatedly (e.g. inside ENCOUNTER_END handlers).
function WGS:HasAddon(name)
    if not name then return false end
    local cached = presenceCache[name]
    if cached ~= nil then return cached end

    local loaded = false
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        loaded = C_AddOns.IsAddOnLoaded(name) and true or false
    elseif _G.IsAddOnLoaded then
        loaded = _G.IsAddOnLoaded(name) and true or false
    end

    presenceCache[name] = loaded
    return loaded
end

--- Test-only: drop the presence cache. Production code should not need
--- this — addon presence is fixed for the session. Exposed so busted
--- specs can flip _G.IsAddOnLoaded between cases without leaking state.
function WGS:_ResetAddonCache()
    presenceCache = {}
end
