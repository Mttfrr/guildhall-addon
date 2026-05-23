local helpers = require("spec.helpers")

describe("WGS:NormalizeRole", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("returns canonical TANK / HEALER / DPS", function()
        assert.are.equal("TANK", WGS:NormalizeRole("TANK"))
        assert.are.equal("HEALER", WGS:NormalizeRole("HEALER"))
        assert.are.equal("DPS", WGS:NormalizeRole("DPS"))
    end)

    it("uppercases lowercased input", function()
        assert.are.equal("TANK", WGS:NormalizeRole("tank"))
        assert.are.equal("HEALER", WGS:NormalizeRole("Healer"))
    end)

    it("normalises DAMAGER (live UnitGroupRolesAssigned) to DPS", function()
        assert.are.equal("DPS", WGS:NormalizeRole("DAMAGER"))
        assert.are.equal("DPS", WGS:NormalizeRole("damager"))
    end)

    it("defaults nil / unknown / empty to DPS", function()
        assert.are.equal("DPS", WGS:NormalizeRole(nil))
        assert.are.equal("DPS", WGS:NormalizeRole(""))
        assert.are.equal("DPS", WGS:NormalizeRole("NONE"))
        assert.are.equal("DPS", WGS:NormalizeRole("MELEE"))
    end)
end)
