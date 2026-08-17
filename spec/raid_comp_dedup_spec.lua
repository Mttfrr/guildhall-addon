local helpers = require("spec.helpers")

-- WGS:SnapshotRaidComp dedupes against EVERY snapshot already recorded
-- for the current session (matched by startedAt), not just the last
-- row. The regression this pins: an A→B→A comp sequence used to record
-- comp A twice because only the newest row was compared.

describe("WGS:SnapshotRaidComp session-wide dedup", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
        _G.IsInRaid = function() return true end
        _G.IsInGroup = function() return true end
        _G.GetInstanceInfo = function() return "TestRaid", nil, 16, "Mythic" end
        WGS.GetTimestamp = function() return 1700000000 end
        WGS:StartAttendanceForTeam(1, "Team", { id = 7 })
    end)

    -- Overwrite the live session's member map with a synthetic comp.
    -- db.global.activeSession aliases the module's currentSession table,
    -- so writes here are visible to SnapshotRaidComp.
    local function setComp(names)
        local members = {}
        for _, n in ipairs(names) do
            members[n] = { name = n, present = true, subgroup = 1, class = "MAGE", role = "DPS" }
        end
        WGS.db.global.activeSession.members = members
    end

    it("records distinct comps and skips a comp identical to ANY earlier snapshot (A→B→A)", function()
        setComp({ "Foo", "Bar" })
        assert.is_true(WGS:SnapshotRaidComp(nil), "first comp records")

        setComp({ "Foo", "Bar", "Baz" })
        assert.is_true(WGS:SnapshotRaidComp(nil), "changed comp records")

        setComp({ "Foo", "Bar" })   -- back to the first comp
        assert.is_false(WGS:SnapshotRaidComp(nil),
            "returning to an earlier comp must NOT record a duplicate")

        assert.are.equal(2, #WGS.db.global.raidCompResults)
    end)

    it("does not dedupe across sessions (same comp, different startedAt)", function()
        setComp({ "Foo", "Bar" })
        assert.is_true(WGS:SnapshotRaidComp(nil))

        -- A pre-existing row from ANOTHER session with the same
        -- signature must not block this session's snapshot.
        local other = WGS.db.global.raidCompResults[1]
        assert.are.equal(1700000000, other.startedAt)
        WGS.db.global.raidCompResults[1] = nil
        WGS.db.global.raidCompResults[1] = {
            startedAt = 1600000000,          -- different session
            signature = other.signature,     -- identical comp
        }
        assert.is_true(WGS:SnapshotRaidComp(nil),
            "an identical comp from a different session must not suppress recording")
    end)
end)
