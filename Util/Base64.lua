---@type GuildHall
local WGS = GuildHall

-- RFC 4648 base64 codec + djb2 hash. Used by the v3 export envelope:
-- `WGS3<8-hex-djb2-of-base64>:<base64(JSON)>`. The hash must stay in
-- lockstep with the web's `djb2Hex` in client/src/pages/AddonSync.jsx.

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64encode, b64lookup = {}, {}
for i = 1, 64 do
    b64encode[i - 1] = b64chars:sub(i, i)
    b64lookup[b64chars:sub(i, i)] = i - 1
end

local floor = math.floor

function WGS:Base64Encode(data)
    local out, n = {}, 0
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i), 0, 0
        if i + 1 <= #data then b = data:byte(i + 1) end
        if i + 2 <= #data then c = data:byte(i + 2) end
        local v = a * 65536 + b * 256 + c
        n = n + 1; out[n] = b64encode[floor(v / 262144) % 64]
        n = n + 1; out[n] = b64encode[floor(v / 4096) % 64]
        n = n + 1; out[n] = (i + 1 <= #data) and b64encode[floor(v / 64) % 64] or "="
        n = n + 1; out[n] = (i + 2 <= #data) and b64encode[v % 64] or "="
    end
    return table.concat(out)
end

function WGS:Base64Decode(str)
    str = str:gsub("%s+", ""):gsub("=", "")
    local out, n = {}, 0
    for i = 1, #str, 4 do
        local a = b64lookup[str:sub(i, i)] or 0
        local b = (i + 1 <= #str) and (b64lookup[str:sub(i + 1, i + 1)] or 0) or 0
        local c = (i + 2 <= #str) and (b64lookup[str:sub(i + 2, i + 2)] or 0) or nil
        local d = (i + 3 <= #str) and (b64lookup[str:sub(i + 3, i + 3)] or 0) or nil
        if c and d then
            local v = a * 262144 + b * 4096 + c * 64 + d
            n = n + 1; out[n] = string.char(floor(v / 65536) % 256)
            n = n + 1; out[n] = string.char(floor(v / 256) % 256)
            n = n + 1; out[n] = string.char(v % 256)
        elseif c then
            local v = a * 262144 + b * 4096 + c * 64
            n = n + 1; out[n] = string.char(floor(v / 65536) % 256)
            n = n + 1; out[n] = string.char(floor(v / 256) % 256)
        else
            local v = a * 262144 + b * 4096
            n = n + 1; out[n] = string.char(floor(v / 65536) % 256)
        end
    end
    return table.concat(out)
end

-- djb2 — 32-bit, 8-char lowercase hex. Cheap, suitable as an integrity
-- check on a copy-pasted base64 string.
function WGS:HashString(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end
