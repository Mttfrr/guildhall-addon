local ADDON_NAME = "GuildHall"

---@type GuildHall
local WGS = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0")
local L = GuildHall_L

GuildHall = WGS
_G["GuildHall"] = WGS

WGS.version = "0.7.0-beta"

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
        characterDetails = {},  -- imported per-character info: { charName → { class, spec, ilvl, missingEnchants, missingGems } }
        signups = {},           -- imported event signups: [{eventId, characterName, class, status}]
        targetIlvl = 0,
        webMOTD = "",
        lastExport = 0,
        lastImport = 0,
        exportHistory = {},
        serverMinAddonVersion = nil,  -- captured from the web's export response on import
        lastClearSnapshot = { t = 0 }, -- 24h recoverable backup of cleared exported data
    },
}

function WGS:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("GuildHallDB", dbDefaults, true)
    -- Public event bus. Other addons (or our own future MRT/NSRT bridge
    -- modules) subscribe via `GuildHall.RegisterCallback(handlerSelf,
    -- eventName, methodOrFn)`. New(self) installs Register/Unregister
    -- methods on us and returns the registry whose :Fire(event, ...)
    -- dispatches to subscribers. The set of events we emit is documented
    -- in docs/EVENTS.md — keep this list and that file in sync.
    self.callbacks = LibStub("CallbackHandler-1.0"):New(self)
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

--- Internal: fire a public event on the callback registry. Tolerant of
--- being called before OnInitialize has wired callbacks up (load-order
--- corner cases during early bootstrap). Modules use this instead of
--- poking self.callbacks directly so the registry can be swapped or
--- profiled in one place later.
function WGS:FireEvent(event, ...)
    if self.callbacks and self.callbacks.Fire then
        self.callbacks:Fire(event, ...)
    end
end

function WGS:OnDisable() end

function WGS:PLAYER_ENTERING_WORLD() end

function WGS:SlashCommand(input)
    local cmd = self:GetArgs(input, 1)
    cmd = (cmd or ""):lower()

    local ui = self._ui
    if cmd == "show" or cmd == "" then
        self:ToggleMainFrame()
    elseif cmd == "export" or cmd == "import" then
        self:SelectMainFrameTab(ui.TAB_SYNC)
    elseif cmd == "attendance" then
        -- Capture is auto-started on raid entry now; /gh attendance is
        -- a status read-out only.
        self:AttendanceStatus()
    elseif cmd == "config" or cmd == "options" then
        self:OpenConfig()
    elseif cmd == "teams" then
        self:SelectMainFrameTab(ui.TAB_TEAMS, ui.TEAMS_SUB_TEAMS)
    elseif cmd == "bossnotes" or cmd == "bn" then
        local _, bossName = self:GetArgs(input, 2)
        if bossName and bossName ~= "" then
            self:ShowBossNotes(bossName)
        else
            self:Print("Usage: /gh bossnotes <boss name>")
        end
    elseif cmd == "events" then
        self:SelectMainFrameTab(ui.TAB_EVENTS)
    elseif cmd == "readiness" or cmd == "ready" then
        self:SelectMainFrameTab(ui.TAB_RAIDS, ui.RAIDS_SUB_READINESS)
    elseif cmd == "invite" or cmd == "autoinvite" then
        self:AutoInvite()
    elseif cmd == "sortgroups" or cmd == "sort" then
        self:SortRaidGroups()
    elseif cmd == "loot" then
        self:SelectMainFrameTab(ui.TAB_RAIDS, ui.RAIDS_SUB_LOOT)
    elseif cmd == "wishlists" or cmd == "wishlist" or cmd == "wl" then
        self:SelectMainFrameTab(ui.TAB_TEAMS, ui.TEAMS_SUB_WISHLISTS)
    elseif cmd == "rostercheck" or cmd == "check" then
        self:SelectMainFrameTab(ui.TAB_TEAMS, ui.TEAMS_SUB_CHECK)
    elseif cmd == "bank" then
        self:SelectMainFrameTab(ui.TAB_BANK)
    elseif cmd == "restore" then
        self:RestoreClearedData()
    else
        self:Print(L["SLASH_HELP"])
    end
end

function GuildHall_OnAddonCompartmentClick()
    WGS:ToggleMainFrame()
end

-- JSON / Base64 / djb2 hash live in Util/JSON.lua + Util/Base64.lua.
-- Identity helpers (GetPlayerKey, GetTimestamp) live in Util/Time.lua.
-- Roster / character / guild-group helpers live in Util/Roster.lua.

-- Compare two semver-ish strings ("0.6.0", "0.6.0-beta"). Pre-release
-- suffixes are stripped so "0.6.0-beta" == "0.6.0", matching the server's
-- compareVersions in server/routes/addonSync.js. Returns -1 / 0 / 1.
function WGS:CompareVersions(a, b)
    local function parts(v)
        v = (v or ""):gsub("%-.*$", "")
        local t = {}
        for n in v:gmatch("(%d+)") do t[#t + 1] = tonumber(n) or 0 end
        return t
    end
    local pa, pb = parts(a), parts(b)
    local n = math.max(#pa, #pb)
    for i = 1, n do
        local na, nb = pa[i] or 0, pb[i] or 0
        if na > nb then return 1 end
        if na < nb then return -1 end
    end
    return 0
end

-- True iff the running addon is older than the server's MIN_ADDON_VERSION
-- (captured into db.global.serverMinAddonVersion on the last import).
function WGS:IsOutdated()
    local required = self.db and self.db.global and self.db.global.serverMinAddonVersion
    if not required or required == "" then return false end
    return self:CompareVersions(self.version, required) < 0
end

---------------------------------------------------------------------------
-- Exported-data clear safety net
--
-- "Clear exported data" wipes loot/attendance/encounters/bank into the
-- void. If the user pasted into the wrong web tab — or thought they did
-- but the string was truncated — that data is irrecoverable. We keep one
-- snapshot on disk for 24h so the user has an undo, via `/gh restore`.
---------------------------------------------------------------------------

WGS.CLEAR_SNAPSHOT_TTL = 24 * 60 * 60

local SNAPSHOTTED_KEYS = {
    "loot", "attendance", "encounters", "raidCompResults",
    "guildBankMoneyChanges", "guildBankTransactions",
}

function WGS:SnapshotExportedData()
    local db = self.db.global
    local snap = { t = self:GetTimestamp() }
    for _, k in ipairs(SNAPSHOTTED_KEYS) do
        snap[k] = db[k] or {}
    end
    db.lastClearSnapshot = snap
end

function WGS:HasRestorableSnapshot()
    local snap = self.db and self.db.global and self.db.global.lastClearSnapshot
    if not snap or not snap.t or snap.t == 0 then return false end
    return (self:GetTimestamp() - snap.t) <= self.CLEAR_SNAPSHOT_TTL
end

function WGS:RestoreClearedData()
    local db = self.db.global
    local snap = db.lastClearSnapshot
    if not snap or not snap.t or snap.t == 0 then
        self:Print("No snapshot available to restore.")
        return false
    end
    local age = self:GetTimestamp() - snap.t
    if age > self.CLEAR_SNAPSHOT_TTL then
        self:Print(string.format("Snapshot expired (%.1fh old; TTL is 24h).", age / 3600))
        return false
    end
    for _, k in ipairs(SNAPSHOTTED_KEYS) do
        db[k] = snap[k] or {}
    end
    self:Print(string.format("Restored data cleared %d minute(s) ago.", math.max(1, math.floor(age / 60))))
    if self.RefreshMainFrame then self:RefreshMainFrame() end
    return true
end

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

