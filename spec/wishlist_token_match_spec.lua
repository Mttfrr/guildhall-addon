-- Tier set tokens: the raid drops ONE item that several classes turn into
-- several different pieces.
--
-- A raider wishlists (or sims into their list) the piece they will equip —
-- their class's tier chest, one item id, one name. What drops is the token:
-- different id, different name. The wish index matches on id, then on name,
-- so a token matched neither and the tooltip, the loot helper and the RCLC
-- voting column all reported that nobody wanted it — on tier, the loot people
-- care most about.
--
-- The platform ships the mapping (services/tierTokens.js → export
-- `tierTokens`); these specs pin how the addon resolves through it.

local helpers = require("spec.helpers")

local TOKEN_ID = 235123
local PALADIN_CHEST = 245001

describe("wishlist lookup through a tier token", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
        WGS.db.global.wishlists = {
            {
                playerName = "Lightbringer", class = "Paladin",
                items = {
                    { itemID = PALADIN_CHEST, itemName = "Chestpiece of Dawn", slot = "Chest", priority = "BiS", simPct = 4.2 },
                    { itemID = 999001, itemName = "Ring of Nothing", slot = "Ring", priority = "Low" },
                },
            },
            {
                playerName = "Whisper", class = "Priest",
                items = {
                    { itemID = 246001, itemName = "Robes of Dusk", slot = "Chest", priority = "High" },
                },
            },
            {
                playerName = "Frostbite", class = "Mage",   -- not on this token
                items = {
                    { itemID = 247001, itemName = "Cloth Chest of Elsewhere", slot = "Chest", priority = "BiS" },
                },
            },
        }
        WGS.db.global.wishlistImportedAt = 1
        WGS.db.global.tierTokens = {
            {
                itemID = TOKEN_ID, slot = "Chest", name = "Zenith Chestguard",
                classes = {
                    { name = "Paladin", itemId = PALADIN_CHEST },   -- exact piece known
                    { name = "Priest" },                            -- covered, piece unknown
                },
            },
        }
    end)

    it("surfaces the wishers of the pieces the token becomes", function()
        local wishes = WGS:GetWishlistForItem(TOKEN_ID, "Zenith Chestguard")
        assert.are.equal(2, #wishes)

        local byName = {}
        for _, w in ipairs(wishes) do byName[w.playerName] = w end
        assert.is_truthy(byName.Lightbringer, "matched by the exact configured piece")
        assert.is_truthy(byName.Whisper, "matched by class + slot when no piece id is configured")
        assert.is_nil(byName.Frostbite, "a class the token doesn't serve is never a candidate")
        assert.are.equal("BiS", byName.Lightbringer.priority)
        assert.are.equal(4.2, byName.Lightbringer.simPct, "the Droptimizer gain rides along")
    end)

    it("does not drag in the wisher's other slots", function()
        local wishes = WGS:GetWishlistForItem(TOKEN_ID)
        for _, w in ipairs(wishes) do
            assert.are_not.equal("Ring of Nothing", w.itemName)
        end
        assert.are.equal(2, #wishes)
    end)

    it("leaves the id and name paths untouched", function()
        local byId = WGS:GetWishlistForItem(PALADIN_CHEST)
        assert.are.equal(1, #byId)
        assert.are.equal("Lightbringer", byId[1].playerName)

        assert.are.equal(0, #WGS:GetWishlistForItem(555555, "Nothing At All"))
    end)

    it("is inert without a token map (older platform export)", function()
        WGS.db.global.tierTokens = nil
        assert.are.equal(0, #WGS:GetWishlistForItem(TOKEN_ID, "Zenith Chestguard"))

        WGS.db.global.tierTokens = {}
        assert.are.equal(0, #WGS:GetWishlistForItem(TOKEN_ID, "Zenith Chestguard"))
    end)

    it("re-resolves after a fresh import rather than serving a stale answer", function()
        assert.are.equal(2, #WGS:GetWishlistForItem(TOKEN_ID))

        -- A new import replaces the wishlists table and bumps the stamp; the
        -- token cache is keyed to the index it was built from.
        WGS.db.global.wishlists = {
            { playerName = "Lightbringer", class = "Paladin",
              items = { { itemID = PALADIN_CHEST, itemName = "Chestpiece of Dawn", slot = "Chest", priority = "Medium" } } },
        }
        WGS.db.global.wishlistImportedAt = 2
        local after = WGS:GetWishlistForItem(TOKEN_ID)
        assert.are.equal(1, #after)
        assert.are.equal("Medium", after[1].priority)
    end)

    it("stores the map on import", function()
        WGS:ProcessImport({
            wishlists = { { playerName = "Lightbringer", class = "Paladin", items = {} } },
            tierTokens = { { itemID = TOKEN_ID, slot = "Chest", classes = { { name = "Paladin" } } } },
        })
        assert.are.equal(TOKEN_ID, WGS.db.global.tierTokens[1].itemID)

        -- An export from a platform that predates the map must clear it
        -- rather than leave the previous tier's tokens resolving forever.
        WGS:ProcessImport({ wishlists = { { playerName = "Lightbringer", class = "Paladin", items = {} } } })
        assert.are.equal(0, #WGS.db.global.tierTokens)
    end)
end)
