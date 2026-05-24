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

-- /gh interop diagnostic. Returns a structured snapshot of MRT/NSRT
-- integration state so officers can confirm the bridges are wired up
-- without having to /dump SavedVariables.
describe("WGS:InteropStatus", function()
    local WGS, origVMRT, origNSRT, origMRT, origGMRT
    local origCAddOns, origIsAddOnLoaded

    before_each(function()
        WGS = helpers.setup()
        origVMRT          = _G.VMRT
        origNSRT          = _G.NSRT
        origMRT           = _G.MRT
        origGMRT          = _G.GMRT
        origCAddOns       = _G.C_AddOns
        origIsAddOnLoaded = _G.IsAddOnLoaded
        WGS:_ResetAddonCache()
    end)

    after_each(function()
        _G.VMRT          = origVMRT
        _G.NSRT          = origNSRT
        _G.MRT           = origMRT
        _G.GMRT          = origGMRT
        _G.C_AddOns      = origCAddOns
        _G.IsAddOnLoaded = origIsAddOnLoaded
    end)

    -- Clean-slate: nothing loaded, nothing captured. Status should
    -- still return a valid table so the printer never NPEs.
    it("returns a valid snapshot when nothing is loaded", function()
        _G.C_AddOns = { IsAddOnLoaded = function() return false end }
        _G.VMRT, _G.NSRT, _G.MRT, _G.GMRT = nil, nil, nil, nil
        local s = WGS:InteropStatus()
        assert.is_false(s.mrtLoaded)
        assert.is_false(s.nsrtLoaded)
        assert.is_false(s.vmrtPresent)
        assert.is_false(s.hasMRTData)
        assert.are.equal(0, s.mrtLootCount)
        assert.are.equal(0, s.mrtAttCount)
        assert.is_nil(s.noteAPIUsed)
    end)

    -- MRT loaded, VMRT populated, some gap-fill loot recorded → all
    -- counts surface and the note API picks the right preferred path.
    it("counts MRT-sourced loot + bossAttendance sessions and surfaces note size", function()
        _G.C_AddOns = { IsAddOnLoaded = function(name) return name == "MRT" end }
        _G.VMRT = { Note = { Text1 = "phase 1: stack on tank" }, LootHistory = {}, Attendance = {} }
        _G.MRT  = { F = { GetNote = function(_, _) return "phase 1: stack on tank" end } }
        WGS.db.global.loot = {
            { itemID = 1, player = "X", timestamp = 1000, source = "mrt" },
            { itemID = 2, player = "Y", timestamp = 2000 },                  -- not from MRT
            { itemID = 3, player = "Z", timestamp = 3000, source = "mrt" },
        }
        WGS.db.global.attendance = {
            { startedAt = 100, endedAt = 200, bossAttendance = { { eN = "Boss1" } } },
            { startedAt = 300, endedAt = 400 },                              -- no bossAttendance
            { startedAt = 500, endedAt = 600, bossAttendance = { { eN = "Boss2" } } },
        }

        local s = WGS:InteropStatus()
        assert.is_true(s.mrtLoaded)
        assert.is_true(s.hasMRTData)
        assert.are.equal(2, s.mrtLootCount)
        assert.are.equal(3, s.mrtLootTotal)
        assert.are.equal(3000, s.mrtLootLast,
            "last MRT loot timestamp should track the most recent row")
        assert.are.equal(2, s.mrtAttCount)
        assert.are.equal(3, s.mrtAttTotal)
        assert.are.equal(600, s.mrtAttLast)
        assert.are.equal("MRT.F.GetNote", s.noteAPIUsed,
            "should prefer the public MRT.F.GetNote when available")
        assert.are.equal(#"phase 1: stack on tank", s.noteSize)
    end)

    -- NSRT-only scenario (no MRT addon, but VMRT global is populated
    -- because NSRT writes to it for backwards compat). hasMRTData
    -- should still be true so the bridges run.
    it("reports hasMRTData true when only NSRT is loaded with VMRT populated", function()
        _G.C_AddOns = { IsAddOnLoaded = function(name)
            return name == "NSRT" or name == "NorthernSkyRaidTools"
        end }
        _G.VMRT = { Note = { Text1 = "n" } }
        _G.MRT, _G.GMRT = nil, nil

        local s = WGS:InteropStatus()
        assert.is_false(s.mrtLoaded)
        assert.is_true(s.nsrtLoaded)
        assert.is_true(s.hasMRTData)
        -- No MRT.F.GetNote, no GMRT.F:GetNote → falls back to raw read.
        assert.are.equal("VMRT.Note.Text1 (raw)", s.noteAPIUsed)
    end)
end)
