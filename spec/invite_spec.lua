local helpers = require("spec.helpers")

describe("GetEventSignups", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("returns only committed statuses (P/L/B/LT)", function()
        WGS.db.global.signups = {
            { eventId = 42, characterName = "Foo",  status = "P"  },
            { eventId = 42, characterName = "Bar",  status = "L"  },
            { eventId = 42, characterName = "Baz",  status = "B"  },
            { eventId = 42, characterName = "Qux",  status = "LT" },
            { eventId = 42, characterName = "Mae",  status = "T"  },  -- tentative — excluded
            { eventId = 42, characterName = "Nix",  status = "A"  },  -- absent — excluded
        }
        local names = WGS:GetEventSignups(42)
        table.sort(names)
        assert.same({ "Bar", "Baz", "Foo", "Qux" }, names)
    end)

    it("filters by eventId", function()
        WGS.db.global.signups = {
            { eventId = 1, characterName = "Foo", status = "P" },
            { eventId = 2, characterName = "Bar", status = "P" },
        }
        assert.same({ "Foo" }, WGS:GetEventSignups(1))
        assert.same({ "Bar" }, WGS:GetEventSignups(2))
        assert.same({},        WGS:GetEventSignups(3))
    end)

    it("returns an empty list when there are no signups at all", function()
        WGS.db.global.signups = {}
        assert.same({}, WGS:GetEventSignups(42))
    end)

    it("tolerates a nil/missing eventId argument", function()
        assert.same({}, WGS:GetEventSignups(nil))
    end)
end)

describe("GetEventInviteList source preference", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("prefers signups over raid comp + team roster", function()
        WGS.db.global.signups = {
            { eventId = 99, characterName = "FromSignup", status = "P" },
        }
        WGS.db.global.raidComps = {
            { eventId = 99, assignments = {{ name = "FromComp" }} },
        }
        WGS.db.global.teams = {
            { id = 1, members = { "FromRoster" } },
        }
        local names, source = WGS:GetEventInviteList({ id = 99, team_id = 1 })
        assert.same({ "FromSignup" }, names)
        assert.are.equal("signups", source)
    end)

    it("falls back to raid comp when signups exist but none are committed", function()
        WGS.db.global.signups = {
            -- Only tentative — filtered out by GetEventSignups
            { eventId = 99, characterName = "Maybe", status = "T" },
        }
        WGS.db.global.raidComps = {
            { eventId = 99, assignments = {{ name = "FromComp" }} },
        }
        local names, source = WGS:GetEventInviteList({ id = 99 })
        assert.same({ "FromComp" }, names)
        assert.are.equal("raid comp", source)
    end)

    it("falls back to team roster when there's no signup and no comp", function()
        WGS.db.global.teams = {
            { id = 7, members = { "Alpha", "Beta" } },
        }
        local names, source = WGS:GetEventInviteList({ id = 99, team_id = 7 })
        assert.same({ "Alpha", "Beta" }, names)
        assert.are.equal("team roster", source)
    end)

    it("expands team playerMembers + their alts when using roster fallback", function()
        WGS.db.global.characters = {
            ["p-1"] = { main = "Main", alts = { "Alt1", "Alt2" } },
        }
        WGS.db.global.teams = {
            { id = 7, playerMembers = { { playerId = "p-1", main = "Main" } } },
        }
        local names, source = WGS:GetEventInviteList({ id = 99, team_id = 7 })
        table.sort(names)
        assert.same({ "Alt1", "Alt2", "Main" }, names)
        assert.are.equal("team roster", source)
    end)

    it("returns an empty list when no source has any data", function()
        local names, source = WGS:GetEventInviteList({ id = 99, team_id = 7 })
        assert.same({}, names)
        assert.is_nil(source)
    end)
end)

describe("Import: signups roundtrip into db.global", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("ProcessImport captures data.signups", function()
        WGS:ProcessImport({
            signups = {
                { eventId = 1, characterName = "Foo", status = "P" },
                { eventId = 1, characterName = "Bar", status = "T" },
            },
        })
        assert.are.equal(2, #WGS.db.global.signups)
        assert.are.equal("P", WGS.db.global.signups[1].status)
    end)
end)
