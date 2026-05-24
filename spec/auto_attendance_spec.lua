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
