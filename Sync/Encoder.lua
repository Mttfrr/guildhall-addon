---@type GuildHall
local WGS = GuildHall

-- Export envelope versions, emitted newest-first. v3 stays valid; we
-- only drop to it if LibDeflate failed to load (vendored library, but
-- defensive). Web side accepts v2/v3/v4 — old paste strings still
-- round-trip.
--   v4: WGS4<8-hex-djb2>:<LibDeflate:EncodeForPrint(deflate(JSON))>
--   v3: WGS3<8-hex-djb2>:<base64(JSON)>
--   v2: WGS<base64(JSON)>                                (legacy, unchecked)
-- The 8-char checksum on v3/v4 catches the silent-truncation failure
-- that's common with very long strings in WoW's edit boxes.
local EXPORT_VERSION = 4
local EXPORT_HEADER_V3 = "WGS3"
local EXPORT_HEADER_V4 = "WGS4"

-- Lazy-loaded LibDeflate handle. Stored on the WGS namespace (not in
-- a module-local) so the Encoder and Decoder share the same cache and
-- _ResetCompressionCache flushes both at once — important for tests
-- that swap LibStub between cases.
local function GetLibDeflate()
    if WGS._libDeflate ~= nil then return WGS._libDeflate or nil end
    local ok, lib = pcall(LibStub, "LibDeflate")
    if ok and lib and type(lib.CompressDeflate) == "function"
       and type(lib.EncodeForPrint) == "function" then
        WGS._libDeflate = lib
        return lib
    end
    WGS._libDeflate = false  -- probed and missing — don't retry
    return nil
end

-- Encode a data table into a WGS export string.
function WGS:Encode(data)
    if not data then return nil end

    -- Normalize attendance session shape before serializing. Bad data
    -- (type-wrong scalars: array teamId, table eventId, etc.) gets
    -- coerced to nil so the platform's strict Zod schema doesn't 400
    -- the whole import over one malformed row. Walks db.global.attendance
    -- in place; idempotent. Surfaces a one-line print when repairs
    -- happened so the user knows their data was self-healed.
    if self.NormalizeAttendanceSessions then
        local repairs = self:NormalizeAttendanceSessions()
        if repairs > 0 then
            self:Print(string.format(
                "Normalized %d malformed field%s in attendance data before export.",
                repairs, repairs == 1 and "" or "s"))
        end
    end

    -- v4 is the preferred envelope when LibDeflate is loaded. The
    -- payload's `v` field reflects the envelope ACTUALLY emitted (not
    -- EXPORT_VERSION), so decoders can route on either the envelope
    -- header OR the embedded `v` field consistently.
    local lib = GetLibDeflate()
    local emitVersion = lib and EXPORT_VERSION or 3

    local payload = {
        v = emitVersion,
        addonVersion = self.version,
        t = self:GetTimestamp(),
        by = self:GetPlayerKey(),
        guildWebId = self.db.profile.guildWebId or "",
        data = data,
    }

    local json = self:ToJson(payload)
    if not json then return nil end

    if lib then
        -- v4: compress + print-encode. LibDeflate:CompressDeflate emits
        -- raw deflate bytes (no zlib header), which the server decodes
        -- with zlib.inflateRawSync. EncodeForPrint uses a chat-safe
        -- 64-char alphabet ([a-z][A-Z][0-9]()) — no '+' or '/' to break
        -- in WoW's chat edit boxes.
        local compressed = lib:CompressDeflate(json)
        if compressed then
            local encoded = lib:EncodeForPrint(compressed)
            if encoded then
                local sum = self:HashString(encoded)
                return EXPORT_HEADER_V4 .. sum .. ":" .. encoded
            end
        end
        -- Fall through to v3 if compression failed mid-pipeline.
        -- Re-serialize with v=3 in the payload so the envelope and the
        -- embedded version stay consistent.
        payload.v = 3
        json = self:ToJson(payload)
        if not json then return nil end
    end

    -- v3 fallback: raw base64 of JSON, same checksum scheme as v4.
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

--- Test-only: drop the LibDeflate handle cache so specs can flip
--- LibStub() between cases. Production code should never call this.
function WGS:_ResetCompressionCache()
    WGS._libDeflate = nil
end
