local ADDON_NAME = "GuildHall"

---@type GuildHall
local WGS = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0")
local L = GuildHall_L

GuildHall = WGS
_G["GuildHall"] = WGS

-- Keep in lockstep with GuildHall.toc's `## Version: …`. Runtime code
-- reads WGS.version (minimap tooltip, "What's new" gate, server's
-- minAddonVersion check); the TOC field drives the packager + Wago
-- listing. Diverging the two was a real bug in past releases — the
-- TOC said 0.7.3 while runtime reported 0.7.0-beta.
WGS.version = "0.7.4-beta"

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
        -- Highest addon version this character has acknowledged the
        -- "What's new" dialog for. nil on fresh install (the dialog
        -- silently sets it without showing — we don't want to greet
        -- a brand-new user with legacy release notes). Bumped to
        -- WGS.version when the user clicks "Got it" on the modal.
        lastSeenVersion = nil,
        -- Global current-team filter. nil = "All Teams" (no filter).
        -- Otherwise a `team.id` from db.global.teams. Read by the main
        -- frame's title-bar picker + every team-scoped tab via
        -- WGS:GetCurrentTeamId(). Per-character so different officers
        -- can default to different teams.
        currentTeamId = nil,
    },
    global = {
        attendance = {},
        -- In-flight attendance session, mirrored from Modules/Attendance.lua's
        -- currentSession so /reload mid-raid doesn't drop captured state.
        -- StartAttendanceForTeam aliases the same Lua table here; mutations
        -- write through for free. StopAttendance clears it back to nil.
        activeSession = nil,
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
        characterIds = {},      -- { [characterName] = guild_members.id } from platform export
        characterLookup = {},   -- reverse: { [charName-realm] = playerId }
        gearAudit = {},
        characterDetails = {},  -- imported per-character info: { charName → { class, spec, ilvl, missingEnchants, missingGems } }
        signups = {},           -- imported event signups: [{eventId, characterName, class, status}]
        pendingSignupChanges = {}, -- queued officer mutations from WGS:UpdateSignupStatus; shipped via the next export
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

--- Print the standard "edit applied" confirmation that the correction
--- mutators (RetagLootRow, DeleteLootRow, RebindAttendanceSession,
--- RemoveMemberFromSession, DeleteAttendanceSession) emit after every
--- successful edit. Shared so the string stays consistent across
--- surfaces. The cross-officer edit-propagation work (per-row rev
--- counter + LWW merge) closed the "local-only" gap — edits now
--- broadcast through the same PeerSync channel as captures, so this
--- print is a confirmation rather than a limitation warning.
function WGS:PrintCorrectionHint()
    self:Print("Correction applied — propagating to other officers.")
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

function WGS:PLAYER_ENTERING_WORLD()
    -- Reserved for future per-character init. The "What's new" modal
    -- used to fire here on version bumps but auto-popping a modal on
    -- every login was intrusive — it now surfaces via a title-bar
    -- badge in the main frame (opt-in) and the /gh whatsnew slash.
    -- See UI/WhatsNew.lua.
end

-- Slash command dispatch. Each entry is a function(self, input) where
-- input is the raw rest-of-line so handlers that need sub-args can
-- call self:GetArgs(input, n) themselves. Aliases map alternate names
-- to the canonical handler key (the empty-string alias is what /gh
-- with no args resolves to). Adding a new command = append to the
-- table; no more elseif chain to grow.
--
-- Hidden commands (`interop`, `peerloopback`, `restore`) intentionally
-- aren't in L["SLASH_HELP"] — they're dev / recovery affordances. The
-- public help string only lists the user-facing surface.
local SLASH_HANDLERS = {
    show      = function(self) self:ToggleMainFrame() end,
    -- /gh export             → open the Sync tab (full export flow)
    -- /gh export <table>     → emit a selective export string for one
    --                          telemetry table only, popped into the
    --                          copy-via-EditBox dialog. Useful for the
    --                          "I just want to update the loot ledger,
    --                          not push every captured row" workflow
    --                          when the full export is large or
    --                          partially stale.
    export = function(self, input)
        local _, tableName = self:GetArgs(input, 2)
        if not tableName or tableName == "" then
            self:SelectMainFrameTab(self._ui.TAB_SYNC)
            return
        end
        self:ExportTableInteractive(tableName)
    end,
    config    = function(self) self:OpenConfig() end,
    teams     = function(self) self:SelectMainFrameTab(self._ui.TAB_TEAMS, self._ui.TEAMS_SUB_TEAMS) end,
    events    = function(self) self:SelectMainFrameTab(self._ui.TAB_EVENTS) end,
    invite    = function(self) self:AutoInvite() end,
    sortgroups= function(self) self:SortRaidGroups() end,
    loot      = function(self) self:SelectMainFrameTab(self._ui.TAB_LOGS, self._ui.LOGS_SUB_LOOT) end,
    wishlists = function(self) self:SelectMainFrameTab(self._ui.TAB_TEAMS, self._ui.TEAMS_SUB_WISHLISTS) end,
    rostercheck = function(self) self:SelectMainFrameTab(self._ui.TAB_TEAMS, self._ui.TEAMS_SUB_CHECK) end,
    bank      = function(self) self:SelectMainFrameTab(self._ui.TAB_LOGS, self._ui.LOGS_SUB_BANK) end,
    logs      = function(self) self:SelectMainFrameTab(self._ui.TAB_LOGS, self._ui.LOGS_SUB_LOOT) end,
    restore   = function(self) self:RestoreClearedData() end,
    whatsnew  = function(self) if self.ShowWhatsNew then self:ShowWhatsNew() end end,

    -- /gh sync / catchup — manual peer-sync catch-up. Useful when you
    -- join a raid late and the GROUP_ROSTER_UPDATE debounce hasn't
    -- fired yet, or when you suspect a peer's data drifted. Bypasses
    -- the 60s debounce so it always does something visible.
    sync = function(self) self:PeerSync_ManualCatchup() end,

    -- /gh interop — read-only MRT/NSRT integration diagnostic. Prints
    -- which addons are loaded, VMRT/NSRT global presence, gap-fill
    -- loot count, sessions with bossAttendance, MRT note size +
    -- which public API surface fetched it. Safe to run anywhere.
    interop = function(self) self:PrintInteropStatus() end,

    -- /gh diag — print a one-screen health-check of db.global. Row
    -- counts per telemetry table, last-import timestamp, addon
    -- version, current team filter. Useful for "is something off?"
    -- self-debugging without /dump-spelunking. Surfaces tables
    -- growing unusually large so an officer notices before it
    -- becomes a performance issue.
    diag = function(self) self:PrintDiagSummary() end,

    -- /gh search <name> — cross-context lookup. Walks loot,
    -- attendance, signups, teams, wishlists for any row mentioning
    -- the character (case-insensitive substring on short or full
    -- name). Useful for "where have I seen this player?" — replaces
    -- the four-different-tabs-and-eyeballing flow with one chat
    -- dump.
    search = function(self, input)
        local _, query = self:GetArgs(input, 2)
        if not query or query == "" then
            self:Print("Usage: |cffffd100/gh search <character-name>|r")
            return
        end
        self:PrintSearchResults(query)
    end,

    -- /gh peerloopback — dev-only PeerSync loopback toggle. Every
    -- broadcast self-delivers so the full encode → decode → merge →
    -- catch-up round-trip can be tested from a single client. No
    -- outbound broadcasts go anywhere they wouldn't have gone anyway
    -- — this just enables self-delivery on top.
    peerloopback = function(self)
        self.db.profile.peerSyncLoopback = not self.db.profile.peerSyncLoopback
        self:Print("PeerSync loopback: " ..
            (self.db.profile.peerSyncLoopback
                and "|cff00ff00on|r — broadcasts self-deliver for dev testing"
                or  "|cff888888off|r"))
    end,

    -- /gh attendance              → live status + open the log
    -- /gh attendance reconcile    → retro-fill missing eventIds
    attendance = function(self, input)
        local _, sub = self:GetArgs(input, 2)
        if sub == "reconcile" then
            self:ReconcileAttendanceEventBindings()
            return
        end
        self:AttendanceStatus()
        self:SelectMainFrameTab(self._ui.TAB_LOGS, self._ui.LOGS_SUB_ATTENDANCE)
    end,

    -- /gh bossnotes <name> — open the Events tab pre-selected to the
    -- named boss. With no name, prints usage.
    bossnotes = function(self, input)
        local _, bossName = self:GetArgs(input, 2)
        if bossName and bossName ~= "" then
            self:ShowBossNotes(bossName)
        else
            self:Print("Usage: /gh bossnotes <boss name>")
        end
    end,

    -- /gh team <name>   → set current-team filter by name (case-insensitive substring)
    -- /gh team all      → clear the filter (show all teams)
    -- /gh team          → print current state
    team = function(self, input)
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
    end,
}

local SLASH_ALIASES = {
    [""]         = "show",
    import       = "export",
    options      = "config",
    bn           = "bossnotes",
    autoinvite   = "invite",
    sort         = "sortgroups",
    wishlist     = "wishlists",
    wl           = "wishlists",
    check        = "rostercheck",
    catchup      = "sync",
}

function WGS:SlashCommand(input)
    local cmd = (self:GetArgs(input, 1) or ""):lower()
    cmd = SLASH_ALIASES[cmd] or cmd
    local handler = SLASH_HANDLERS[cmd]
    if handler then
        handler(self, input)
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

---------------------------------------------------------------------------
-- /gh diag — db.global health summary
---------------------------------------------------------------------------
--
-- One-screen sanity check: addon version + interface, last-import
-- recency, current team filter, and row counts for every telemetry /
-- imported table on db.global. Useful for "is something off?" self-
-- debugging without /dump-spelunking, and for surfacing a table
-- growing unusually large so the officer notices before it becomes
-- a performance problem.

local DIAG_LARGE_THRESHOLDS = {
    loot                  = 10000,
    attendance            = 5000,
    raidCompResults       = 5000,
    encounters            = 5000,
    guildBankTransactions = 20000,
    guildBankMoneyChanges = 20000,
}

local function formatRowCount(name, val)
    if type(val) ~= "table" then return "n/a" end
    local n = 0
    if val[1] ~= nil then
        n = #val
    else
        for _ in pairs(val) do n = n + 1 end
    end
    local warn = DIAG_LARGE_THRESHOLDS[name] and n >= DIAG_LARGE_THRESHOLDS[name]
    if warn then
        return string.format("|cffffaa00%d|r (large — consider /gh clear)", n)
    end
    return tostring(n)
end

local function formatAgo(ts)
    if not ts or ts <= 0 then return "never" end
    local delta = (time() or 0) - ts
    if delta < 60 then return delta .. "s ago" end
    if delta < 3600 then return math.floor(delta / 60) .. "m ago" end
    if delta < 86400 then return math.floor(delta / 3600) .. "h ago" end
    return math.floor(delta / 86400) .. "d ago"
end

function WGS:PrintDiagSummary()
    local g = self.db and self.db.global or {}
    self:Print("|cffffd100=== GuildHall diag ===|r")
    self:Print(string.format("Version: %s   |cff888888(see /gh whatsnew)|r", self.version))
    self:Print(string.format("Last import: %s   Last export: %s",
        formatAgo(g.lastImport), formatAgo(g.lastExport)))

    local currentTeam = self.GetCurrentTeamId and self:GetCurrentTeamId() or nil
    local teamLabel = "All Teams"
    if currentTeam then
        teamLabel = "team " .. tostring(currentTeam)
        for _, t in ipairs(g.teams or {}) do
            if t.id == currentTeam then teamLabel = t.name or teamLabel; break end
        end
    end
    self:Print("Current-team filter: " .. teamLabel)

    -- Telemetry / capture tables (officer cares: do these have data?
    -- are any growing unusually large?)
    self:Print("|cffaaaaaa-- telemetry --|r")
    local TELEMETRY = {
        "loot", "attendance", "raidCompResults", "encounters",
        "guildBankTransactions", "guildBankMoneyChanges",
    }
    for _, name in ipairs(TELEMETRY) do
        self:Print(string.format("  %s: %s", name, formatRowCount(name, g[name])))
    end

    -- Imported-from-platform tables (officer cares: did the import
    -- come through? are there obvious empties from a partial paste?)
    self:Print("|cffaaaaaa-- imported --|r")
    local IMPORTED = {
        "events", "teams", "signups", "wishlists", "bossNotes",
        "raidComps", "characters", "characterIds", "gearAudit",
        "characterDetails",
    }
    for _, name in ipairs(IMPORTED) do
        self:Print(string.format("  %s: %s", name, formatRowCount(name, g[name])))
    end

    if g.activeSession then
        self:Print("|cffaaaaaa-- in flight --|r")
        self:Print(string.format("  activeSession: started %s ago (team=%s, event=%s)",
            formatAgo(g.activeSession.startedAt),
            tostring(g.activeSession.teamName or g.activeSession.teamId),
            tostring(g.activeSession.eventTitle or g.activeSession.eventId or "untagged")))
    end
end

---------------------------------------------------------------------------
-- /gh search — cross-context character lookup
---------------------------------------------------------------------------
--
-- Returns counts (and a few sample rows where useful) across every
-- db.global table that references a character by name. Matches case-
-- insensitively against either the short name (post-realm-strip) or
-- the full Name-Realm form, so users can search "foo" and find both
-- "Foo-EU" rows and "Foo-Realm" rows.

local function shortLower(name)
    if not name or name == "" then return "" end
    return ((name):match("^([^%-]+)") or name):lower()
end

local function nameMatches(needle, value)
    if not value or value == "" then return false end
    return shortLower(value):find(needle, 1, true) ~= nil
        or value:lower():find(needle, 1, true) ~= nil
end

function WGS:PrintSearchResults(query)
    local needle = (query or ""):lower()
    if needle == "" then return end

    local g = self.db and self.db.global or {}
    self:Print(string.format("|cffffd100/gh search '%s'|r", query))

    -- Loot
    local lootHits, latestLoot = 0, nil
    for _, row in ipairs(g.loot or {}) do
        if nameMatches(needle, row.player) then
            lootHits = lootHits + 1
            if not latestLoot or (row.timestamp or 0) > (latestLoot.timestamp or 0) then
                latestLoot = row
            end
        end
    end
    if lootHits > 0 then
        local last = latestLoot and string.format("latest: %s (%s)",
            latestLoot.itemName or "?",
            date("%m/%d", latestLoot.timestamp or 0)) or ""
        self:Print(string.format("  Loot:        %d row%s   %s",
            lootHits, lootHits == 1 and "" or "s", last))
    end

    -- Attendance
    local attendHits = 0
    for _, session in ipairs(g.attendance or {}) do
        for _, m in ipairs(session.memberList or {}) do
            if nameMatches(needle, m.name) then
                attendHits = attendHits + 1; break
            end
        end
    end
    if attendHits > 0 then
        self:Print(string.format("  Attendance:  %d session%s",
            attendHits, attendHits == 1 and "" or "s"))
    end

    -- Signups
    local signupHits = {}
    for _, s in ipairs(g.signups or {}) do
        if nameMatches(needle, s.characterName) then
            signupHits[#signupHits + 1] = s
        end
    end
    if #signupHits > 0 then
        local labels = {}
        for _, s in ipairs(signupHits) do
            labels[s.status or "?"] = (labels[s.status or "?"] or 0) + 1
        end
        local parts = {}
        for status, n in pairs(labels) do
            parts[#parts + 1] = n .. "x " .. status
        end
        self:Print(string.format("  Signups:     %d   (%s)",
            #signupHits, table.concat(parts, ", ")))
    end

    -- Teams (membership)
    local teamHits = {}
    for _, t in ipairs(g.teams or {}) do
        for _, member in ipairs(t.members or {}) do
            if nameMatches(needle, member) then
                teamHits[#teamHits + 1] = t.name or "?"
                break
            end
        end
        if t.playerMembers then
            for _, pm in ipairs(t.playerMembers) do
                if nameMatches(needle, pm.main) then
                    teamHits[#teamHits + 1] = (t.name or "?") .. " (linked)"
                    break
                end
            end
        end
    end
    if #teamHits > 0 then
        self:Print(string.format("  Teams:       %s", table.concat(teamHits, ", ")))
    end

    -- Wishlists
    local wishHits = 0
    local wl = g.wishlists or {}
    -- Wishlists can be keyed by playerName → list[] OR a flat array
    -- with playerName field. Handle both shapes.
    if wl[1] ~= nil then
        for _, w in ipairs(wl) do
            if nameMatches(needle, w.playerName) then wishHits = wishHits + 1 end
        end
    else
        for playerName, items in pairs(wl) do
            if nameMatches(needle, playerName) and type(items) == "table" then
                wishHits = wishHits + #items
            end
        end
    end
    if wishHits > 0 then
        self:Print(string.format("  Wishlist:    %d item%s",
            wishHits, wishHits == 1 and "" or "s"))
    end

    if lootHits == 0 and attendHits == 0 and #signupHits == 0
       and #teamHits == 0 and wishHits == 0 then
        self:Print("  |cff888888no matches|r")
    end
end

