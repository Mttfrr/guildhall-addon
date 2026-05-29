local helpers = require("spec.helpers")

-- WGS:UpdateSignupStatus is the officer-side mutation behind the
-- Events Roster row's right-click "Mark status ▸" submenu. Updates
-- db.global.signups in place AND queues the change in
-- db.global.pendingSignupChanges so the next addon-sync export
-- ships it to the platform.

local function setup()
    local WGS = helpers.setup()
    WGS._printed = {}
    function WGS:Print(s) self._printed[#self._printed + 1] = s end
    -- Default to officer rank — non-officer rejection is tested
    -- explicitly below.
    function WGS:IsGuildOfficer() return true end
    WGS.GetTimestamp = function() return 1700000000 end
    return WGS
end

describe("WGS:UpdateSignupStatus", function()
    local WGS
    before_each(function()
        WGS = setup()
        WGS.db.global.signups = {
            { eventId = 7, characterName = "Alice-EU", status = "P" },
            { eventId = 7, characterName = "Bob-EU",   status = "P" },
            { eventId = 9, characterName = "Alice-EU", status = "T" },
        }
    end)

    it("rewrites the existing signup's status in place", function()
        local ok = WGS:UpdateSignupStatus(7, "Alice-EU", "L")
        assert.is_true(ok)
        assert.are.equal("L", WGS.db.global.signups[1].status)
        assert.are.equal("P", WGS.db.global.signups[2].status,
            "other signups must not be touched")
        assert.are.equal("T", WGS.db.global.signups[3].status,
            "same character on a different event must not be touched")
    end)

    it("appends a new signup row when no existing one matches", function()
        WGS:UpdateSignupStatus(7, "Charlie-EU", "L")
        assert.are.equal(4, #WGS.db.global.signups)
        local last = WGS.db.global.signups[4]
        assert.are.equal(7, last.eventId)
        assert.are.equal("Charlie-EU", last.characterName)
        assert.are.equal("L", last.status)
    end)

    it("queues the change in pendingSignupChanges with a timestamp", function()
        WGS:UpdateSignupStatus(7, "Alice-EU", "L")
        local q = WGS.db.global.pendingSignupChanges
        assert.is_table(q)
        assert.are.equal(1, #q)
        assert.are.equal(7,           q[1].eventId)
        assert.are.equal("Alice-EU",  q[1].characterName)
        assert.are.equal("L",         q[1].status)
        assert.are.equal(1700000000,  q[1].t)
    end)

    it("collapses duplicate queue entries (same event + character)", function()
        WGS:UpdateSignupStatus(7, "Alice-EU", "L")
        WGS:UpdateSignupStatus(7, "Alice-EU", "LT")   -- update the status
        local q = WGS.db.global.pendingSignupChanges
        assert.are.equal(1, #q, "second mutation collapses into the existing queue entry")
        assert.are.equal("LT", q[1].status)
    end)

    it("rejects when not an officer (no mutation, no queue)", function()
        function WGS:IsGuildOfficer() return false end
        local ok, err = WGS:UpdateSignupStatus(7, "Alice-EU", "L")
        assert.is_false(ok)
        assert.are.equal("not officer", err)
        assert.are.equal("P", WGS.db.global.signups[1].status,
            "non-officer mutation must not touch the data")
        assert.are.equal(0, #(WGS.db.global.pendingSignupChanges or {}))
    end)

    it("rejects unknown status codes", function()
        local ok, err = WGS:UpdateSignupStatus(7, "Alice-EU", "ZZ")
        assert.is_false(ok)
        assert.is_truthy(err:find("unknown status"))
        assert.are.equal("P", WGS.db.global.signups[1].status)
    end)

    it("is a no-op when the status matches what's already stored", function()
        WGS.db.global.pendingSignupChanges = {}
        local ok = WGS:UpdateSignupStatus(7, "Alice-EU", "P")   -- same status
        assert.is_true(ok)
        assert.are.equal(0, #WGS.db.global.pendingSignupChanges,
            "no queue entry should be added when nothing actually changed")
    end)

    it("fires WGS_SIGNUP_EDITED with { eventId, characterName, status }", function()
        WGS:UpdateSignupStatus(7, "Alice-EU", "L")
        local fired
        for _, f in ipairs(GuildHall._fired) do
            if f.event == "WGS_SIGNUP_EDITED" then fired = f.args[1] end
        end
        assert.is_table(fired)
        assert.are.equal(7, fired.eventId)
        assert.are.equal("Alice-EU", fired.characterName)
        assert.are.equal("L", fired.status)
    end)
end)
