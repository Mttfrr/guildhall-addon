---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

---@class WGSAttendanceModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("Attendance", "AceEvent-3.0")

local isTracking = false
local currentSession = nil
---@type WGSTeamPickerFrame?
local teamPickerFrame = nil

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

    -- Auto-show readiness check on raid entry
    C_Timer.After(3, function()
        WGS:CheckRaidReadiness()
    end)

    if not WGS.db.profile.autoTrackAttendance then return end
    if isTracking then return end
    if WGS.db.profile.guildGroupsOnly and not WGS:IsGuildGroup() then return end
    -- Auto-start: show team picker if teams exist, otherwise start without team
    WGS:PromptAttendanceStart()
end

function module:OnGroupRosterUpdate()
    if not isTracking or not currentSession then return end

    local ok, members = pcall(WGS.GetRaidMembers, WGS)
    if not ok or not members then return end
    local timestamp = WGS:GetTimestamp()

    for name, info in pairs(members) do
        if not currentSession.members[name] then
            local playerId = WGS:ResolvePlayerForCharacter(name)
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

-- Find today's event for a given team (or any event today if no team)
function WGS:FindTodayEvent(teamId)
    local events = self.db.global.events
    if not events or #events == 0 then return nil end

    local today = date("%Y-%m-%d")
    for _, event in ipairs(events) do
        if event.date == today then
            if not teamId or event.team_id == teamId then
                return event
            end
        end
    end
    return nil
end

-- Show team picker before starting attendance
function WGS:PromptAttendanceStart()
    local teams = self.db.global.teams
    if not teams or #teams == 0 then
        -- No teams imported — start without team tag
        local event = self:FindTodayEvent(nil)
        self:StartAttendanceForTeam(nil, nil, event)
        return
    end

    self:ShowTeamPicker(function(teamId, teamName)
        local event = self:FindTodayEvent(teamId)
        self:StartAttendanceForTeam(teamId, teamName, event)
    end)
end

function WGS:StartAttendanceForTeam(teamId, teamName, event)
    if not IsInRaid() and not IsInGroup() then
        self:Print(L["NOT_IN_RAID"])
        return
    end

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

    local msg = L["ATTENDANCE_START"]
    if teamName then
        msg = msg .. " (Team: " .. teamName .. ")"
    end
    if event then
        msg = msg .. " - Event: " .. (event.title or "?")
    end
    self:Print(msg)
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

    table.insert(self.db.global.attendance, currentSession)

    self:Print(string.format(L["ATTENDANCE_STOP"], #memberList))

    currentSession = nil

    -- Show export reminder after a short delay (let chat settle)
    C_Timer.After(2, function()
        WGS:ShowExportReminder()
    end)

    return true
end

function WGS:ToggleAttendance()
    if isTracking then
        self:StopAttendance()
    else
        self:PromptAttendanceStart()
    end
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

---------------------------------------------------------------------------
-- Team Picker UI
---------------------------------------------------------------------------

function WGS:ShowTeamPicker(callback)
    if not teamPickerFrame then
        teamPickerFrame = self:CreateTeamPickerFrame()
    end

    local picker = teamPickerFrame --[[@as WGSTeamPickerFrame]]
    local teams = self.db.global.teams or {}
    picker.callback = callback
    picker:PopulateTeams(teams)
    picker:Show()
end

function WGS:CreateTeamPickerFrame()
    local f = CreateFrame("Frame", "GuildHallTeamPicker", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(260, 50)  -- Will resize based on team count
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("FULLSCREEN_DIALOG")

    f.TitleBg:SetHeight(30)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", f.TitleBg, "TOPLEFT", 5, -3)
    f.title:SetText("Select Team")

    f.buttons = {}

    -- Pool of reusable button/label frames
    f.buttonPool = {}
    f.labelPool = {}

    local function GetOrCreateButton(parent)
        local pool = parent.buttonPool
        for i, btn in ipairs(pool) do
            if not btn._inUse then
                btn._inUse = true
                btn:Show()
                return btn
            end
        end
        local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        btn._inUse = true
        table.insert(pool, btn)
        return btn
    end

    local function GetOrCreateLabel(parent)
        local pool = parent.labelPool
        for i, lbl in ipairs(pool) do
            if not lbl._inUse then
                lbl._inUse = true
                lbl:Show()
                return lbl
            end
        end
        local lbl = CreateFrame("Frame", nil, parent)
        lbl.text = lbl:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl.text:SetAllPoints()
        lbl._inUse = true
        table.insert(pool, lbl)
        return lbl
    end

    function f:PopulateTeams(teams)
        -- Return all frames to pool
        for _, btn in ipairs(self.buttonPool) do
            btn._inUse = false
            btn:Hide()
        end
        for _, lbl in ipairs(self.labelPool) do
            lbl._inUse = false
            lbl:Hide()
        end
        self.buttons = {}

        local btnY = -35
        local btnHeight = 28
        local labelHeight = 16
        local spacing = 4

        for _, team in ipairs(teams) do
            local todayEvent = WGS:FindTodayEvent(team.id)

            local btn = GetOrCreateButton(self)
            btn:SetSize(300, btnHeight)
            btn:ClearAllPoints()
            btn:SetPoint("TOP", self, "TOP", 0, btnY)
            btn:SetText(team.name .. " (" .. (team.type or "Raid") .. ")")
            btn:SetScript("OnClick", function()
                self:Hide()
                if self.callback then
                    self.callback(team.id, team.name)
                end
            end)
            table.insert(self.buttons, btn)
            btnY = btnY - btnHeight - 1

            if todayEvent then
                local lbl = GetOrCreateLabel(self)
                lbl:SetSize(300, labelHeight)
                lbl:ClearAllPoints()
                lbl:SetPoint("TOP", self, "TOP", 0, btnY)
                lbl.text:SetText("|cff00ff00Event: " .. (todayEvent.title or "?") .. " @ " .. (todayEvent.time or "?") .. "|r")
                table.insert(self.buttons, lbl)
                btnY = btnY - labelHeight
            end

            btnY = btnY - spacing
        end

        -- "No team" button
        local btnNone = GetOrCreateButton(self)
        btnNone:SetSize(300, btnHeight)
        btnNone:ClearAllPoints()
        btnNone:SetPoint("TOP", self, "TOP", 0, btnY)
        btnNone:SetText("|cff888888No team (untagged)|r")
        btnNone:SetScript("OnClick", function()
            self:Hide()
            if self.callback then
                self.callback(nil, nil)
            end
        end)
        table.insert(self.buttons, btnNone)
        btnY = btnY - btnHeight - spacing

        -- Resize frame to fit
        self:SetSize(320, math.abs(btnY) + 15)
    end

    f:Hide()
    return f
end
