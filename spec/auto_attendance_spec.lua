local helpers = require("spec.helpers")

-- These tests exercise the window-match logic that replaces the team-picker
-- modal. The rule (Modules/EventScheduler.lua FindActiveScheduledEvent):
--   * Walk db.global.events
--   * Pick the one whose scheduled time falls within [now-30min, now+1h]
--   * Exactly one match → return it. Zero or multiple → return nil.
-- Returning nil makes Modules/Attendance.lua OnRaidEnter start untagged.

local function dateStringForNow()
    return os.date("%Y-%m-%d")
end

local function timeStringOffset(seconds)
    -- "HH:MM" string for (now + seconds), no AM/PM (24h form is supported)
    return os.date("%H:%M", os.time() + seconds)
end

describe("WGS:GetCurrentAttendanceContext", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("returns nil when no session is active", function()
        assert.is_nil(WGS:GetCurrentAttendanceContext())
    end)

    it("returns the team + event tagging after StartAttendanceForTeam", function()
        -- Stub the WoW state StartAttendanceForTeam reads.
        _G.IsInRaid          = function() return true end
        _G.IsInGroup         = function() return true end
        _G.GetInstanceInfo   = function() return "Test Raid", "raid", 16, "Mythic" end
        WGS.GetRaidMembers   = function() return {} end
        WGS.GetTimestamp     = function() return 1700000000 end

        WGS:StartAttendanceForTeam(42, "Mythic Raiders",
            { id = 7, title = "Tuesday Pulls" })

        local ctx = WGS:GetCurrentAttendanceContext()
        assert.is_table(ctx)
        assert.are.equal(42, ctx.teamId)
        assert.are.equal("Mythic Raiders", ctx.teamName)
        assert.are.equal(7, ctx.eventId)
        assert.are.equal(1700000000, ctx.startedAt)
    end)

    it("returns nil again after StopAttendance", function()
        _G.IsInRaid          = function() return true end
        _G.IsInGroup         = function() return true end
        _G.GetInstanceInfo   = function() return "Test Raid", "raid", 16, "Mythic" end
        WGS.GetRaidMembers   = function() return {} end
        WGS.GetTimestamp     = function() return 1700000000 end
        WGS.SnapshotRaidComp = function() end                -- no-op for this test
        WGS.HasAddon         = function() return false end   -- MRT not loaded
        WGS.ShowExportReminder = function() end              -- skip popup
        _G.C_Timer           = { After = function() end }    -- no-op scheduler

        WGS:StartAttendanceForTeam(42, "Mythic Raiders", { id = 7 })
        WGS:StopAttendance()
        assert.is_nil(WGS:GetCurrentAttendanceContext())
    end)
end)

describe("FindActiveScheduledEvent (auto-team resolution)", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("returns nil when no events are imported", function()
        WGS.db.global.events = {}
        assert.is_nil(WGS:FindActiveScheduledEvent())
    end)

    it("picks the event when its scheduled start is within the window", function()
        WGS.db.global.events = {
            { id = 1, team_id = 99, title = "Tonight raid",
              date = dateStringForNow(), time = timeStringOffset(10 * 60) }, -- starts in 10 min
        }
        local ev = WGS:FindActiveScheduledEvent()
        assert.is_not_nil(ev)
        assert.are.equal(99, ev.team_id)
    end)

    it("matches events that started up to 1 hour ago (officer joined late)", function()
        WGS.db.global.events = {
            { id = 2, team_id = 7, title = "Started 45min ago",
              date = dateStringForNow(), time = timeStringOffset(-45 * 60) },
        }
        local ev = WGS:FindActiveScheduledEvent()
        assert.is_not_nil(ev)
        assert.are.equal(7, ev.team_id)
    end)

    it("matches events scheduled to start in 30 minutes (officer arrived early)", function()
        WGS.db.global.events = {
            { id = 3, team_id = 5, title = "Starts in 25min",
              date = dateStringForNow(), time = timeStringOffset(25 * 60) },
        }
        local ev = WGS:FindActiveScheduledEvent()
        assert.is_not_nil(ev)
        assert.are.equal(5, ev.team_id)
    end)

    it("returns nil when the only candidate started over an hour ago", function()
        WGS.db.global.events = {
            { id = 4, team_id = 11, title = "Started 90min ago",
              date = dateStringForNow(), time = timeStringOffset(-90 * 60) },
        }
        assert.is_nil(WGS:FindActiveScheduledEvent())
    end)

    it("returns nil when the only candidate is more than 30 min away", function()
        WGS.db.global.events = {
            { id = 5, team_id = 12, title = "Starts in 90min",
              date = dateStringForNow(), time = timeStringOffset(90 * 60) },
        }
        assert.is_nil(WGS:FindActiveScheduledEvent())
    end)

    it("returns nil when two events overlap the window (ambiguous)", function()
        -- Two events with overlapping windows — we refuse to guess.
        WGS.db.global.events = {
            { id = 6, team_id = 21, title = "Team A raid",
              date = dateStringForNow(), time = timeStringOffset(0) },
            { id = 7, team_id = 22, title = "Team B raid",
              date = dateStringForNow(), time = timeStringOffset(15 * 60) },
        }
        assert.is_nil(WGS:FindActiveScheduledEvent())
    end)

    it("skips events whose date string is malformed instead of crashing", function()
        WGS.db.global.events = {
            { id = 8, team_id = 33, title = "Bad date", date = "not-a-date", time = "20:00" },
            { id = 9, team_id = 44, title = "Good event",
              date = dateStringForNow(), time = timeStringOffset(0) },
        }
        local ev = WGS:FindActiveScheduledEvent()
        assert.is_not_nil(ev)
        assert.are.equal(44, ev.team_id)
    end)
end)

