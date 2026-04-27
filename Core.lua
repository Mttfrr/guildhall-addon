local ADDON_NAME = "GuildHall"

---@type GuildHall
local WGS = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0")
local L = GuildHall_L

GuildHall = WGS
_G["GuildHall"] = WGS

WGS.version = "0.6.0-beta"

local dbDefaults = {
    profile = {
        minimap = { hide = false },
        autoTrackAttendance = true,
        autoTrackLoot = true,
        guildGroupsOnly = true,
        guildWebId = "",
        showLootDistHelper = true,
        showReadinessCheck = true,
        showBossNotes = true,
        showWebMOTD = true,
    },
    global = {
        attendance = {},
        loot = {},
        guildBankMoneyChanges = {},
        guildBankTransactions = {},
        encounters = {},
        raidCompResults = {},  -- snapshots of actual raid groups at end of session
        lastKnownGold = nil,
        teams = {},
        wishlists = {},
        bossNotes = {},
        raidComps = {},
        events = {},
        characters = {},        -- { [playerId] = { displayName, main, alts } }
        characterLookup = {},   -- reverse: { [charName-realm] = playerId }
        gearAudit = {},
        targetIlvl = 0,
        webMOTD = "",
        lastExport = 0,
        lastImport = 0,
        exportHistory = {},
    },
}

function WGS:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("GuildHallDB", dbDefaults, true)
    self:RegisterChatCommand("gh", "SlashCommand")
    self:RegisterChatCommand("guildhall", "SlashCommand")
    self:SetupConfig()
    self:SetupMinimapIcon()
    self:Print("GuildHall v" .. self.version .. " loaded. Type /gh help for commands.")
end

function WGS:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:SetupTooltipHooks()
end

function WGS:OnDisable() end

function WGS:PLAYER_ENTERING_WORLD() end

function WGS:SlashCommand(input)
    local cmd = self:GetArgs(input, 1)
    cmd = (cmd or ""):lower()

    if cmd == "show" or cmd == "" then
        self:ToggleMainFrame()
    elseif cmd == "export" then
        self:SelectMainFrameTab(5)
    elseif cmd == "import" then
        self:SelectMainFrameTab(5)
    elseif cmd == "attendance" then
        self:ToggleAttendance()
        self:RefreshMainFrame()
    elseif cmd == "config" or cmd == "options" then
        self:OpenConfig()
    elseif cmd == "teams" then
        self:SelectMainFrameTab(2, 1)
    elseif cmd == "bossnotes" or cmd == "bn" then
        local _, bossName = self:GetArgs(input, 2)
        if bossName and bossName ~= "" then
            self:ShowBossNotes(bossName)
        else
            self:Print("Usage: /gh bossnotes <boss name>")
        end
    elseif cmd == "events" then
        self:SelectMainFrameTab(3, 3)
    elseif cmd == "readiness" or cmd == "ready" then
        self:SelectMainFrameTab(3, 2)
    elseif cmd == "invite" or cmd == "autoinvite" then
        self:AutoInvite()
    elseif cmd == "sortgroups" or cmd == "sort" then
        self:SortRaidGroups()
    elseif cmd == "loot" then
        self:SelectMainFrameTab(4, 1)
    elseif cmd == "wishlists" or cmd == "wishlist" or cmd == "wl" then
        self:SelectMainFrameTab(4, 2)
    elseif cmd == "rostercheck" or cmd == "check" then
        self:SelectMainFrameTab(2, 2)
    else
        self:Print(L["SLASH_HELP"])
    end
end

function GuildHall_OnAddonCompartmentClick()
    WGS:ToggleMainFrame()
end

---------------------------------------------------------------------------
-- Player identity
---------------------------------------------------------------------------

local cachedPlayerKey
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

function WGS:GetTimestamp()
    return time()
end

--- Reverse lookup: CharName-Realm → playerId. Rebuilt on each import.
function WGS:BuildCharacterLookup()
    local lookup = {}
    local chars = self.db.global.characters
    if chars then
        for pid, info in pairs(chars) do
            if info.main then lookup[info.main] = pid end
            if info.alts then
                for _, alt in ipairs(info.alts) do lookup[alt] = pid end
            end
        end
    end
    self.db.global.characterLookup = lookup
    return lookup
