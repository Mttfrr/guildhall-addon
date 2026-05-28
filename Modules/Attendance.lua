---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

---@class WGSAttendanceModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("Attendance", "AceEvent-3.0")

local isTracking = false
local currentSession = nil

-- Maximum age (seconds) for a stashed activeSession to be rehydrated on
-- addon load. Anything older is treated as orphan — the user almost
-- certainly logged off mid-raid and only came back the next day, so
-- resurrecting it would produce a session that looks "live" but with
-- no meaningful endedAt. 8h covers the longest realistic raid window
-- (heroic clears that drag past midnight) without holding onto stale
-- state across days.
local SESSION_REHYDRATE_MAX_AGE = 8 * 60 * 60

-- Rehydrate an in-flight session from db.global.activeSession after
-- an addon load (/reload, /logout-login, fresh game session). Without
-- this, every /reload mid-raid abandoned the session — currentSession
-- was a module-local that reset to nil on load, while finalized rows
-- only land in db.global.attendance via StopAttendance. So a /reload
-- between Start and Stop dropped everything captured up to that point
-- on the floor.
--
-- StartAttendanceForTeam aliases db.global.activeSession to the same
-- table as currentSession (Lua reference semantics), so every
-- subsequent mutation to currentSession.members / .endedAt / etc.
-- writes through to SavedVariables for free — no per-mutation persist
-- call needed. StopAttendance clears db.global.activeSession back to
-- nil so a /reload AFTER stop doesn't resurrect the finalized session.
local function rehydrateActiveSession()
    local stored = WGS.db and WGS.db.global and WGS.db.global.activeSession
    if not stored then return end
    local now = WGS:GetTimestamp()
    if (now - (tonumber(stored.startedAt) or 0)) > SESSION_REHYDRATE_MAX_AGE then
        WGS.db.global.activeSession = nil   -- orphan, drop quietly
        return
    end
    currentSession = stored
    isTracking = true
    local tag = currentSession.teamName or "untagged"
    if currentSession.eventTitle and currentSession.eventTitle ~= "" then
        tag = tag .. " \194\183 " .. currentSession.eventTitle
    end
    WGS:Print("Resumed attendance tracking: " .. tag .. " (carried over from before /reload)")
end
WGS._AttendanceRehydrate = rehydrateActiveSession   -- exposed for tests

function module:OnEnable()
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnGroupRosterUpdate")
    self:RegisterEvent("RAID_INSTANCE_WELCOME", "OnRaidEnter")
    self:RegisterEvent("GROUP_LEFT", "OnGroupLeft")
    rehydrateActiveSession()
end

function module:OnGroupLeft()
    if not isTracking then return end
    -- Player left the raid — auto-stop attendance and prompt export
    WGS:StopAttendance()
    WGS:ShowExportReminder()
end

function module:OnRaidEnter()
    if not IsInRaid() then return end

    if not WGS.db.profile.autoTrackAttendance then return end
    if isTracking then return end
    if WGS.db.profile.guildGroupsOnly and not WGS:IsGuildGroup() then return end

    -- Silent: no modal, no HUD — the addon should be invisible at this
    -- point. Auto-tag the session from the matching scheduled event,
    -- or start untagged if none / ambiguous.
    WGS:StartAttendanceAutoTagged()
end

-- Resolve the team from the currently-scheduled event and start a
-- session. Used by the auto-start RAID_INSTANCE_WELCOME path AND by
-- the manual button in Logs → Attendance + the minimap shift-click.
-- Falls back to untagged when no scheduled event matches.
function WGS:StartAttendanceAutoTagged()
    local event = self:FindActiveScheduledEvent()
    local teamId, teamName = nil, nil
    if event then
        teamId = event.team_id or event.teamId
        teamName = self:GetTeamName(teamId)
    end
    self:StartAttendanceForTeam(teamId, teamName, event)
end

