local helpers = require("spec.helpers")

-- WGS:BuildWishlistGroups (UI/Teams/Wishlists.lua) turns the platform's
-- wishlist export into the grouped, sorted structure the Teams →
-- Wishlists browser renders — pivoted on whichever dimension the user
-- picked (Boss / Player / Location / Slot / Armor) and narrowed by one
-- free-text search. It replaced a hardcoded boss grouping plus four
-- filter dropdowns; grouping subsumes filtering for those dimensions,
-- and search reaches one they never did (wisher names).
--
-- Fallback paths, all still load-bearing because older imports lack the
-- newer per-item fields:
--   source   → majority vote over the item's wish sources (trimmed,
--              case-insensitive merge) → loot-history itemID→boss
--              derivation → "Unassigned" group, always sorted last
--   class    → entry.class → characterDetails → guild-roster lookup →
--              nil (renderer omits the icon)
--   location → per-item field (first non-blank wish wins); items
--              without one land in the "Unknown" group under the
--              Location pivot
--   armorType → per-item field, same first-non-blank rule; the four
--              known values (Cloth/Leather/Mail/Plate) normalise to
--              canonical casing, blanks degrade exactly like location
--
-- The leaf shape differs per pivot on purpose: item modes hang wishers
-- under the item, player mode folds that player's own wish onto the
-- item (the group header already names them). Pure with respect to its
-- inputs (no db reads), so these specs pin grouping, ordering, search
-- and every fallback without a rendering harness.

local function setup()
    local WGS = helpers.setup()
    helpers.loadUIShims()
    dofile("UI/Teams/Wishlists.lua")
    return WGS
end

-- Most specs below exercise the default (Boss) pivot, which the browser
-- opens on. `build` calls the real entry point and aliases groups→bosses
-- so those specs read in the vocabulary of what they're testing; the
-- pivot-specific describes call WGS:BuildWishlistGroups directly.
local function build(wishlists, opts)
    local result = GuildHall:BuildWishlistGroups(wishlists, opts)
    result.bosses = result.groups
    return result
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

