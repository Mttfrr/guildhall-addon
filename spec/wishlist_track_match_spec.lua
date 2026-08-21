-- A raider sims Mythic and wishlists the Myth-track piece; the guild runs
-- Heroic and the Hero-track piece drops. Same item, different item id — so
-- the id-only index reported nobody wanting it, and the tooltip, the loot
-- helper and the RCLC voting column all stayed silent for the one raider
-- it was for.

local helpers = require("spec.helpers")

describe("wishlist lookup across upgrade tracks", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
        WGS.db.global.wishlists = {
            {
                playerName = "Korvold",
                items = {
                    -- Wished at the Myth track…
                    { itemID = 111111, itemName = "Chestguard of Broken Vows", priority = "BiS", simPct = 5.2 },
                    { itemID = 222222, itemName = "Idol of the Drowned Choir", priority = "High" },
                },
            },
            {
                playerName = "Yukiya",
                items = {
                    { itemID = 333333, itemName = "Chestguard of Broken Vows", priority = "Medium" },
                },
            },
        }
        WGS.db.global.wishlistImportedAt = 1
    end)

    it("matches the exact item id, as before", function()
        local wishes = WGS:GetWishlistForItem(111111)
        assert.are.equal(1, #wishes)
        assert.are.equal("Korvold", wishes[1].playerName)
        assert.are.equal(5.2, wishes[1].simPct)
    end)

    it("…and the SAME item at a different track, by name", function()
        -- 999999 = the Hero-track id nobody wishlisted.
        local wishes = WGS:GetWishlistForItem(999999, "Chestguard of Broken Vows")
        assert.are.equal(2, #wishes)
        local names = { wishes[1].playerName, wishes[2].playerName }
        table.sort(names)
        assert.same({ "Korvold", "Yukiya" }, names)
    end)

    it("prefers an id hit outright — a name never dilutes an exact match", function()
        -- 111111 is Korvold's; Yukiya wants the same NAME at another id.
        -- The id hit must not pull her in.
        local wishes = WGS:GetWishlistForItem(111111, "Chestguard of Broken Vows")
        assert.are.equal(1, #wishes)
        assert.are.equal("Korvold", wishes[1].playerName)
    end)

    it("is case- and whitespace-insensitive on the name", function()
        assert.are.equal(2, #WGS:GetWishlistForItem(999999, "  chestguard OF broken vows  "))
    end)

    it("returns nothing for an unrelated item, with or without a name", function()
        assert.are.equal(0, #WGS:GetWishlistForItem(888888))
        assert.are.equal(0, #WGS:GetWishlistForItem(888888, "Some Other Thing"))
        assert.are.equal(0, #WGS:GetWishlistForItem(888888, ""))
    end)

    it("tolerates wishes with no name — the id index still works", function()
        WGS.db.global.wishlists = {
            { playerName = "Nameless", items = { { itemID = 444444, priority = "Low" } } },
        }
        WGS.db.global.wishlistImportedAt = 2
        assert.are.equal(1, #WGS:GetWishlistForItem(444444))
        assert.are.equal(0, #WGS:GetWishlistForItem(555555, "Anything"))
    end)

    it("rebuilds the name index on re-import, not just the id index", function()
        assert.are.equal(2, #WGS:GetWishlistForItem(999999, "Chestguard of Broken Vows"))
        WGS.db.global.wishlists = {
            { playerName = "Korvold", items = { { itemID = 111111, itemName = "Something Else" } } },
        }
        WGS.db.global.wishlistImportedAt = 3
        assert.are.equal(0, #WGS:GetWishlistForItem(999999, "Chestguard of Broken Vows"))
        assert.are.equal(1, #WGS:GetWishlistForItem(999999, "Something Else"))
    end)
end)
