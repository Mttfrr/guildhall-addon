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
        showBossNotes = true,
        -- nil = "use officer default" (on for officers, off otherwise).
        -- Explicit true/false from the user takes precedence.
        peerSyncEnabled = nil,
        -- Dev-only: when true, every PeerSync broadcast is also re-fed
        -- through the local dispatch path so the encode → decode →
        -- merge round-trip can be exercised from a single client (no
        -- second officer required). See WGS:PeerSync_Broadcast for the
        -- loopback hook + `/gh peerloopback` to toggle.
        peerSyncLoopback = false,
        -- Global current-team filter. nil = "All Teams" (no filter).
        -- Otherwise a `team.id` from db.global.teams. Read by the main
        -- frame's title-bar picker + every team-scoped tab via
        -- WGS:GetCurrentTeamId(). Per-character so different officers
        -- can default to different teams.
        currentTeamId = nil,
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
        -- /gh attendance              → status + open log
        -- /gh attendance reconcile    → retro-fill missing eventIds
        local _, sub = self:GetArgs(input, 2)
        if sub == "reconcile" then
            self:ReconcileAttendanceEventBindings()
            return
        end
        -- Capture is auto-started on raid entry now. `/gh attendance`
        -- prints the live status (whether we're recording, which
        -- team/event) AND opens the Logs → Attendance log so the
        -- officer can scan past sessions. Print + show together avoids
        -- a separate "/gh attendance log" alias.
        self:AttendanceStatus()
        self:SelectMainFrameTab(ui.TAB_LOGS, ui.LOGS_SUB_ATTENDANCE)
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
    elseif cmd == "invite" or cmd == "autoinvite" then
        self:AutoInvite()
    elseif cmd == "sortgroups" or cmd == "sort" then
        self:SortRaidGroups()
    elseif cmd == "loot" then
        self:SelectMainFrameTab(ui.TAB_LOGS, ui.LOGS_SUB_LOOT)
    elseif cmd == "wishlists" or cmd == "wishlist" or cmd == "wl" then
        self:SelectMainFrameTab(ui.TAB_TEAMS, ui.TEAMS_SUB_WISHLISTS)
    elseif cmd == "rostercheck" or cmd == "check" then
        self:SelectMainFrameTab(ui.TAB_TEAMS, ui.TEAMS_SUB_CHECK)
    elseif cmd == "bank" then
        self:SelectMainFrameTab(ui.TAB_LOGS, ui.LOGS_SUB_BANK)
    elseif cmd == "logs" then
        self:SelectMainFrameTab(ui.TAB_LOGS, ui.LOGS_SUB_LOOT)
    elseif cmd == "sync" or cmd == "catchup" then
        -- Manual catch-up. Useful when you join a raid late and the
        -- automatic GROUP_ROSTER_UPDATE debounce hasn't fired yet, or
        -- when you suspect a peer's data drifted. Bypasses the 60s
        -- debounce so it always does something visible.
        self:PeerSync_ManualCatchup()
    elseif cmd == "peerloopback" then
        -- Dev-only: toggle PeerSync loopback. Every broadcast is also
        -- re-fed through our own dispatch path so the full encode →
        -- decode → merge → catch-up round-trip can be exercised from
        -- a single client. No outbound broadcasts go to anyone else
        -- that they wouldn't have gone to anyway — this just enables
        -- self-delivery on top. Useful for verifying peer-sync work
        -- without bothering other officers with test traffic.
        self.db.profile.peerSyncLoopback = not self.db.profile.peerSyncLoopback
        self:Print("PeerSync loopback: " ..
            (self.db.profile.peerSyncLoopback
                and "|cff00ff00on|r — broadcasts self-deliver for dev testing"
                or  "|cff888888off|r"))
    elseif cmd == "restore" then
        self:RestoreClearedData()
    elseif cmd == "interop" then
        -- Print MRT/NSRT integration status: which addons are loaded,
        -- whether VMRT/NSRT globals are populated, how many loot rows
        -- came from the MRT gap-fill, how many sessions have
        -- bossAttendance attached, and the MRT note size + which
        -- public API surface fetched it. Read-only diagnostic; safe
        -- to run anywhere.
        self:PrintInteropStatus()
    elseif cmd == "team" then
        -- /gh team <name>   → set current-team picker by name (case-
        --                     insensitive substring match)
        -- /gh team all      → clear the filter (show all teams)
        -- /gh team          → print current state
        local _, arg = self:GetArgs(input, 2)
        if not arg or arg == "" then
            local id = self:GetCurrentTeamId()
            if id then
                local teams = self.db.global.teams or {}
                for _, t in ipairs(teams) do
                    if t.id == id then
                        self:Print("Current team filter: " .. (t.name or tostring(id)))
                        return
                    end
                end
                self:Print("Current team filter: (team id " .. tostring(id) .. " — no longer in db)")
            else
                self:Print("Current team filter: All Teams")
            end
            return
        end
        if arg:lower() == "all" or arg:lower() == "none" or arg:lower() == "clear" then
            self:SetCurrentTeamId(nil)
            self:Print("Team filter cleared (showing all teams).")
            return
        end
        local needle = arg:lower()
        local teams = self.db.global.teams or {}
        for _, t in ipairs(teams) do
            local n = (t.name or ""):lower()
            if n == needle or n:find(needle, 1, true) then
                self:SetCurrentTeamId(t.id)
                self:Print("Team filter set to: " .. (t.name or tostring(t.id)))
                return
            end
        end
        self:Print("No team matching: " .. arg)
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
-- Current-team picker
--
-- Global filter id that scopes team-aware UI surfaces (Events rail,
-- Teams tab, Logs sub-views) to a single team. nil = "All Teams" / no
-- filter. Persisted to db.profile.currentTeamId.
--
-- Get coerces orphan ids back to nil — if the picked team is no longer
-- in db.global.teams (re-import removed it) the filter would otherwise
-- silently hide every row.
--
-- Set fires WGS_CURRENT_TEAM_CHANGED { teamId } so UI surfaces re-render.
---------------------------------------------------------------------------

function WGS:GetCurrentTeamId()
    if not self.db or not self.db.profile then return nil end
    local id = self.db.profile.currentTeamId
    if id == nil then return nil end
    local teams = self.db.global and self.db.global.teams or {}
    for _, t in ipairs(teams) do
        if t.id == id then return id end
    end
    return nil
end

function WGS:SetCurrentTeamId(teamId)
    if not self.db or not self.db.profile then return end
    if self.db.profile.currentTeamId == teamId then return end
    self.db.profile.currentTeamId = teamId
    self:FireEvent("WGS_CURRENT_TEAM_CHANGED", { teamId = teamId })
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

