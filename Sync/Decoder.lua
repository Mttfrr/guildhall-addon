---@type GuildHall
local WGS = GuildHall

local EXPORT_HEADER_V2 = "WGS"
local EXPORT_HEADER_V3 = "WGS3"
local EXPORT_HEADER_V4 = "WGS4"
local MAX_KNOWN_ENVELOPE_VERSION = 4

-- LibDeflate handle, lazy + cached on WGS so it's shared with the
-- Encoder. WGS:_ResetCompressionCache (defined in Encoder.lua) flushes
-- both paths in one call.
local function GetLibDeflate()
    if WGS._libDeflate ~= nil then return WGS._libDeflate or nil end
    local ok, lib = pcall(LibStub, "LibDeflate")
    if ok and lib and type(lib.DecompressDeflate) == "function"
       and type(lib.DecodeForPrint) == "function" then
        WGS._libDeflate = lib
        return lib
    end
    WGS._libDeflate = false
    return nil
end

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

    if encoded:sub(1, #EXPORT_HEADER_V4) == EXPORT_HEADER_V4
       and encoded:sub(#EXPORT_HEADER_V4 + 9, #EXPORT_HEADER_V4 + 9) == ":" then
        -- v4: deflate + print encoding. Checksum is over the encoded
        -- string, same scheme as v3.
        local expectedSum = encoded:sub(#EXPORT_HEADER_V4 + 1, #EXPORT_HEADER_V4 + 8)
        local payload = encoded:sub(#EXPORT_HEADER_V4 + 10)
        if self:HashString(payload) ~= expectedSum then
            return nil, "Export string appears truncated — please re-copy the full string."
        end
        local lib = GetLibDeflate()
        if not lib then
            return nil, "Export uses compression (v4) but LibDeflate is not loaded. Please update GuildHall."
        end
        local raw = lib:DecodeForPrint(payload)
        if not raw then return nil, "Failed to decode v4 print-encoding" end
        json = lib:DecompressDeflate(raw)
        if not json then return nil, "Failed to decompress v4 payload" end

    elseif encoded:sub(1, #EXPORT_HEADER_V3) == EXPORT_HEADER_V3
       and encoded:sub(#EXPORT_HEADER_V3 + 9, #EXPORT_HEADER_V3 + 9) == ":" then
        -- v3: base64 + checksum.
        local expectedSum = encoded:sub(#EXPORT_HEADER_V3 + 1, #EXPORT_HEADER_V3 + 8)
        local payload = encoded:sub(#EXPORT_HEADER_V3 + 10)
        if self:HashString(payload) ~= expectedSum then
            return nil, "Export string appears truncated — please re-copy the full string."
        end
        json = self:Base64Decode(payload)

    elseif encoded:sub(1, #EXPORT_HEADER_V2) == EXPORT_HEADER_V2 then
        -- v2: base64, no checksum.
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
