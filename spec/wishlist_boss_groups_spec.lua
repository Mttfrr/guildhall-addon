local helpers = require("spec.helpers")

-- WGS:BuildWishlistBossGroups (UI/Teams/Wishlists.lua) turns the
-- platform's wishlist export into the boss-grouped, priority-sorted
-- structure the Teams → Wishlists browser renders. The platform export
-- now carries a per-player `class` and a per-item `source` (the wish's
-- boss); older imports lack both, so every fallback path matters:
--
--   source   → majority vote over the item's wish sources (trimmed,
--              case-insensitive merge) → loot-history itemID→boss
--              derivation → "Unassigned" bucket
--   class    → entry.class → characterDetails → guild-roster lookup →
--              nil (renderer omits the icon)
--   location → per-item field (first non-blank wish wins); items
--              without one fall into the filter's "Unknown" bucket,
--              which exists only when imports are mixed
--   armorType → per-item field, same first-non-blank rule; the four
--              known values (Cloth/Leather/Mail/Plate) normalise to
--              canonical casing, blanks degrade exactly like location
--
-- The builder also derives the Location/Slot/Armor filter dropdowns'
-- option lists (distinct values present in the team-filtered data),
-- and its sibling WGS:FilterWishlistBossGroups applies the Boss +
-- Location + Slot + Armor selections (AND) as a pure view over the
-- built structure — recomputed counts, emptied groups dropped.
--
-- Both functions are pure with respect to their inputs (no db reads),
-- so these specs pin the grouping + filtering without a rendering
-- harness.

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

    it("returns empty boss/location/slot/armor lists for empty/nil wishlists", function()
        local empty = { bosses = {}, locations = {}, slots = {}, armorTypes = {} }
        assert.are.same(empty, WGS:BuildWishlistBossGroups({}, {}))
        assert.are.same(empty, WGS:BuildWishlistBossGroups(nil, {}))
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
            assert.are.same(
                { bosses = {}, locations = {}, slots = {}, armorTypes = {} },
                result)
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
        assert.is_nil(w.simPct, "no sim data on legacy imports — renders nothing")
    end)

    it("carries each wisher's Droptimizer gain through as a number", function()
        local result = WGS:BuildWishlistBossGroups({
            { playerName = "Simmed", items = {
                { itemID = 101, priority = "BiS", source = "B", simPct = 2.5 } } },
            { playerName = "Stringy", items = {
                { itemID = 101, priority = "High", source = "B", simPct = "1.2" } } },
        }, {})
        local wishers = result.bosses[1].items[1].wishers
        assert.are.equal(2.5, wishers[1].simPct)
        assert.are.equal(1.2, wishers[2].simPct,
            "tolerates a stringly-typed simPct from a hand-rolled export")
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

    describe("location metadata + filter option list", function()
        it("carries per-item location through — first non-blank wish wins, trimmed + keyed", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage",   { item(101, { source = "B" }) }),  -- blank first: doesn't lock in nil
                wish("Bob", "Rogue",  { item(101, { source = "B", location = "  The Voidspire " }) }),
                wish("Cid", "Priest", { item(202, { source = "B" }) }),
            }, {})
            local byId = {}
            for _, it in ipairs(result.bosses[1].items) do byId[it.itemID] = it end
            assert.are.equal("The Voidspire", byId[101].location)
            assert.are.equal("the voidspire", byId[101].locationKey)
            assert.is_nil(byId[202].location)
            assert.is_nil(byId[202].locationKey)
        end)

        it("derives the distinct location list, sorted, merged case-insensitively (first-seen casing)", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", {
                    item(101, { source = "A", location = "The Voidspire" }),
                    item(202, { source = "B", location = "Manaforge Omega" }),
                }),
                wish("Bob", "Rogue", { item(303, { source = "C", location = "the VOIDSPIRE" }) }),
            }, {})
            local names = {}
            for _, l in ipairs(result.locations) do names[#names + 1] = l.name end
            assert.are.same({ "Manaforge Omega", "The Voidspire" }, names)
        end)

        it("adds an Unknown bucket, last, only when locations are mixed", function()
            local mixed = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", {
                    item(101, { source = "B", location = "The Voidspire" }),
                    item(202, { source = "B" }),                    -- no location
                }),
            }, {})
            local names = {}
            for _, l in ipairs(mixed.locations) do names[#names + 1] = l.name end
            assert.are.same({ "The Voidspire", "Unknown" }, names)

            local complete = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", { item(101, { source = "B", location = "The Voidspire" }) }),
            }, {})
            assert.are.same({ "The Voidspire" }, { complete.locations[1].name })
            assert.are.equal(1, #complete.locations)
        end)

        it("returns no location options at all for a pre-location export (legacy back-compat)", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", { item(101, { source = "B" }) }),
                wish("Bob", "Rogue", { item(202, { source = "B" }) }),
            }, {})
            -- A lone "Unknown" option would make the dropdown a no-op
            -- filter; the list stays empty so the UI offers only "All".
            assert.are.same({}, result.locations)
        end)
    end)

    describe("slot filter option list", function()
        it("orders present slots canonically (character-sheet order), not alphabetically", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", {
                    item(101, { source = "B", slot = "Trinket" }),
                    item(202, { source = "B", slot = "Back" }),
                    item(303, { source = "B", slot = "Head" }),
                }),
            }, {})
            local names = {}
            for _, s in ipairs(result.slots) do names[#names + 1] = s.name end
            assert.are.same({ "Head", "Back", "Trinket" }, names)
        end)

        it("normalises recognised slots to canonical casing, merging case-insensitively", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage",  { item(101, { source = "B", slot = "head" }) }),
                wish("Bob", "Rogue", { item(202, { source = "B", slot = "HEAD" }) }),
            }, {})
            assert.are.equal(1, #result.slots)
            assert.are.equal("Head", result.slots[1].name)
        end)

        it("keeps unrecognised slot values, after the canonical list, alphabetically", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", {
                    item(101, { source = "B", slot = "Two Hand" }),   -- not in the vocabulary
                    item(202, { source = "B", slot = "Other" }),      -- canonical, last
                    item(303, { source = "B", slot = "Head" }),
                    item(404, { source = "B", slot = "Cloak" }),      -- not in the vocabulary
                }),
            }, {})
            local names = {}
            for _, s in ipairs(result.slots) do names[#names + 1] = s.name end
            assert.are.same({ "Head", "Other", "Cloak", "Two Hand" }, names)
        end)

        it("buckets slotless items as Unknown, last, only when slots are mixed", function()
            local mixed = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", {
                    item(101, { source = "B", slot = "Ring" }),
                    item(202, { source = "B" }),                     -- no slot
                }),
            }, {})
            local names = {}
            for _, s in ipairs(mixed.slots) do names[#names + 1] = s.name end
            assert.are.same({ "Ring", "Unknown" }, names)

            local none = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", { item(101, { source = "B" }) }),
            }, {})
            assert.are.same({}, none.slots)
        end)

        it("derives the option lists fresh from each build (the stale-selection reset inputs)", function()
            -- The UI resets a selected location/slot the moment a
            -- re-import/team switch produces a list without it — same
            -- contract as the boss filter. Pin the input side: a value
            -- present in one build is absent from the next.
            local first = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", { item(101, { source = "B", slot = "Head", location = "The Voidspire", armorType = "Plate" }) }),
            }, {})
            assert.are.equal("the voidspire", first.locations[1].key)
            assert.are.equal("head", first.slots[1].key)
            assert.are.equal("plate", first.armorTypes[1].key)

            local second = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", { item(101, { source = "B", slot = "Ring", location = "Manaforge Omega", armorType = "Cloth" }) }),
            }, {})
            for _, l in ipairs(second.locations) do
                assert.are_not.equal("the voidspire", l.key)
            end
            for _, s in ipairs(second.slots) do
                assert.are_not.equal("head", s.key)
            end
            for _, a in ipairs(second.armorTypes) do
                assert.are_not.equal("plate", a.key)
            end
        end)
    end)

    describe("armor type metadata + filter option list", function()
        it("carries per-item armorType through — first non-blank wish wins, trimmed + keyed", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage",   { item(101, { source = "B", armorType = "" }) }),  -- blank first: doesn't lock in nil
                wish("Bob", "Rogue",  { item(101, { source = "B", armorType = "  Plate " }) }),
                wish("Cid", "Priest", { item(202, { source = "B" }) }),
            }, {})
            local byId = {}
            for _, it in ipairs(result.bosses[1].items) do byId[it.itemID] = it end
            assert.are.equal("Plate", byId[101].armorType)
            assert.are.equal("plate", byId[101].armorTypeKey)
            assert.is_nil(byId[202].armorType)
            assert.is_nil(byId[202].armorTypeKey)
        end)

        it("normalises the four known values to canonical casing, merging case-insensitively", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage",  { item(101, { source = "B", armorType = "cloth" }) }),
                wish("Bob", "Rogue", { item(202, { source = "B", armorType = "CLOTH" }) }),
            }, {})
            assert.are.equal(1, #result.armorTypes)
            assert.are.equal("Cloth", result.armorTypes[1].name)
            local byId = {}
            for _, it in ipairs(result.bosses[1].items) do byId[it.itemID] = it end
            assert.are.equal("Cloth", byId[101].armorType)
            assert.are.equal("Cloth", byId[202].armorType)
        end)

        it("orders present armor types Cloth → Leather → Mail → Plate, not alphabetically or by appearance", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", {
                    item(101, { source = "B", armorType = "Plate" }),
                    item(202, { source = "B", armorType = "Cloth" }),
                    item(303, { source = "B", armorType = "Mail" }),
                }),
            }, {})
            local names = {}
            for _, a in ipairs(result.armorTypes) do names[#names + 1] = a.name end
            -- Leather absent: only the types present are listed.
            assert.are.same({ "Cloth", "Mail", "Plate" }, names)
        end)

        it("keeps unrecognised armor values, after the canonical list, in first-seen casing", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", {
                    item(101, { source = "B", armorType = "Shield" }),   -- not in the vocabulary
                    item(202, { source = "B", armorType = "Plate" }),
                    item(303, { source = "B", armorType = "Cosmic" }),   -- not in the vocabulary
                }),
            }, {})
            local names = {}
            for _, a in ipairs(result.armorTypes) do names[#names + 1] = a.name end
            assert.are.same({ "Plate", "Cosmic", "Shield" }, names)
        end)

        it("buckets armor-less items as Unknown, last, only when armor types are mixed", function()
            local mixed = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", {
                    item(101, { source = "B", armorType = "Leather" }),
                    item(202, { source = "B", armorType = "" }),         -- non-armor: blank
                }),
            }, {})
            local names = {}
            for _, a in ipairs(mixed.armorTypes) do names[#names + 1] = a.name end
            assert.are.same({ "Leather", "Unknown" }, names)
        end)

        it("returns no armor options at all for a pre-armorType export (legacy back-compat)", function()
            local result = WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", { item(101, { source = "B" }) }),
                wish("Bob", "Rogue", { item(202, { source = "B" }) }),
            }, {})
            -- A lone "Unknown" option would make the dropdown a no-op
            -- filter; the list stays empty so the UI offers only "All".
            assert.are.same({}, result.armorTypes)
        end)
    end)

    describe("WGS:FilterWishlistBossGroups (combined filtering)", function()
        -- One dataset exercised by every case: two bosses, mixed
        -- locations, slots and armor types (the jewelry carries none,
        -- like the platform's "" for non-armor), one fully-legacy item.
        local function build()
            return WGS:BuildWishlistBossGroups({
                wish("Aly", "Mage", {
                    item(101, { source = "Ulgrax", slot = "Head", location = "The Voidspire", armorType = "Plate" }),
                    item(202, { source = "Ulgrax", slot = "Ring", location = "Manaforge Omega" }),
                    item(303, { source = "Sikran", slot = "Ring", location = "The Voidspire", armorType = "Plate" }),
                }),
                wish("Bob", "Rogue", {
                    item(101, { source = "Ulgrax", slot = "Head", location = "The Voidspire", armorType = "Plate" }),
                    item(404, { source = "Sikran" }),   -- legacy: no slot, no location, no armor
                }),
            }, {})
        end

        local function itemIds(view)
            local ids = {}
            for _, g in ipairs(view.bosses) do
                for _, it in ipairs(g.items) do ids[#ids + 1] = it.itemID end
            end
            table.sort(ids)
            return ids
        end

        it("passes the structure through untouched when no filter is set", function()
            local result = build()
            local view = WGS:FilterWishlistBossGroups(result, {})
            assert.are.equal(result.bosses, view.bosses)
            local noFilters = WGS:FilterWishlistBossGroups(result)
            assert.are.equal(result.bosses, noFilters.bosses)
        end)

        it("filters by boss group key", function()
            local view = WGS:FilterWishlistBossGroups(build(), { boss = "sikran" })
            assert.are.equal(1, #view.bosses)
            assert.are.equal("Sikran", view.bosses[1].name)
            assert.are.same({ 303, 404 }, itemIds(view))
        end)

        it("filters by location across every boss, dropping emptied groups", function()
            local view = WGS:FilterWishlistBossGroups(build(), { location = "manaforge omega" })
            assert.are.equal(1, #view.bosses)
            assert.are.equal("Ulgrax", view.bosses[1].name)
            assert.are.same({ 202 }, itemIds(view))
        end)

        it("filters by slot across every boss", function()
            local view = WGS:FilterWishlistBossGroups(build(), { slot = "ring" })
            assert.are.same({ 202, 303 }, itemIds(view))
            assert.are.equal(2, #view.bosses)
        end)

        it("filters by armor type across every boss", function()
            local view = WGS:FilterWishlistBossGroups(build(), { armor = "plate" })
            assert.are.same({ 101, 303 }, itemIds(view))
            assert.are.equal(2, #view.bosses)
        end)

        it("combines boss + location + slot + armor (AND)", function()
            local view = WGS:FilterWishlistBossGroups(build(), {
                boss = "ulgrax", location = "the voidspire",
                slot = "head", armor = "plate",
            })
            assert.are.same({ 101 }, itemIds(view))
        end)

        it("recomputes the surviving groups' item/wish counts", function()
            local view = WGS:FilterWishlistBossGroups(build(), { slot = "head" })
            -- Ulgrax keeps only item 101 (2 wishers) of its 2 items / 3 wishes.
            assert.are.equal(1, #view.bosses)
            assert.are.equal(1, view.bosses[1].itemCount)
            assert.are.equal(2, view.bosses[1].wishCount)
        end)

        it("matches items with no location/slot/armor via the Unknown bucket", function()
            local byLoc = WGS:FilterWishlistBossGroups(build(), { location = "__unknown" })
            assert.are.same({ 404 }, itemIds(byLoc))
            local bySlot = WGS:FilterWishlistBossGroups(build(), { slot = "__unknown" })
            assert.are.same({ 404 }, itemIds(bySlot))
            -- Both armor-less items match — the jewelry AND the legacy row.
            local byArmor = WGS:FilterWishlistBossGroups(build(), { armor = "__unknown" })
            assert.are.same({ 202, 404 }, itemIds(byArmor))
        end)

        it("returns an empty boss list when the combination matches nothing", function()
            local view = WGS:FilterWishlistBossGroups(build(), {
                boss = "sikran", slot = "head",
            })
            assert.are.same({ bosses = {} }, view)
            -- Armor participates in the dead-end too: the only Head
            -- item is Plate, so Head + armor-Unknown is a contradiction.
            local viaArmor = WGS:FilterWishlistBossGroups(build(), {
                slot = "head", armor = "__unknown",
            })
            assert.are.same({ bosses = {} }, viaArmor)
        end)

        it("never mutates the built structure (counts + items survive filtering)", function()
            local result = build()
            WGS:FilterWishlistBossGroups(result, { slot = "head", location = "the voidspire" })
            local ulgrax
            for _, g in ipairs(result.bosses) do
                if g.name == "Ulgrax" then ulgrax = g end
            end
            assert.are.equal(2, ulgrax.itemCount)
            assert.are.equal(3, ulgrax.wishCount)
            assert.are.equal(2, #ulgrax.items)
        end)

        it("filters a legacy no-location/no-slot/no-armor import only by boss (the rest are no-ops)", function()
            local legacy = WGS:BuildWishlistBossGroups({
                wish("Old", nil, { { itemID = 101, priority = "BiS", source = "B" } }),
            }, {})
            local view = WGS:FilterWishlistBossGroups(legacy, { boss = "b" })
            assert.are.same({ 101 }, itemIds(view))
        end)
    end)
end)
