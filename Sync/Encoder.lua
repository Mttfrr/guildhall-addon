---@type GuildHall
local WGS = GuildHall

-- Export format version. Emitted format is v3:
--   WGS3<8-hex-djb2-of-base64>:<base64(JSON)>
-- The 8-char checksum lets the decoder reject silently-truncated paste
-- (a very common failure mode in WoW's edit boxes). The web's decoder
-- in client/src/pages/AddonSync.jsx accepts both v2 (`WGS<base64>`)
-- and v3, so old web↔addon exports still round-trip.
local EXPORT_VERSION = 3
local EXPORT_HEADER_V3 = "WGS3"

-- Encode a data table into a WGS export string.
function WGS:Encode(data)
    if not data then return nil end

    -- Wrap with metadata
    local payload = {
        v = EXPORT_VERSION,
        addonVersion = self.version,
        t = self:GetTimestamp(),
        by = self:GetPlayerKey(),
        guildWebId = self.db.profile.guildWebId or "",
        data = data,
    }

    local json = self:ToJson(payload)
    if not json then return nil end

    local encoded = self:Base64Encode(json)
    if not encoded then return nil end

    local sum = self:HashString(encoded)
    return EXPORT_HEADER_V3 .. sum .. ":" .. encoded
end

-- Clean loot entries for export (strip WoW-specific itemLink escape codes)
local function CleanLootForExport(lootEntries)
    local cleaned = {}
    for _, entry in ipairs(lootEntries) do
        local copy = {}
        for k, v in pairs(entry) do
            if k ~= "itemLink" then
                copy[k] = v
            end
        end
        table.insert(cleaned, copy)
    end
    return cleaned
end

-- Build export data from all captured modules
function WGS:BuildExportData(modules)
    modules = modules or { "attendance", "loot", "encounters", "raidCompResults", "guildBankMoneyChanges", "guildBankTransactions" }

    local data = {}
    for _, mod in ipairs(modules) do
        local stored = self.db.global[mod]
        if stored and next(stored) ~= nil then
            if mod == "loot" then
                data[mod] = CleanLootForExport(stored)
            else
                data[mod] = stored
            end
        end
    end

    -- Always include the current bank gold balance if known
    local lastGold = self.db.global.lastKnownGold
    if lastGold and lastGold > 0 then
        data.bankGoldCopper = lastGold
    end

    -- Include character map version so the web knows which mapping was active
    local characters = self.db.global.characters
    if characters and next(characters) ~= nil then
        data.characterMapVersion = self.db.global.lastImport
    end

    return data
end

-- Full export: build + encode
function WGS:ExportAll()
    local data = self:BuildExportData()
    if not data or next(data) == nil then
        self:Print("No data to export.")
        return nil
    end
    return self:Encode(data)
end

-- Export specific module
function WGS:ExportModule(moduleName)
    local stored = self.db.global[moduleName]
    if not stored or next(stored) == nil then
        self:Print("No " .. moduleName .. " data to export.")
        return nil
    end
    local exportData = stored
    if moduleName == "loot" then
        exportData = CleanLootForExport(stored)
    end
    return self:Encode({ [moduleName] = exportData })
end

-- Export multiple specific modules
function WGS:ExportModules(moduleNames)
    local data = {}
    for _, mod in ipairs(moduleNames) do
        local stored = self.db.global[mod]
        if stored and next(stored) ~= nil then
            if mod == "loot" then
                data[mod] = CleanLootForExport(stored)
            else
                data[mod] = stored
            end
        end
    end
    if next(data) == nil then
        self:Print("No data to export for selected modules.")
        return nil
    end
    return self:Encode(data)
end
