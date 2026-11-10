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

-- Who we've fired an invite at this group session (short name → true).
-- This is NOT a gate on re-inviting — pressing Invite always re-invites
-- anyone who isn't already in the group, so stragglers who declined or
-- reconnected get pulled in whenever the officer clicks (no cooldown, no
-- "all invited" dead end). It's kept purely so the raid-status snapshot
-- can tell "invite sent, waiting on them" apart from "not invited yet."
-- Wiped when the officer drops to solo (a fresh group starts clean).
local invitedThisSession = {}

--- Read-only view of who's been invited this group session. Used by the
--- raid-status snapshot (WGS:BuildInviteSnapshot) to mark pending invites.
function WGS:HasInvited(shortName)
    return shortName ~= nil and invitedThisSession[shortName] == true
end

--- Clear the invited-this-session set. Called when the group disbands so
--- the next raid's snapshot doesn't show stale "pending" markers.
function WGS:ResetInviteTracking()
    invitedThisSession = {}
end

function module:OnEnable()
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnGroupRosterUpdate")
end

-- Drop the invited-set the moment we're no longer in any group, so the
-- next group we form starts with a clean "nobody invited yet" snapshot.
function module:OnGroupRosterUpdate()
    if not WGS:IsInAnyGroup() then
        WGS:ResetInviteTracking()
    end
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

--- Every event on today's local date for `teamId` (nil = all teams).
function WGS:GetTodayEvents(teamId)
    local out = {}
    local events = self.db.global.events
    if not events then return out end
    local today = date("%Y-%m-%d")
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
            if evDay == today and t then out[#out + 1] = ev end
        end
    end
    return out
end

--- Today's event for `teamId` (nil = all teams) closest to now.
function WGS:FindTodayEventForTeam(teamId)
    local now = time()
    local best, bestDelta = nil, math.huge
    for _, ev in ipairs(self:GetTodayEvents(teamId)) do
        local d = math.abs(ParseEventTime(ev) - now)
        if d < bestDelta then best, bestDelta = ev, d end
    end
    return best
end

-- Return the character names that committed to attending an event.
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
--- Expand a team id into its full character-name list: each player's
--- main plus every mapped alt (legacy team shape: the flat `members`
--- array). Returns nil when the team isn't in db.global.teams — the
--- callers in GetEventInviteList distinguish "no such team" from an
--- empty roster.
local function expandTeamRoster(self, teamId)
    if not teamId then return nil end
    local teams = self.db.global.teams
    if not teams then return nil end
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
            return names
        end
    end
    return nil
end

function WGS:GetEventInviteList(event, opts)
    opts = opts or {}
    local eventId = event.id or event.eventId

    -- Team-roster override skips ahead to tier 3.
    if opts.sourceOverride == "roster" then
        local names = expandTeamRoster(self, event.team_id or event.teamId)
        return names or {}, "team roster"
    end

    -- 1. Event signups — primary source. If the web has signups for this
    -- event, that's what officers actually committed to. Comp slots may
    -- be stale or speculative; team roster pulls in benched players.
    --
    -- Invite path defaults to EXCLUDING bench — Bench = "available if
    -- needed", not "actively going." Marking a Present player as Bench
    -- then hitting Invite shouldn't pull them in. The split button's
    -- arrow dropdown opts back in via opts.includeBench = true.
    -- (Note: GetEventSignups's nil-default is true to preserve legacy
    -- non-invite callers like the export pipeline; the invite path has
    -- to be explicit.)
    if eventId then
        local includeBench = opts.includeBench == true
        local signupNames = self:GetEventSignups(eventId, includeBench)
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
    local names = expandTeamRoster(self, event.team_id or event.teamId)
    if names then
        return names, "team roster"
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
    --
    -- The ONLY skip is "already in the group" — there's no cooldown. Press
    -- Invite as often as you like: everyone online who isn't in the group
    -- yet gets (re-)invited, so people who declined the first invite or
    -- disconnected-and-came-back are pulled in the moment you click again.
    for _, name in ipairs(names) do
        local short = WGS:ShortName(name)
        if short ~= "" then
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
                if IsInRaid() then self:SortRaidGroups(event) end
            end)
        end
    else
        self:Print(L["INVITE_ALL_IN"])
    end