end

--- O(1) character → player resolution via cached lookup.
function WGS:ResolvePlayerForCharacter(charName)
    if not charName then return nil, nil end
    local lookup = self.db.global.characterLookup
    if not lookup then return nil, nil end
    local pid = lookup[charName]
    if not pid then return nil, nil end
    return pid, self.db.global.characters[pid]
end

---------------------------------------------------------------------------
-- JSON
---------------------------------------------------------------------------

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
    return ok and result or nil
end

---------------------------------------------------------------------------
-- Base64
---------------------------------------------------------------------------

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

---------------------------------------------------------------------------
-- Guild roster
---------------------------------------------------------------------------

local rosterCache = { data = nil, expiry = 0 }

function WGS:GetGuildRosterLookup()
    local now = time()
    if rosterCache.data and now < rosterCache.expiry then return rosterCache.data end

    local roster = {}
    if not IsInGuild() then return roster end

    for i = 1, GetNumGuildMembers() do
        local name, rankName, _, level, _, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
        if name then
            local short = name:match("^([^%-]+)")
            roster[short] = {
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

---------------------------------------------------------------------------
-- Class colors (Blizzard RAID_CLASS_COLORS hex values)
---------------------------------------------------------------------------

WGS.CLASS_COLORS = {
    WARRIOR     = "ffc69b6d", PALADIN     = "fff48cba",
    HUNTER      = "ffaad372", ROGUE       = "fffff468",
    PRIEST      = "ffffffff", DEATHKNIGHT = "ffc41e3a",
    SHAMAN      = "ff0070dd", MAGE        = "ff3fc7eb",
    WARLOCK     = "ff8788ee", MONK        = "ff00ff98",
    DRUID       = "ffff7c0a", DEMONHUNTER = "ffa330c9",
    EVOKER      = "ff33937f",
}

---------------------------------------------------------------------------
-- Teams
---------------------------------------------------------------------------

function WGS:ListTeams()
    local teams = self.db.global.teams
    if not teams or #teams == 0 then
        self:Print("No teams imported. Use /gh import.")
        return
    end

    local chars = self.db.global.characters or {}
    self:Print("--- Imported Teams ---")
    for i, team in ipairs(teams) do
        local count = team.playerMembers and #team.playerMembers or (team.members and #team.members or 0)
        self:Print(string.format("  %d. %s (%s) — %d members", team.id or i, team.name or "?", team.type or "?", count))

        if team.playerMembers then
            for _, pm in ipairs(team.playerMembers) do
                local info = chars[pm.playerId]
                local main = (pm.main or ""):match("^([^%-]+)") or "?"
                local nAlts = info and info.alts and #info.alts or 0
                self:Print("     " .. main .. (nAlts > 0 and (" (+" .. nAlts .. " alts)") or ""))
            end
        elseif team.members and #team.members > 0 then
            self:Print("     " .. table.concat(team.members, ", "))
        end
    end
end

---------------------------------------------------------------------------
-- Guild group check (>=80% guildmates required, cached 5s)
---------------------------------------------------------------------------

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
    if total <= 1 then return true end

    local guildCount, checked = 0, 0
    if IsInRaid() then
        for i = 1, total do
            local unit = "raid" .. i
            if UnitExists(unit) then
                checked = checked + 1
                if GetGuildInfo(unit) == myGuild then guildCount = guildCount + 1 end
            end
        end
    elseif IsInGroup() then
        checked, guildCount = 1, 1
        for i = 1, total - 1 do
            local unit = "party" .. i
            if UnitExists(unit) then
                checked = checked + 1
                if GetGuildInfo(unit) == myGuild then guildCount = guildCount + 1 end
            end
        end
    end

    if checked < total * 0.5 then
        guildGroupCache.result = false
        guildGroupCache.expiry = now + 5
        return false
    end

    local result = (guildCount / checked) >= 0.8
    guildGroupCache.result = result
    guildGroupCache.expiry = now + 5
    return result
end
