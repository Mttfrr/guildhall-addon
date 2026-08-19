-- Regression: a raider's SEAT was being read as their GROUP.
--
-- The web app keys comp buckets as "group1".."group8" plus "bench", and
-- sends the seat within that bucket separately as `slot_index`. The
-- importer's `group` fell through to `slot_index`, so every bucket's first
-- occupant came out as group 0 — and SetRaidSubgroup(index, 0) is out of
-- range, which raises a hard Lua error. Officers saw
-- "Usage: SetRaidSubgroup(index, subgroup)" the moment they hit sort, with
-- a quarter of the raid shuffled to the wrong groups first.

local helpers = require("spec.helpers")

describe("raid comp slot_group → subgroup", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    local function importSlots(slots)
        WGS:ProcessImport({ raidComps = { { eventId = 1, slots = slots } } })
        return WGS.db.global.raidComps[1].assignments
    end

    it("reads the group from slot_group, NOT from slot_index", function()
        local a = importSlots({
            { character_name = "Ahead", slot_group = "group1", slot_index = 0 },
            { character_name = "Behind", slot_group = "group1", slot_index = 4 },
            { character_name = "Elsewhere", slot_group = "group3", slot_index = 0 },
        })
        assert.are.equal(1, a[1].group)   -- seat 0 is NOT group 0
        assert.are.equal(1, a[2].group)   -- same group, different seat
        assert.are.equal(3, a[3].group)
    end)

    it("never yields 0 — the value SetRaidSubgroup rejects", function()
        local a = importSlots({
            { character_name = "First", slot_group = "group1", slot_index = 0 },
            { character_name = "Second", slot_group = "group2", slot_index = 0 },
            { character_name = "Third", slot_group = "group4", slot_index = 0 },
        })
        for _, entry in ipairs(a) do
            assert.is_truthy(entry.group)
            assert.is_true(entry.group >= 1 and entry.group <= 8)
        end
    end)

    it("leaves a benched raider with NO group", function()
        -- Bench isn't a subgroup: there's nowhere to put them, and callers
        -- read nil as "leave them where they are".
        local a = importSlots({ { character_name = "Sat", slot_group = "bench", slot_index = 2 } })
        assert.is_nil(a[1].group)
    end)

    it("tolerates an unknown bucket rather than inventing a group", function()
        local a = importSlots({
            { character_name = "Odd", slot_group = "somethingelse", slot_index = 1 },
            { character_name = "Blank", slot_index = 3 },
        })
        assert.is_nil(a[1].group)
        assert.is_nil(a[2].group)
    end)

    it("still honours an explicit group/subgroup when the payload has one", function()
        local a = importSlots({
            { character_name = "Explicit", group = 5, slot_group = "group1", slot_index = 0 },
            { character_name = "Sub", subgroup = 6, slot_index = 0 },
        })
        assert.are.equal(5, a[1].group)
        assert.are.equal(6, a[2].group)
    end)

    it("keeps the role the server sent", function()
        local a = importSlots({
            { character_name = "Tanky", slot_group = "group1", slot_index = 0, role = "TANK" },
        })
        assert.are.equal("TANK", a[1].role)
    end)
end)

describe("SetRaidSubgroup is never called with an out-of-range group", function()
    local WGS
    local moves

    before_each(function()
        WGS = helpers.setup()
        moves = {}
        _G.IsInRaid = function() return true end
        _G.GetNumGroupMembers = function() return 3 end
        _G.GetRaidRosterInfo = function(i)
            if i == 1 then return "Zero", nil, 1 end
            if i == 2 then return "Huge", nil, 1 end
            if i == 3 then return "Fine", nil, 1 end
        end
        _G.SetRaidSubgroup = function(i, g)
            -- Mirror the real API: it raises rather than failing quietly.
            if type(g) ~= "number" or g < 1 or g > 8 then
                error("Usage: SetRaidSubgroup(index, subgroup)")
            end
            moves[#moves + 1] = { i = i, g = g }
        end
        WGS.HasGroupLeadOrAssist = function() return true, nil end
        WGS.FindTodayEventForTeam = function() return nil end
    end)

    it("skips a corrupt group instead of erroring the whole sort", function()
        WGS.GetRaidComp = function()
            return { assignments = {
                { name = "Zero", group = 0 },      -- the bug's signature
                { name = "Huge", group = 99 },
                { name = "Fine", group = 4 },
            } }
        end
        -- The point: this call used to throw, taking the valid move with it.
        assert.has_no.errors(function() WGS:SortRaidGroups({ id = 1 }) end)
        assert.are.equal(1, #moves, "only the sane assignment moves")
        assert.are.equal(3, moves[1].i)
        assert.are.equal(4, moves[1].g)
    end)

    it("guards the auto-place path the same way", function()
        WGS.GetRaidComp = function()
            return { assignments = { { name = "Zero", group = 0 } } }
        end
        local moved
        assert.has_no.errors(function() moved = WGS:PlaceRaiderInCompGroup("Zero", 1) end)
        assert.is_false(moved)
        assert.are.equal(0, #moves)
    end)
end)
