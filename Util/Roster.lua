---@type GuildHall
local WGS = GuildHall

-- Character / guild roster helpers. Two state caches live at file scope:
--   rosterCache       — { fullName, class, online, level, rank } per short
--                       name, refreshed every 10s when read.
--   guildGroupCache   — IsGuildGroup result, refreshed every 5s.
-- BuildCharacterLookup is repopulated explicitly on each web import.

--- Ensure a name is in "CharName-Realm" format. Two call shapes:
---
---   NormalizeFullName("Foo")            → "Foo-CurrentRealm"
---   NormalizeFullName("Foo-Other")      → "Foo-Other"        (already suffixed)
---   NormalizeFullName("Foo", "Other")   → "Foo-Other"        (explicit realm)
---   NormalizeFullName("Foo", "")        → "Foo-CurrentRealm" (empty falls back)
---
--- Same-realm members from GetGuildRosterInfo / GetRaidRosterInfo /
--- UnitFullName can come back with an empty or nil realm string — this
--- collapses that case so callers stop hand-rolling the same defensive
--- ternary.
function WGS:NormalizeFullName(name, realm)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then return name end
    if not realm or realm == "" then
        realm = GetNormalizedRealmName() or ""
    end
    if realm == "" then return name end
    return name .. "-" .. realm
end

--- Reverse lookup: CharName-Realm → playerId. Rebuilt on each import.
function WGS:BuildCharacterLookup()
    local lookup = {}
    local chars = self.db.global.characters
    if chars then
        for pid, info in pairs(chars) do
            if info.main then lookup[info.main] = pid end
            if info.alts then
                for _, alt in ipairs(info.alts) do lookup[alt] = pid end
            end
        end
    end
    self.db.global.characterLookup = lookup
    return lookup
end

--- O(1) character → player resolution via cached lookup.
function WGS:ResolvePlayerForCharacter(charName)
    if not charName then return nil, nil end
    local lookup = self.db.global.characterLookup
    if not lookup then return nil, nil end
    local pid = lookup[charName]
    if not pid then return nil, nil end
    return pid, self.db.global.characters[pid]
end

---------------------------------------------------------------------------
-- Class colors (Blizzard RAID_CLASS_COLORS hex values)
---------------------------------------------------------------------------

WGS.CLASS_COLORS = {
    WARRIOR     = "ffc69b6d", PALADIN     = "fff48cba",
    HUNTER      = "ffaad372", ROGUE       = "fffff468",
    PRIEST      = "ffffffff", DEATHKNIGHT = "ffc41e3a",
    SHAMAN      = "ff0070dd", MAGE        = "ff3fc7eb",
    WARLOCK     = "ff8788ee", MONK        = "ff00ff98",
    DRUID       = "ffff7c0a", DEMONHUNTER = "ffa330c9",
    EVOKER      = "ff33937f",
}

-- Convert any class string into Blizzard's classFile constant form
-- (UPPERCASE, no spaces). The platform's export ships localized
-- display names like "Death Knight" / "Demon Hunter"; GetGuildRosterInfo
-- returns the file constant directly. Both flow through the same
-- CLASS_COLORS / CLASS_ICON_TCOORDS lookups, so a single normaliser
-- avoids per-call-site `:upper():gsub("%s", "")` churn — and the
-- spaces in "Death Knight" / "Demon Hunter" were precisely why those
-- two classes rendered with a white name + a blank icon rectangle.
function WGS:NormalizeClassFile(class)
    if not class or class == "" then return "" end
    return (class:upper():gsub("%s", ""))
end

---------------------------------------------------------------------------
-- Guild roster lookup (cached 10s)
---------------------------------------------------------------------------

local rosterCache = { data = nil, expiry = 0 }

function WGS:GetGuildRosterLookup()
    local now = time()
    if rosterCache.data and now < rosterCache.expiry then return rosterCache.data end

    local roster = {}
    if not IsInGuild() then return roster end

    for i = 1, GetNumGuildMembers() do
        local name, rankName, _, level, _, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
        if name then
            local short = name:match("^([^%-]+)")
            roster[short] = {
                fullName = self:NormalizeFullName(name),  -- always "Char-Realm"
                class = classFile or "",
                online = online or false,
                level = level or 0,
                rank = rankName or "",
            }
        end
    end
    rosterCache.data = roster
    rosterCache.expiry = now + 10
    return roster
end

---------------------------------------------------------------------------
-- Guild group check (>=80% guildmates required, cached 5s)
---------------------------------------------------------------------------

local GUILD_GROUP_CACHE_TTL = 5
local guildGroupCache = { result = nil, expiry = 0 }

local function cacheAndReturn(result, now)
    guildGroupCache.result = result
    guildGroupCache.expiry = now + GUILD_GROUP_CACHE_TTL
    return result
end

function WGS:IsGuildGroup()
    local now = time()
    if guildGroupCache.result ~= nil and now < guildGroupCache.expiry then
        return guildGroupCache.result
    end

    if not IsInGuild() then return cacheAndReturn(false, now) end
    local myGuild = GetGuildInfo("player")
    if not myGuild then return cacheAndReturn(false, now) end

    local total = GetNumGroupMembers()
    -- Solo: trivially a "guild group" for filter purposes. Not cached
    -- — a moment later we might be in a real group whose composition
    -- needs evaluating.
    if total <= 1 then return true end

    local guildCount, checked = 0, 0
    if IsInRaid() then
        for i = 1, total do
            local unit = "raid" .. i
            if UnitExists(unit) then
                checked = checked + 1
                if GetGuildInfo(unit) == myGuild then guildCount = guildCount + 1 end
            end
        end
    elseif IsInGroup() then
        checked, guildCount = 1, 1
        for i = 1, total - 1 do
            local unit = "party" .. i
            if UnitExists(unit) then
                checked = checked + 1
                if GetGuildInfo(unit) == myGuild then guildCount = guildCount + 1 end
            end
        end
    end

    -- Not enough units resolved yet (roster still loading) — refuse to
    -- decide and force a re-check on the next call.
    if checked < total * 0.5 then return cacheAndReturn(false, now) end

    return cacheAndReturn((guildCount / checked) >= 0.8, now)
end
