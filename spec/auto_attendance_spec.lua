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
