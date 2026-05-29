local helpers = require("spec.helpers")

-- UI/EventsDetail.lua's evaluateRaidCompBalance flags class/role
-- mix issues in a planned raid comp (no battle rez, no Bloodlust,
-- low tank/healer count at mythic size, ≥4 of one class stacking).
-- Output drives a yellow warning strip above the Raid Comp section
-- so officers catch obvious balance mistakes at planning time, not
-- at the pull.

local function setup()
    local WGS = helpers.setup()
    helpers.loadUIShims()
    dofile("UI/EventsDetail.lua")
    return WGS
end

local function slot(class, role) return { class = class, role = role } end

describe("evaluateRaidCompBalance", function()
    local WGS, evaluate

    before_each(function()
        WGS = setup()
        evaluate = WGS._EvaluateRaidCompBalance
    end)

    it("returns no warnings for a well-formed mythic comp", function()
        local comp = {
            -- 2 tanks
            slot("WARRIOR", "TANK"), slot("DEATHKNIGHT", "TANK"),
            -- 5 healers
            slot("PRIEST", "HEALER"), slot("PALADIN", "HEALER"),
            slot("MONK", "HEALER"), slot("DRUID", "HEALER"),
            slot("SHAMAN", "HEALER"),
            -- 13 dps (mix of classes)
            slot("MAGE", "DPS"), slot("WARLOCK", "DPS"), slot("ROGUE", "DPS"),
            slot("HUNTER", "DPS"), slot("DEMONHUNTER", "DPS"), slot("EVOKER", "DPS"),
            slot("DEATHKNIGHT", "DPS"), slot("WARRIOR", "DPS"), slot("PRIEST", "DPS"),
            slot("MONK", "DPS"), slot("DRUID", "DPS"), slot("PALADIN", "DPS"),
            slot("SHAMAN", "DPS"),
        }
        local warnings = evaluate(comp)
        assert.are.equal(0, #warnings,
            "balanced mythic comp must produce zero warnings — got: " ..
            table.concat(warnings, " | "))
    end)

    it("flags missing combat rez when no DK/Druid/Hunter/Warlock present", function()
        local comp = {
            slot("WARRIOR", "TANK"), slot("PALADIN", "TANK"),
            slot("PRIEST", "HEALER"), slot("MONK", "HEALER"),
            slot("MAGE", "DPS"), slot("SHAMAN", "DPS"),
        }
        local warnings = evaluate(comp)
        local sawBR = false
        for _, w in ipairs(warnings) do
            if w:find("combat rez", 1, true) then sawBR = true end
        end
        assert.is_true(sawBR)
    end)

    it("flags missing Bloodlust when no Shaman/Mage/Hunter/Evoker present", function()
        local comp = {
            slot("WARRIOR", "TANK"), slot("PALADIN", "TANK"),
            slot("PRIEST", "HEALER"), slot("DRUID", "HEALER"),
            slot("WARLOCK", "DPS"), slot("ROGUE", "DPS"),
        }
        local warnings = evaluate(comp)
        local sawLust = false
        for _, w in ipairs(warnings) do
            if w:find("Bloodlust", 1, true) then sawLust = true end
        end
        assert.is_true(sawLust)
    end)

    it("flags low tank/healer count ONLY when comp size ≥18", function()
        -- 5-person comp: 1 tank, 1 healer is fine (m+ shape), no
        -- count warnings should fire.
        local small = {
            slot("WARRIOR", "TANK"), slot("PRIEST", "HEALER"),
            slot("MAGE", "DPS"), slot("ROGUE", "DPS"), slot("DRUID", "DPS"),
        }
        local smallWarnings = evaluate(small)
        for _, w in ipairs(smallWarnings) do
            assert.is_nil(w:find("tank", 1, true) or w:find("healer", 1, true),
                "small comp must not get tank/healer count warnings: " .. w)
        end

        -- 18+ comp with 1 tank → tank warning fires
        local big = {
            slot("WARRIOR", "TANK"),   -- only 1 tank
            slot("PRIEST", "HEALER"), slot("MONK", "HEALER"),
            slot("DRUID", "HEALER"), slot("PALADIN", "HEALER"),
        }
        for _ = 1, 14 do big[#big + 1] = slot("MAGE", "DPS") end
        -- 18 total now (need 18 for the size-gate)
        for _ = 1, 18 - #big do big[#big + 1] = slot("MAGE", "DPS") end
        local bigWarnings = evaluate(big)
        local sawTank = false
        for _, w in ipairs(bigWarnings) do
            if w:find("tank", 1, true) then sawTank = true end
        end
        assert.is_true(sawTank, "mythic-size comp with 1 tank must surface the warning")
    end)

    it("flags class stacking at ≥4 of the same class", function()
        local comp = {
            slot("WARRIOR", "TANK"), slot("PALADIN", "TANK"),
            slot("PRIEST", "HEALER"), slot("DRUID", "HEALER"),
            slot("MAGE", "DPS"), slot("MAGE", "DPS"),
            slot("MAGE", "DPS"), slot("MAGE", "DPS"),   -- 4 mages
        }
        local warnings = evaluate(comp)
        local sawStack = false
        for _, w in ipairs(warnings) do
            if w:find("stacking", 1, true) then sawStack = true end
        end
        assert.is_true(sawStack)
    end)

    it("tolerates an empty comp without throwing", function()
        local warnings = evaluate({})
        assert.is_table(warnings)
        assert.are.equal(0, #warnings,
            "empty comp = no opinions; warnings only matter for real comps")
    end)
end)
