local helpers = require("spec.helpers")

-- WGS:GetMRTNote (Modules/MRTNotes.lua) reads from MRT's shared raid
-- note. Three sources, in fallback order:
--   1. MRT.F.GetNote(removeColors, removeExtraSpaces) — preferred,
--      returns the same formatted text MRT displays.
--   2. GMRT.F:GetNote() — alternate namespace, older builds.
--   3. VMRT.Note.Text1 — raw saved-variable read, last resort.
-- All three are gated on WGS:HasAddon("MRT") first; if MRT isn't loaded,
-- the accessor returns nil and BossNotesFrame skips the section.

describe("WGS:GetMRTNote", function()
    local WGS

    local origCAddOns, origIsAddOnLoaded
    local origMRT, origGMRT, origVMRT

    local function pretendMRTLoaded(loaded)
        _G.C_AddOns = { IsAddOnLoaded = function(n) return n == "MRT" and loaded end }
        WGS:_ResetAddonCache()
    end

    before_each(function()
        WGS = helpers.setup()
        origCAddOns       = _G.C_AddOns
        origIsAddOnLoaded = _G.IsAddOnLoaded
        origMRT           = _G.MRT
        origGMRT          = _G.GMRT
        origVMRT          = _G.VMRT
        _G.MRT  = nil
        _G.GMRT = nil
        _G.VMRT = nil
    end)

    after_each(function()
        _G.C_AddOns       = origCAddOns
        _G.IsAddOnLoaded  = origIsAddOnLoaded
        _G.MRT            = origMRT
        _G.GMRT           = origGMRT
        _G.VMRT           = origVMRT
    end)

    it("returns nil when no VMRT data is available", function()
        pretendMRTLoaded(false)
        _G.VMRT = nil   -- nothing for the bridge to read
        assert.is_nil(WGS:GetMRTNote())
    end)

    -- New contract: NSRT writes to VMRT too, so VMRT-populated-but-
    -- MRT-not-loaded is a valid case (NSRT user, no MRT). We used to
    -- treat that as "ignore the global"; now we treat it as "use it."
    it("reads VMRT.Note even when the MRT addon name isn't loaded (NSRT compat)", function()
        pretendMRTLoaded(false)
        _G.VMRT = { Note = { Text1 = "via-NSRT" } }
        assert.are.equal("via-NSRT", WGS:GetMRTNote())
    end)

    it("prefers MRT.F.GetNote when present (formatted output)", function()
        pretendMRTLoaded(true)
        _G.MRT = {
            F = {
                GetNote = function(removeColors, removeExtraSpaces)
                    -- Sanity: GuildHall asks for cleaned text.
                    assert(removeColors == true)
                    assert(removeExtraSpaces == true)
                    return "Phase 1: tank swap at 30%"
                end,
            },
        }
        _G.VMRT = { Note = { Text1 = "raw-stale-text-should-not-win" } }
        assert.are.equal("Phase 1: tank swap at 30%", WGS:GetMRTNote())
    end)

    it("falls back to GMRT.F:GetNote when MRT.F is missing", function()
        pretendMRTLoaded(true)
        _G.GMRT = {
            F = {
                GetNote = function(self_, removeColors, removeExtraSpaces)
                    -- Colon-call: first arg is the F table itself.
                    assert(self_ == _G.GMRT.F)
                    assert(removeColors == true)
                    assert(removeExtraSpaces == true)
                    return "from-gmrt"
                end,
            },
        }
        _G.VMRT = { Note = { Text1 = "raw-stale" } }
        assert.are.equal("from-gmrt", WGS:GetMRTNote())
    end)

    it("falls back to VMRT.Note.Text1 raw read when no public API is exposed", function()
        pretendMRTLoaded(true)
        _G.VMRT = { Note = { Text1 = "raw-note-content" } }
        assert.are.equal("raw-note-content", WGS:GetMRTNote())
    end)

    it("returns nil when MRT is loaded but every source is empty", function()
        pretendMRTLoaded(true)
        _G.MRT  = { F = { GetNote = function() return "" end } }
        _G.VMRT = { Note = { Text1 = "" } }
        assert.is_nil(WGS:GetMRTNote())
    end)

    it("returns nil when MRT is loaded but VMRT.Note table is missing", function()
        pretendMRTLoaded(true)
        _G.VMRT = {}  -- no Note table at all
        assert.is_nil(WGS:GetMRTNote())
    end)

    it("survives MRT.F.GetNote throwing (pcall guard)", function()
        pretendMRTLoaded(true)
        _G.MRT = { F = { GetNote = function() error("MRT internal bug") end } }
        _G.VMRT = { Note = { Text1 = "fallback-after-error" } }
        assert.are.equal("fallback-after-error", WGS:GetMRTNote())
    end)

    it("raw=true bypasses the public API and reads VMRT directly", function()
        pretendMRTLoaded(true)
        _G.MRT  = { F = { GetNote = function() return "formatted-version" end } }
        _G.VMRT = { Note = { Text1 = "|cffffffffraw|r with colors" } }
        assert.are.equal("|cffffffffraw|r with colors", WGS:GetMRTNote(true))
    end)
end)
