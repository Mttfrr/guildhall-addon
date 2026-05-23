local helpers = require("spec.helpers")

-- WGS:HasAddon is the gate every MRT/NSRT bridge module uses to decide
-- whether to read VMRT.* / NSRT.*. If the gate misbehaves (false
-- positives → nil-deref on read; false negatives → bridge silently
-- inert) the whole synergy story breaks. Tests cover both APIs
-- (C_AddOns.IsAddOnLoaded modern, IsAddOnLoaded legacy) and the cache.

describe("WGS:HasAddon", function()
    local WGS

    local origCAddOns
    local origGlobalCheck

    before_each(function()
        WGS = helpers.setup()
        -- Snapshot whatever the helper stubbed so each case starts clean.
        origCAddOns      = _G.C_AddOns
        origGlobalCheck  = _G.IsAddOnLoaded
        WGS:_ResetAddonCache()
    end)

    after_each(function()
        _G.C_AddOns       = origCAddOns
        _G.IsAddOnLoaded  = origGlobalCheck
    end)

    it("returns false for nil/empty names without touching the API", function()
        _G.C_AddOns = { IsAddOnLoaded = function() error("should not be called") end }
        assert.is_false(WGS:HasAddon(nil))
    end)

    it("returns true when C_AddOns reports the addon is loaded", function()
        _G.C_AddOns = { IsAddOnLoaded = function(name)
            return name == "MRT"
        end }
        assert.is_true(WGS:HasAddon("MRT"))
        assert.is_false(WGS:HasAddon("UnloadedAddon"))
    end)

    it("falls back to the legacy global when C_AddOns is missing", function()
        _G.C_AddOns = nil
        _G.IsAddOnLoaded = function(name) return name == "NorthernSkyRaidTools" end
        assert.is_true(WGS:HasAddon("NorthernSkyRaidTools"))
        assert.is_false(WGS:HasAddon("Bogus"))
    end)

    it("caches the first result per name", function()
        local calls = 0
        _G.C_AddOns = { IsAddOnLoaded = function(name)
            calls = calls + 1
            return name == "MRT"
        end }
        assert.is_true(WGS:HasAddon("MRT"))
        assert.is_true(WGS:HasAddon("MRT"))
        assert.is_true(WGS:HasAddon("MRT"))
        assert.are.equal(1, calls)
    end)

    it("caches negative results too (avoids re-polling for missing addons)", function()
        local calls = 0
        _G.C_AddOns = { IsAddOnLoaded = function()
            calls = calls + 1
            return false
        end }
        assert.is_false(WGS:HasAddon("DefinitelyNotLoaded"))
        assert.is_false(WGS:HasAddon("DefinitelyNotLoaded"))
        assert.are.equal(1, calls)
    end)

    it("_ResetAddonCache forces a fresh probe (test-helper contract)", function()
        local probe = "MRT"
        local loaded = false
        _G.C_AddOns = { IsAddOnLoaded = function(n) return n == probe and loaded end }

        assert.is_false(WGS:HasAddon(probe))
        loaded = true
        -- Without resetting, cache returns the stale false.
        assert.is_false(WGS:HasAddon(probe))
        WGS:_ResetAddonCache()
        assert.is_true(WGS:HasAddon(probe))
    end)
end)
