local helpers = require("spec.helpers")

-- WGS:BuildWishlistBossGroups (UI/Teams/Wishlists.lua) turns the
-- platform's wishlist export into the boss-grouped, priority-sorted
-- structure the Teams → Wishlists browser renders. The platform export
-- now carries a per-player `class` and a per-item `source` (the wish's
-- boss); older imports lack both, so every fallback path matters:
--
--   source → majority vote over the item's wish sources (trimmed,
--            case-insensitive merge) → loot-history itemID→boss
--            derivation → "Unassigned" bucket
--   class  → entry.class → characterDetails → guild-roster lookup →
--            nil (renderer omits the icon)
--
-- The function is pure with respect to its opts (no db reads), so these
-- specs pin the grouping without a rendering harness.

local function setup()
    local WGS = helpers.setup()
    helpers.loadUIShims()
    dofile("UI/Teams/Wishlists.lua")
    return WGS
end

-- Shorthand builders for the platform export shape.
local function wish(playerName, class, items)
    return { playerName = playerName, class = class, items = items }
end
local function item(itemID, over)
    local it = { itemID = itemID, priority = "High" }
    for k, v in pairs(over or {}) do it[k] = v end
    return it
end

describe("WGS:BuildWishlistBossGroups", function()
    local WGS

    before_each(function()
        WGS = setup()
    end)

    it("returns an empty boss list for empty/nil wishlists", function()
        assert.are.same({ bosses = {} }, WGS:BuildWishlistBossGroups({}, {}))
        assert.are.same({ bosses = {} }, WGS:BuildWishlistBossGroups(nil, {}))
    end)

    it("groups items under their wish-supplied source", function()
        local result = WGS:BuildWishlistBossGroups({
            wish("Aly", "Mage", { item(101, { source = "Queen Ansurek" }) }),
            wish("Bob", "Rogue", { item(202, { source = "Broodtwister" }) }),
        }, {})
        assert.are.equal(2, #result.bosses)
        -- Alphabetical boss order
        assert.are.equal("Broodtwister", result.bosses[1].name)
        assert.are.equal("Queen Ansurek", result.bosses[2].name)
        assert.are.equal(202, result.bosses[1].items[1].itemID)
        assert.are.equal(101, result.bosses[2].items[1].itemID)
    end)

    it("merges sources case-insensitively and trimmed, keeping first-seen casing", function()
        local result = WGS:BuildWishlistBossGroups({
            wish("Aly", "Mage",  { item(101, { source = "Queen Ansurek" }) }),
            wish("Bob", "Rogue", { item(202, { source = "  queen ANSUREK  " }) }),
        }, {})
        assert.are.equal(1, #result.bosses)
        assert.are.equal("Queen Ansurek", result.bosses[1].name)
        assert.are.equal(2, result.bosses[1].itemCount)
    end)

    it("resolves an item's boss by majority vote over its wish sources", function()
        local result = WGS:BuildWishlistBossGroups({
            wish("Aly", "Mage",   { item(101, { source = "Ulgrax" }) }),
            wish("Bob", "Rogue",  { item(101, { source = "Ulgrax" }) }),
            wish("Cid", "Priest", { item(101, { source = "Sikran" }) }),
        }, {})
        assert.are.equal(1, #result.bosses)
        assert.are.equal("Ulgrax", result.bosses[1].name)
    end)

    it("breaks source-vote ties deterministically (lexicographically-smallest key)", function()
        local result = WGS:BuildWishlistBossGroups({
            wish("Aly", "Mage",  { item(101, { source = "Sikran" }) }),
            wish("Bob", "Rogue", { item(101, { source = "Ulgrax" }) }),
        }, {})
        assert.are.equal(1, #result.bosses)
        assert.are.equal("Sikran", result.bosses[1].name)
    end)

    it("falls back to the loot-history itemID→boss derivation when wishes carry no source", function()
        local result = WGS:BuildWishlistBossGroups({
            wish("Aly", "Mage", { item(101) }),   -- legacy import: no source
        }, {
            loot = {
                { itemID = 101, itemName = "Old Blade", boss = "Rasha'nan" },
            },
        })
        assert.are.equal(1, #result.bosses)
        assert.are.equal("Rasha'nan", result.bosses[1].name)
    end)

    it("prefers the wish source over a conflicting loot-history boss", function()
        local result = WGS:BuildWishlistBossGroups({
            wish("Aly", "Mage", { item(101, { source = "Queen Ansurek" }) }),
        }, {
            loot = {
                { itemID = 101, boss = "Rasha'nan" },
            },
        })
        assert.are.equal(1, #result.bosses)
        assert.are.equal("Queen Ansurek", result.bosses[1].name)
    end)

    it("buckets sourceless items with no loot history under Unassigned, ordered last", function()
        local result = WGS:BuildWishlistBossGroups({
            wish("Aly", "Mage", {
                item(101, { source = "Zzar the Last" }),  -- alphabetically after "Unassigned"
                item(202),                                -- nothing to derive from
            }),
        }, {})
        assert.are.equal(2, #result.bosses)
        assert.are.equal("Zzar the Last", result.bosses[1].name)
        assert.are.equal("Unassigned", result.bosses[2].name)
        assert.are.equal(202, result.bosses[2].items[1].itemID)
    end)

    it("sorts wishers by priority rank (BiS first, unknown last), then name", function()
        local result = WGS:BuildWishlistBossGroups({
            wish("Zed", "Mage",    { item(101, { source = "B", priority = "BiS" }) }),
            wish("Amy", "Rogue",   { item(101, { source = "B", priority = "Low" }) }),
            wish("Bea", "Priest",  { item(101, { source = "B", priority = "Medium" }) }),
            wish("Cal", "Warlock", { item(101, { source = "B", priority = "High" }) }),
            wish("Dot", "Druid",   { item(101, { source = "B", priority = "???" }) }),
            wish("Abe", "Monk",    { item(101, { source = "B", priority = "Low" }) }),
        }, {})
        local names = {}
        for _, w in ipairs(result.bosses[1].items[1].wishers) do
            names[#names + 1] = w.short .. ":" .. w.priority
        end
        assert.are.same(
            { "Zed:BiS", "Cal:High", "Bea:Medium", "Abe:Low", "Amy:Low", "Dot:???" },
            names)
    end)

    it("sorts a boss's items by wisher count desc, then name", function()
        local result = WGS:BuildWishlistBossGroups({
            wish("Aly", "Mage", {
                item(101, { source = "B", itemName = "Zeta Blade" }),
                item(202, { source = "B", itemName = "Alpha Ring" }),
                item(303, { source = "B", itemName = "Popular Axe" }),
            }),
            wish("Bob", "Rogue", { item(303, { source = "B", itemName = "Popular Axe" }) }),
        }, {})
        local order = {}
        for _, it in ipairs(result.bosses[1].items) do order[#order + 1] = it.name end
        assert.are.same({ "Popular Axe", "Alpha Ring", "Zeta Blade" }, order)
    end)

    describe("class resolution", function()
        it("normalises the entry's own class field to the classFile constant", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Death Knight", { item(101, { source = "B" }) }),
            }, {})
            assert.are.equal("DEATHKNIGHT", result.bosses[1].items[1].wishers[1].class)
        end)

        it("falls back to characterDetails, then the guild roster lookup", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly-Realm", nil, { item(101, { source = "B" }) }),  -- legacy: no class
                wish("Bob", "",     { item(101, { source = "B" }) }),
            }, {
                characterDetails = { Aly = { class = "Demon Hunter" } },
                roster           = { Bob = { class = "SHAMAN" } },
            })
            local wishers = result.bosses[1].items[1].wishers
            local byName = {}
            for _, w in ipairs(wishers) do byName[w.short] = w.class end
            assert.are.equal("DEMONHUNTER", byName.Aly)
            assert.are.equal("SHAMAN", byName.Bob)
        end)

        it("returns nil class for unknown players and garbage class strings", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Ghost", nil,          { item(101, { source = "B" }) }),
                wish("Junk", "Not A Class", { item(101, { source = "B" }) }),
            }, {})
            for _, w in ipairs(result.bosses[1].items[1].wishers) do
                assert.is_nil(w.class)
            end
        end)
    end)

    describe("team filter (opts.allowed)", function()
        it("keeps players matched by full or short name, drops the rest", function()
            local allowed = { ["Aly-Realm"] = true, Aly = true, Bob = true }
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly-Realm", "Mage",   { item(101, { source = "B" }) }),
                wish("Bob-Other", "Rogue",  { item(101, { source = "B" }) }),
                wish("Eve",       "Priest", { item(101, { source = "B" }) }),
            }, { allowed = allowed })
            local wishers = result.bosses[1].items[1].wishers
            assert.are.equal(2, #wishers)
            local names = {}
            for _, w in ipairs(wishers) do names[w.short] = true end
            assert.is_true(names.Aly)
            assert.is_true(names.Bob)
            assert.is_nil(names.Eve)
        end)

        it("drops an item (and its boss group) entirely when every wisher is out of scope", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Eve", "Priest", { item(101, { source = "B" }) }),
            }, { allowed = { Aly = true } })
            assert.are.same({ bosses = {} }, result)
        end)
    end)

    describe("item name + quality resolution", function()
        it("prefers the wish's own itemName", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", { item(101, { source = "B", itemName = "Fresh Name" }) }),
            }, {
                loot = { { itemID = 101, itemName = "Stale Loot Name", boss = "B" } },
                getItemInfo = function() return "Client Name", 4 end,
            })
            assert.are.equal("Fresh Name", result.bosses[1].items[1].name)
        end)

        it("falls back to the loot-history name, then getItemInfo, then a placeholder", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", {
                    item(101, { source = "B" }),
                    item(202, { source = "B" }),
                    item(303, { source = "B" }),
                }),
            }, {
                loot = { { itemID = 101, itemName = "Loot Name", boss = "B" } },
                getItemInfo = function(id)
                    if id == 202 then return "Client Name", 4 end
                end,
            })
            local byId = {}
            for _, it in ipairs(result.bosses[1].items) do byId[it.itemID] = it end
            assert.are.equal("Loot Name", byId[101].name)
            assert.are.equal("Client Name", byId[202].name)
            assert.are.equal("Item 303", byId[303].name)
        end)

        it("records the quality getItemInfo reports, nil when uncached", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", {
                    item(101, { source = "B", itemName = "Named" }),
                    item(202, { source = "B", itemName = "Unknown Quality" }),
                }),
            }, {
                getItemInfo = function(id)
                    if id == 101 then return "Named", 5 end
                end,
            })
            local byId = {}
            for _, it in ipairs(result.bosses[1].items) do byId[it.itemID] = it end
            assert.are.equal(5, byId[101].quality)
            assert.is_nil(byId[202].quality)
        end)

        it("tolerates a missing C_Item (no getItemInfo injected, no global)", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", { item(101, { source = "B" }) }),
            }, {})
            assert.are.equal("Item 101", result.bosses[1].items[1].name)
            assert.is_nil(result.bosses[1].items[1].quality)
        end)
    end)

    it("carries slot through and tallies per-boss item/wish counts", function()
        local result = WGS:BuildWishlistBossGroups({
            wish("Aly", "Mage",  { item(101, { source = "B", slot = "Head" }) }),
            wish("Bob", "Rogue", {
                item(101, { source = "B" }),
                item(202, { source = "B", slot = "Ring" }),
            }),
        }, {})
        local boss = result.bosses[1]
        assert.are.equal(2, boss.itemCount)
        assert.are.equal(3, boss.wishCount)
        local byId = {}
        for _, it in ipairs(boss.items) do byId[it.itemID] = it end
        assert.are.equal("Head", byId[101].slot)
        assert.are.equal("Ring", byId[202].slot)
    end)

    it("degrades a fully-legacy import (no class, no source) without erroring", function()
        local result = WGS:BuildWishlistBossGroups({
            { playerName = "Old", items = { { itemID = 101, priority = "BiS", note = "pls" } } },
        }, {})
        assert.are.equal(1, #result.bosses)
        assert.are.equal("Unassigned", result.bosses[1].name)
        local w = result.bosses[1].items[1].wishers[1]
        assert.are.equal("Old", w.short)
        assert.is_nil(w.class)
        assert.are.equal("pls", w.note)
    end)

    it("skips wishes without an itemID (free-text platform wishes are not exported rows)", function()
        local result = WGS:BuildWishlistBossGroups({
            wish("Aly", "Mage", {
                { priority = "BiS", source = "B" },          -- no itemID
                item(101, { source = "B" }),
            }),
        }, {})
        assert.are.equal(1, #result.bosses)
        assert.are.equal(1, result.bosses[1].itemCount)
        assert.are.equal(101, result.bosses[1].items[1].itemID)
    end)
end)
