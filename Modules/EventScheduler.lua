---@type GuildHall
local WGS = GuildHall

---@class WGSEventSchedulerModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("EventScheduler", "AceEvent-3.0")

local INVITE_COOLDOWN = 3
local invitedThisSession = {}

function module:OnEnable()
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "OnGuildRosterUpdate")
end

---------------------------------------------------------------------------
-- Time parsing
---------------------------------------------------------------------------

local function ParseEventTime(event)
    if not event.date or not event.time then return nil end
    local y, m, d = event.date:match("(%d+)-(%d+)-(%d+)")
    if not y then return nil end
    local timeStr = event.time:gsub("%s+", "")
    local hour, min = timeStr:match("^(%d+):(%d+)")
    if not hour then return nil end
    hour, min = tonumber(hour), tonumber(min)
    local ampm = timeStr:match("[AaPp][Mm]$")
    if ampm then
        ampm = ampm:upper()
        if ampm == "PM" and hour < 12 then hour = hour + 12 end
        if ampm == "AM" and hour == 12 then hour = 0 end
    end
    return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = hour, min = min, sec = 0 })
end

---------------------------------------------------------------------------
-- Find today's event + matching raid comp
---------------------------------------------------------------------------

function WGS:FindTodayEventForTeam(teamId)
    local events = self.db.global.events
    if not events or #events == 0 then return nil end
    local today = date("%Y-%m-%d")
    local now = time()
    local best, bestDelta = nil, math.huge
    for _, ev in ipairs(events) do
        if ev.date == today then
            if not teamId or ev.team_id == teamId or ev.teamId == teamId then
                local t = ParseEventTime(ev)
                if t then
                    local d = math.abs(t - now)
                    if d < bestDelta then best, bestDelta = ev, d end
                end
            end
        end
    end
    return best
end

--- Get the invite list for an event. Prefers raid comp assignments,
--- falls back to team roster.
function WGS:GetEventInviteList(event)
    local eventId = event.id or event.eventId
    local names = {}

    -- Try raid comp first (exact assignments for this event)
    if eventId then
        local comp = self:GetRaidComp(eventId)
        if comp and comp.assignments and #comp.assignments > 0 then
            for _, a in ipairs(comp.assignments) do
                if a.name then names[#names + 1] = a.name end
            end
            return names, "raid comp"
        end
    end

    -- Fall back to team roster
    local teamId = event.team_id or event.teamId
    if teamId then
        local teams = self.db.global.teams
        if teams then
            for _, t in ipairs(teams) do
                if t.id == teamId then
                    if t.playerMembers then
                        local chars = self.db.global.characters or {}
                        for _, pm in ipairs(t.playerMembers) do
                            if pm.main then names[#names + 1] = pm.main end
                            local info = chars[pm.playerId]
                            if info and info.alts then
                                for _, alt in ipairs(info.alts) do
                                    names[#names + 1] = alt
                                end
                            end
                        end
                    elseif t.members then
                        for _, m in ipairs(t.members) do names[#names + 1] = m end
                    end
                    return names, "team roster"
                end
            end
        end
    end

    return names, nil
end

---------------------------------------------------------------------------
-- /gh invite — manual auto-invite
---------------------------------------------------------------------------

function WGS:AutoInvite()
    -- Permission check: must be in group as leader/assistant, or not in group
    if IsInRaid() then
        if not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player") then
            self:Print("|cffff4444You must be raid leader or assistant to auto-invite.|r")
            return
        end
    elseif IsInGroup() then
        if not UnitIsGroupLeader("player") then
            self:Print("|cffff4444You must be party leader to auto-invite.|r")
            return
        end
    end

    -- Officer check (top 3 guild ranks)
    if IsInGuild() then
        local _, _, rankIndex = GetGuildInfo("player")
        if not rankIndex or rankIndex > 2 then
            self:Print("|cffff4444Auto-invite requires officer rank or higher.|r")
            return
        end
    else
        self:Print("|cffff4444You must be in a guild.|r")
        return
    end

    -- Find today's event
    local event = self:FindTodayEventForTeam(nil)
    if not event then
        self:Print("No event found for today.")
        return
    end

    local names, source = self:GetEventInviteList(event)
    if #names == 0 then
        self:Print("No members to invite for: " .. (event.title or "?"))
        return
    end

    local roster = self:GetGuildRosterLookup()
    local myKey = self:GetPlayerKey()
    local queued = 0

    for _, name in ipairs(names) do
        local short = name:match("^([^%-]+)")
        if short and not invitedThisSession[short] then
            local gi = roster[short]
            if gi and gi.online and gi.fullName ~= myKey then
                -- Skip if already in group
                if not module:IsInCurrentGroup(gi.fullName) then
                    invitedThisSession[short] = true
                    queued = queued + 1
                    C_Timer.After(queued * INVITE_COOLDOWN, function()
                        C_PartyInfo.InviteUnit(gi.fullName)
                    end)
                end
            end
        end
    end

    if queued > 0 then
        self:Print(string.format("|cffffd100Inviting %d member(s) for %s (from %s)|r", queued, event.title or "?", source or "roster"))
    else
        self:Print("All members are already in group or offline.")
    end
end

---------------------------------------------------------------------------
-- Watch for guild members logging in — notify if near event time
---------------------------------------------------------------------------

function module:OnGuildRosterUpdate()
    -- Lightweight: just refresh roster cache so next /gh invite is current
    -- No auto-actions here (removed polling)
end

---------------------------------------------------------------------------
-- Late detection: enrich event with pullTime for Attendance module
---------------------------------------------------------------------------

--- Called from Attendance when starting for an event.
--- Attaches _pullTime to the event so members joining after are flagged late.
function WGS:GetEventPullTime(event)
    if not event then return nil end
    return ParseEventTime(event)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

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
