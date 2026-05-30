---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

---@class WGSEventSchedulerModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("EventScheduler", "AceEvent-3.0")

-- Statuses we treat as "this player committed to attending". Matches the
-- server's COMMITTED_SIGNUPS set (server/routes/addonSync.js):
--   P = Present, L = Late, B = Bench, LT = Late-tentative.
-- Tentative (T) is intentionally excluded — they said "maybe", don't
-- pull them into the raid by default.
local COMMITTED_SIGNUP_STATUSES = { P = true, L = true, B = true, LT = true }

-- How long to wait after firing invites before auto-sorting raid groups.
-- Gives people a moment to accept; sorting only acts on members already
-- in the raid so calling it too early is a no-op.
local SORT_AFTER_INVITE_DELAY = 5

local invitedThisSession = {}

function module:OnEnable()
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "OnGuildRosterUpdate")
end

---------------------------------------------------------------------------
-- Time parsing
---------------------------------------------------------------------------

-- Resolve an event's start time to a unix-seconds timestamp.
--
-- The platform's addon export ships `start_ts` (UTC unix seconds,
-- computed server-side from the event's IANA timezone) since the
-- timezone-aware export commit. Use it when present — it's the
-- authoritative answer and correct across all member timezones.
--
-- Fallback: parse the wall-clock date+time strings in the user's
-- local timezone via Lua's time(table). This is wrong when the WoW
-- client is in a different region than the raid schedule (Paris
-- raids viewed from HK, etc.) — Events tab will flip to "Past"
-- mid-raid, FindActiveScheduledEvent windows shift. But it's all we
-- can do for events imported before the platform shipped start_ts;
-- matches the legacy behaviour exactly so re-import is the clean
-- upgrade path.
local function ParseEventTime(event)
    if not event then return nil end
    local serverTs = tonumber(event.start_ts)
    if serverTs and serverTs > 0 then return serverTs end

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
        if not teamId or ev.team_id == teamId or ev.teamId == teamId then
            local t = ParseEventTime(ev)
            -- "Today" = the event's local day in the user's timezone
            -- matches our local today. Derive from the parsed timestamp
            -- when available (start_ts path) so a Paris raid the HK
            -- viewer is actually in matches even when ev.date says
            -- yesterday. Falls back to the raw ev.date string for
            -- legacy events where ParseEventTime used local-time math.
            local evDay = (t and date("%Y-%m-%d", t)) or ev.date
            if evDay == today and t then
                local d = math.abs(t - now)
                if d < bestDelta then best, bestDelta = ev, d end
            end
        end
    end
    return best
end

