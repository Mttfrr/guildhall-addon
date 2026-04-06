---@type WoWGuildSync
local WGS = WoWGuildSync

-- Export format version (for future compatibility)
local EXPORT_VERSION = 2
local EXPORT_HEADER = "WGS"  -- 3-char prefix to identify our strings

-- Encode a data table into a WGS export string: WGS + base64(JSON)
-- This format is directly decodable by the web platform (atob + JSON.parse)
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

    -- Step 1: Serialize to JSON
    local json = self:ToJson(payload)
    if not json then return nil end

    -- Step 2: Base64 encode
    local encoded = self:Base64Encode(json)
    if not encoded then return nil end

    -- Step 3: Prepend header
    return EXPORT_HEADER .. encoded
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
    modules = modules or { "attendance", "loot", "encounters", "guildBankMoneyChanges", "guildBankTransactions" }

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
