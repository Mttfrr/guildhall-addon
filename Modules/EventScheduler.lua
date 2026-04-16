---@type GuildHall
local WGS = GuildHall

---@class WGSEventSchedulerModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("EventScheduler", "AceEvent-3.0")

local POLL_INTERVAL = 30         -- check every 30 seconds
local INVITE_WINDOW = 15 * 60   -- 15 minutes before event
local INVITE_COOLDOWN = 5        -- seconds between individual invites

local ticker = nil
local invitedThisEvent = {}      -- { [charName] = true } reset per event
local lastEventId = nil

function module:OnEnable()
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "OnGuildRosterUpdate")
    ticker = C_Timer.NewTicker(POLL_INTERVAL, function() self:Poll() end)
end

function module:OnDisable()
    if ticker then ticker:Cancel(); ticker = nil end
end

---------------------------------------------------------------------------
-- Time parsing
---------------------------------------------------------------------------

--- Parse event date + time into a unix timestamp.
-- event.date = "2026-04-16", event.time = "20:00" or "8:00 PM"
local function ParseEventTime(event)
    if not event.date or not event.time then return nil end

    local y, m, d = event.date:match("(%d+)-(%d+)-(%d+)")
    if not y then return nil end

    local timeStr = event.time:gsub("%s+", "")
    local hour, min = timeStr:match("^(%d+):(%d+)")
    if not hour then return nil end
    hour, min = tonumber(hour), tonumber(min)

    -- Handle AM/PM
    local ampm = timeStr:match("[AaPp][Mm]$")
    if ampm then
        ampm = ampm:upper()
        if ampm == "PM" and hour < 12 then hour = hour + 12 end
        if ampm == "AM" and hour == 12 then hour = 0 end
    end

    return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = hour, min = min, sec = 0 })
end

---------------------------------------------------------------------------
-- Core poll loop
---------------------------------------------------------------------------

function module:Poll()
    local events = WGS.db.global.events
    if not events or #events == 0 then return end

    local now = time()
    local upcoming = self:FindNextEvent(events, now)
    if not upcoming then return end

    local eventTime = ParseEventTime(upcoming)
    if not eventTime then return end

    local delta = eventTime - now -- seconds until event

    -- Reset invite tracking when event changes
    if upcoming.id ~= lastEventId then
        lastEventId = upcoming.id
        invitedThisEvent = {}
    end

    -- 15 min window: auto-invite + auto-attendance
    if delta <= INVITE_WINDOW and delta > -3600 then
        self:HandlePreEvent(upcoming, eventTime, now, delta)
    end
end

--- Find the next upcoming event (or currently active within 1 hour).
function module:FindNextEvent(events, now)
    local best, bestTime = nil, nil
    for _, ev in ipairs(events) do
        local t = ParseEventTime(ev)
        if t then
            local d = t - now
            -- Consider events from 15 min before to 1 hour after start
            if d > -3600 and d <= INVITE_WINDOW then
                if not bestTime or t < bestTime then
                    best, bestTime = ev, t
                end
            end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- Pre-event actions
---------------------------------------------------------------------------

function module:HandlePreEvent(event, eventTime, now, delta)
    local teamId = event.team_id or event.teamId
    local team = self:GetTeamById(teamId)

    -- Auto-invite (officers/leaders only, before event start)
    if delta > 0 and team then
        self:TryAutoInvite(team, event)
    end

    -- Auto-start attendance if in group and not already tracking
    if not WGS:IsTrackingAttendance() and (IsInRaid() or IsInGroup()) then
        if WGS.db.profile.guildGroupsOnly and not WGS:IsGuildGroup() then return end

        -- Tag the event with pull time for late detection
        event._pullTime = eventTime
        local teamName = team and team.name or nil
        WGS:StartAttendanceForTeam(teamId, teamName, event)
        WGS:Print("|cff00ff00Auto-started attendance for event: " .. (event.title or "?") .. "|r")
    end
end

---------------------------------------------------------------------------
-- Auto-invite
---------------------------------------------------------------------------

function module:TryAutoInvite(team, event)
    -- Must be leader or assistant to invite
    if IsInRaid() then
        if not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player") then return end
    elseif IsInGroup() then
        if not UnitIsGroupLeader("player") then return end
    else
        -- Not in group — can't mass-invite without creating one first
        return
    end

    -- Must be officer (rank index 0 = GM, 1 = officer typically; check top 3 ranks)
    if IsInGuild() then
        local _, _, rankIndex = GetGuildInfo("player")
        if not rankIndex or rankIndex > 2 then return end
    else
        return
    end

    local roster = WGS:GetGuildRosterLookup()
    local members = self:GetTeamMemberNames(team)
    local queued = 0

    for _, name in ipairs(members) do
        local short = name:match("^([^%-]+)")
        if short and not invitedThisEvent[short] then
            local gi = roster[short]
            if gi and gi.online then
                -- Don't invite ourselves or people already in group
                if gi.fullName ~= WGS:GetPlayerKey() and not self:IsInCurrentGroup(gi.fullName) then
                    invitedThisEvent[short] = true
                    queued = queued + 1
                    -- Stagger invites to avoid spam
                    C_Timer.After(queued * INVITE_COOLDOWN, function()
                        C_PartyInfo.InviteUnit(gi.fullName)
                    end)
                end
            end
        end
    end

    if queued > 0 then
        WGS:Print("|cffffd100Auto-inviting " .. queued .. " online team member(s) for: " .. (event.title or "?") .. "|r")
    end
end

--- Watch guild roster for members coming online near event time.
function module:OnGuildRosterUpdate()
    if not lastEventId then return end
    local events = WGS.db.global.events
    if not events then return end

    local now = time()
    local upcoming = self:FindNextEvent(events, now)
    if not upcoming then return end

    local eventTime = ParseEventTime(upcoming)
    if not eventTime then return end
    if eventTime - now > INVITE_WINDOW or eventTime - now < 0 then return end

    local teamId = upcoming.team_id or upcoming.teamId
    local team = self:GetTeamById(teamId)
    if team then
        self:TryAutoInvite(team, upcoming)
    end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function module:GetTeamById(teamId)
    if not teamId then return nil end
    local teams = WGS.db.global.teams
    if not teams then return nil end
    for _, t in ipairs(teams) do
        if t.id == teamId then return t end
    end
    return nil
end

--- Get flat list of character names from a team (handles both formats).
function module:GetTeamMemberNames(team)
    local names = {}
    if team.playerMembers then
        local chars = WGS.db.global.characters or {}
        for _, pm in ipairs(team.playerMembers) do
            if pm.main then names[#names + 1] = pm.main end
            local info = chars[pm.playerId]
            if info and info.alts then
                for _, alt in ipairs(info.alts) do
                    names[#names + 1] = alt
                end
            end
        end
    elseif team.members then
        for _, m in ipairs(team.members) do names[#names + 1] = m end
    end
    return names
end

--- Check if a player is already in the current group.
function module:IsInCurrentGroup(fullName)
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name = GetRaidRosterInfo(i)
            if name and fullName:find(name) then return true end
        end
    elseif IsInGroup() then
        if fullName == WGS:GetPlayerKey() then return true end
        for i = 1, GetNumGroupMembers() - 1 do
            local uName, uRealm = UnitFullName("party" .. i)
            if uName then
                uRealm = (uRealm and uRealm ~= "") and uRealm or (GetNormalizedRealmName() or "")
                if (uName .. "-" .. uRealm) == fullName then return true end
            end
        end
    end
    return false
end
