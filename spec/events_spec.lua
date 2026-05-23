local helpers = require("spec.helpers")

-- The public event bus contract (docs/EVENTS.md). Tests assert each
-- documented event fires at the right point with the documented shape.
-- The test harness installs a shim callback registry that records every
-- Fire() into GuildHall._fired; the FireEvent helper in Core.lua uses
-- that registry uniformly so we don't need to mock CallbackHandler.

local function firedNames(WGS)
    local names = {}
    for _, e in ipairs(WGS._fired) do names[#names + 1] = e.event end
    return names
end

local function firstFiredEvent(WGS, name)
    for _, e in ipairs(WGS._fired) do
        if e.event == name then return e end
    end
    return nil
end

describe("public event bus", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("FireEvent is a no-op when callbacks isn't wired", function()
        WGS.callbacks = nil
        assert.has_no.errors(function()
            WGS:FireEvent("WGS_UNIT_TEST_EVENT", {})
        end)
    end)

    it("fires WGS_IMPORT_APPLIED at the end of ProcessImport", function()
        WGS:ProcessImport({
            signups = { { eventId = 1, characterName = "A", status = "P" } },
        })
        local fired = firstFiredEvent(WGS, "WGS_IMPORT_APPLIED")
        assert.is_not_nil(fired, "expected WGS_IMPORT_APPLIED to fire")
        local payload = fired.args[1]
        assert.is_table(payload)
        assert.is_number(payload.count)
        assert.is_true(payload.count >= 1)
        assert.is_number(payload.importedAt)
        assert.are.equal(WGS.db.global.lastImport, payload.importedAt)
    end)

    it("does not fire WGS_LOOT_RECORDED without a loot capture", function()
        -- Sanity: importing data should not produce loot events.
        WGS:ProcessImport({ events = {} })
        for _, name in ipairs(firedNames(WGS)) do
            assert.are_not.equal("WGS_LOOT_RECORDED", name)
        end
    end)

    it("session start/end fires are observable via the shim", function()
        -- Direct FireEvent calls exercise the dispatch path. (Modules/
        -- Attendance.lua's StartAttendanceForTeam calls WoW APIs we
        -- don't stub — IsInRaid, GetInstanceInfo — so the integration
        -- test for the real start/stop trigger is manual / in-game.)
        WGS:FireEvent("WGS_SESSION_STARTED", { startedAt = 1, teamId = 7 })
        WGS:FireEvent("WGS_SESSION_ENDED", { endedAt = 2, teamId = 7 })

        local started = firstFiredEvent(WGS, "WGS_SESSION_STARTED")
        local ended   = firstFiredEvent(WGS, "WGS_SESSION_ENDED")
        assert.is_not_nil(started)
        assert.is_not_nil(ended)
        assert.are.equal(7, started.args[1].teamId)
        assert.are.equal(7, ended.args[1].teamId)
    end)
end)
