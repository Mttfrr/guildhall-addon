---@type GuildHall
local WGS = GuildHall

local EXPORT_HEADER = "WGS"

-- Decode an export string back into a data table
-- Accepts: WGS + base64(JSON) or raw JSON
function WGS:Decode(encoded)
    if not encoded or type(encoded) ~= "string" then
        return nil, "Invalid input"
    end

    -- Strip whitespace
    encoded = encoded:match("^%s*(.-)%s*$")

    -- Try raw JSON first (starts with {)
    if encoded:sub(1, 1) == "{" then
        local data = self:FromJson(encoded)
        if data then return data end
        return nil, "Invalid JSON"
    end

    -- Check WGS header
    if encoded:sub(1, #EXPORT_HEADER) ~= EXPORT_HEADER then
        return nil, "Invalid export string (missing WGS header)"
    end

    -- Remove header
    local payload = encoded:sub(#EXPORT_HEADER + 1)

    -- Base64 decode
    local json = self:Base64Decode(payload)
    if not json or json == "" then
        return nil, "Failed to decode base64"
    end

    -- Parse JSON
    local data = self:FromJson(json)
    if not data or type(data) ~= "table" then
        return nil, "Failed to parse JSON data"
    end

    -- Version check
    if data.v and data.v > 2 then
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
