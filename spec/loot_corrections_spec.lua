local helpers = require("spec.helpers")

-- Modules/Loot.lua — officer correction mutators. Used by the right-
-- click menu on Logs → Loot rows; each one owns the data change + a
-- rev-counter bump + the WGS_LOOT_EDITED FireEvent that PeerSync wires
-- to a peer broadcast + a confirmation print.
--
-- Edits propagate: PeerSync's merge fn is rev-aware (LWW), so an edit
-- with a higher rev replaces the peers' existing row in place. Deletes
-- broadcast a `_deleted = true` tombstone with bumped rev that peers
-- find by natural key and remove. Coverage here pins the rev bump on
-- every mutator + the tombstone shape on delete.

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

    -- Confirmation print after every successful edit. The wording
    -- changed when cross-officer propagation landed ("Local change
    -- saved..." → "Correction applied..."); the print itself stays so
    -- the user sees something happened.
    it("prints the correction-applied confirmation", function()
        WGS:RetagLootRow(2, 7, 3)
        local sawHint = false
        for _, line in ipairs(WGS._printed) do
            if line:find("Correction applied") then sawHint = true end
        end
        assert.is_true(sawHint)
    end)

    -- Rev bump is what makes the broadcast win the LWW merge on the
    -- peer side. Without this, an edit arrives at a peer with the same
    -- rev as the existing row and gets dropped as a no-op.
    it("bumps row.rev so the broadcast wins LWW on the peer side", function()
        assert.are.equal(nil, WGS.db.global.loot[2].rev,
            "fresh capture row carries no rev field (treated as 0)")
        WGS:RetagLootRow(2, 7, 3)
        assert.are.equal(1, WGS.db.global.loot[2].rev,
            "first edit bumps rev 0 → 1")
        WGS:RetagLootRow(2, 8, 4)
        assert.are.equal(2, WGS.db.global.loot[2].rev,
            "second edit bumps rev 1 → 2")
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

    -- Delete broadcasts a tombstone: same natural key (itemID, player,
    -- timestamp) so peers can find their copy, plus _deleted=true and a
    -- bumped rev so LWW removes it. Without _deleted the peer would
    -- treat the broadcast as a re-add of the deleted row.
    it("broadcasts a tombstone payload with _deleted=true and a bumped rev", function()
        WGS:DeleteLootRow(2)
        local fired
        for _, f in ipairs(GuildHall._fired) do
            if f.event == "WGS_LOOT_EDITED" then fired = f.args[1] end
        end
        assert.is_true(fired.row._deleted, "tombstone must carry _deleted=true")
        assert.are.equal(1, fired.row.rev,
            "tombstone rev must be bumped past the deleted row's rev")
        assert.are.equal(2, fired.row.itemID,
            "tombstone carries the natural key so peers find the row")
        assert.are.equal("Y-Realm", fired.row.player)
        assert.are.equal(200, fired.row.timestamp)
    end)
end)