function module:OnGroupRosterUpdate()
    if not isTracking or not currentSession then return end

    local ok, members = pcall(WGS.GetRaidMembers, WGS)
    if not ok then
        WGS:FireEvent("WGS_INTERNAL_ERROR", { source = "Attendance.OnGroupRosterUpdate", error = members })
        return
    end
    if not members then return end
    local timestamp = WGS:GetTimestamp()

    local pullTime = currentSession.pullTime
    for name, info in pairs(members) do
        if not currentSession.members[name] then
            local playerId = WGS:ResolvePlayerForCharacter(name)
            local isLate = pullTime and timestamp > pullTime or false
            currentSession.members[name] = {
                name = name,
                playerId = playerId,
                class = info.class,
                role = info.role,
                subgroup = info.subgroup,
                isGuildMember = info.isGuildMember,
                joinedAt = timestamp,
                leftAt = nil,
                present = true,
                late = isLate,
            }
        else
            currentSession.members[name].present = true
            currentSession.members[name].leftAt = nil
            currentSession.members[name].subgroup = info.subgroup
            currentSession.members[name].role = info.role
        end
    end

    for name, member in pairs(currentSession.members) do
        if member.present and not members[name] then
            member.present = false
            member.leftAt = timestamp
        end
    end
end

--- Resolve a team name from db.global.teams by id. Used so OnRaidEnter
--- can label the session without the user picking it.
function WGS:GetTeamName(teamId)
    if not teamId then return nil end
    local teams = self.db.global.teams
    if not teams then return nil end
    for _, t in ipairs(teams) do
        if t.id == teamId then return t.name end
    end
    return nil
end

function WGS:StartAttendanceForTeam(teamId, teamName, event)
    if not IsInRaid() and not IsInGroup() then
        return
    end
    if isTracking then return end

    isTracking = true
    local members = self:GetRaidMembers()
    local timestamp = self:GetTimestamp()

    local instanceName, _, difficultyID, difficultyName = GetInstanceInfo()
    currentSession = {
        startedAt = timestamp,
        startedBy = self:GetPlayerKey(),
        instanceName = instanceName or "Unknown",
        difficultyID = difficultyID or 0,
        difficultyName = difficultyName or "",
        teamId = teamId,
        teamName = teamName,
        eventId = event and event.id or nil,
        eventTitle = event and event.title or nil,
        pullTime = event and WGS:GetEventPullTime(event) or nil,
        members = {},
    }
    -- Alias the same table into SavedVariables so every subsequent
    -- mutation to currentSession (member join/leave, comp snapshot,
    -- endedAt finalization) automatically persists for /reload survival.
    -- StopAttendance clears this back to nil so a /reload AFTER stop
    -- doesn't resurrect the finalized session.
    self.db.global.activeSession = currentSession

    for name, info in pairs(members) do
        local playerId = self:ResolvePlayerForCharacter(name)
        currentSession.members[name] = {
            name = name,
            playerId = playerId, -- nil if character not in player map
            class = info.class,
            role = info.role,
            subgroup = info.subgroup,
            isGuildMember = info.isGuildMember,
            joinedAt = timestamp,
            leftAt = nil,
            present = true,
        }
    end

    self:FireEvent("WGS_SESSION_STARTED", currentSession)

    -- Chat confirmation so the user sees that capture actually started
    -- (auto-start fires on RAID_INSTANCE_WELCOME, manual start via the
    -- Track button or shift-minimap; both go silent without this). Same
    -- one-line style as the bank-capture confirmation.
    local startTag = teamName or "untagged"
    if event and event.title and event.title ~= "" then
        startTag = startTag .. " \194\183 " .. event.title
    end
    self:Print("Attendance tracking started: " .. startTag)

    -- Take an immediate raid-comp snapshot now, while the roster is
    -- fresh from GetRaidMembers and every member has present=true. This
    -- guarantees at least one raidCompResults row per session — even
    -- for raids that have no boss kills AND empty out before
    -- StopAttendance fires (everyone leaves to log off). Without this,
    -- the only other snapshot opportunities are on ENCOUNTER_END
    -- (none if nothing died) and at session end (filtered to
    -- present + subgroup>0, so empty if the raid disbanded first).
    -- The result: a session with no recorded comp, and the platform
    -- import reports "raid comp for event #n is missing" because
    -- there's no row to link.
    self:SnapshotRaidComp(nil)
end

-- MRT (VMRT.Attendance.data[]) stores rosters with a one-character class
-- code prefix on each name. Mapping mirrors MRT's ExLib.lua. Bump this
-- table here AND docs/INTEROP.md if a new class is added.
local MRT_CLASS_LETTER_TO_NAME = {
    A = "WARRIOR",     B = "PALADIN",   C = "HUNTER",      D = "ROGUE",
    E = "PRIEST",      F = "DEATHKNIGHT", G = "SHAMAN",    H = "MAGE",
    I = "WARLOCK",     J = "MONK",      K = "DRUID",       L = "DEMONHUNTER",
    M = "EVOKER",
}

