local helpers = require("spec.helpers")

-- Modules/Loot.lua — officer correction mutators. Used by the right-
-- click menu on Logs → Loot rows; each one owns the data change + the
-- WGS_LOOT_EDITED FireEvent + the local-only chat hint.
--
-- v1 limitation locked down here: PeerSync's per-row merge dedups on
-- (itemID, shortName(player), timestamp ±60s) — so edits don't
-- propagate to other officers via per-row sync. Each mutator prints
-- the CORRECTION_LOCAL_HINT to flag this; tests assert the print
-- happens so the limitation stays visible to users.

local function setup()
    local WGS = helpers.setup()
    -- Modules/Loot.lua isn't in helpers.setup()'s dofile list (it
    -- registers WoW chat events at file scope that other specs don't
    -- need), so the correction-mutator surface has to be loaded here.
    dofile("Modules/Loot.lua")
    WGS._printed = {}
    function WGS:Print(s) self._printed[#self._printed + 1] = s end
    return WGS
end

describe("WGS:RetagLootRow", function()
    local WGS
    before_each(function()
        WGS = setup()
        WGS.db.global.loot = {
            { itemID = 1, player = "X-Realm", timestamp = 100, eventId = 5, teamId = 1 },
            { itemID = 2, player = "Y-Realm", timestamp = 200, eventId = nil, teamId = nil },
        }
    end)

    it("rewrites eventId / teamId on the row at the given index", function()
        local ok = WGS:RetagLootRow(2, 99, 42)
        assert.is_true(ok)
        assert.are.equal(99, WGS.db.global.loot[2].eventId)
        assert.are.equal(42, WGS.db.global.loot[2].teamId)
        -- The other row stays untouched.
        assert.are.equal(5, WGS.db.global.loot[1].eventId)
    end)

    it("treats nil eventId/teamId as an untag (clears existing binding)", function()
        WGS:RetagLootRow(1, nil, nil)
        assert.is_nil(WGS.db.global.loot[1].eventId)
        assert.is_nil(WGS.db.global.loot[1].teamId)
    end)

    it("returns false when the index is out of range", function()
        assert.is_false(WGS:RetagLootRow(99, 1, 1))
    end)

    -- The UI subscribes to WGS_LOOT_EDITED to re-render. Without this
    -- firing, the right-click menu's "Re-tag event" wouldn't update
    -- the visible row until the user switched tabs and back.
    it("fires WGS_LOOT_EDITED with the index, row, and 'retag' kind", function()
        WGS:RetagLootRow(2, 7, 3)
        local fired
        for _, f in ipairs(GuildHall._fired) do
            if f.event == "WGS_LOOT_EDITED" then fired = f.args[1] end
        end
        assert.is_table(fired)
        assert.are.equal(2, fired.index)
        assert.are.equal("retag", fired.kind)
        assert.are.equal(7, fired.row.eventId)
    end)

    -- Edits are local-only in v1 (see Cross-officer propagation in the
    -- plan). The chat hint is the user-visible signal that the change
    -- won't sync. If this assertion regresses, restore the hint.
    it("prints the local-only hint so the user knows other officers won't see this", function()
        WGS:RetagLootRow(2, 7, 3)
        local sawHint = false
        for _, line in ipairs(WGS._printed) do
            if line:find("Local change saved") then sawHint = true end
        end
        assert.is_true(sawHint)
    end)
end)

describe("WGS:DeleteLootRow", function()
    local WGS
    before_each(function()
        WGS = setup()
        WGS.db.global.loot = {
            { itemID = 1, player = "X-Realm", timestamp = 100 },
            { itemID = 2, player = "Y-Realm", timestamp = 200 },
            { itemID = 3, player = "Z-Realm", timestamp = 300 },
        }
    end)

    it("removes the row at the given index and shifts the rest down", function()
        local ok = WGS:DeleteLootRow(2)
        assert.is_true(ok)
        assert.are.equal(2, #WGS.db.global.loot)
        assert.are.equal(1, WGS.db.global.loot[1].itemID)
        assert.are.equal(3, WGS.db.global.loot[2].itemID,
            "row at index 3 should now be at index 2 after the delete")
    end)

    it("returns false when the index is out of range", function()
        assert.is_false(WGS:DeleteLootRow(99))
        assert.are.equal(3, #WGS.db.global.loot)
    end)

    it("fires WGS_LOOT_EDITED with the removed row and 'delete' kind", function()
        WGS:DeleteLootRow(1)
        local fired
        for _, f in ipairs(GuildHall._fired) do
            if f.event == "WGS_LOOT_EDITED" then fired = f.args[1] end
        end
        assert.is_table(fired)
        assert.are.equal("delete", fired.kind)
        assert.are.equal(1, fired.row.itemID,
            "the fired payload should carry the row that was just deleted")
    end)
end)