describe("WGS:GetTeamName", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("returns the team's name when the id matches", function()
        WGS.db.global.teams = {
            { id = 1, name = "Alpha" },
            { id = 2, name = "Bravo" },
        }
        assert.are.equal("Bravo", WGS:GetTeamName(2))
    end)

    it("returns nil for an unknown id", function()
        WGS.db.global.teams = { { id = 1, name = "Alpha" } }
        assert.is_nil(WGS:GetTeamName(99))
    end)

    it("returns nil when teamId itself is nil (untagged session)", function()
        WGS.db.global.teams = { { id = 1, name = "Alpha" } }
        assert.is_nil(WGS:GetTeamName(nil))
    end)

    it("returns nil when no teams have been imported", function()
        WGS.db.global.teams = nil
        assert.is_nil(WGS:GetTeamName(7))
    end)
end)

-- Raid comp capture guarantees. The platform import errors with
-- "raid comp for event #n is missing" when an event has no matching
-- raidCompResults row. Two ways this used to happen:
--   (B) Session had no boss kills AND raid emptied before StopAttendance,
--       so the only snapshot attempts (kill + end-of-session) both
--       produced empty slot lists and recorded nothing.
--   (A) Session was started outside the auto-resolve window
--       [start-30min, start+1h] — eventId stayed nil, snapshots had
--       no event tag, platform couldn't link them.
-- These specs lock down the fixes for both.
describe("WGS:StartAttendanceForTeam raid-comp guarantee (Bug B)", function()
    local WGS
    before_each(function()
        WGS = helpers.setup()
        _G.IsInRaid        = function() return true end
        _G.IsInGroup       = function() return true end
        _G.GetInstanceInfo = function() return "Test Raid", "raid", 16, "Mythic" end
        WGS.GetTimestamp   = function() return 1700000000 end
        WGS.GetPlayerKey   = function() return "Tester-TestRealm" end
        WGS.ResolvePlayerForCharacter = function() return nil end
    end)

    it("records a snapshot at session start so a kill-less raid still has one", function()
        WGS.GetRaidMembers = function()
            return {
                ["Alpha-Realm"] = { class = "WARRIOR", role = "TANK",   subgroup = 1 },
                ["Beta-Realm"]  = { class = "PRIEST",  role = "HEALER", subgroup = 1 },
            }
        end
        assert.are.equal(0, #WGS.db.global.raidCompResults)
        WGS:StartAttendanceForTeam(42, "Mythic Raiders", { id = 7, title = "Tuesday" })
        assert.are.equal(1, #WGS.db.global.raidCompResults,
            "expected one snapshot recorded at session start")
        local snap = WGS.db.global.raidCompResults[1]
        assert.are.equal(7, snap.eventId)
        assert.are.equal(2, #snap.slots)
    end)

    it("doesn't record a snapshot if the raid roster is empty at start", function()
        WGS.GetRaidMembers = function() return {} end
        WGS:StartAttendanceForTeam(42, "Mythic Raiders", { id = 7, title = "Tuesday" })
        -- Empty roster → CaptureRaidComposition returns nil → no row.
        -- The platform will still flag this event as missing, but
        -- there's genuinely nothing to record — the user shouldn't be
        -- in a 0-person "raid" to begin with.
        assert.are.equal(0, #WGS.db.global.raidCompResults)
    end)
end)

describe("WGS:StopAttendance event back-resolution (Bug A)", function()
    local WGS
    before_each(function()
        WGS = helpers.setup()
        _G.IsInRaid        = function() return true end
        _G.IsInGroup       = function() return true end
        _G.GetInstanceInfo = function() return "Test Raid", "raid", 16, "Mythic" end
        WGS.GetPlayerKey   = function() return "Tester-TestRealm" end
        WGS.ResolvePlayerForCharacter = function() return nil end
        WGS.BuildBossAttendanceFromMRT = function() return {} end
        WGS.ShowExportReminder = function() end
    end)

    it("back-resolves eventId at session end via the wider window", function()
        local sessionStart = 1700000000
        -- Event scheduled 90 minutes before the session started — outside
        -- the strict [start-30m, start+1h] window the auto-flow uses,
        -- but inside the [start-2h, start+4h] wider window the back-
        -- resolution uses.
        local eventTs = sessionStart - 90 * 60
        WGS.db.global.events = {
            {
                id    = 99, title = "Reset Night",
                date  = os.date("%Y-%m-%d", eventTs),
                time  = os.date("%H:%M",    eventTs),
            },
        }

        WGS.GetTimestamp   = function() return sessionStart end
        WGS.GetRaidMembers = function()
            return { ["Alpha-Realm"] = { class = "WARRIOR", role = "TANK", subgroup = 1 } }
        end
        -- No event passed → auto-flow would have left eventId nil.
        WGS:StartAttendanceForTeam(42, "Mythic Raiders", nil)
        assert.is_nil(WGS:GetCurrentAttendanceContext().eventId,
            "precondition: session should start untagged")

        WGS.GetTimestamp = function() return sessionStart + 60 end
        WGS:StopAttendance()

        local sessions = WGS.db.global.attendance
        assert.are.equal(1, #sessions)
        assert.are.equal(99, sessions[1].eventId,
            "session should be back-resolved to the wider-window match")
        -- The startup snapshot must have its eventId backfilled too —
        -- that's what the platform import is going to use to link.
        for _, snap in ipairs(WGS.db.global.raidCompResults) do
            if snap.startedAt == sessionStart then
                assert.are.equal(99, snap.eventId,
                    "snapshots for this session must inherit the resolved eventId")
            end
        end
    end)

    it("leaves the session untagged when the wider window has no match", function()
        WGS.db.global.events = {}    -- nothing to match
        WGS.GetTimestamp   = function() return 1700000000 end
        WGS.GetRaidMembers = function()
            return { ["Alpha-Realm"] = { class = "WARRIOR", role = "TANK", subgroup = 1 } }
        end
        WGS:StartAttendanceForTeam(42, "Mythic Raiders", nil)
        WGS.GetTimestamp = function() return 1700000060 end
        WGS:StopAttendance()
        assert.is_nil(WGS.db.global.attendance[1].eventId)
    end)
end)

describe("WGS:ReconcileAttendanceEventBindings (retro fix)", function()
    local WGS
    before_each(function()
        WGS = helpers.setup()
    end)

    it("backfills orphan sessions + their raidCompResults rows", function()
        local sessionStart = 1700000000
        local eventTs = sessionStart - 30 * 60
        WGS.db.global.events = {
            {
                id    = 55, title = "Reset Night",
                date  = os.date("%Y-%m-%d", eventTs),
                time  = os.date("%H:%M",    eventTs),
            },
        }
        WGS.db.global.attendance = {
            { startedAt = sessionStart, eventId = nil,
              memberList = { { name = "Alpha", subgroup = 1, present = true } } },
        }
        WGS.db.global.raidCompResults = {
            { startedAt = sessionStart, eventId = nil, slots = { { name = "Alpha", group = 1 } } },
        }

        local bound, ambiguous, unmatched = WGS:ReconcileAttendanceEventBindings()
        assert.are.equal(1, bound)
        assert.are.equal(0, ambiguous)
        assert.are.equal(0, unmatched)
        assert.are.equal(55, WGS.db.global.attendance[1].eventId)
        assert.are.equal(55, WGS.db.global.raidCompResults[1].eventId)
    end)

    it("counts ambiguous separately when multiple events match a session's window", function()
        local sessionStart = 1700000000
        WGS.db.global.events = {
            { id = 1, title = "A",
              date = os.date("%Y-%m-%d", sessionStart - 60 * 60),
              time = os.date("%H:%M",    sessionStart - 60 * 60) },
            { id = 2, title = "B",
              date = os.date("%Y-%m-%d", sessionStart),
              time = os.date("%H:%M",    sessionStart) },
        }
        WGS.db.global.attendance = {
            { startedAt = sessionStart, eventId = nil, memberList = {} },
        }

        local bound, ambiguous, unmatched = WGS:ReconcileAttendanceEventBindings()
        assert.are.equal(0, bound)
        assert.are.equal(1, ambiguous,
            "two events inside the wider window → ambiguous, not bound")
        assert.are.equal(0, unmatched)
        assert.is_nil(WGS.db.global.attendance[1].eventId,
            "ambiguous matches must not silently bind")
    end)

    it("leaves already-bound sessions alone", function()
        WGS.db.global.events = {
            { id = 1, title = "X",
              date = os.date("%Y-%m-%d"), time = os.date("%H:%M") },
        }
        WGS.db.global.attendance = {
            { startedAt = 1700000000, eventId = 999, memberList = {} },
        }
        local bound = WGS:ReconcileAttendanceEventBindings()
        assert.are.equal(0, bound)
        assert.are.equal(999, WGS.db.global.attendance[1].eventId,
            "existing bindings must not be overwritten")
    end)
end)

-- /reload survival: the in-flight session used to live only in a module-
-- local, so /reload mid-raid dropped everything captured up to that
-- point. Modules/Attendance.lua now aliases the active session into
-- db.global.activeSession on Start and clears it on Stop, and exposes
-- a rehydrateActiveSession that module:OnEnable calls on load to
-- restore the local from SavedVariables.
describe("attendance /reload survival", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
        WGS.GetTimestamp = function() return 1700000000 end
        _G.IsInRaid = function() return true end
        _G.IsInGroup = function() return true end
        _G.GetInstanceInfo = function() return "TestRaid", nil, 16, "Mythic" end
    end)

    it("aliases db.global.activeSession to the in-flight session on Start", function()
        WGS:StartAttendanceForTeam(42, "Mythic Raiders", { id = 7, title = "Tuesday Pulls" })
        local stored = WGS.db.global.activeSession
        assert.is_table(stored, "Start must populate db.global.activeSession")
        assert.are.equal(42, stored.teamId)
        assert.are.equal(7, stored.eventId)
        assert.are.equal(1700000000, stored.startedAt)
    end)

    it("clears db.global.activeSession on Stop", function()
        WGS:StartAttendanceForTeam(42, "Mythic Raiders", { id = 7 })
        assert.is_table(WGS.db.global.activeSession)
        WGS:StopAttendance()
        assert.is_nil(WGS.db.global.activeSession,
            "Stop must clear the rehydrate alias so the next /reload doesn't resurrect this session")
    end)

    it("rehydrates a recent session: restores currentSession + IsTrackingAttendance", function()
        -- Simulate a /reload: stash a session into SavedVariables and
        -- run the rehydrate path. The local currentSession reset to
        -- nil between addon loads — rehydrate must repopulate it from
        -- db.global.activeSession.
        WGS.db.global.activeSession = {
            startedAt = 1700000000 - (60 * 60),   -- 1h ago, well within window
            startedBy = "Tester-TestRealm",
            teamId = 42,
            teamName = "Mythic Raiders",
            eventId = 7,
            eventTitle = "Tuesday Pulls",
            members = { ["Tester-TestRealm"] = { name = "Tester-TestRealm", present = true } },
        }
        WGS._printed = {}
        function WGS:Print(s) self._printed[#self._printed + 1] = s end

        WGS:_AttendanceRehydrate()

        assert.is_true(WGS:IsTrackingAttendance(),
            "after rehydrate the addon must report tracking as active")
        local ctx = WGS:GetCurrentAttendanceContext()
        assert.is_table(ctx)
        assert.are.equal(42, ctx.teamId)
        assert.are.equal(7, ctx.eventId)
        -- Resume message is the user-visible signal that the survival
        -- path actually fired.
        local sawResume = false
        for _, line in ipairs(WGS._printed) do
            if line:find("Resumed attendance tracking") then sawResume = true end
        end
        assert.is_true(sawResume)
    end)

    it("drops an orphan session older than 8h without rehydrating", function()
        -- 24h-old stub: user logged off mid-raid and came back next day.
        -- Resurrecting would produce a "live" session with no endedAt
        -- and no useful continuation; better to quietly drop.
        WGS.db.global.activeSession = {
            startedAt = 1700000000 - (24 * 60 * 60),
            teamId = 42,
            members = {},
        }
        WGS._printed = {}
        function WGS:Print(s) self._printed[#self._printed + 1] = s end

        WGS:_AttendanceRehydrate()

        assert.is_nil(WGS.db.global.activeSession,
            "orphan stash must be cleared so it can't be resurrected on the next load either")
        assert.is_false(WGS:IsTrackingAttendance())
        assert.are.equal(0, #WGS._printed,
            "no chat noise for the orphan-drop path — silent cleanup")
    end)

    it("no-ops when db.global.activeSession is nil (fresh install / clean stop)", function()
        WGS.db.global.activeSession = nil
        WGS._printed = {}
        function WGS:Print(s) self._printed[#self._printed + 1] = s end

        WGS:_AttendanceRehydrate()

        assert.is_false(WGS:IsTrackingAttendance())
        assert.are.equal(0, #WGS._printed)
    end)
end)
