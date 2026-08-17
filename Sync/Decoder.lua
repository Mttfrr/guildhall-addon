---@type GuildHall
local WGS = GuildHall

local EXPORT_HEADER_V2 = "WGS"
local EXPORT_HEADER_V3 = "WGS3"
local EXPORT_HEADER_V4 = "WGS4"
local MAX_KNOWN_ENVELOPE_VERSION = 4

-- LibDeflate access goes through the shared WGS:GetLibDeflate()
-- (defined in Sync/Encoder.lua, which loads first). One cache, one
-- capability check; WGS:_ResetCompressionCache flushes it for tests.

-- Decode an export string back into a data table. Accepts:
--   v4:  WGS4<8-hex-djb2>:<LibDeflate-print-encoded deflated JSON>
--   v3:  WGS3<8-hex-djb2>:<base64(JSON)>            — checksum-protected
--   v2:  WGS<base64(JSON)>                          — legacy, unchecked
--   raw: <JSON>                                     — for debugging
function WGS:Decode(encoded)
    if not encoded or type(encoded) ~= "string" then
        return nil, "Invalid input"
    end

    encoded = encoded:match("^%s*(.-)%s*$")

    -- Try raw JSON first (starts with {)
    if encoded:sub(1, 1) == "{" then
        local data = self:FromJson(encoded)
        if data then return data end
        return nil, "Invalid JSON"
    end

    local json

    if encoded:sub(1, #EXPORT_HEADER_V4) == EXPORT_HEADER_V4 then
        -- v4: deflate + print encoding. Checksum is over the encoded
        -- string, same scheme as v3.
        --
        -- The `:` structure check reports "truncated" rather than
        -- falling through: "WGS4…" also starts with "WGS", so a paste
        -- cut inside the checksum used to reach the legacy v2 branch,
        -- base64-decode garbage, and report a misleading generic
        -- JSON-parse error.
        if encoded:sub(#EXPORT_HEADER_V4 + 9, #EXPORT_HEADER_V4 + 9) ~= ":" then
            return nil, "Export string appears truncated — please re-copy the full string."
        end
        local expectedSum = encoded:sub(#EXPORT_HEADER_V4 + 1, #EXPORT_HEADER_V4 + 8)
        local payload = encoded:sub(#EXPORT_HEADER_V4 + 10)
        if self:HashString(payload) ~= expectedSum then
            return nil, "Export string appears truncated — please re-copy the full string."
        end
        local lib = self:GetLibDeflate()
        if not lib then
            return nil, "Export uses compression (v4) but LibDeflate is not loaded. Please update GuildHall."
        end
        local raw = lib:DecodeForPrint(payload)
        if not raw then return nil, "Failed to decode v4 print-encoding" end
        json = lib:DecompressDeflate(raw)
        if not json then return nil, "Failed to decompress v4 payload" end

    elseif encoded:sub(1, #EXPORT_HEADER_V3) == EXPORT_HEADER_V3 then
        -- v3: base64 + checksum. Same truncation-over-fallthrough
        -- rule as v4 for the structure check.
        if encoded:sub(#EXPORT_HEADER_V3 + 9, #EXPORT_HEADER_V3 + 9) ~= ":" then
            return nil, "Export string appears truncated — please re-copy the full string."
        end
        local expectedSum = encoded:sub(#EXPORT_HEADER_V3 + 1, #EXPORT_HEADER_V3 + 8)
        local payload = encoded:sub(#EXPORT_HEADER_V3 + 10)
        if self:HashString(payload) ~= expectedSum then
            return nil, "Export string appears truncated — please re-copy the full string."
        end
        json = self:Base64Decode(payload)

    elseif encoded:sub(1, #EXPORT_HEADER_V2) == EXPORT_HEADER_V2 then
        -- v2: base64, no checksum. Only genuine legacy strings reach
        -- here — WGS3/WGS4 prefixes are fully handled above.
        json = self:Base64Decode(encoded:sub(#EXPORT_HEADER_V2 + 1))

    else
        return nil, "Invalid export string (missing WGS header)"
    end

    if not json or json == "" then
        return nil, "Failed to decode payload"
    end

    local data = self:FromJson(json)
    if not data or type(data) ~= "table" then
        return nil, "Failed to parse JSON data"
    end

    if data.v and data.v > MAX_KNOWN_ENVELOPE_VERSION then
        WGS:Print("Warning: export string is from a newer version. Some data may not be recognized.")
    end

    return data, nil
end

-- Decode and process an import string from the web platform
function WGS:DecodeAndImport(encoded)
    local data, err = self:Decode(encoded)
    if not data then
        self:Print("Import failed: " .. (err or "unknown error"))
        return false
    end

    -- The web platform wraps data in the same envelope: { v, t, data: { teams, wishlists, ... } }
    local importData = data.data or data

    -- Debug: show what keys were found
    local keys = {}
    for k, v in pairs(importData) do
        if type(v) == "table" then
            local count = 0
            for _ in pairs(v) do count = count + 1 end
            table.insert(keys, k .. "(" .. count .. ")")
        else
            table.insert(keys, k)
        end
    end
    self:Print("Import data keys: " .. (next(keys) and table.concat(keys, ", ") or "none"))

    return self:ProcessImport(importData)
end
