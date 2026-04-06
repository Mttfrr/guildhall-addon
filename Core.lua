local ADDON_NAME = "WoWGuildSync"

---@type WoWGuildSync
local WGS = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0")
local L = WoWGuildSync_L

-- Make globally accessible
WoWGuildSync = WGS
_G["WoWGuildSync"] = WGS

-- Version
WGS.version = "0.3.0-beta"

-- Database defaults
local dbDefaults = {
    profile = {
        minimap = { hide = false },
        autoTrackAttendance = true,
        autoTrackLoot = true,
        guildGroupsOnly = true,
        guildWebId = "",
        -- Feature toggles
        showLootDistHelper = true,
        showReadinessCheck = true,
        showBossNotes = true,
        showWebMOTD = true,
    },
    global = {
        -- Captured data awaiting export (in-game only data)
        attendance = {},
        loot = {},
        guildBankMoneyChanges = {},
        guildBankTransactions = {},
        encounters = {},
        lastKnownGold = nil,
        -- Imported data from web
        teams = {},
        wishlists = {},
        bossNotes = {},
        raidComps = {},
        events = {},
        -- Web platform data
        gearAudit = {},
        targetIlvl = 0,
        webMOTD = "",
        -- Sync metadata
        lastExport = 0,
        lastImport = 0,
        exportHistory = {},
    },
}

function WGS:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("WoWGuildSyncDB", dbDefaults, true)

    -- Register slash commands
    self:RegisterChatCommand("wgs", "SlashCommand")
    self:RegisterChatCommand("wowguildsync", "SlashCommand")

    -- Setup config panel and minimap icon (called here to avoid fragile hook chains)
    self:SetupConfig()
    self:SetupMinimapIcon()

    self:Print("GuildHall v" .. self.version .. " loaded. |cffff8800[BETA] Early development — verify exported data before relying on it. Feedback: guildhall.run|r")
    self:Print("Type /wgs help for commands.")
end

function WGS:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:SetupTooltipHooks()
end

function WGS:OnDisable()
end

function WGS:PLAYER_ENTERING_WORLD()
    -- Nothing needed on login — modules self-register for their events
end

function WGS:SlashCommand(input)
    local cmd = self:GetArgs(input, 1)
    cmd = (cmd or ""):lower()

    if cmd == "show" or cmd == "" then
        self:ToggleMainFrame()
    elseif cmd == "export" then
        self:ShowExportFrame()
    elseif cmd == "import" then
        self:ShowImportFrame()
    elseif cmd == "attendance" then
        self:ToggleAttendance()
    elseif cmd == "config" or cmd == "options" then
        self:OpenConfig()
    elseif cmd == "teams" then
        self:ListTeams()
    elseif cmd == "bossnotes" or cmd == "bn" then
        local _, bossName = self:GetArgs(input, 2)
        if bossName and bossName ~= "" then
            self:ShowBossNotes(bossName)
        else
            self:Print("Usage: /wgs bossnotes <boss name>")
        end
    elseif cmd == "events" then
        self:ToggleEventsFrame()
    elseif cmd == "readiness" or cmd == "ready" then
        self:ToggleReadinessFrame()
    elseif cmd == "help" then
        self:Print(L["SLASH_HELP"])
    else
        self:Print(L["SLASH_HELP"])
    end
end

-- Addon compartment (minimap menu) click handler
function WoWGuildSync_OnAddonCompartmentClick()
    WGS:ToggleMainFrame()
end

-- Utility: get player-realm identifier (cached after first successful call)
local cachedPlayerKey = nil
function WGS:GetPlayerKey()
    if cachedPlayerKey then return cachedPlayerKey end
    local name, realm = UnitFullName("player")
    realm = realm or GetNormalizedRealmName() or ""
    if name and name ~= "" and realm ~= "" then
        cachedPlayerKey = name .. "-" .. realm
        return cachedPlayerKey
    end
    return (name or "Unknown") .. "-" .. realm
end

-- Utility: get current timestamp
function WGS:GetTimestamp()
    return time()
end

---------------------------------------------------------------------------
-- JSON utilities (needed for web-compatible export/import)
---------------------------------------------------------------------------

