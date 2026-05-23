local helpers = require("spec.helpers")

-- Three small helpers carved out of repeated patterns across UI/* and
-- Modules/*. The tests pin behaviour so future tweaks to group-state
-- detection (e.g. WoW adds a third group category) only need one
-- update site instead of nine.

describe("WGS:GetGroupChannel", function()
    local WGS
    local origInRaid, origInGroup

    before_each(function()
        WGS = helpers.setup()
        origInRaid  = _G.IsInRaid
        origInGroup = _G.IsInGroup
    end)
    after_each(function()
        _G.IsInRaid  = origInRaid
        _G.IsInGroup = origInGroup
    end)

    it("returns RAID when in a raid", function()
        _G.IsInRaid  = function() return true end
        _G.IsInGroup = function() return true end
        assert.are.equal("RAID", WGS:GetGroupChannel())
    end)

    it("returns PARTY when in a party but not a raid", function()
        _G.IsInRaid  = function() return false end
        _G.IsInGroup = function() return true end
        assert.are.equal("PARTY", WGS:GetGroupChannel())
    end)

    it("returns nil when solo", function()
        _G.IsInRaid  = function() return false end
        _G.IsInGroup = function() return false end
        assert.is_nil(WGS:GetGroupChannel())
    end)
end)

describe("WGS:IsInAnyGroup", function()
    local WGS
    local origInRaid, origInGroup

    before_each(function()
        WGS = helpers.setup()
        origInRaid  = _G.IsInRaid
        origInGroup = _G.IsInGroup
    end)
    after_each(function()
        _G.IsInRaid  = origInRaid
        _G.IsInGroup = origInGroup
    end)

    it("is true in a raid", function()
        _G.IsInRaid  = function() return true end
        _G.IsInGroup = function() return true end
        assert.is_true(WGS:IsInAnyGroup())
    end)

    it("is true in a party", function()
        _G.IsInRaid  = function() return false end
        _G.IsInGroup = function() return true end
        assert.is_true(WGS:IsInAnyGroup())
    end)

    it("is false when solo", function()
        _G.IsInRaid  = function() return false end
        _G.IsInGroup = function() return false end
        assert.is_false(WGS:IsInAnyGroup())
    end)

    it("always returns a boolean (never nil)", function()
        -- A common bug class: returning nil from a "boolean-looking" function
        -- breaks `assert(x == true)` callers downstream.
        _G.IsInRaid  = function() return nil end
        _G.IsInGroup = function() return nil end
        assert.are.equal("boolean", type(WGS:IsInAnyGroup()))
    end)
end)

describe("WGS:NormalizeFullName (2-arg form)", function()
    local WGS

    before_each(function() WGS = helpers.setup() end)

    it("joins name + realm when both are given", function()
        assert.are.equal("Foo-Other", WGS:NormalizeFullName("Foo", "Other"))
    end)

    it("returns the name unchanged when it's already suffixed", function()
        assert.are.equal("Foo-Other", WGS:NormalizeFullName("Foo-Other", "Different"))
    end)

    it("falls back to the player's own realm when realm is nil", function()
        -- helpers stubs GetNormalizedRealmName → "TestRealm"
        assert.are.equal("Foo-TestRealm", WGS:NormalizeFullName("Foo", nil))
    end)

    it("falls back to the player's own realm when realm is empty string", function()
        -- The case GetRaidRosterInfo / UnitFullName actually produces for
        -- same-realm members — empty string, not nil.
        assert.are.equal("Foo-TestRealm", WGS:NormalizeFullName("Foo", ""))
    end)

    it("returns nil for nil / empty name", function()
        assert.is_nil(WGS:NormalizeFullName(nil, "Realm"))
        assert.is_nil(WGS:NormalizeFullName("", "Realm"))
    end)
end)

describe("WGS:HasGroupLeadOrAssist", function()
    local WGS
    local origInRaid, origInGroup, origLeader, origAssist

    before_each(function()
        WGS = helpers.setup()
        origInRaid  = _G.IsInRaid
        origInGroup = _G.IsInGroup
        origLeader  = _G.UnitIsGroupLeader
        origAssist  = _G.UnitIsGroupAssistant
    end)
    after_each(function()
        _G.IsInRaid              = origInRaid
        _G.IsInGroup             = origInGroup
        _G.UnitIsGroupLeader     = origLeader
        _G.UnitIsGroupAssistant  = origAssist
    end)

    it("returns true,nil for raid leader", function()
        _G.IsInRaid  = function() return true end
        _G.UnitIsGroupLeader = function() return true end
        _G.UnitIsGroupAssistant = function() return false end
        local ok, reason = WGS:HasGroupLeadOrAssist()
        assert.is_true(ok); assert.is_nil(reason)
    end)

    it("returns true,nil for raid assistant", function()
        _G.IsInRaid  = function() return true end
        _G.UnitIsGroupLeader = function() return false end
        _G.UnitIsGroupAssistant = function() return true end
        local ok, reason = WGS:HasGroupLeadOrAssist()
        assert.is_true(ok); assert.is_nil(reason)
    end)

    it("returns false,'raid-need-lead' for a raid grunt", function()
        _G.IsInRaid  = function() return true end
        _G.UnitIsGroupLeader = function() return false end
        _G.UnitIsGroupAssistant = function() return false end
        local ok, reason = WGS:HasGroupLeadOrAssist()
        assert.is_false(ok); assert.are.equal("raid-need-lead", reason)
    end)

    it("returns true,nil for party leader", function()
        _G.IsInRaid  = function() return false end
        _G.IsInGroup = function() return true end
        _G.UnitIsGroupLeader = function() return true end
        local ok, reason = WGS:HasGroupLeadOrAssist()
        assert.is_true(ok); assert.is_nil(reason)
    end)

    it("returns false,'party-need-lead' for a party non-leader", function()
        _G.IsInRaid  = function() return false end
        _G.IsInGroup = function() return true end
        _G.UnitIsGroupLeader = function() return false end
        local ok, reason = WGS:HasGroupLeadOrAssist()
        assert.is_false(ok); assert.are.equal("party-need-lead", reason)
    end)

    it("returns true,nil when solo (no group → nothing to gate on)", function()
        _G.IsInRaid  = function() return false end
        _G.IsInGroup = function() return false end
        local ok, reason = WGS:HasGroupLeadOrAssist()
        assert.is_true(ok); assert.is_nil(reason)
    end)
end)

describe("WGS:IsGuildOfficer", function()
    local WGS
    local origInGuild, origGuildInfo

    before_each(function()
        WGS = helpers.setup()
        origInGuild   = _G.IsInGuild
        origGuildInfo = _G.GetGuildInfo
    end)
    after_each(function()
        _G.IsInGuild     = origInGuild
        _G.GetGuildInfo  = origGuildInfo
    end)

    it("is true for rank index 0 (Guild Master)", function()
        _G.IsInGuild     = function() return true end
        _G.GetGuildInfo  = function() return "Guild", "Master", 0 end
        assert.is_true(WGS:IsGuildOfficer())
    end)

    it("is true for rank index 2 (third tier — typically 'Officer Alt')", function()
        _G.IsInGuild     = function() return true end
        _G.GetGuildInfo  = function() return "Guild", "Officer Alt", 2 end
        assert.is_true(WGS:IsGuildOfficer())
    end)

    it("is false for rank index 3+", function()
        _G.IsInGuild     = function() return true end
        _G.GetGuildInfo  = function() return "Guild", "Raider", 3 end
        assert.is_false(WGS:IsGuildOfficer())
    end)

    it("is false when not in a guild", function()
        _G.IsInGuild = function() return false end
        assert.is_false(WGS:IsGuildOfficer())
    end)

    it("is false when GetGuildInfo returns no rank", function()
        _G.IsInGuild     = function() return true end
        _G.GetGuildInfo  = function() return "Guild", "Member" end  -- nil rankIndex
        assert.is_false(WGS:IsGuildOfficer())
    end)
end)

describe("WGS:FormatGold", function()
    local WGS
    before_each(function() WGS = helpers.setup() end)

    it("formats a typical bank balance", function()
        -- 12345 gold 67 silver 89 copper = 123456789 copper
        assert.are.equal("12345g 67s 89c", WGS:FormatGold(123456789))
    end)

    it("handles 0 copper", function()
        assert.are.equal("0g 0s 0c", WGS:FormatGold(0))
    end)

    it("handles nil defensively (returns zero string)", function()
        assert.are.equal("0g 0s 0c", WGS:FormatGold(nil))
    end)
end)
