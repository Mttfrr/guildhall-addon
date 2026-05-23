local helpers = require("spec.helpers")

-- WGS:BuildBossAttendanceFromMRT (Modules/Attendance.lua) folds MRT's
-- per-encounter rosters (VMRT.Attendance.data) into a session's
-- bossAttendance array. Tests cover:
--   * MRT not loaded → empty list, no errors
--   * Class-letter prefix decoded correctly (A=Warrior … M=Evoker)
--   * Window filtering: rows outside [startedAt, endedAt] excluded
--   * Defensive parsing: bad rows skipped instead of crashing

describe("WGS:BuildBossAttendanceFromMRT", function()
    local WGS

    local origCAddOns, origVMRT

    local function pretendMRTLoaded(loaded)
        _G.C_AddOns = { IsAddOnLoaded = function(n) return n == "MRT" and loaded end }
        WGS:_ResetAddonCache()
    end

    before_each(function()
        WGS = helpers.setup()
        origCAddOns = _G.C_AddOns
        origVMRT    = _G.VMRT
        _G.VMRT = nil
    end)

    after_each(function()
        _G.C_AddOns = origCAddOns
        _G.VMRT     = origVMRT
    end)

    it("returns an empty list when MRT is not loaded", function()
        pretendMRTLoaded(false)
        _G.VMRT = { Attendance = { data = { { t = 100, eI = 1, eN = "x", [1] = "AFoo" } } } }
        local rows = WGS:BuildBossAttendanceFromMRT(0, 1000)
        assert.same({}, rows)
    end)

    it("returns an empty list when MRT is loaded but data is missing", function()
        pretendMRTLoaded(true)
        _G.VMRT = {}  -- no Attendance namespace
        assert.same({}, WGS:BuildBossAttendanceFromMRT(0, 1000))
    end)

    it("decodes the class letter prefix into a class name", function()
        pretendMRTLoaded(true)
        _G.VMRT = { Attendance = { data = {
            { t = 500, eI = 2902, eN = "Ulgrax", d = 16, k = true, g = 25,
              [1] = "AWarriorBob",   -- A = Warrior
              [2] = "BPaladin",      -- B = Paladin
              [3] = "MEvokerEve",    -- M = Evoker
            },
        } } }
        local rows = WGS:BuildBossAttendanceFromMRT(0, 1000)
        assert.are.equal(1, #rows)
        local roster = rows[1].roster
        assert.are.equal(3, #roster)
        assert.same({ name = "WarriorBob", class = "WARRIOR" }, roster[1])
        assert.same({ name = "Paladin",    class = "PALADIN" }, roster[2])
        assert.same({ name = "EvokerEve",  class = "EVOKER" },  roster[3])
    end)

    it("copies the encounter metadata across (eI/eN/d/k/g/t)", function()
        pretendMRTLoaded(true)
        _G.VMRT = { Attendance = { data = {
            { t = 500, eI = 2902, eN = "Ulgrax the Devourer",
              d = 16, k = true, g = 25, [1] = "AFoo" },
        } } }
        local row = WGS:BuildBossAttendanceFromMRT(0, 1000)[1]
        assert.are.equal(2902,                   row.encounterID)
        assert.are.equal("Ulgrax the Devourer",  row.encounterName)
        assert.are.equal(16,                     row.difficultyID)
        assert.are.equal(500,                    row.time)
        assert.is_true(row.isKill)
        assert.are.equal(25,                     row.groupSize)
    end)

    it("excludes rows whose timestamp falls outside the session window", function()
        pretendMRTLoaded(true)
        _G.VMRT = { Attendance = { data = {
            { t = 99,    eI = 1, eN = "before",  [1] = "AFoo" },
            { t = 500,   eI = 2, eN = "inside",  [1] = "AFoo" },
            { t = 1500,  eI = 3, eN = "after",   [1] = "AFoo" },
        } } }
        local rows = WGS:BuildBossAttendanceFromMRT(100, 1000)
        assert.are.equal(1, #rows)
        assert.are.equal("inside", rows[1].encounterName)
    end)

    it("treats startedAt and endedAt as inclusive bounds", function()
        pretendMRTLoaded(true)
        _G.VMRT = { Attendance = { data = {
            { t = 100,   eI = 1, eN = "lower",   [1] = "AFoo" },
            { t = 1000,  eI = 2, eN = "upper",   [1] = "AFoo" },
        } } }
        local rows = WGS:BuildBossAttendanceFromMRT(100, 1000)
        assert.are.equal(2, #rows)
    end)

    it("kill flag is coerced to boolean (MRT sometimes stores it as a number)", function()
        pretendMRTLoaded(true)
        _G.VMRT = { Attendance = { data = {
            { t = 500, eI = 1, eN = "wipe", k = nil,    [1] = "AFoo" },
            { t = 500, eI = 2, eN = "kill", k = true,   [1] = "AFoo" },
            { t = 500, eI = 3, eN = "kill", k = 1,      [1] = "AFoo" },
        } } }
        local rows = WGS:BuildBossAttendanceFromMRT(0, 1000)
        assert.is_false(rows[1].isKill)
        assert.is_true(rows[2].isKill)
        assert.is_true(rows[3].isKill)
    end)

    it("skips bad roster entries (non-string, single-char, empty name)", function()
        pretendMRTLoaded(true)
        _G.VMRT = { Attendance = { data = {
            { t = 500, eI = 1, eN = "boss",
              [1] = "AValidName",
              [2] = "A",        -- prefix only, no name → skip
              [3] = "",         -- empty → skip
              [4] = 42,         -- non-string → skip
              [5] = "ZUnknownClass", -- unknown letter → keep, class = ""
            },
        } } }
        local rows = WGS:BuildBossAttendanceFromMRT(0, 1000)
        local roster = rows[1].roster
        assert.are.equal(2, #roster)
        assert.same({ name = "ValidName",    class = "WARRIOR" }, roster[1])
        assert.same({ name = "UnknownClass", class = "" },        roster[2])
    end)

    it("survives a malformed top-level data table (defensive)", function()
        pretendMRTLoaded(true)
        _G.VMRT = { Attendance = { data = {
            { t = 500, eI = 1, eN = "good", [1] = "AFoo" },
            "not-a-table",                  -- garbage row
            { t = "not-a-number" },         -- bad timestamp
            { },                            -- no timestamp
        } } }
        local rows = WGS:BuildBossAttendanceFromMRT(0, 1000)
        assert.are.equal(1, #rows)
        assert.are.equal("good", rows[1].encounterName)
    end)
end)
