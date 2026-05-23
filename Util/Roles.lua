---@type GuildHall
local WGS = GuildHall

-- Role normalisation — single source of truth.
--
-- The same player's role comes through with different spellings
-- depending on the source:
--   UnitGroupRolesAssigned()  → "TANK" / "HEALER" / "DAMAGER" / "NONE"
--   server-side import (slot) → "TANK" / "HEALER" / "DPS"
--   raid-comp assignments     → mixed, sometimes lowercase
--
-- Every UI surface that buckets by role used to have its own variant
-- of `(role or "DPS"):upper()` plus an ad-hoc DAMAGER→DPS fallback.
-- Routing everything through this helper means there's one place to
-- fix when the platform adds a new role bucket (e.g. Melee / Ranged
-- counts in `client/src/utils.js ROLES`).
--
-- Output is one of: "TANK", "HEALER", "DPS". Anything else (NONE,
-- nil, an unknown string) buckets as DPS so a stale role doesn't drop
-- the member from a comp render.

function WGS:NormalizeRole(role)
    if not role then return "DPS" end
    local up = role:upper()
    if up == "TANK"   then return "TANK"   end
    if up == "HEALER" then return "HEALER" end
    -- DAMAGER (live UnitGroupRolesAssigned) and DPS (import path) both
    -- bucket as damage; NONE / unknown / "" also default so the role
    -- can't drop a member on a stale signup.
    return "DPS"
end
