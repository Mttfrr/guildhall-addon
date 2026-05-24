local helpers = require("spec.helpers")

-- Modules/Attendance.lua — officer correction mutators for captured
-- sessions. Each one cascades into raidCompResults rows sharing the
-- session's startedAt so per-pull comp snapshots stay consistent with
-- the session-level roster — otherwise a removed member would still
-- appear "present" in the comp.
--
-- Same v1 local-only limitation as the loot mutators; chat hint is
-- the user-visible signal.

local function setup()
    local WGS = helpers.setup()
    WGS._printed = {}
    function WGS:Print(s) self._printed[#self._printed + 1] = s end
    return WGS
end

describe("WGS:RebindAttendanceSession", function()
    local WGS
    before_each(function()
        WGS = setup()
        WGS.db.global.attendance = {
            { startedAt = 1000, eventId = nil, eventTitle = nil, memberList = {} },
            { startedAt = 2000, eventId = 5,   eventTitle = "Old", memberList = {} },
        }
        -- Two snapshot rows for session 1 (one start-snapshot, one
        -- end-snapshot — the typical pattern) plus one for session 2.
        WGS.db.global.raidCompResults = {
            { startedAt = 1000, eventId = nil, signature = "A" },
            { startedAt = 1000, eventId = nil, signature = "B" },
            { startedAt = 2000, eventId = 5,   signature = "C" },
        }
    end)

    it("rebinds the session AND every raidCompResults row sharing its startedAt", function()
        local ok = WGS:RebindAttendanceSession(1, 99, "New Event")
        assert.is_true(ok)
        assert.are.equal(99, WGS.db.global.attendance[1].eventId)
        assert.are.equal("New Event", WGS.db.global.attendance[1].eventTitle)
        -- Both session-1 snapshots get the new eventId.
        assert.are.equal(99, WGS.db.global.raidCompResults[1].eventId)
        assert.are.equal(99, WGS.db.global.raidCompResults[2].eventId)
        -- Session 2's snapshot is untouched.
        assert.are.equal(5, WGS.db.global.raidCompResults[3].eventId)
    end)

    it("accepts nil eventId to clear an existing binding", function()
        WGS:RebindAttendanceSession(2, nil, nil)
        assert.is_nil(WGS.db.global.attendance[2].eventId)
        assert.is_nil(WGS.db.global.raidCompResults[3].eventId)
    end)

    it("returns false on out-of-range index", function()
        assert.is_false(WGS:RebindAttendanceSession(99, 1, "x"))
    end)

    it("fires WGS_ATTENDANCE_EDITED with kind=rebind", function()
        WGS:RebindAttendanceSession(1, 99, "New")
        local fired
        for _, f in ipairs(GuildHall._fired) do
            if f.event == "WGS_ATTENDANCE_EDITED" then fired = f.args[1] end
        end
        assert.is_table(fired)
        assert.are.equal("rebind", fired.kind)
        assert.are.equal(1, fired.index)
    end)
end)

describe("WGS:RemoveMemberFromSession", function()
    local WGS
    before_each(function()
        WGS = setup()
        WGS.db.global.attendance = {
            { startedAt = 1000, memberList = {
                { name = "Alpha", class = "WARRIOR" },
                { name = "Beta",  class = "PRIEST" },
                { name = "Gamma", class = "MAGE" },
            } },
        }
        WGS.db.global.raidCompResults = {
            { startedAt = 1000, slots = {
                { name = "Alpha" }, { name = "Beta" }, { name = "Gamma" },
            } },
            { startedAt = 1000, slots = {
                { name = "Alpha" }, { name = "Beta" },
            } },
            -- Different session — must NOT be touched.
            { startedAt = 9999, slots = { { name = "Beta" } } },
        }
    end)

    it("removes the member from memberList AND from every matching snapshot's slots", function()
        local ok = WGS:RemoveMemberFromSession(1, "Beta")
        assert.is_true(ok)
        assert.are.equal(2, #WGS.db.global.attendance[1].memberList)
        for _, m in ipairs(WGS.db.global.attendance[1].memberList) do
            assert.are_not.equal("Beta", m.name)
        end
        -- Both session-1 snapshots lose Beta.
        for i = 1, 2 do
            for _, s in ipairs(WGS.db.global.raidCompResults[i].slots) do
                assert.are_not.equal("Beta", s.name)
            end
        end
        -- The unrelated session keeps Beta.
        assert.are.equal("Beta", WGS.db.global.raidCompResults[3].slots[1].name,
            "snapshots from other sessions must not be touched")
    end)

    it("returns false when the member isn't in the roster", function()
        assert.is_false(WGS:RemoveMemberFromSession(1, "NotHere"))
    end)

    it("returns false on out-of-range session index", function()
        assert.is_false(WGS:RemoveMemberFromSession(99, "Alpha"))
    end)
end)

describe("WGS:DeleteAttendanceSession", function()
    local WGS
    before_each(function()
        WGS = setup()
        WGS.db.global.attendance = {
            { startedAt = 1000, memberList = {} },
            { startedAt = 2000, memberList = {} },
        }
        WGS.db.global.raidCompResults = {
            { startedAt = 1000, signature = "A" },
            { startedAt = 1000, signature = "B" },
            { startedAt = 2000, signature = "C" },
        }
    end)

    it("removes the session AND every raidCompResults row sharing its startedAt", function()
        local ok = WGS:DeleteAttendanceSession(1)
        assert.is_true(ok)
        assert.are.equal(1, #WGS.db.global.attendance)
        assert.are.equal(2000, WGS.db.global.attendance[1].startedAt)
        -- Both session-1 snapshots gone, session-2's stays.
        assert.are.equal(1, #WGS.db.global.raidCompResults)
        assert.are.equal("C", WGS.db.global.raidCompResults[1].signature)
    end)

    it("returns false on out-of-range index", function()
        assert.is_false(WGS:DeleteAttendanceSession(99))
        assert.are.equal(2, #WGS.db.global.attendance)
    end)

    it("fires WGS_ATTENDANCE_EDITED with the removed session and kind=delete", function()
        WGS:DeleteAttendanceSession(1)
        local fired
        for _, f in ipairs(GuildHall._fired) do
            if f.event == "WGS_ATTENDANCE_EDITED" then fired = f.args[1] end
        end
        assert.is_table(fired)
        assert.are.equal("delete", fired.kind)
        assert.are.equal(1000, fired.session.startedAt)
    end)
end)
