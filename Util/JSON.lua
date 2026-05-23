---@type GuildHall
local WGS = GuildHall

-- Minimal pure-Lua JSON encoder / decoder. The encoder writes RFC-8259 with
-- two compatibility quirks for WoW addon ergonomics:
--   * Empty Lua tables encode as "[]" by default (treating them as empty
--     arrays). A table with `_isObject = true` becomes "{}" instead.
--   * `WGS.JSON_NULL` (a sentinel singleton) round-trips as JSON `null`.

WGS._jsonEscapes = { ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

function WGS:ToJson(val)
    if val == nil or val == self.JSON_NULL then return "null" end
    local t = type(val)
    if t == "boolean" then return val and "true" or "false"
    elseif t == "number" then
        if val ~= val or val == math.huge or val == -math.huge then return "null" end
        return tostring(val)
    elseif t == "string" then
        return '"' .. val:gsub('[\\"\n\r\t]', self._jsonEscapes) .. '"'
    elseif t == "table" then
        if next(val) == nil then return val._isObject and "{}" or "[]" end

        local isArray = true
        local maxIdx = 0
        for k in pairs(val) do
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then isArray = false; break end
            if k > maxIdx then maxIdx = k end
        end
        if maxIdx ~= #val then isArray = false end

        local parts = {}
        if isArray then
            for _, v in ipairs(val) do parts[#parts + 1] = self:ToJson(v) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                local key = (type(k) == "string" and k or tostring(k)):gsub('[\\"\n\r\t]', self._jsonEscapes)
                parts[#parts + 1] = '"' .. key .. '":' .. self:ToJson(v)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

WGS.JSON_NULL = setmetatable({}, { __tostring = function() return "null" end })

function WGS:FromJson(str)
    if not str or str == "" then return nil end
    local pos = 1
    local len = #str

    local function skipWs()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c ~= " " and c ~= "\t" and c ~= "\n" and c ~= "\r" then break end
            pos = pos + 1
        end
    end

    local parseValue

    local function parseString()
        pos = pos + 1
        local parts = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == "\\" then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if     esc == "n"  then parts[#parts + 1] = "\n"
                elseif esc == "r"  then parts[#parts + 1] = "\r"
                elseif esc == "t"  then parts[#parts + 1] = "\t"
                elseif esc == '"'  then parts[#parts + 1] = '"'
                elseif esc == "\\" then parts[#parts + 1] = "\\"
                elseif esc == "/"  then parts[#parts + 1] = "/"
                elseif esc == "u"  then pos = pos + 4; parts[#parts + 1] = "?"
                else parts[#parts + 1] = esc end
                pos = pos + 1
            elseif c == '"' then
                pos = pos + 1
                return table.concat(parts)
            else
                parts[#parts + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(parts)
    end

    local function parseNumber()
        local start = pos
        if str:sub(pos, pos) == "-" then pos = pos + 1 end
        while pos <= len and str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
        if pos <= len and str:sub(pos, pos) == "." then
            pos = pos + 1
            while pos <= len and str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
        end
        if pos <= len and str:sub(pos, pos):match("[eE]") then
            pos = pos + 1
            if pos <= len and str:sub(pos, pos):match("[%+%-]") then pos = pos + 1 end
            while pos <= len and str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
        end
        return tonumber(str:sub(start, pos - 1))
    end

    local function parseArray()
        pos = pos + 1; skipWs()
        local arr = {}
        if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while true do
            skipWs(); arr[#arr + 1] = parseValue(); skipWs()
            if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            pos = pos + 1
        end
    end

    local function parseObject()
        pos = pos + 1; skipWs()
        local obj = {}
        if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while true do
            skipWs(); local key = parseString(); skipWs()
            pos = pos + 1; skipWs()
            obj[key] = parseValue(); skipWs()
            if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            pos = pos + 1
        end
    end

    parseValue = function()
        skipWs()
        local c = str:sub(pos, pos)
        if     c == '"' then return parseString()
        elseif c == "{" then return parseObject()
        elseif c == "[" then return parseArray()
        elseif c == "t" then pos = pos + 4; return true
        elseif c == "f" then pos = pos + 5; return false
        elseif c == "n" then pos = pos + 4; return WGS.JSON_NULL
        else return parseNumber() end
    end

    local ok, result = pcall(parseValue)
    if ok then return result end
    -- Malformed JSON. The caller already handles nil-return; we surface
    -- the parse error on the event bus so future `/gh diag` consumers
    -- can show "import string failed to parse at character N" instead
    -- of just "import failed".
    if WGS.FireEvent then
        WGS:FireEvent("WGS_INTERNAL_ERROR", { source = "JSON.FromJson", error = result })
    end
    return nil
end
