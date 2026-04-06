---@type WoWGuildSync
local WGS = WoWGuildSync
local L = WoWGuildSync_L

---@class WGSImportModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("Import", "AceEvent-3.0")

function module:OnEnable()
end

-- Process decoded import data from web platform
function WGS:ProcessImport(data)
    if not data or type(data) ~= "table" then
        self:Print(L["IMPORT_FAILED"])
        return false
    end

    local count = 0

    -- Import teams
    if data.teams then
        self.db.global.teams = data.teams
        count = count + #data.teams
        if #data.teams > 0 then
            local names = {}
            for _, team in ipairs(data.teams) do
                table.insert(names, team.name or ("Team " .. (team.id or "?")))
            end
            self:Print("Teams imported: " .. table.concat(names, ", "))
        end
    end

    -- Import wishlists
    if data.wishlists then
        self.db.global.wishlists = data.wishlists
        count = count + (data.wishlists and #data.wishlists or 0)

        -- Pre-cache all wishlist item data so tooltips work instantly during boss fights
        if C_Item and C_Item.RequestLoadItemDataByID then
            local preloadCount = 0
            for _, entry in ipairs(data.wishlists) do
                if entry.items then
                    for _, item in ipairs(entry.items) do
                        if item.itemID then
                            C_Item.RequestLoadItemDataByID(item.itemID)
                            preloadCount = preloadCount + 1
                        end
                    end
                end
            end
            if preloadCount > 0 then
                self:Print("Pre-cached " .. preloadCount .. " wishlist items for tooltip display.")
            end
        end
    end

    -- Import boss notes
    if data.bossNotes then
        self.db.global.bossNotes = data.bossNotes
        count = count + (data.bossNotes and #data.bossNotes or 0)
    end

    -- Import raid comp assignments (normalize server slots format)
    if data.raidComps then
        local normalized = {}
        for _, comp in ipairs(data.raidComps) do
            if comp.slots then
                -- Server sends { eventId, slots: [{ slot_group, slot_index, character_name, class, role }] }
                -- Normalize to { eventId, name, assignments: [{ name, class, role }] }
                local SLOT_GROUP_TO_ROLE = {
                    tanks = "TANK", tank = "TANK",
                    healers = "HEALER", healer = "HEALER",
                    dps = "DPS", damage = "DPS",
                }
                local assignments = {}
                for _, slot in ipairs(comp.slots) do
                    table.insert(assignments, {
                        name = slot.character_name or slot.name or "Unknown",
                        class = slot.class or "",
                        role = SLOT_GROUP_TO_ROLE[(slot.slot_group or ""):lower()] or slot.role or "DPS",
                        spec = slot.spec or nil,
                        note = slot.note or nil,
                    })
                end
                table.insert(normalized, {
                    eventId = comp.eventId,
                    name = comp.name or comp.title or nil,
                    assignments = assignments,
                })
            else
                -- Already in the expected format
                table.insert(normalized, comp)
            end
        end
        self.db.global.raidComps = normalized
        count = count + #normalized
    end

    -- Import upcoming events
    if data.events then
        self.db.global.events = data.events
        count = count + (data.events and #data.events or 0)
    end

    -- Import gear audit (for raid readiness check)
    if data.gearAudit then
        self.db.global.gearAudit = data.gearAudit
        count = count + #data.gearAudit
    end

    -- Import target ilvl
    if data.targetIlvl then
        self.db.global.targetIlvl = data.targetIlvl
    end

    -- Auto-populate Guild ID from invite code (secure linking)
    if data.inviteCode and data.inviteCode ~= "" then
        if self.db.profile.guildWebId == "" or self.db.profile.guildWebId ~= data.inviteCode then
            self.db.profile.guildWebId = data.inviteCode
            self:Print("Guild ID automatically set to: " .. data.inviteCode)
        end
    end

    -- Import guild web MOTD
    if data.motd then
        self.db.global.webMOTD = data.motd
        if data.motd ~= "" then
            self:Print("|cffffd100[Guild Web MOTD]|r " .. data.motd)
        end
    end

    self.db.global.lastImport = self:GetTimestamp()
    self:Print(string.format(L["IMPORT_SUCCESS"], count))
    return true
end

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
