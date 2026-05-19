---@type GuildHall
local WGS = GuildHall

local EXPORT_HEADER_V2 = "WGS"
local EXPORT_HEADER_V3 = "WGS3"
local MAX_KNOWN_ENVELOPE_VERSION = 3

-- Decode an export string back into a data table. Accepts:
--   v3:  WGS3<8-hex-djb2-of-base64>:<base64(JSON)>   — checksum-protected
--   v2:  WGS<base64(JSON)>                           — legacy, unchecked
--   raw: <JSON>                                      — for debugging
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

    local payload
    if encoded:sub(1, #EXPORT_HEADER_V3) == EXPORT_HEADER_V3
       and encoded:sub(#EXPORT_HEADER_V3 + 9, #EXPORT_HEADER_V3 + 9) == ":" then
        -- v3 envelope. Validate the checksum on the base64 string before decoding.
        local expectedSum = encoded:sub(#EXPORT_HEADER_V3 + 1, #EXPORT_HEADER_V3 + 8)
        payload = encoded:sub(#EXPORT_HEADER_V3 + 10)
        if self:HashString(payload) ~= expectedSum then
            return nil, "Export string appears truncated — please re-copy the full string."
        end
    elseif encoded:sub(1, #EXPORT_HEADER_V2) == EXPORT_HEADER_V2 then
        -- v2 legacy envelope, no checksum.
        payload = encoded:sub(#EXPORT_HEADER_V2 + 1)
    else
        return nil, "Invalid export string (missing WGS header)"
    end

    local json = self:Base64Decode(payload)
    if not json or json == "" then
        return nil, "Failed to decode base64"
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