end

---------------------------------------------------------------------------
--- WoW raid subgroups are 1..8. SetRaidSubgroup raises a hard Lua error
--- ("Usage: SetRaidSubgroup(index, subgroup)") on anything else rather
--- than failing quietly, so every value from imported data is checked
--- here before it gets near the API — a malformed comp should sort
--- nothing, not blow up mid-raid in front of the raid leader.
local MAX_RAID_SUBGROUP = 8

local function validSubgroup(value)
    local n = tonumber(value)
    if not n then return nil end
    n = math.floor(n)
    if n < 1 or n > MAX_RAID_SUBGROUP then return nil end
    return n
end

local GROUP_SIZE = 5

--- Who goes where, for a comp: lowercased short name → planned subgroup,
--- plus the standby set (on the comp but with no group — the comp's
--- Standby bucket). A comp without any group data falls back to role
--- groups (tanks 1, healers 2, dps 3) and has no standby.
local function compTargets(self, comp)
    local target, standby, hasGroups = {}, {}, false
    for _, a in ipairs(comp.assignments or {}) do
        -- Any group value at all means the comp carries group data; a
        -- corrupt one (0, 99) places nobody rather than dropping the whole
        -- comp to the role fallback.
        if a.group ~= nil then hasGroups = true end
        if a.group and a.name and not a.placeholder then
            local g = validSubgroup(a.group)
            if g then target[(WGS:ShortName(a.name)):lower()] = g end
        end
    end
    if not hasGroups then
        local roleGroup = { TANK = 1, HEALER = 2 }
        for _, a in ipairs(comp.assignments or {}) do
            if a.name and not a.placeholder then
                target[(WGS:ShortName(a.name)):lower()] = roleGroup[self:NormalizeRole(a.role)] or 3
            end
        end
        return target, standby
    end
    for _, a in ipairs(comp.assignments or {}) do
        local k = a.name and (WGS:ShortName(a.name)):lower()
        -- Pug placeholders aren't characters: nobody in the raid is named
        -- "+ Pug", so they never match and never move anyone.
        if k and a.group == nil and not a.placeholder and target[k] == nil then standby[k] = true end
    end
    return target, standby
end