describe("WGS:BuildWishlistGroups", function()
    local WGS

    before_each(function()
        WGS = setup()
    end)

    it("returns no groups for empty/nil wishlists", function()
        assert.are.same({}, build({}, {}).bosses)
        assert.are.same({}, build(nil, {}).bosses)
    end)

    it("groups items under their wish-supplied source", function()
        local result = build({
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
        local result = build({
            wish("Aly", "Mage",  { item(101, { source = "Queen Ansurek" }) }),
            wish("Bob", "Rogue", { item(202, { source = "  queen ANSUREK  " }) }),
        }, {})
        assert.are.equal(1, #result.bosses)
        assert.are.equal("Queen Ansurek", result.bosses[1].name)
        assert.are.equal(2, result.bosses[1].itemCount)
    end)

    it("resolves an item's boss by majority vote over its wish sources", function()
        local result = build({
            wish("Aly", "Mage",   { item(101, { source = "Ulgrax" }) }),
            wish("Bob", "Rogue",  { item(101, { source = "Ulgrax" }) }),
            wish("Cid", "Priest", { item(101, { source = "Sikran" }) }),
        }, {})
        assert.are.equal(1, #result.bosses)
        assert.are.equal("Ulgrax", result.bosses[1].name)
    end)

    it("breaks source-vote ties deterministically (lexicographically-smallest key)", function()
        local result = build({
            wish("Aly", "Mage",  { item(101, { source = "Sikran" }) }),
            wish("Bob", "Rogue", { item(101, { source = "Ulgrax" }) }),
        }, {})
        assert.are.equal(1, #result.bosses)
        assert.are.equal("Sikran", result.bosses[1].name)
    end)

    it("falls back to the loot-history itemID→boss derivation when wishes carry no source", function()
        local result = build({
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
        local result = build({
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
        local result = build({
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
        local result = build({
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
        local result = build({
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
            local result = build({
                wish("Aly", "Death Knight", { item(101, { source = "B" }) }),
            }, {})
            assert.are.equal("DEATHKNIGHT", result.bosses[1].items[1].wishers[1].class)
        end)

        it("falls back to characterDetails, then the guild roster lookup", function()
            local result = build({
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
            local result = build({
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
            local result = build({
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
            local result = build({
                wish("Eve", "Priest", { item(101, { source = "B" }) }),
            }, { allowed = { Aly = true } })
            assert.are.same({}, result.bosses)
            assert.are.equal(0, result.itemCount)
        end)
    end)

    describe("item name + quality resolution", function()
        it("prefers the wish's own itemName", function()
            local result = build({
                wish("Aly", "Mage", { item(101, { source = "B", itemName = "Fresh Name" }) }),
            }, {
                loot = { { itemID = 101, itemName = "Stale Loot Name", boss = "B" } },
                getItemInfo = function() return "Client Name", 4 end,
            })
            assert.are.equal("Fresh Name", result.bosses[1].items[1].name)
        end)

        it("falls back to the loot-history name, then getItemInfo, then a placeholder", function()
            local result = build({
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
            local result = build({
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
            local result = build({
                wish("Aly", "Mage", { item(101, { source = "B" }) }),
            }, {})
            assert.are.equal("Item 101", result.bosses[1].items[1].name)
            assert.is_nil(result.bosses[1].items[1].quality)
        end)
    end)

    it("carries slot through and tallies per-boss item/wish counts", function()
        local result = build({
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
        local result = build({
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
        local result = build({
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
        local result = build({
            wish("Aly", "Mage", {
                { priority = "BiS", source = "B" },          -- no itemID
                item(101, { source = "B" }),
            }),
        }, {})
        assert.are.equal(1, #result.bosses)
        assert.are.equal(1, result.bosses[1].itemCount)
        assert.are.equal(101, result.bosses[1].items[1].itemID)
    end)


    ------------------------------------------------------------------
    -- Per-item metadata (pivot-independent: every item carries every
    -- dimension so the row renderer can show the ones that AREN'T the
    -- current grouping)
    ------------------------------------------------------------------

    describe("per-item metadata", function()
        it("carries location through — first non-blank wish wins, trimmed + keyed", function()
            local result = build({
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

        it("carries armorType through, canonicalising the four known values", function()
            local result = build({
                wish("Aly", "Mage",   { item(101, { source = "B", armorType = "" }) }),
                wish("Bob", "Rogue",  { item(101, { source = "B", armorType = "  plate " }) }),
                wish("Cid", "Priest", { item(202, { source = "B" }) }),
            }, {})
            local byId = {}
            for _, it in ipairs(result.bosses[1].items) do byId[it.itemID] = it end
            assert.are.equal("Plate", byId[101].armorType, "canonical casing regardless of export")
            assert.are.equal("plate", byId[101].armorTypeKey)
            assert.is_nil(byId[202].armorType)
        end)

        it("canonicalises slot casing and stamps the boss name on every item", function()
            local result = build({
                wish("Aly", "Mage", { item(101, { source = "Ulgrax", slot = "head" }) }),
            }, {})
            local it = result.bosses[1].items[1]
            assert.are.equal("Head", it.slot)
            assert.are.equal("head", it.slotKey)
            assert.are.equal("Ulgrax", it.bossName,
                "bossName rides the item so non-boss pivots can show it as meta")
        end)
    end)

    ------------------------------------------------------------------
    -- The pivot. Grouping subsumes filtering for these dimensions, so
    -- each mode is exercised for bucketing, ordering and the catch-all
    -- bucket's placement.
    ------------------------------------------------------------------

    -- The dropdown feeds WGS.WISHLIST_GROUP_MODES straight into the
    -- shared menu factory, which renders `o.name`. Shipping `label`
    -- instead made every row concatenate nil and throw, so the menu
    -- silently refused to open — no error visible, just a dead button.
    describe("group-mode dropdown contract", function()
        -- Belt and braces: the contract above is what SHOULD hold, and
        -- the fallback below is what happens when it doesn't. A missing
        -- cosmetic field must never be able to throw a Lua error at a
        -- raider mid-raid; the spec keeps it from silently becoming the
        -- normal case.
        it("renders a nameless option instead of concatenating nil", function()
            local function menuLabel(o)
                return o.name or o.label or tostring(o.key or "?")
            end
            assert.are.equal("Boss", menuLabel({ key = "boss", name = "Boss" }))
            assert.are.equal("Boss", menuLabel({ key = "boss", label = "Boss" }))
            assert.are.equal("boss", menuLabel({ key = "boss" }))
            assert.are.equal("?", menuLabel({}))
            for _, bad in ipairs({ { key = "boss" }, {}, { label = "L" } }) do
                assert.has_no.errors(function() return "  " .. menuLabel(bad) end)
            end
        end)

        it("every mode carries the key + name the menu factory renders", function()
            local modes = WGS.WISHLIST_GROUP_MODES
            assert.is_table(modes)
            assert.is_true(#modes >= 5)
            for _, m in ipairs(modes) do
                assert.is_string(m.key, "mode needs a key")
                assert.is_string(m.name,
                    "mode needs `name` — the dropdown renders o.name, not o.label")
                assert.not_equal("", m.name)
                -- The concatenation that used to blow up.
                assert.has_no.errors(function() return "  " .. m.name end)
            end
        end)

        it("offers exactly the pivots the builder accepts, and every one resolves", function()
            local offered = {}
            for _, m in ipairs(WGS.WISHLIST_GROUP_MODES) do
                offered[#offered + 1] = m.key
                -- Round-trip: picking this option must not silently fall
                -- back to boss.
                local result = WGS:BuildWishlistGroups({}, { groupBy = m.key })
                assert.are.equal(m.key, result.groupBy,
                    m.key .. " is offered in the dropdown but not honoured by the builder")
            end
            table.sort(offered)
            assert.are.same(
                { "armor", "boss", "contentType", "location", "player", "slot" }, offered)
        end)
    end)

    describe("groupBy pivots", function()
        local DATA = {
            wish("Aly", "MAGE", {
                item(101, { source = "Ulgrax", slot = "Head",  location = "Nerub-ar", armorType = "Cloth", priority = "BiS" }),
                item(202, { source = "Sikran", slot = "Ring",  location = "Nerub-ar", priority = "Low" }),
            }),
            wish("Bob", "WARRIOR", {
                item(101, { source = "Ulgrax", slot = "Head",  location = "Nerub-ar", armorType = "Cloth", priority = "Medium" }),
                item(303, { source = "Ulgrax", slot = "Chest", location = "Undermine", armorType = "Plate", priority = "High" }),
            }),
        }

        local function groupNames(result)
            local names = {}
            for _, g in ipairs(result.groups) do names[#names + 1] = g.name end
            return names
        end

        it("defaults to boss and echoes the resolved pivot back", function()
            local result = WGS:BuildWishlistGroups(DATA, {})
            assert.are.equal("boss", result.groupBy)
            assert.are.same({ "Sikran", "Ulgrax" }, groupNames(result))
        end)

        it("falls back to boss for an unknown pivot rather than rendering nothing", function()
            local result = WGS:BuildWishlistGroups(DATA, { groupBy = "nonsense" })
            assert.are.equal("boss", result.groupBy)
        end)

        it("groups by player, folding that player's wish onto the item", function()
            local result = WGS:BuildWishlistGroups(DATA, { groupBy = "player" })
            assert.are.same({ "Aly", "Bob" }, groupNames(result))

            local aly = result.groups[1]
            assert.are.equal("MAGE", aly.class, "class rides the group for the header icon")
            assert.are.equal("Aly", aly.playerName)
            assert.are.equal(2, aly.itemCount)
            -- Priority-sorted (BiS before Low), and the wish is ON the item.
            assert.are.equal(101, aly.items[1].itemID)
            assert.are.equal("BiS", aly.items[1].priority)
            assert.are.equal("Low", aly.items[2].priority)
            assert.is_nil(aly.items[1].wishers,
                "no wisher sub-rows in player mode — the header already names them")

            -- The SAME item under a different player carries that
            -- player's own priority, not the first wisher's.
            local bob = result.groups[2]
            local bobOn101
            for _, it in ipairs(bob.items) do
                if it.itemID == 101 then bobOn101 = it end
            end
            assert.are.equal("Medium", bobOn101.priority)
            assert.are.equal("High", bob.items[1].priority,
                "and Bob's own list is priority-sorted: High (303) before Medium (101)")
        end)

        it("groups by slot in character-sheet order, not alphabetically", function()
            local result = WGS:BuildWishlistGroups(DATA, { groupBy = "slot" })
            assert.are.same({ "Head", "Chest", "Ring" }, groupNames(result))
        end)

        it("groups by armor lightest-first, sinking the armour-less bucket", function()
            local result = WGS:BuildWishlistGroups(DATA, { groupBy = "armor" })
            assert.are.same({ "Cloth", "Plate", "Unknown" }, groupNames(result))
            -- The ring carries no armor type — non-armor is honest data.
            assert.are.equal(202, result.groups[3].items[1].itemID)
        end)

        it("groups by content type — Raid and Dungeon are one axis, instance another", function()
            local result = WGS:BuildWishlistGroups({
                wish("Aly", "MAGE", {
                    item(101, { contentType = "Raid",    location = "Manaforge Omega" }),
                    item(202, { contentType = "Dungeon", location = "Ara-Kara" }),
                    item(303, { contentType = "Dungeon", location = "City of Threads" }),
                }),
            }, { groupBy = "contentType" })
            assert.are.same({ "Dungeon", "Raid" }, groupNames(result))
            assert.are.equal(2, result.groups[1].itemCount, "both dungeons collapse together")
        end)

        it("sinks items with no content type into Unknown", function()
            local result = WGS:BuildWishlistGroups({
                wish("Aly", "MAGE", {
                    item(101, { contentType = "Raid" }),
                    item(202, {}),
                }),
            }, { groupBy = "contentType" })
            assert.are.same({ "Raid", "Unknown" }, groupNames(result))
        end)

        it("groups by location alphabetically", function()
            local result = WGS:BuildWishlistGroups(DATA, { groupBy = "location" })
            assert.are.same({ "Nerub-ar", "Undermine" }, groupNames(result))
        end)

        it("sinks Unassigned/Unknown last whatever the pivot", function()
            local result = WGS:BuildWishlistGroups({
                wish("Aly", "MAGE", {
                    item(101, { source = "Zzar the Last", location = "Zone" }),
                    item(202, {}),   -- no boss, no location
                }),
            }, { groupBy = "location" })
            assert.are.same({ "Zone", "Unknown" }, groupNames(result))

            local byBoss = WGS:BuildWishlistGroups({
                wish("Aly", "MAGE", {
                    item(101, { source = "Zzar the Last" }),
                    item(202, {}),
                }),
            }, { groupBy = "boss" })
            assert.are.same({ "Zzar the Last", "Unassigned" }, groupNames(byBoss))
        end)

        it("counts per group: wishes in item modes, one-per-row in player mode", function()
            local byBoss = WGS:BuildWishlistGroups(DATA, { groupBy = "boss" })
            local ulgrax = byBoss.groups[2]
            assert.are.equal("Ulgrax", ulgrax.name)
            assert.are.equal(2, ulgrax.itemCount, "items 101 + 303")
            assert.are.equal(3, ulgrax.wishCount, "101 wished twice, 303 once")

            local byPlayer = WGS:BuildWishlistGroups(DATA, { groupBy = "player" })
            assert.are.equal(2, byPlayer.groups[1].wishCount,
                "player mode: one wish per listed item")
        end)

        it("reports totals across every group", function()
            local result = WGS:BuildWishlistGroups(DATA, { groupBy = "boss" })
            assert.are.equal(3, result.itemCount, "101, 202, 303")
            assert.are.equal(4, result.wishCount)
        end)

        it("returns no groups for empty/nil input", function()
            assert.are.same({}, WGS:BuildWishlistGroups({}, {}).groups)
            assert.are.same({}, WGS:BuildWishlistGroups(nil, {}).groups)
        end)
    end)

    ------------------------------------------------------------------
    -- Search. One box replaces the old four filter dropdowns, so it has
    -- to reach every dimension — including the wisher names, which no
    -- dropdown ever covered.
    ------------------------------------------------------------------

    describe("search", function()
        local DATA = {
            wish("Aly", "MAGE", {
                item(101, { source = "Ulgrax", slot = "Head", location = "Nerub-ar", armorType = "Cloth", itemName = "Crown of Whispers" }),
            }),
            wish("Bob", "WARRIOR", {
                item(303, { source = "Sikran", slot = "Chest", location = "Undermine", armorType = "Plate", itemName = "Breastplate of Dawn" }),
            }),
        }
        local function only(result)
            local ids = {}
            for _, g in ipairs(result.groups) do
                for _, it in ipairs(g.items) do ids[#ids + 1] = it.itemID end
            end
            table.sort(ids)
            return ids
        end

        it("matches item name, case-insensitively and mid-word", function()
            assert.are.same({ 101 }, only(WGS:BuildWishlistGroups(DATA, { search = "whisp" })))
        end)

        it("matches boss, location, slot and armor", function()
            assert.are.same({ 303 }, only(WGS:BuildWishlistGroups(DATA, { search = "sikran" })))
            assert.are.same({ 101 }, only(WGS:BuildWishlistGroups(DATA, { search = "nerub" })))
            assert.are.same({ 303 }, only(WGS:BuildWishlistGroups(DATA, { search = "chest" })))
            assert.are.same({ 101 }, only(WGS:BuildWishlistGroups(DATA, { search = "cloth" })))
        end)

        it("matches a wisher's name — the reach no dropdown had", function()
            assert.are.same({ 101 }, only(WGS:BuildWishlistGroups(DATA, { search = "aly" })))
        end)

        it("composes with the pivot and keeps counts honest", function()
            local result = WGS:BuildWishlistGroups(DATA, { groupBy = "location", search = "plate" })
            assert.are.equal(1, #result.groups)
            assert.are.equal("Undermine", result.groups[1].name)
            assert.are.equal(1, result.groups[1].itemCount)
            assert.are.equal(1, result.itemCount)
        end)

        it("treats blank/whitespace search as no search", function()
            assert.are.equal(2, WGS:BuildWishlistGroups(DATA, { search = "   " }).itemCount)
            assert.are.equal(2, WGS:BuildWishlistGroups(DATA, { search = "" }).itemCount)
        end)

        it("returns zero groups when nothing matches (rather than everything)", function()
            local result = WGS:BuildWishlistGroups(DATA, { search = "zzzz" })
            assert.are.same({}, result.groups)
            assert.are.equal(0, result.itemCount)
        end)

        it("is applied before grouping, so a plain-text search can't resurrect a filtered item", function()
            local result = WGS:BuildWishlistGroups(DATA, { groupBy = "player", search = "whisp" })
            assert.are.equal(1, #result.groups)
            assert.are.equal("Aly", result.groups[1].name)
        end)
    end)
end)