--- Return the character names that committed to attending an event.
--- Status filter matches COMMITTED_SIGNUP_STATUSES (P/L/B/LT) by
--- default. Pass includeBench=false to drop B (Bench) — the
--- split-button's primary action uses this to match the semantic of
--- "Bench = available if needed, not actively going."
function WGS:GetEventSignups(eventId, includeBench)
    local names = {}
    if not eventId then return names end
    local signups = self.db.global.signups
    if not signups then return names end
    -- Default (no arg) = include bench, preserves the legacy callers
    -- (export pipeline, status counts) that aren't about invites.
    if includeBench == nil then includeBench = true end
    for _, s in ipairs(signups) do
        local committed = COMMITTED_SIGNUP_STATUSES[s.status]
        local benchSkip = not includeBench and s.status == "B"
        if s.eventId == eventId
           and s.characterName
           and committed
           and not benchSkip
        then
            names[#names + 1] = s.characterName
        end
    end
    return names
end

--- Get the invite list for an event. Source preference:
---   1. Event signups (web platform's source of truth — who said "I'm in")
---   2. Raid comp assignments (planned roster for this event)
---   3. Team roster (everyone on the team — broadest net)
---
--- opts.includeBench (default false): include B (Bench) status when
---   pulling from signups. Bench-included is the dropdown override on
---   the split button; the primary action excludes bench.
--- opts.sourceOverride: "roster" forces the team-roster source, skipping
---   the signups + comp tiers. Used by the split button's "Invite team
---   roster" dropdown option.
function WGS:GetEventInviteList(event, opts)
    opts = opts or {}
    local eventId = event.id or event.eventId

    -- Team-roster override skips ahead to tier 3.
    if opts.sourceOverride == "roster" then
        local teamId = event.team_id or event.teamId
        if teamId then
            local teams = self.db.global.teams
            if teams then
                for _, t in ipairs(teams) do
                    if t.id == teamId then
                        local names = {}
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
        return {}, "team roster"   -- override fell through
    end

    -- 1. Event signups — primary source. If the web has signups for this
    -- event, that's what officers actually committed to. Comp slots may
    -- be stale or speculative; team roster pulls in benched players.
    if eventId then
        local signupNames = self:GetEventSignups(eventId, opts.includeBench)
        if #signupNames > 0 then
            return signupNames, "signups"
        end
    end

    -- 2. Raid comp — fall back to the planned comp's character list.
    if eventId then
        local comp = self:GetRaidComp(eventId)
        if comp and comp.assignments and #comp.assignments > 0 then
            local names = {}
            for _, a in ipairs(comp.assignments) do
                if a.name then names[#names + 1] = a.name end
            end
            return names, "raid comp"
        end
    end

    -- 3. Team roster — broadest net, used when neither signups nor comp
    -- are available (e.g. ad-hoc weekly raid without sign-ups recorded).
    local teamId = event.team_id or event.teamId
    if teamId then
        local teams = self.db.global.teams
        if teams then
            for _, t in ipairs(teams) do
                if t.id == teamId then
                    local names = {}
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

    return {}, nil
end

---------------------------------------------------------------------------
-- /gh invite — manual auto-invite
---------------------------------------------------------------------------

function WGS:AutoInvite(eventOverride, opts)
    opts = opts or {}
    -- Permission gate. Lead-or-assist on the group (if any) + officer
    -- rank in the guild. Both branches print a clear reason and bail
    -- before we touch anything.
    local ok, reason = self:HasGroupLeadOrAssist()
    if not ok then
        if reason == "raid-need-lead" then
            self:Print(L["ERR_RAID_LEAD_FOR_INVITE"])
        elseif reason == "party-need-lead" then
            self:Print(L["ERR_PARTY_LEAD_FOR_INVITE"])
        end
        return
    end
    if not IsInGuild() then
        self:Print(L["ERR_NEED_GUILD"])
        return
    end
    if not self:IsGuildOfficer() then
        self:Print(L["ERR_NEED_OFFICER_INVITE"])
        return
    end

    -- eventOverride lets callers (e.g. the rail-row kebab's "Invite
    -- signups" item) target a specific event regardless of which
    -- one is "today's." Falls back to the existing today-resolution
    -- when no override is supplied — preserves the /gh invite flow.
    local event = eventOverride or self:FindTodayEventForTeam(nil)
    if not event then
        self:Print(L["NO_EVENT_TODAY"])
        return
    end

    local names, source = self:GetEventInviteList(event, opts)
    if #names == 0 then
        self:Print(string.format(L["INVITE_NONE_FOR"], event.title or "?"))
        return
    end

    local roster = self:GetGuildRosterLookup()
    local myKey = self:GetPlayerKey()
    local invited = 0

    -- Fire invites in a single tick. The previous 3s-per-invite stagger
    -- meant a 25-person raid took 75 seconds to start; WoW handles a
    -- burst of InviteUnit calls fine in practice.
    for _, name in ipairs(names) do
        local short = name:match("^([^%-]+)")
        if short and not invitedThisSession[short] then
            local gi = roster[short]
            if gi and gi.online and gi.fullName ~= myKey then
                -- Skip if already in group
                if not module:IsInCurrentGroup(gi.fullName) then
                    invitedThisSession[short] = true
                    invited = invited + 1
                    C_PartyInfo.InviteUnit(gi.fullName)
                end
            end
        end
    end

    if invited > 0 then
        self:Print(string.format(L["INVITE_SUMMARY"], invited, event.title or "?", source or "roster"))
        -- Auto-sort raid groups once invites have had time to land.
        -- The previous guard (`source == "raid comp"`) skipped the
        -- sort whenever signups existed — but signups take priority
        -- over comp, so in the common case (officers using signups
        -- on guildhall.run) invited raiders never got placed in
        -- their planned groups. New rule: schedule the sort whenever
        -- the event HAS a comp with at least one group assignment,
        -- regardless of which list we used for the invites.
        local eventId = event.id or event.eventId
        local comp = eventId and self:GetRaidComp(eventId) or nil
        local hasGroups = false
        if comp and comp.assignments then
            for _, a in ipairs(comp.assignments) do
                if a.group then hasGroups = true; break end
            end
        end
        if hasGroups then
            C_Timer.After(SORT_AFTER_INVITE_DELAY, function()
                if IsInRaid() then self:SortRaidGroups() end
            end)
        end
    else
        self:Print(L["INVITE_ALL_IN"])
    end
end

---------------------------------------------------------------------------
-- /gh sortgroups — assign raid subgroups from comp
---------------------------------------------------------------------------

function WGS:SortRaidGroups()
    if not IsInRaid() then
        self:Print(L["ERR_NEED_RAID_TO_SORT"])
        return
    end
    local ok = self:HasGroupLeadOrAssist()
    if not ok then
        self:Print(L["ERR_RAID_LEAD_FOR_SORT"])
        return
    end

    local event = self:FindTodayEventForTeam(nil)
    if not event then
        self:Print(L["NO_EVENT_TODAY"])
        return
    end

    local eventId = event.id or event.eventId
    if not eventId then
        self:Print(L["EVENT_NO_ID"])
        return
    end

    local comp = self:GetRaidComp(eventId)
    if not comp or not comp.assignments then
        self:Print(L["NO_COMP_FOR_EVENT"])
        return
    end

    -- Build name → target group lookup from comp assignments
    local targetGroup = {}
    local hasGroups = false
    for _, a in ipairs(comp.assignments) do
        if a.group and a.name then
            local short = a.name:match("^([^%-]+)") or a.name
            targetGroup[short:lower()] = tonumber(a.group)
            hasGroups = true
        end
    end

    if not hasGroups then
        -- No group data in comp — assign by role: tanks→1, healers→2, dps→3+
        local roleGroup = { TANK = 1, HEALER = 2 }
        local dpsGroup = 3
        for _, a in ipairs(comp.assignments) do
            if a.name then
                local short = (a.name:match("^([^%-]+)") or a.name):lower()
                local role = self:NormalizeRole(a.role)
                targetGroup[short] = roleGroup[role] or dpsGroup
            end
        end
    end

    -- Apply to current raid
    local moved = 0
    for i = 1, GetNumGroupMembers() do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if name then
            local short = name:match("^([^%-]+)") or name
            local target = targetGroup[short:lower()]
            if target and target ~= subgroup then
                SetRaidSubgroup(i, target)
                moved = moved + 1
            end
        end
    end

    if moved > 0 then
        self:Print(string.format(L["SORT_SUMMARY"], moved))
    else
        self:Print(L["SORT_NONE"])
    end
end

---------------------------------------------------------------------------
-- Guild roster watch (lightweight, no polling)
---------------------------------------------------------------------------

function module:OnGuildRosterUpdate()
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

--- Find the event whose scheduled window contains "now" — used by
--- Modules/Attendance.lua to auto-pick a team without prompting the user.
---
--- Window: [scheduledStart - LEAD, scheduledStart + TRAIL]. LEAD covers
--- raid leaders entering the instance early to set up; TRAIL covers
--- starting a session late (officer was AFK at pull). If exactly one
--- event matches, it wins. If zero or multiple match, return nil and
--- let attendance start untagged — the user explicitly chose this over
--- a "best match" heuristic to avoid silent mis-tagging.
local AUTO_WINDOW_LEAD  = 30 * 60      -- 30 minutes before scheduled start
local AUTO_WINDOW_TRAIL = 60 * 60      -- 1 hour after scheduled start

function WGS:FindActiveScheduledEvent(now, leadOverride, trailOverride)
    local events = self.db.global.events
    if not events or #events == 0 then return nil end
    now = now or time()
    local lead  = leadOverride  or AUTO_WINDOW_LEAD
    local trail = trailOverride or AUTO_WINDOW_TRAIL

    local matched = nil
    for _, ev in ipairs(events) do
        local start = ParseEventTime(ev)
        if start and now >= (start - lead) and now <= (start + trail) then
            if matched then
                -- Ambiguous — multiple events overlap this instant. Bail out
                -- to untagged rather than guess which one this raid is for.
                return nil
            end
            matched = ev
        end
    end
    return matched
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function module:IsInCurrentGroup(fullName)
    if not WGS:IsInAnyGroup() then return false end
    if fullName == WGS:GetPlayerKey() then return true end

    -- Use UnitFullName for both raid and party — gives consistent (name, realm)
    -- output across cross-realm and same-realm members. GetRaidRosterInfo
    -- returns realm-suffixed only for cross-realm; UnitFullName is uniform.
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and GetNumGroupMembers() or (GetNumGroupMembers() - 1)
    for i = 1, count do
        local uName, uRealm = UnitFullName(prefix .. i)
        if uName and WGS:NormalizeFullName(uName, uRealm) == fullName then
            return true
        end
    end
    return false
end
