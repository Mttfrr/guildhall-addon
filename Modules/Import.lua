---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

---@class WGSImportModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("Import", "AceEvent-3.0")

function module:OnEnable()
end

---------------------------------------------------------------------------
-- Per-section importers
--
-- Each importer takes `(self, data)` where `data` is the raw import
-- payload and returns the number of rows merged. They run in a defined
-- order in ProcessImport because some sections depend on others —
-- characters must land before teams so BuildCharacterLookup is ready
-- when team-member resolution looks up alts.
--
-- Adding a new importer: write a function, add it to the IMPORTERS
-- list at the bottom of this section in the order it should execute,
-- and the ProcessImport loop picks it up.
---------------------------------------------------------------------------

-- characters: map of playerId → { main, alts }. Drives alt-aware
-- character resolution everywhere else (loot attribution, attendance
-- matching). Triggers BuildCharacterLookup which rebuilds the
-- reverse index.
local function importCharacters(self, data)
    if not data.characters then return 0 end
    self.db.global.characters = data.characters
    self:BuildCharacterLookup()
    local n = 0
    for _ in pairs(data.characters) do n = n + 1 end
    if n > 0 then
        self:Print("Player-character map imported: " .. n .. " players.")
    end
    return n
end

-- teams: per-guild raid/m+/etc. groupings. Imported wholesale —
-- the server's roster of teams is authoritative.
local function importTeams(self, data)
    if not data.teams then return 0 end
    self.db.global.teams = data.teams
    if #data.teams > 0 then
        local names = {}
        for _, team in ipairs(data.teams) do
            names[#names + 1] = team.name or ("Team " .. (team.id or "?"))
        end
        self:Print("Teams imported: " .. table.concat(names, ", "))
    end
    return #data.teams
end

-- wishlists + tooltip-cache priming. C_Item.RequestLoadItemDataByID
-- warms Blizzard's item cache so wishlist tooltips render instantly
-- during boss fights (otherwise the first hover blocks on a server
-- round-trip).
local function importWishlists(self, data)
    if not data.wishlists then return 0 end
    self.db.global.wishlists = data.wishlists

    if C_Item and C_Item.RequestLoadItemDataByID then
        local preload = 0
        for _, entry in ipairs(data.wishlists) do
            if entry.items then
                for _, item in ipairs(entry.items) do
                    if item.itemID then
                        C_Item.RequestLoadItemDataByID(item.itemID)
                        preload = preload + 1
                    end
                end
            end
        end
        if preload > 0 then
            self:Print("Pre-cached " .. preload .. " wishlist items for tooltip display.")
        end
    end
    return #data.wishlists
end

-- bossNotes: per-encounter strategy / assignments. Display-only.
local function importBossNotes(self, data)
    if not data.bossNotes then return 0 end
    self.db.global.bossNotes = data.bossNotes
    return #data.bossNotes
end

-- raidComps: planned raid composition per event. Server may send
-- either of two shapes — { eventId, slots: [...] } (current API) or
-- { eventId, assignments: [...] } (pre-normalised). This importer
-- collapses both to the second shape so consumers don't branch.
local SLOT_GROUP_TO_ROLE = {
    tanks   = "TANK",   tank    = "TANK",
    healers = "HEALER", healer  = "HEALER",
    dps     = "DPS",    damage  = "DPS",
}

local function normalizeRaidComp(comp)
    if not comp.slots then return comp end
    local assignments = {}
    for _, slot in ipairs(comp.slots) do
        assignments[#assignments + 1] = {
            name = slot.character_name or slot.name or "Unknown",
            class = slot.class or "",
            role = SLOT_GROUP_TO_ROLE[(slot.slot_group or ""):lower()] or slot.role or "DPS",
            group = slot.group or slot.subgroup or slot.slot_index or nil,
            spec = slot.spec or nil,
            note = slot.note or nil,
        }
    end
    return {
        eventId = comp.eventId,
        name = comp.name or comp.title or nil,
        assignments = assignments,
    }
end

local function importRaidComps(self, data)
    if not data.raidComps then return 0 end
    local normalized = {}
    for _, comp in ipairs(data.raidComps) do
        normalized[#normalized + 1] = normalizeRaidComp(comp)
    end
    self.db.global.raidComps = normalized
    return #normalized
end

-- Each of these is a "trivial-replace" section: take the server's
-- payload, drop it into the matching db.global field, return the row
-- count. Grouped to keep the per-section noise low.
local function importEvents(self, data)
    if not data.events then return 0 end
    self.db.global.events = data.events
    return #data.events
end

local function importGearAudit(self, data)
    if not data.gearAudit then return 0 end
    self.db.global.gearAudit = data.gearAudit
    return #data.gearAudit
end

local function importSignups(self, data)
    if not data.signups then return 0 end
    self.db.global.signups = data.signups
    return #data.signups
end

local function importTargetIlvl(self, data)
    if data.targetIlvl == nil then return 0 end
    self.db.global.targetIlvl = data.targetIlvl
    return 0  -- scalar, not a row
end

-- Server's minimum required addon version. Recorded so the Dashboard
-- can show an "addon outdated" banner without waiting for the next
-- push-import to be rejected.
local function importMinAddonVersion(self, data)
    if not data.minAddonVersion or data.minAddonVersion == "" then return 0 end
    self.db.global.serverMinAddonVersion = data.minAddonVersion
    if self:IsOutdated() then
        self:Print(string.format(
            "|cffff8800GuildHall is outdated:|r the web requires v%s but you have v%s. Update from addons.wago.io/addons/guildhall-addon",
            data.minAddonVersion, self.version))
    end
    return 0
end

-- Auto-populate Guild ID from invite code (secure linking). Only
-- mutates if the new code differs from what's already stored, to
-- avoid spamming the user on every re-import.
local function importInviteCode(self, data)
    if not data.inviteCode or data.inviteCode == "" then return 0 end
    if self.db.profile.guildWebId ~= data.inviteCode then
        self.db.profile.guildWebId = data.inviteCode
        self:Print("Guild ID automatically set to: " .. data.inviteCode)
    end
    return 0
end

local function importMOTD(self, data)
    if not data.motd then return 0 end
    self.db.global.webMOTD = data.motd
    if data.motd ~= "" then
        self:Print("|cffffd100[Guild Web MOTD]|r " .. data.motd)
    end
    return 0
end

-- Order matters: characters must come first so BuildCharacterLookup
-- has the canonical player map before any team-member-resolution
-- consumer runs. Otherwise it's the order the user sees diagnostic
-- prints on the chat frame, which roughly matches what the web sends.
local IMPORTERS = {
    importCharacters,
    importTeams,
    importWishlists,
    importBossNotes,
    importRaidComps,
    importEvents,
    importGearAudit,
    importSignups,
    importTargetIlvl,
    importMinAddonVersion,
    importInviteCode,
    importMOTD,
}

---------------------------------------------------------------------------
-- Public entry point
---------------------------------------------------------------------------

-- Process decoded import data from web platform
function WGS:ProcessImport(data)
    if not data or type(data) ~= "table" then
        self:Print(L["IMPORT_FAILED"])
        return false
    end

    local count = 0
    for _, importer in ipairs(IMPORTERS) do
        count = count + (importer(self, data) or 0)
    end

    -- Ensure character lookup is current (handles partial imports
    -- where characters weren't included but are already stored in DB).
    if self.db.global.characters and next(self.db.global.characters) then
        self:BuildCharacterLookup()
    end

    self.db.global.lastImport = self:GetTimestamp()
    self:Print(string.format(L["IMPORT_SUCCESS"], count))

    self:FireEvent("WGS_IMPORT_APPLIED", { count = count, importedAt = self.db.global.lastImport })
    return true
end

---------------------------------------------------------------------------
-- Read helpers (used by other modules + UI)
---------------------------------------------------------------------------

-- Get wishlist for a specific player (used by tooltip enrichment)
function WGS:GetWishlistForPlayer(playerName)
    local wishlists = self.db.global.wishlists
    if not wishlists then return nil end

    for _, entry in ipairs(wishlists) do
        if entry.playerName == playerName then
            return entry.items
        end
    end
    return nil
end

-- Get wishlist entries for a specific item ID
function WGS:GetWishlistForItem(itemID)
    local wishlists = self.db.global.wishlists
    if not wishlists then return {} end

    local results = {}
    for _, entry in ipairs(wishlists) do
        if entry.items then
            for _, item in ipairs(entry.items) do
                if item.itemID == itemID then
                    table.insert(results, {
                        playerName = entry.playerName,
                        priority = item.priority,
                        note = item.note,
                    })
                end
            end
        end
    end
    return results
end

-- Get boss notes for a specific encounter
function WGS:GetBossNotes(encounterName)
    local notes = self.db.global.bossNotes
    if not notes then return nil end

    for _, note in ipairs(notes) do
        if note.encounterName == encounterName or note.bossName == encounterName then
            return note
        end
    end
    return nil
end

-- Get raid comp for an event
function WGS:GetRaidComp(eventId)
    local comps = self.db.global.raidComps
    if not comps then return nil end

    for _, comp in ipairs(comps) do
        if comp.eventId == eventId then
            return comp
        end
    end
    return nil
end