-- Lookup table for single-pass JSON string escaping
WGS._jsonEscapes = { ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

-- Lua table → JSON string
function WGS:ToJson(val)
    if val == nil or val == self.JSON_NULL then
        return "null"
    end
    local t = type(val)
    if t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val then return "null" end -- NaN
        if val == math.huge or val == -math.huge then return "null" end
        return tostring(val)
    elseif t == "string" then
        -- Single-pass escaping via lookup table (avoids 5 intermediate strings)
        return '"' .. val:gsub('[\\"\n\r\t]', self._jsonEscapes) .. '"'
    elseif t == "table" then
        -- Empty table: default to empty array (use val._isObject = true to force {})
        if next(val) == nil then
            return val._isObject and "{}" or "[]"
        end

        -- Detect array vs object
        local isArray = true
        local maxIdx = 0
        for k in pairs(val) do
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
                isArray = false
                break
            end
            if k > maxIdx then maxIdx = k end
        end
        if maxIdx ~= #val then isArray = false end

        local parts = {}
        if isArray then
            for _, v in ipairs(val) do
                table.insert(parts, self:ToJson(v))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                local key = type(k) == "string" and k or tostring(k)
                key = key:gsub('[\\"\n\r\t]', self._jsonEscapes)
                table.insert(parts, '"' .. key .. '":' .. self:ToJson(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

-- Sentinel for JSON null (Lua nil creates holes in arrays)
WGS.JSON_NULL = setmetatable({}, { __tostring = function() return "null" end })

-- JSON string → Lua table
function WGS:FromJson(str)
    if not str or str == "" then return nil end
    local pos = 1
    local len = #str

    local function skipWs()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parseValue -- forward declaration

    local function parseString()
        pos = pos + 1 -- skip opening "
        local parts = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == "\\" then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if esc == "n" then parts[#parts + 1] = "\n"
                elseif esc == "r" then parts[#parts + 1] = "\r"
                elseif esc == "t" then parts[#parts + 1] = "\t"
                elseif esc == '"' then parts[#parts + 1] = '"'
                elseif esc == "\\" then parts[#parts + 1] = "\\"
                elseif esc == "/" then parts[#parts + 1] = "/"
                elseif esc == "u" then
                    -- Skip unicode escape, replace with ?
                    pos = pos + 4
                    parts[#parts + 1] = "?"
                else
                    parts[#parts + 1] = esc
                end
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
        pos = pos + 1 -- skip [
        skipWs()
        local arr = {}
        if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while true do
            skipWs()
            arr[#arr + 1] = parseValue()
            skipWs()
            if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            pos = pos + 1 -- skip ,
        end
    end

    local function parseObject()
        pos = pos + 1 -- skip {
        skipWs()
        local obj = {}
        if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while true do
            skipWs()
            local key = parseString()
            skipWs()
            pos = pos + 1 -- skip :
            skipWs()
            obj[key] = parseValue()
            skipWs()
            if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            pos = pos + 1 -- skip ,
        end
    end

    parseValue = function()
        skipWs()
        local c = str:sub(pos, pos)
        if c == '"' then return parseString()
        elseif c == "{" then return parseObject()
        elseif c == "[" then return parseArray()
        elseif c == "t" then pos = pos + 4; return true
        elseif c == "f" then pos = pos + 5; return false
        elseif c == "n" then pos = pos + 4; return WGS.JSON_NULL
        else return parseNumber()
        end
    end

    local ok, result = pcall(parseValue)
    if ok then return result end
    return nil
end

---------------------------------------------------------------------------
-- Base64 utilities
---------------------------------------------------------------------------
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
-- Pre-built array lookup for encode (index 0..63 → character)
local b64encode = {}
for i = 1, 64 do b64encode[i - 1] = b64chars:sub(i, i) end
-- Pre-built decode lookup (character → 0..63)
local b64lookup = {}
for i = 1, 64 do b64lookup[b64chars:sub(i, i)] = i - 1 end

local floor = math.floor

function WGS:Base64Encode(data)
    local result = {}
    local n = 0
    local len = #data
    for i = 1, len, 3 do
        local a = data:byte(i)
        local b = (i + 1 <= len) and data:byte(i + 1) or 0
        local c = (i + 2 <= len) and data:byte(i + 2) or 0
        local val = a * 65536 + b * 256 + c

        n = n + 1; result[n] = b64encode[floor(val / 262144) % 64]
        n = n + 1; result[n] = b64encode[floor(val / 4096) % 64]
        n = n + 1; result[n] = (i + 1 <= len) and b64encode[floor(val / 64) % 64] or "="
        n = n + 1; result[n] = (i + 2 <= len) and b64encode[val % 64] or "="
    end
    return table.concat(result)
end

function WGS:Base64Decode(str)
    str = str:gsub("%s+", ""):gsub("=", "")
    local result = {}
    local n = 0
    local len = #str
    for i = 1, len, 4 do
        local a = b64lookup[str:sub(i, i)] or 0
        local b = (i + 1 <= len) and (b64lookup[str:sub(i + 1, i + 1)] or 0) or 0
        local c = (i + 2 <= len) and (b64lookup[str:sub(i + 2, i + 2)] or 0) or nil
        local d = (i + 3 <= len) and (b64lookup[str:sub(i + 3, i + 3)] or 0) or nil

        if c and d then
            local val = a * 262144 + b * 4096 + c * 64 + d
            n = n + 1; result[n] = string.char(floor(val / 65536) % 256)
            n = n + 1; result[n] = string.char(floor(val / 256) % 256)
            n = n + 1; result[n] = string.char(val % 256)
        elseif c then
            local val = a * 262144 + b * 4096 + c * 64
            n = n + 1; result[n] = string.char(floor(val / 65536) % 256)
            n = n + 1; result[n] = string.char(floor(val / 256) % 256)
        else
            local val = a * 262144 + b * 4096
            n = n + 1; result[n] = string.char(floor(val / 65536) % 256)
        end
    end
    return table.concat(result)
end

---------------------------------------------------------------------------

-- Build a lookup table of guild members: { ["CharName"] = { class, online, level, rank } }
-- Cached for 10 seconds to avoid iterating full roster on every UI refresh
local rosterCache = { data = nil, expiry = 0 }
function WGS:GetGuildRosterLookup()
    local now = time()
    if rosterCache.data and now < rosterCache.expiry then
        return rosterCache.data
    end

    local roster = {}
    if not IsInGuild() then return roster end

    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        local name, rankName, _, level, _, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
        if name then
            -- Strip realm suffix for matching
            local shortName = name:match("^([^%-]+)")
            roster[shortName] = {
                fullName = name,
                class = classFile or "",
                online = online or false,
                level = level or 0,
                rank = rankName or "",
            }
        end
    end
    rosterCache.data = roster
    rosterCache.expiry = now + 10
    return roster
end

-- WoW class colors for display
-- All WoW 12.0 Midnight class colors (matching Blizzard RAID_CLASS_COLORS)
WGS.CLASS_COLORS = {
    WARRIOR     = "ffc69b6d",
    PALADIN     = "fff48cba",
    HUNTER      = "ffaad372",
    ROGUE       = "fffff468",
    PRIEST      = "ffffffff",
    DEATHKNIGHT = "ffc41e3a",
    SHAMAN      = "ff0070dd",
    MAGE        = "ff3fc7eb",
    WARLOCK     = "ff8788ee",
    MONK        = "ff00ff98",
    DRUID       = "ffff7c0a",
    DEMONHUNTER = "ffa330c9",
    EVOKER      = "ff33937f",
}

-- List imported teams
function WGS:ListTeams()
    local teams = self.db.global.teams
    if not teams or #teams == 0 then
        self:Print("No teams imported. Use /wgs import to paste the export string from the web platform.")
        return
    end
    self:Print("--- Imported Teams ---")
    for i, team in ipairs(teams) do
        local memberCount = team.members and #team.members or 0
        self:Print(string.format("  %d. %s (%s) — %d members", team.id or i, team.name or "?", team.type or "?", memberCount))
        if team.members and #team.members > 0 then
            self:Print("     " .. table.concat(team.members, ", "))
        end
    end
end

-- Utility: check if current group is a guild group (majority are guildmates)
-- Cached for 5 seconds to avoid re-scanning on rapid loot events
local guildGroupCache = { result = nil, expiry = 0 }
function WGS:IsGuildGroup()
    local now = time()
    if guildGroupCache.result ~= nil and now < guildGroupCache.expiry then
        return guildGroupCache.result
    end

    if not IsInGuild() then guildGroupCache.result = false; guildGroupCache.expiry = now + 5; return false end
    local myGuild = GetGuildInfo("player")
    if not myGuild then guildGroupCache.result = false; guildGroupCache.expiry = now + 5; return false end

    local total = GetNumGroupMembers()
    if total <= 1 then return true end -- solo or just you, allow tracking

    local guildCount = 0
    local checkedCount = 0
    if IsInRaid() then
        for i = 1, total do
            local unit = "raid" .. i
            if UnitExists(unit) then
                checkedCount = checkedCount + 1
                local unitGuild = GetGuildInfo(unit)
                if unitGuild and unitGuild == myGuild then
                    guildCount = guildCount + 1
                end
            end
        end
    elseif IsInGroup() then
        -- Count self
        checkedCount = checkedCount + 1
        guildCount = guildCount + 1

        for i = 1, total - 1 do
            local unit = "party" .. i
            if UnitExists(unit) then
                checkedCount = checkedCount + 1
                local unitGuild = GetGuildInfo(unit)
                if unitGuild and unitGuild == myGuild then
                    guildCount = guildCount + 1
                end
            end
        end
    end

    -- If we couldn't check most members (loading screen etc.), assume guild group
    if checkedCount < total * 0.5 then return true end

    -- Guild group = at least half the group are guildmates
    local result = (guildCount / checkedCount) >= 0.5
    guildGroupCache.result = result
    guildGroupCache.expiry = now + 5
    return result
end

