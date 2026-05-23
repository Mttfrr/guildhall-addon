---@type GuildHall
local WGS = GuildHall

---@class WGSAttendanceModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("Attendance", "AceEvent-3.0")

local isTracking = false
local currentSession = nil

function module:OnEnable()
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnGroupRosterUpdate")
    self:RegisterEvent("RAID_INSTANCE_WELCOME", "OnRaidEnter")
    self:RegisterEvent("GROUP_LEFT", "OnGroupLeft")
end

function module:OnGroupLeft()
    if not isTracking then return end
    -- Player left the raid — auto-stop attendance and prompt export
    WGS:StopAttendance()
    WGS:ShowExportReminder()
end

function module:OnRaidEnter()
    if not IsInRaid() then return end

    -- Auto-show readiness check on raid entry (independent of attendance)
    C_Timer.After(3, function()
        WGS:CheckRaidReadiness()
    end)

    if not WGS.db.profile.autoTrackAttendance then return end
    if isTracking then return end
    if WGS.db.profile.guildGroupsOnly and not WGS:IsGuildGroup() then return end

    -- Resolve team silently: pick the scheduled event whose window
    -- contains "now". If none (or ambiguous), start untagged. No modal,
    -- no HUD — the addon should be invisible at this point.
    local event = WGS:FindActiveScheduledEvent()
    local teamId, teamName = nil, nil
    if event then
        teamId = event.team_id or event.teamId
        teamName = WGS:GetTeamName(teamId)
    end
    WGS:StartAttendanceForTeam(teamId, teamName, event)
end

function module:OnGroupRosterUpdate()
    if not isTracking or not currentSession then return end

    local ok, members = pcall(WGS.GetRaidMembers, WGS)
    if not ok or not members then return end
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

    -- Final raid comp snapshot (deduped against any kill snapshots from
    -- this session — if the comp didn't change since the last kill, skip)
    self:SnapshotRaidComp(nil)

    table.insert(self.db.global.attendance, currentSession)

    currentSession = nil

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
        self:Print("Attendance: not recording.")
        return
    end
    local startedHM = date("%H:%M", currentSession.startedAt)
    local tag = currentSession.teamName or "untagged"
    if currentSession.eventTitle then
        tag = tag .. " / " .. currentSession.eventTitle
    end
    self:Print(string.format("Attendance: recording since %s (%s).", startedHM, tag))
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
    return true
end

function WGS:IsTrackingAttendance()
    return isTracking
end

function WGS:GetAttendanceStartTime()
    return currentSession and currentSession.startedAt or nil
end

function WGS:GetRaidMembers()
    local members = {}
    local myGuild = IsInGuild() and GetGuildInfo("player") or nil

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            local name, realm = UnitFullName(unit)
            if name then
                realm = (realm and realm ~= "") and realm or (GetNormalizedRealmName() or "")
                local fullName = name .. "-" .. realm
                local _, class = UnitClass(unit)
                local role = UnitGroupRolesAssigned(unit)
                local unitGuild = GetGuildInfo(unit)
                -- GetRaidRosterInfo returns: name, rank, subgroup, level, class, ...
                local _, _, subgroup = GetRaidRosterInfo(i)
                members[fullName] = {
                    class = class or "",
                    role = role or "NONE",
                    subgroup = subgroup or 0,
                    isGuildMember = (myGuild and unitGuild == myGuild) or false,
                }
            end
        end
    elseif IsInGroup() then
        local playerName = WGS:GetPlayerKey()
        local role = UnitGroupRolesAssigned("player")
        local _, class = UnitClass("player")
        members[playerName] = {
            class = class or "",
            role = role or "NONE",
            subgroup = 1,
            isGuildMember = true,
        }

        local total = GetNumGroupMembers()
        for i = 1, total - 1 do
            local unit = "party" .. i
            local name, realm = UnitFullName(unit)
            if name then
                realm = (realm and realm ~= "") and realm or (GetNormalizedRealmName() or "")
                local fullName = name .. "-" .. realm
                local _, pClass = UnitClass(unit)
                local pRole = UnitGroupRolesAssigned(unit)
                local unitGuild = GetGuildInfo(unit)
                members[fullName] = {
                    class = pClass or "",
                    role = pRole or "NONE",
                    subgroup = 1,
                    isGuildMember = (myGuild and unitGuild == myGuild) or false,
                }
            end
        end
    end

    return members
end