--- Decode a single MRT roster entry ("APlayerName" → ("PlayerName",
--- "WARRIOR")). Returns the raw name unchanged and class="" if the
--- prefix isn't a known code (defensive against MRT introducing a new
--- class before we update the table). Empty / non-string entries return
--- nil so the caller can skip them.
local function DecodeMRTRosterEntry(raw)
    if type(raw) ~= "string" or #raw < 2 then return nil end
    local letter = raw:sub(1, 1)
    local name = raw:sub(2)
    if name == "" then return nil end
    return name, MRT_CLASS_LETTER_TO_NAME[letter] or ""
end

--- Read MRT's per-encounter roster snapshots (VMRT.Attendance.data) and
--- return rows whose timestamp falls inside [startedAt, endedAt]. Each
--- row becomes a `bossAttendance` entry on the session. Returns an
--- empty table if MRT isn't loaded or has no overlapping rows.
---
--- Contract reference: docs/INTEROP.md → MRT → Attendance.
function WGS:BuildBossAttendanceFromMRT(startedAt, endedAt)
    local out = {}
    if not self:HasMRTData() then return out end
    local vmrt = _G.VMRT
    local data = vmrt and vmrt.Attendance and vmrt.Attendance.data
    if type(data) ~= "table" then return out end

    for _, row in ipairs(data) do
        if type(row) == "table"
           and type(row.t) == "number"
           and row.t >= startedAt
           and row.t <= endedAt
        then
            local roster = {}
            -- MRT stores players as positional integer keys [1..40].
            for i = 1, 40 do
                local entry = row[i]
                if entry then
                    local name, class = DecodeMRTRosterEntry(entry)
                    if name then
                        roster[#roster + 1] = { name = name, class = class }
                    end
                end
            end
            out[#out + 1] = {
                encounterID   = row.eI,
                encounterName = row.eN,
                difficultyID  = row.d,
                time          = row.t,
                isKill        = row.k and true or false,
                groupSize     = row.g,
                roster        = roster,
            }
        end
    end
    return out
end

function WGS:StopAttendance()
    if not isTracking or not currentSession then return end

    isTracking = false
    currentSession.endedAt = self:GetTimestamp()

    for _, member in pairs(currentSession.members) do
        if member.present then
            member.leftAt = currentSession.endedAt
        end
    end

    local memberList = {}
    for _, member in pairs(currentSession.members) do
        table.insert(memberList, member)
    end
    currentSession.memberList = memberList
    currentSession.members = nil

    -- Per-encounter rosters from MRT (if MRT is loaded). Strictly
    -- additive — GuildHall's session-level roster is still authoritative
    -- for the session as a whole; this gives the web a boss-by-boss
    -- "who was here for which pull" dimension.
    local mrtBossAttendance = self:BuildBossAttendanceFromMRT(
        currentSession.startedAt, currentSession.endedAt)
    if #mrtBossAttendance > 0 then
        currentSession.bossAttendance = mrtBossAttendance
    end

    -- Back-resolve event binding for sessions that started without one.
    -- The auto-flow uses a tight [start-30m, start+1h] window so it
    -- never silently mis-tags raids; this widens to [start-2h, start+4h]
    -- on the back-resolution pass, which covers the common case where
    -- the event was created on the platform AFTER the raid started
    -- (and only just landed via import or snapshot sync). Still requires
    -- exactly one event in the wider window — ambiguous matches stay
    -- untagged so we don't silently bind to the wrong raid.
    --
    -- If we find a match, backfill not just the session fields but
    -- also any raidCompResults rows already recorded for this session,
    -- so the platform import can link them.
    if not currentSession.eventId then
        local widerLead, widerTrail = 2 * 60 * 60, 4 * 60 * 60   -- 2h / 4h
        local ev = self:FindActiveScheduledEvent(currentSession.startedAt, widerLead, widerTrail)
        if ev then
            currentSession.eventId    = ev.id
            currentSession.eventTitle = ev.title
            currentSession.pullTime   = self:GetEventPullTime(ev)
            for _, snap in ipairs(self.db.global.raidCompResults or {}) do
                if snap.startedAt == currentSession.startedAt and not snap.eventId then
                    snap.eventId    = ev.id
                    snap.eventTitle = ev.title
                end
            end
            self:Print(string.format(
                "Bound this session to scheduled event: %s", ev.title or tostring(ev.id)))
        else
            -- No match even with the wider window. Surface so the
            -- officer can either re-import (if the event hasn't landed
            -- yet) or fix it via /gh attendance reconcile after import.
            self:Print(
                "Session ended without a scheduled-event binding. " ..
                "After importing the latest platform data, run " ..
                "|cffffd100/gh attendance reconcile|r to back-fill.")
        end
    end

    -- Final raid comp snapshot (deduped against any kill snapshots from
    -- this session — if the comp didn't change since the last kill, skip)
    self:SnapshotRaidComp(nil)

    table.insert(self.db.global.attendance, currentSession)

    local endedSession = currentSession
    currentSession = nil
    -- Clear the /reload-survival alias so the next addon load doesn't
    -- rehydrate this (now finalised) session. Cleanup pair with the
    -- alias in StartAttendanceForTeam.
    self.db.global.activeSession = nil

    -- One-line session summary so the user sees that the capture
    -- actually finalized and lands a row in db.global.attendance.
    -- Format mirrors the bank-capture confirmation. Boss kill count
    -- only shows if MRT/NSRT is loaded and contributed bossAttendance.
    local duration = (endedSession.endedAt or 0) - (endedSession.startedAt or 0)
    local minutes  = math.max(0, math.floor(duration / 60))
    local hours    = math.floor(minutes / 60)
    local durStr   = hours > 0
        and string.format("%dh %dm", hours, minutes % 60)
        or  string.format("%dm", minutes)
    local memberCount = #(endedSession.memberList or {})
    local killCount = 0
    for _, ba in ipairs(endedSession.bossAttendance or {}) do
        if ba.isKill then killCount = killCount + 1 end
    end
    local killSuffix = ""
    if killCount > 0 then
        killSuffix = string.format(" \194\183 %d boss kill%s",
            killCount, killCount > 1 and "s" or "")
    end
    self:Print(string.format(
        "Attendance recorded: %d member%s \194\183 %s%s. " ..
        "|cffffd100/gh attendance|r to review.",
        memberCount, memberCount == 1 and "" or "s", durStr, killSuffix))

    self:FireEvent("WGS_SESSION_ENDED", endedSession)

    -- Show export reminder after a short delay (let chat settle)
    C_Timer.After(2, function()
        WGS:ShowExportReminder()
    end)

    return true
end

--- Status-only command. `/gh attendance` prints whether capture is active
--- and, if so, which team/event it's tagged to. Replaces the old toggle
--- behavior — capture is event-driven now, manual start/stop is gone.
function WGS:AttendanceStatus()
    if not isTracking or not currentSession then
        self:Print(L["ATTENDANCE_NOT_RECORDING"])
        return
    end
    local startedHM = date("%H:%M", currentSession.startedAt)
    local tag = currentSession.teamName or "untagged"
    if currentSession.eventTitle then
        tag = tag .. " / " .. currentSession.eventTitle
    end
    self:Print(string.format(L["ATTENDANCE_RECORDING"], startedHM, tag))
end

--- Stable signature for a slots array. Used to dedupe identical snapshots.
local function ComputeCompSignature(slots)
    local parts = {}
    for _, s in ipairs(slots) do
        parts[#parts + 1] = (s.name or "?") .. ":" .. (s.group or 0)
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

--- Snapshot of who was in which raid group at a given moment.
--- Reads from session.memberList (set on stop) or session.members (live during
--- session). StopAttendance is often triggered by OnGroupLeft, at which point
--- IsInRaid() is already false, so we cannot rely on the live raid API.
---
--- bossInfo (optional): { encounterID, encounterName, difficultyID, difficultyName }
--- — when present, the snapshot is tagged with the kill that triggered it.
function WGS:CaptureRaidComposition(session, bossInfo)
    if not session then return nil end
    local source = session.memberList or session.members
    if not source then return nil end

    local slots = {}
    for _, member in pairs(source) do
        -- Only members currently present with a valid raid subgroup
        if member.present and member.subgroup and member.subgroup > 0 then
            slots[#slots + 1] = {
                name = member.name,
                playerId = member.playerId,
                class = member.class or "",
                role = member.role or "DPS",
                group = member.subgroup,
            }
        end
    end

    if #slots == 0 then return nil end

    return {
        eventId = session.eventId,
        eventTitle = session.eventTitle,
        teamId = session.teamId,
        teamName = session.teamName,
        instance = session.instanceName,
        difficultyID = session.difficultyID,
        difficultyName = session.difficultyName,
        startedAt = session.startedAt,
        finalAt = self:GetTimestamp(),
        recordedBy = self:GetPlayerKey(),
        boss = bossInfo and bossInfo.encounterName or nil,
        encounterID = bossInfo and bossInfo.encounterID or nil,
        bossDifficultyID = bossInfo and bossInfo.difficultyID or nil,
        signature = ComputeCompSignature(slots),
        slots = slots,
    }
end

--- Capture + dedupe + save. Skips if the comp is identical to the last
--- saved snapshot for the current session (same signature).
--- Called on boss kills (with bossInfo) and at session end (without).
function WGS:SnapshotRaidComp(bossInfo)
    if not currentSession then return false end

    local snapshot = self:CaptureRaidComposition(currentSession, bossInfo)
    if not snapshot then return false end

    local results = self.db.global.raidCompResults
    local last = results[#results]
    -- Dedupe: skip if the previous snapshot is from the same session and has
    -- the same comp signature. (Same session = same startedAt timestamp.)
    if last and last.startedAt == snapshot.startedAt and last.signature == snapshot.signature then
        return false
    end

    results[#results + 1] = snapshot
    self:FireEvent("WGS_RAID_COMP_SNAPSHOT", snapshot)
    return true
end

function WGS:IsTrackingAttendance()
    return isTracking
end

-- Returns the active session's tagging context — eventId, teamId,
-- teamName — for any capture site that wants to stamp itself with the
-- raid it's part of (loot rows, encounter rows, …). Returns nil when
-- attendance isn't currently being tracked.
--
-- Retroactively bind orphan sessions (and their raidCompResults rows)
-- to scheduled events. Walks every attendance row whose eventId is nil
-- and re-runs the wider-window FindActiveScheduledEvent against the
-- session's startedAt. The common reason for orphans: the event was
-- created on the platform AFTER the raid started, so when the auto-flow
-- ran at raid entry there was no event in db.global.events to match.
-- Now that the import has landed, the events ARE there and the binding
-- can be made — but only for sessions where exactly one event in the
-- [start-2h, start+4h] window matches. Ambiguous matches stay
-- untouched so an officer never has to undo a silently-wrong bind.
--
-- Returns (bound, ambiguous, unmatched) counts so the caller (the
-- slash command + future UI) can report what happened.
function WGS:ReconcileAttendanceEventBindings()
    local sessions = self.db.global.attendance or {}
    local comps    = self.db.global.raidCompResults or {}
    local widerLead, widerTrail = 2 * 60 * 60, 4 * 60 * 60

    local bound, ambiguous, unmatched = 0, 0, 0
    for _, session in ipairs(sessions) do
        if not session.eventId and session.startedAt then
            -- Re-run with the wider window. FindActiveScheduledEvent
            -- already returns nil for "0 OR >1 matches" — we can't
            -- tell those apart from the return value alone. Re-walk
            -- the events to distinguish for the user-facing count.
            local ev = self:FindActiveScheduledEvent(session.startedAt, widerLead, widerTrail)
            if ev then
                session.eventId    = ev.id
                session.eventTitle = ev.title
                for _, snap in ipairs(comps) do
                    if snap.startedAt == session.startedAt and not snap.eventId then
                        snap.eventId    = ev.id
                        snap.eventTitle = ev.title
                    end
                end
                bound = bound + 1
            else
                -- Disambiguate: count matches inside the window
                -- manually so the user knows whether to wait for
                -- more import data or whether the raid genuinely
                -- has no scheduled event.
                local matches = 0
                for _, candidate in ipairs(self.db.global.events or {}) do
                    local startTs = self:GetEventPullTime(candidate)
                    if startTs
                       and session.startedAt >= (startTs - widerLead)
                       and session.startedAt <= (startTs + widerTrail) then
                        matches = matches + 1
                    end
                end
                if matches > 1 then ambiguous = ambiguous + 1
                else                unmatched = unmatched + 1 end
            end
        end
    end

    self:Print(string.format(
        "Attendance reconcile: |cff00ff00%d bound|r, " ..
        "|cffffd100%d ambiguous|r, |cff888888%d unmatched|r.",
        bound, ambiguous, unmatched))
    return bound, ambiguous, unmatched
end

-- Read-only view; we hand back a fresh table each call so callers can't
-- accidentally mutate the internal session.
function WGS:GetCurrentAttendanceContext()
    if not isTracking or not currentSession then return nil end
    return {
        eventId    = currentSession.eventId,
        teamId     = currentSession.teamId,
        teamName   = currentSession.teamName,
        startedAt  = currentSession.startedAt,
    }
end

function WGS:GetAttendanceStartTime()
    return currentSession and currentSession.startedAt or nil
end

--- Build the per-unit member record. Shared between the raid and
--- party branches of GetRaidMembers so the two used to drift on
--- which fields they read or how isGuildMember was computed.
---
--- Returns (fullName, record) on success, or nil if the unit slot
--- is empty (UnitFullName returned no name).
local function ReadUnitMember(unit, myGuild, subgroup)
    local name, realm = UnitFullName(unit)
    if not name then return nil end
    local fullName = WGS:NormalizeFullName(name, realm)
    local _, class = UnitClass(unit)
    local unitGuild = GetGuildInfo(unit)
    return fullName, {
        class = class or "",
        role = UnitGroupRolesAssigned(unit) or "NONE",
        subgroup = subgroup or 0,
        isGuildMember = (myGuild and unitGuild == myGuild) or false,
    }
end

function WGS:GetRaidMembers()
    local members = {}
    local myGuild = IsInGuild() and GetGuildInfo("player") or nil

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            -- GetRaidRosterInfo returns: name, rank, subgroup, level, class, ...
            local _, _, subgroup = GetRaidRosterInfo(i)
            local fullName, record = ReadUnitMember("raid" .. i, myGuild, subgroup)
            if fullName then members[fullName] = record end
        end
    elseif IsInGroup() then
        -- Party members include the local player via the "player" unit
        -- (which UnitFullName resolves correctly); party1..N-1 are the
        -- rest. Party members all share subgroup 1.
        local fullName, record = ReadUnitMember("player", myGuild, 1)
        if fullName then
            -- The local player is by definition in our own guild — the
            -- generic ReadUnitMember computes this via GetGuildInfo
            -- which can return nil for the local player while the guild
            -- info is still loading. Pin it explicitly.
            record.isGuildMember = true
            members[fullName] = record
        end
        local total = GetNumGroupMembers()
        for i = 1, total - 1 do
            local f, r = ReadUnitMember("party" .. i, myGuild, 1)
            if f then members[f] = r end
        end
    end

    return members
end

---------------------------------------------------------------------------
-- Officer corrections — in-addon edits for captured sessions
---------------------------------------------------------------------------
--
-- Used by Logs → Attendance expand-on-click edit affordances. Each
-- mutator owns the data change + the FireEvent + the cascade into
-- raidCompResults rows that share the session's startedAt (so the
-- per-pull comp snapshots stay consistent with the session-level
-- roster — otherwise a removed member would still appear "present"
-- in the comp).
--
-- Cross-officer propagation: same v1 limitation as the loot mutators
-- (PeerSync.lua's mergeAttendance is first-wins on (startedAt,
-- startedBy); edits don't propagate). The Print hint flags this each
-- time so officers don't assume remote sync.

-- Walk raidCompResults backwards (so fn can table.remove without
-- skipping the next entry) and call fn for each snapshot whose
-- startedAt matches. fn receives (snap, i, comps) so it can mutate
-- fields, splice slots, or remove the row outright.
--
-- All three correction mutators below cascade into raidCompResults
-- this way: rebind updates eventId/eventTitle in place, remove-member
-- splices the member out of slots[], delete drops the row. Without
-- this cascade, per-pull comp snapshots would drift out of sync with
-- the corrected session-level roster — a removed member would still
-- appear "present" in the comp, a rebound session would have orphan
-- snapshots pointing to the wrong event.
local function forEachCompSnapshotAt(startedAt, fn)
    local comps = WGS.db and WGS.db.global and WGS.db.global.raidCompResults
    if type(comps) ~= "table" then return end
    for i = #comps, 1, -1 do
        if comps[i].startedAt == startedAt then
            fn(comps[i], i, comps)
        end
    end
end

--- Rebind a session to a different scheduled event. Backfills any
--- raidCompResults rows sharing the session's startedAt so the
--- exported snapshots link to the new event too. Pass nil eventId to
--- clear the binding (rare; mostly useful if a wrong auto-resolution
--- got picked up). Returns true on success, false on out-of-range.
function WGS:RebindAttendanceSession(sessionIndex, eventId, eventTitle)
    local sessions = self.db and self.db.global and self.db.global.attendance
    if type(sessions) ~= "table" then return false end
    local session = sessions[sessionIndex]
    if not session then return false end

    session.eventId    = eventId or nil
    session.eventTitle = eventTitle or nil

    forEachCompSnapshotAt(session.startedAt, function(snap)
        snap.eventId    = eventId or nil
        snap.eventTitle = eventTitle or nil
    end)

    self:FireEvent("WGS_ATTENDANCE_EDITED",
        { index = sessionIndex, session = session, kind = "rebind" })
    self:PrintCorrectionHint()
    return true
end

--- Remove a member from a session's roster. Also splices them out of
--- every raidCompResults.slots[] sharing the session's startedAt — if
--- we leave the slots untouched the per-pull comp would still show
--- the member as present, contradicting the corrected session. Returns
--- true on success, false if the session or member doesn't exist.
function WGS:RemoveMemberFromSession(sessionIndex, memberName)
    local sessions = self.db and self.db.global and self.db.global.attendance
    if type(sessions) ~= "table" then return false end
    local session = sessions[sessionIndex]
    if not session or type(session.memberList) ~= "table" then return false end

    local found = false
    for i = #session.memberList, 1, -1 do
        if session.memberList[i].name == memberName then
            table.remove(session.memberList, i)
            found = true
        end
    end
    if not found then return false end

    forEachCompSnapshotAt(session.startedAt, function(snap)
        if type(snap.slots) ~= "table" then return end
        for i = #snap.slots, 1, -1 do
            if snap.slots[i].name == memberName then
                table.remove(snap.slots, i)
            end
        end
    end)

    self:FireEvent("WGS_ATTENDANCE_EDITED",
        { index = sessionIndex, session = session, kind = "remove_member",
          memberName = memberName })
    self:PrintCorrectionHint()
    return true
end

--- Delete a session entirely. Also removes every raidCompResults row
--- sharing its startedAt so we don't leave orphan snapshots pointing
--- to a session that no longer exists. Returns true on success,
--- false on out-of-range.
function WGS:DeleteAttendanceSession(sessionIndex)
    local sessions = self.db and self.db.global and self.db.global.attendance
    if type(sessions) ~= "table" then return false end
    local session = sessions[sessionIndex]
    if not session then return false end

    local removed = table.remove(sessions, sessionIndex)

    forEachCompSnapshotAt(removed.startedAt, function(_, i, comps)
        table.remove(comps, i)
    end)

    self:FireEvent("WGS_ATTENDANCE_EDITED",
        { index = sessionIndex, session = removed, kind = "delete" })
    self:PrintCorrectionHint()
    return true
end

---------------------------------------------------------------------------
-- Data normalization (export pre-pass)
---------------------------------------------------------------------------
--
-- Belt-and-suspenders guardrail for the addon → platform import. Every
-- now and then a scalar field on db.global.attendance ends up with a
-- type-wrong value — a Lua table where the schema expected a number,
-- a number where a string was expected, etc. The platform's Zod schema
-- correctly rejects the whole row, which blocks the entire import over
-- one bad field.
--
-- The principled fix is to clean the bad data at the source. This
-- function walks db.global.attendance and coerces type-wrong scalars
-- to nil, in place. Called from Sync/Encoder.lua:WGS:Encode as a
-- pre-export pass so the platform never sees malformed rows. Mutates
-- db.global so the repair persists — a one-time clean.
--
-- The list intentionally only covers scalar contract fields that the
-- platform's addonAttendanceSessionSchema declares. memberList /
-- bossAttendance are nested structures with their own per-row schemas
-- and aren't reduced to nil here.

local ATTENDANCE_SCALAR_TYPES = {
    teamId       = "number",
    eventId      = "number",
    teamName     = "string",
    eventTitle   = "string",
    instanceName = "string",
    startedBy    = "string",
}

function WGS:NormalizeAttendanceSessions()
    local sessions = self.db and self.db.global and self.db.global.attendance
    if type(sessions) ~= "table" then return 0 end
    local repairs = 0
    for _, session in ipairs(sessions) do
        if type(session) == "table" then
            for field, expected in pairs(ATTENDANCE_SCALAR_TYPES) do
                local v = session[field]
                if v ~= nil and type(v) ~= expected then
                    session[field] = nil
                    repairs = repairs + 1
                end
            end
        end
    end
    return repairs
end