--- Pure planner: the moves that put a raid into a comp's groups.
---
--- `roster` = { { index, short, subgroup } }, `target` = short → group,
--- `standby` = short → true. Returns { { op = "set", index, group } |
--- { op = "swap", a, b } } in the order to apply them.
---
--- WoW's SetRaidSubgroup into a FULL group does nothing at all, so the
--- old one-pass "set everyone's group" lost every move into a group that
--- hadn't emptied yet. This keeps its own model of the groups (the API's
--- roster doesn't update until the server answers, so re-reading it
--- mid-sort would lie) and swaps with someone who doesn't belong there
--- when the destination is full.
---
--- Standby raiders move to the groups after the last playing one (5-8
--- for a 4-group comp) when `opts.standbyToBack`; raiders the comp
--- doesn't place are never chased, only swapped out when a planned
--- raider needs their seat and nobody misplaced is left to trade with.
function WGS:PlanGroupMoves(roster, target, standby, opts)
    opts = opts or {}
    local ops, cur, count, short = {}, {}, {}, {}
    for g = 1, MAX_RAID_SUBGROUP do count[g] = 0 end
    for _, r in ipairs(roster) do
        local g = validSubgroup(r.subgroup) or 1
        cur[r.index] = g
        short[r.index] = (r.short or ""):lower()
        count[g] = count[g] + 1
    end

    local lastPlaying = 0
    for _, g in pairs(target) do if g > lastPlaying then lastPlaying = g end end
    lastPlaying = math.max(lastPlaying, 4)
    local function wants(i) return target[short[i]] end
    local function isStandby(i) return standby[short[i]] == true end
    local function belongs(i, g)
        local w = wants(i)
        if w then return w == g end
        if isStandby(i) and opts.standbyToBack then return g > lastPlaying end
        return true   -- not on the comp: wherever they are is fine
    end

    local function set(i, g)
        count[cur[i]] = count[cur[i]] - 1
        count[g] = count[g] + 1
        cur[i] = g
        ops[#ops + 1] = { op = "set", index = i, group = g }
    end
    local function swap(i, j)
        cur[i], cur[j] = cur[j], cur[i]
        ops[#ops + 1] = { op = "swap", a = i, b = j }
    end

    local function moveStandbyBack()
        if not opts.standbyToBack then return end
        for _, r in ipairs(roster) do
            local i = r.index
            if isStandby(i) and cur[i] <= lastPlaying then
                for g = lastPlaying + 1, MAX_RAID_SUBGROUP do
                    if count[g] < GROUP_SIZE then set(i, g); break end
                end
            end
        end
    end

    moveStandbyBack()
    -- Two passes: a move that found its group full the first time can
    -- succeed once a later raider has moved out of it.
    for _ = 1, 2 do
        for _, r in ipairs(roster) do
            local i = r.index
            local d = wants(i)
            if d and cur[i] ~= d then
                if count[d] < GROUP_SIZE then
                    set(i, d)
                else
                    -- Full: trade places with someone who doesn't belong
                    -- there — ideally someone who belongs where i is now.
                    -- Last resort, someone the comp doesn't place at all
                    -- (a trial, an alt, a name spelled differently): a
                    -- planned raider plays before an unplanned one sits.
                    local pick, fallback, lastResort
                    for _, o in ipairs(roster) do
                        local j = o.index
                        if j ~= i and cur[j] == d then
                            if not belongs(j, d) then
                                if belongs(j, cur[i]) then pick = j; break end
                                fallback = fallback or j
                            elseif not wants(j) then
                                lastResort = lastResort or j
                            end
                        end
                    end
                    pick = pick or fallback or lastResort
                    if pick then swap(i, pick) end
                end
            end
        end
    end
    moveStandbyBack()
    return ops
end

local function rosterSnapshot()
    local roster = {}
    for i = 1, GetNumGroupMembers() do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if name then
            roster[#roster + 1] = { index = i, short = WGS:ShortName(name), subgroup = subgroup }
        end
    end
    return roster
end

-- Group changes are asked of the server and land on the client's roster
-- a moment later. Firing a whole plan at once means every move after the
-- first was planned against a roster that is already out of date — and a
-- move into a group the client still thinks is full can be dropped. So a
-- sort runs one move at a time: issue it, wait until the roster shows it
-- (or give up waiting), re-read the roster, re-plan, repeat.
local SORT_STEP_DELAY = 0.25   -- seconds between roster checks
local SORT_STEP_WAIT  = 8      -- checks to wait for one move to land
local SORT_MAX_STEPS  = 40     -- a 30-man raid needs far fewer
local sortGeneration = 0       -- a newer sort supersedes a running one
local sortRunning = false

local function combatBusy()
    return (InCombatLockdown and InCombatLockdown())
        or (IsEncounterInProgress and IsEncounterInProgress()) or false
end

-- name → subgroup on the live roster.
local function groupsByName()
    local out = {}
    for _, r in ipairs(rosterSnapshot()) do out[r.short:lower()] = r.subgroup end
    return out
end

-- Issue one planned op; returns what the roster should then show
-- ({ name → group }) and the names it moves.
local function issueOp(op, roster)
    local byIndex = {}
    for _, r in ipairs(roster) do byIndex[r.index] = r end
    if op.op == "set" then
        local r, g = byIndex[op.index], validSubgroup(op.group)
        if not r or not g then return nil end
        SetRaidSubgroup(op.index, g)
        return { [r.short:lower()] = g }, { r.short }
    elseif op.op == "swap" and SwapRaidSubgroup then
        local a, b = byIndex[op.a], byIndex[op.b]
        if not a or not b then return nil end
        SwapRaidSubgroup(op.a, op.b)
        return { [a.short:lower()] = b.subgroup, [b.short:lower()] = a.subgroup }, { a.short, b.short }
    end
    return nil
end

--- Run a sort to completion, one move at a time. `plan()` returns the
--- moves for the CURRENT roster; `done(movedNames)` is called once at the
--- end. Without C_Timer (tests) every step runs immediately.
local function runSort(plan, done)
    sortGeneration = sortGeneration + 1
    local gen = sortGeneration
    sortRunning = true
    local moved, movedList, steps = {}, {}, 0
    local expect, waited

    local function finish()
        if gen ~= sortGeneration then return end
        sortRunning = false
        done(movedList)
    end

    local step
    local function later()
        if C_Timer and C_Timer.After then
            C_Timer.After(SORT_STEP_DELAY, step)
            return true
        end
        return false
    end

    step = function()
        if gen ~= sortGeneration then return end          -- superseded
        if not IsInRaid() or combatBusy() then return finish() end
        if expect then
            -- Wait for the last move to show before planning the next,
            -- or a swap would be re-issued and undo itself.
            local now = groupsByName()
            local landed = true
            for name, g in pairs(expect) do
                if now[name] ~= nil and now[name] ~= g then landed = false end
            end
            if not landed then
                if waited < SORT_STEP_WAIT and later() then
                    waited = waited + 1
                    return
                end
                -- The move never showed up — refused, or the raid changed
                -- under us. Stop rather than re-issue it forever.
                return finish()
            end
            expect = nil
        end
        if steps >= SORT_MAX_STEPS then return finish() end
        local roster = rosterSnapshot()
        local op = plan(roster)[1]
        if not op then return finish() end
        local e, names = issueOp(op, roster)
        steps = steps + 1
        if not e then return finish() end
        for _, n in ipairs(names) do
            if not moved[n] then moved[n] = true; movedList[#movedList + 1] = n end
        end
        expect, waited = e, 0
        if not later() then return step() end
    end
    step()
end

-- /gh sortgroups — assign raid subgroups from comp
---------------------------------------------------------------------------

-- eventOverride lets the "Organize Groups" button (UI/EventsDetail.lua)
-- sort against the specific event the officer is viewing, instead of
-- whichever one FindTodayEventForTeam resolves. The no-arg /gh sortgroups
-- + the auto-sort-after-invite path keep the today-resolution fallback.
--
-- bossOverride picks a lineup boss's comp; without it the sort uses the
-- boss the raid is currently on (WGS:GetCompBoss — advanced on each kill),
-- else the night default.
function WGS:SortRaidGroups(eventOverride, bossOverride)
    if not IsInRaid() then
        self:Print(L["ERR_NEED_RAID_TO_SORT"])
        return
    end
    local ok = self:HasGroupLeadOrAssist()
    if not ok then
        self:Print(L["ERR_RAID_LEAD_FOR_SORT"])
        return
    end
    if combatBusy() then
        self:Print(L["ERR_SORT_IN_COMBAT"])
        return
    end

    local event = eventOverride or self:FindTodayEventForTeam(nil)
    if not event then
        self:Print(L["NO_EVENT_TODAY"])
        return
    end

    local eventId = event.id or event.eventId
    if not eventId then
        self:Print(L["EVENT_NO_ID"])
        return
    end

    local boss = bossOverride
    if boss == nil then boss = self:GetCompBoss(eventId) end
    if boss == "" then boss = nil end
    local comp = self:GetRaidComp(eventId, boss)
    if not comp or not comp.assignments then
        self:Print(L["NO_COMP_FOR_EVENT"])
        return
    end

    local target, standby = compTargets(self, comp)
    local opts = { standbyToBack = self.db.profile.standbyToBackGroups ~= false }
    local label = boss or L["COMP_NIGHT_DEFAULT"]
    runSort(function(roster)
        return self:PlanGroupMoves(roster, target, standby, opts)
    end, function(movedList)
        if #movedList > 0 then
            self:Print(string.format(L["SORT_SUMMARY_FOR"], #movedList, label))
        else
            self:Print(string.format(L["SORT_NONE_FOR"], label))
        end
    end)
end

--- Place a single raider into their planned comp subgroup, if the comp
--- for `eventId` assigns them one and they aren't already in it. Returns
--- true when a move happened. No-op (false) when there's no comp, the
--- raider has no group assignment, we lack raid lead/assist, a full sort
--- is already running, it's mid-pull, or they're already in place.
--- Powers the auto-place-on-accept flow so a raider lands in their group
--- the moment they join, WITHOUT reshuffling anyone already placed (that's
--- what SortRaidGroups is for) — so a full group is skipped, never swapped
--- into. Same rule as a full sort (compTargets): the comp of the boss the
--- raid is on, role groups for a comp with no group data, and a raider the
--- comp has on standby goes to a back group.
function WGS:PlaceRaiderInCompGroup(shortName, eventId)
    if not shortName or not eventId then return false end
    if not IsInRaid() then return false end
    if sortRunning or combatBusy() then return false end
    if not self:HasGroupLeadOrAssist() then return false end

    local comp = self:GetRaidComp(eventId, self:GetCompBoss(eventId))
    if not comp or not comp.assignments then return false end

    local wanted = shortName:lower()
    local targets, standby = compTargets(self, comp)
    local target = targets[wanted]

    local roster = rosterSnapshot()
    local count, mine = {}, nil
    for g = 1, MAX_RAID_SUBGROUP do count[g] = 0 end
    local lastPlaying = 4
    for _, g in pairs(targets) do if g > lastPlaying then lastPlaying = g end end
    for _, r in ipairs(roster) do
        local g = validSubgroup(r.subgroup)
        if g then count[g] = count[g] + 1 end
        if r.short:lower() == wanted then mine = r end
    end
    if not mine then return false end

    if not target and standby[wanted] and self.db.profile.standbyToBackGroups ~= false
        and (validSubgroup(mine.subgroup) or 1) <= lastPlaying then
        for g = lastPlaying + 1, MAX_RAID_SUBGROUP do
            if count[g] < GROUP_SIZE then target = g; break end
        end
    end
    if not target or mine.subgroup == target then return false end
    if count[target] >= GROUP_SIZE then return false end
    SetRaidSubgroup(mine.index, target)
    return true
end

---------------------------------------------------------------------------
-- Boss lineup: follow the raid through tonight's bosses
---------------------------------------------------------------------------

-- The event a pull or kill belongs to: the tracked attendance session's.
-- Without one, today's event — but only when exactly ONE of today's
-- events has a lineup: two teams raiding the same tier the same night
-- share boss names, and guessing would follow (and sort for) the other
-- team's plan.
local function planEventId(self)
    local ctx = self.GetCurrentAttendanceContext and self:GetCurrentAttendanceContext()
    if ctx and ctx.eventId then return ctx.eventId end
    local found
    for _, ev in ipairs(self:GetTodayEvents(nil)) do
        local id = ev.id or ev.eventId
        local plan = id and self:GetRaidPlan(id)
        if plan and #(plan.bosses or {}) > 0 then
            if found then return nil end
            found = id
        end
    end
    return found
end
WGS._PlanEventId = planEventId

local PENDING_SORT_TIMEOUT = 300   -- seconds; a sort waits at most one pull
local pendingSort   -- { event = {id}, boss, deadline } waiting for combat to end

local function pollPendingSort()
    if not pendingSort then return end
    if time() > pendingSort.deadline then pendingSort = nil; return end
    if combatBusy() then
        if C_Timer and C_Timer.After then C_Timer.After(1, pollPendingSort) end
        return
    end
    WGS:RunPendingSort()
end

--- Sort now, or as soon as it's safe. Raid groups can't be reshuffled
--- mid-pull, and ENCOUNTER_END usually fires a beat before combat drops.
--- Waits on both signals: PLAYER_REGEN_ENABLED covers the common case, and
--- a short poll covers an officer who was already out of combat (dead,
--- say) while the encounter itself was still running.
function WGS:SortWhenSafe(event, boss)
    if not combatBusy() then
        self:SortRaidGroups(event, boss or "")
        return true
    end
    pendingSort = { event = event, boss = boss or "", deadline = time() + PENDING_SORT_TIMEOUT }
    module:RegisterEvent("PLAYER_REGEN_ENABLED", "OnRegenEnabled")
    if C_Timer and C_Timer.After then C_Timer.After(1, pollPendingSort) end
    return false
end

--- Run the sort SortWhenSafe deferred. Returns true when it ran; false
--- when there was none, or it still isn't safe (it stays pending).
function WGS:RunPendingSort()
    local p = pendingSort
    if not p then return false end
    if combatBusy() then return false end
    pendingSort = nil
    if IsInRaid() then self:SortRaidGroups(p.event, p.boss) end
    return true
end

function module:OnRegenEnabled()
    module:UnregisterEvent("PLAYER_REGEN_ENABLED")
    pollPendingSort()
end

local function joinNames(list)
    if #list == 0 then return nil end
    return table.concat(list, ", ")
end

-- The next boss to plan for after `idx`: the first one after it the raid
-- hasn't killed tonight, else the first skipped one before it. nil when
-- everything on the lineup is dead.
local function nextUnkilled(self, eventId, plan, idx)
    for i = idx + 1, #plan.bosses do
        if not self:IsBossKilled(eventId, plan.bosses[i].name) then return plan.bosses[i] end
    end
    for i = 1, idx - 1 do
        if not self:IsBossKilled(eventId, plan.bosses[i].name) then return plan.bosses[i] end
    end
    return nil
end

--- A pull on a lineup boss puts the raid on that boss's comp (so skipping
--- one in the order doesn't leave the plan a boss behind). A boss already
--- killed tonight — a re-pull on another difficulty — changes nothing.
function WGS:OnLineupBossPulled(encounterID, encounterName)
    local eventId = planEventId(self)
    local plan = self:GetRaidPlan(eventId)
    local _, entry = self:FindPlanBoss(plan, encounterName, encounterID)
    if not entry or self:IsBossKilled(eventId, entry.name) then return end
    if self:GetCompBoss(eventId) ~= entry.name then
        self:SetCompBoss(eventId, entry.name)
    end
end

--- A kill moves the raid to the next boss it hasn't killed tonight:
--- prints who comes in and who goes to standby, and — with auto-sort on
--- and lead/assist — sorts the groups for it as soon as it's safe. A kill
--- of a boss that isn't on the lineup, or one already killed tonight,
--- changes nothing: the plan never walks backwards. Returns the next
--- boss's entry.
function WGS:OnLineupBossKilled(encounterID, encounterName)
    local eventId = planEventId(self)
    local plan = self:GetRaidPlan(eventId)
    local idx, killed = self:FindPlanBoss(plan, encounterName, encounterID)
    if not idx or self:IsBossKilled(eventId, killed.name) then return nil end
    self:MarkBossKilled(eventId, killed.name)

    local nextBoss = nextUnkilled(self, eventId, plan, idx)
    local isLead = self:HasGroupLeadOrAssist()
    if not nextBoss then
        if isLead then self:Print(L["LINEUP_DONE"]) end
        return nil
    end
    self:SetCompBoss(eventId, nextBoss.name)
    if not isLead then return nextBoss end

    local swaps = self:CompSwaps(self:GetRaidComp(eventId, killed.name), self:GetRaidComp(eventId, nextBoss.name))
    local parts = {}
    local incoming, out = joinNames(swaps.incoming), joinNames(swaps.standby)
    if incoming then parts[#parts + 1] = string.format(L["LINEUP_IN"], incoming) end
    if out then parts[#parts + 1] = string.format(L["LINEUP_STANDBY"], out) end
    if #parts == 0 then
        parts[1] = swaps.regroup and L["LINEUP_REGROUP"] or L["LINEUP_SAME"]
    end
    self:Print(string.format(L["LINEUP_NEXT"], nextBoss.name, table.concat(parts, " \194\183 ")))

    if self.db.profile.autoSortGroups and IsInRaid() and (#swaps.incoming + #swaps.standby > 0 or swaps.regroup) then
        self:SortWhenSafe({ id = eventId }, nextBoss.name)
    end
    return nextBoss
end

---------------------------------------------------------------------------
-- Raid-status snapshot — who's in / pending / not-invited / offline
---------------------------------------------------------------------------

--- Live who's-here snapshot for an event. For each character on the
--- invite list, classify their current state so the officer can see at a
--- glance who still needs chasing rather than eyeballing 20 unit frames.
---
--- row.live ∈:
---   "in-raid"     — already in the group (accepted the invite / was here)
---   "invited"     — an invite was fired this session, still not in group
---   "not-invited" — online + in the guild, no invite fired yet
---   "offline"     — not online per the guild roster
---
--- Returns { rows = { { short, fullName, class, status, live }, ... },
---           counts = { inRaid, invited, notInvited, offline, total } }.
--- `status` is the character's signup code (P/L/T/B/…) when known.
--- opts is forwarded to GetEventInviteList (includeBench / sourceOverride).
function WGS:BuildInviteSnapshot(event, opts)
    local out = { rows = {}, counts = { inRaid = 0, invited = 0, notInvited = 0, offline = 0, total = 0 } }
    if not event then return out end

    local names = self:GetEventInviteList(event, opts) or {}
    local roster = self:GetGuildRosterLookup() or {}
    local groupSet = self:GetCurrentGroupShortNames()
    local myShort = self:ShortName(self:GetPlayerKey())

    -- Signup status per short name (so a "Late" signup who's now in the
    -- raid can show both dimensions).
    local eventId = event.id or event.eventId
    local statusByShort = {}
    for _, s in ipairs(self.db.global.signups or {}) do
        if s.eventId == eventId and s.characterName then
            local sh = WGS:ShortName(s.characterName)
            statusByShort[sh] = s.status
        end
    end

    local seen = {}
    for _, name in ipairs(names) do
        local short = WGS:ShortName(name)
        if short and not seen[short] then
            seen[short] = true
            local gi = roster[short]
            local live
            if groupSet[short] or short == myShort then
                live = "in-raid";     out.counts.inRaid     = out.counts.inRaid + 1
            elseif not (gi and gi.online) then
                live = "offline";     out.counts.offline    = out.counts.offline + 1
            elseif invitedThisSession[short] then
                live = "invited";     out.counts.invited    = out.counts.invited + 1
            else
                live = "not-invited"; out.counts.notInvited = out.counts.notInvited + 1
            end
            out.counts.total = out.counts.total + 1
            out.rows[#out.rows + 1] = {
                short    = short,
                fullName = (gi and gi.fullName) or name,
                class    = gi and gi.class or nil,
                status   = statusByShort[short],
                live     = live,
            }
        end
    end
    return out
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
