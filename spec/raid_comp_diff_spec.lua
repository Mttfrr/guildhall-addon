local helpers = require("spec.helpers")

-- UI/EventsDetail.lua's buildCompDiff diffs a planned raid-comp slot
-- list against the in-flight session's captured members. Drives the
-- "Planned 25 · In raid 22 · Missing: A, B (Group 3); Subbed: C"
-- strip below the Raid Comp section so the officer can see at a
-- glance who's missing or who got swapped in.

local function setup()
    local WGS = helpers.setup()
    helpers.loadUIShims()
    dofile("UI/EventsDetail.lua")
    return WGS
end

describe("buildCompDiff", function()
    local WGS, diff

    before_each(function()
        WGS = setup()
        diff = WGS._BuildCompDiff
    end)

    it("classifies planned-and-present, planned-missing, and unplanned-extras", function()
        local planned = {
            { name = "Alice-EU",   class = "WARLOCK", role = "DPS", group = 1 },
            { name = "Bob-EU",     class = "MAGE",    role = "DPS", group = 3 },
            { name = "Charlie-EU", class = "PRIEST",  role = "HEALER", group = 2 },
        }
        local actual = {
            { name = "Alice-EU",    class = "WARLOCK" },
            { name = "Charlie-EU",  class = "PRIEST" },
            { name = "Doug-Realm",  class = "ROGUE" },   -- not planned
        }
        local d = diff(planned, actual)
        assert.are.equal(3, d.planned)
        assert.are.equal(3, d.actual)
        assert.are.equal(2, d.present, "Alice + Charlie are both planned and in raid")

        assert.are.equal(1, #d.missing)
        assert.are.equal("Bob-EU",  d.missing[1].name)
        assert.are.equal(3,         d.missing[1].group)

        assert.are.equal(1, #d.extras)
        assert.are.equal("Doug-Realm", d.extras[1].name)
    end)

    it("matches by short name across different realms", function()
        local planned = { { name = "Foo-EU",  class = "MAGE", role = "DPS", group = 1 } }
        local actual  = { { name = "Foo-USA", class = "MAGE" } }
        local d = diff(planned, actual)
        assert.are.equal(1, d.present, "same short name, different realm = same player")
        assert.are.equal(0, #d.missing)
        assert.are.equal(0, #d.extras)
    end)

    it("matches case-insensitively", function()
        local planned = { { name = "ALICE-EU", role = "DPS", group = 2 } }
        local actual  = { { name = "alice-eu" } }
        local d = diff(planned, actual)
        assert.are.equal(1, d.present)
    end)

    it("returns 0 / empty arrays when both sides are empty", function()
        local d = diff({}, {})
        assert.are.equal(0, d.planned)
        assert.are.equal(0, d.actual)
        assert.are.equal(0, d.present)
        assert.are.equal(0, #d.missing)
        assert.are.equal(0, #d.extras)
    end)

    it("sorts missing by group asc, then by name", function()
        local planned = {
            { name = "Z-EU", group = 1, class = "MAGE", role = "DPS" },
            { name = "A-EU", group = 3, class = "ROGUE", role = "DPS" },
            { name = "M-EU", group = 1, class = "PRIEST", role = "HEALER" },
        }
        local actual = {}   -- nobody showed
        local d = diff(planned, actual)
        assert.are.equal(3, #d.missing)
        -- Group 1 first (M, Z by name); then Group 3 (A).
        assert.are.equal("M-EU", d.missing[1].name)
        assert.are.equal("Z-EU", d.missing[2].name)
        assert.are.equal("A-EU", d.missing[3].name)
    end)
end)
