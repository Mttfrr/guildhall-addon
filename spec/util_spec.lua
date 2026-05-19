local helpers = require("spec.helpers")

describe("Util/Roster — character lookup", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("indexes mains + alts to a single playerId", function()
        WGS.db.global.characters = {
            ["p-1"] = { main = "Foo-Realm", alts = { "Bar-Realm", "Baz-Realm" } },
            ["p-2"] = { main = "Qux-Realm", alts = {} },
        }
        WGS:BuildCharacterLookup()
        local lookup = WGS.db.global.characterLookup
        assert.are.equal("p-1", lookup["Foo-Realm"])
        assert.are.equal("p-1", lookup["Bar-Realm"])
        assert.are.equal("p-1", lookup["Baz-Realm"])
        assert.are.equal("p-2", lookup["Qux-Realm"])
    end)

    it("ResolvePlayerForCharacter returns nil for unknown names", function()
        WGS.db.global.characters = {
            ["p-1"] = { main = "Foo-Realm", alts = {} },
        }
        WGS:BuildCharacterLookup()
        local pid = WGS:ResolvePlayerForCharacter("Stranger-Realm")
        assert.is_nil(pid)
    end)

    it("ResolvePlayerForCharacter returns playerId + info for known names", function()
        WGS.db.global.characters = {
            ["p-1"] = { main = "Foo-Realm", alts = { "Bar-Realm" }, displayName = "Foo" },
        }
        WGS:BuildCharacterLookup()
        local pid, info = WGS:ResolvePlayerForCharacter("Bar-Realm")
        assert.are.equal("p-1", pid)
        assert.are.equal("Foo", info.displayName)
    end)

    it("NormalizeFullName leaves Char-Realm strings alone", function()
        assert.are.equal("Foo-Realm", WGS:NormalizeFullName("Foo-Realm"))
    end)

    it("NormalizeFullName appends the player's realm when missing", function()
        -- Test stub sets GetNormalizedRealmName to "TestRealm"
        assert.are.equal("Foo-TestRealm", WGS:NormalizeFullName("Foo"))
    end)

    it("CLASS_COLORS is populated", function()
        assert.is_string(WGS.CLASS_COLORS.WARRIOR)
        assert.is_string(WGS.CLASS_COLORS.EVOKER)
    end)
end)

describe("Util/Time — identity", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("GetTimestamp returns a positive integer second count", function()
        local t = WGS:GetTimestamp()
        assert.is_number(t)
        assert.is_true(t > 0)
    end)

    it("GetPlayerKey returns Name-Realm from the WoW stubs", function()
        assert.are.equal("Tester-TestRealm", WGS:GetPlayerKey())
    end)
end)
