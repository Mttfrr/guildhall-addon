local helpers = require("spec.helpers")

-- WGS:ReconcileLootFromMRT (Modules/Loot.lua) reads VMRT.LootHistory.list
-- 5s after ENCOUNTER_END and gap-fills any drops we missed via
-- CHAT_MSG_LOOT (happens in laggy raids — parser eats malformed
-- localized messages, addon was reloading at the moment of drop, etc.).
--
-- Tests cover:
--   * MRT unloaded → no-op, returns 0
--   * Malformed VMRT.LootHistory.list → no-op
--   * Gap-fill path (item missing from our list)
--   * Dedup path (item present → second call no-op)
--   * Encounter-ID filter (other-boss drops skipped)
--   * Time-window filter (stale rows skipped)
--   * Parse defense (bad pipe-delimited rows skipped, not crashed)
--   * Player-name realm normalisation

describe("WGS:ReconcileLootFromMRT", function()
    local WGS

    local origCAddOns, origVMRT, origGetInstanceInfo, origGetNormalizedRealmName
    local fixedNow

    local function pretendMRTLoaded(loaded)
        _G.C_AddOns = { IsAddOnLoaded = function(n) return n == "MRT" and loaded end }
        WGS:_ResetAddonCache()
    end

    local function mrtRow(t)
        return string.format("%d#%d#%d#%d#%s#%d#%d#%s",
            t.timestamp or fixedNow,
            t.encounterID or 0,
            t.instanceID or 0,
            t.difficulty or 16,
            t.player or "Foo",
            t.classID or 1,
            t.quantity or 1,
            t.itemLink or "|cffa335ee|Hitem:12345|h[Item]|h|r")
    end

    before_each(function()
        WGS = helpers.setup()
        dofile("Modules/Loot.lua")
        origCAddOns                 = _G.C_AddOns
        origVMRT                    = _G.VMRT
        origGetInstanceInfo         = _G.GetInstanceInfo
        origGetNormalizedRealmName  = _G.GetNormalizedRealmName

        _G.GetInstanceInfo        = function() return "TestRaid", nil, 16 end
        _G.GetNormalizedRealmName = function() return "TestRealm" end

        fixedNow = os.time()
        function WGS:GetTimestamp() return fixedNow end
        function WGS:GetPlayerKey() return "Recorder-TestRealm" end

        _G.VMRT = nil
        WGS.db.global.loot = {}
    end)

    after_each(function()
        _G.C_AddOns                  = origCAddOns
        _G.VMRT                      = origVMRT
        _G.GetInstanceInfo           = origGetInstanceInfo
        _G.GetNormalizedRealmName    = origGetNormalizedRealmName
    end)

    it("returns 0 and no-ops when MRT is not loaded", function()
        pretendMRTLoaded(false)
        _G.VMRT = { LootHistory = { list = { mrtRow{ encounterID = 100 } } } }
        local added = WGS:ReconcileLootFromMRT(100)
        assert.are.equal(0, added)
        assert.are.equal(0, #WGS.db.global.loot)
    end)

    it("returns 0 when MRT is loaded but the list is empty / missing", function()
        pretendMRTLoaded(true)
        _G.VMRT = { LootHistory = { list = {} } }
        assert.are.equal(0, WGS:ReconcileLootFromMRT(100))
        _G.VMRT = {}
        assert.are.equal(0, WGS:ReconcileLootFromMRT(100))
    end)

    it("gap-fills an MRT row we don't already have, tagged source='mrt'", function()
        pretendMRTLoaded(true)
        _G.VMRT = { LootHistory = { list = {
            mrtRow{ encounterID = 100, player = "Looter",
                    itemLink = "|cffa335ee|Hitem:212425|h[Sword]|h|r" },
        } } }
        local added = WGS:ReconcileLootFromMRT(100)
        assert.are.equal(1, added)
        local row = WGS.db.global.loot[1]
        assert.are.equal(212425,             row.itemID)
        assert.are.equal("Looter-TestRealm", row.player)
        assert.are.equal("mrt",              row.source)
    end)

    it("dedupes against rows we already captured via CHAT_MSG_LOOT", function()
        pretendMRTLoaded(true)
        -- Pre-existing row from our own capture
        table.insert(WGS.db.global.loot, {
            timestamp = fixedNow - 10,
            player    = "Looter-TestRealm",
            itemID    = 212425,
            itemLink  = "|cffa335ee|Hitem:212425|h[Sword]|h|r",
        })
        -- MRT recorded the same drop ~5s later
        _G.VMRT = { LootHistory = { list = {
            mrtRow{ encounterID = 100, player = "Looter", timestamp = fixedNow - 5,
                    itemLink = "|cffa335ee|Hitem:212425|h[Sword]|h|r" },
        } } }
        local added = WGS:ReconcileLootFromMRT(100)
        assert.are.equal(0, added)
        assert.are.equal(1, #WGS.db.global.loot, "should not double-insert")
    end)

    it("is idempotent: a second reconcile is a no-op", function()
        pretendMRTLoaded(true)
        _G.VMRT = { LootHistory = { list = {
            mrtRow{ encounterID = 100, player = "Looter",
                    itemLink = "|cffa335ee|Hitem:212425|h[Sword]|h|r" },
        } } }
        assert.are.equal(1, WGS:ReconcileLootFromMRT(100))
        assert.are.equal(0, WGS:ReconcileLootFromMRT(100))
        assert.are.equal(1, #WGS.db.global.loot)
    end)

    it("skips MRT rows whose encounterID doesn't match the one we just ended", function()
        pretendMRTLoaded(true)
        _G.VMRT = { LootHistory = { list = {
            mrtRow{ encounterID = 100, itemLink = "|cffa335ee|Hitem:100|h[A]|h|r" },
            mrtRow{ encounterID = 200, itemLink = "|cffa335ee|Hitem:200|h[B]|h|r" },
            mrtRow{ encounterID = 100, itemLink = "|cffa335ee|Hitem:300|h[C]|h|r" },
        } } }
        local added = WGS:ReconcileLootFromMRT(100)
        assert.are.equal(2, added)
        for _, row in ipairs(WGS.db.global.loot) do
            assert.is_not.equal(200, row.itemID, "the off-boss row should not land")
        end
    end)

    it("skips MRT rows older than the 5-minute trust window", function()
        pretendMRTLoaded(true)
        _G.VMRT = { LootHistory = { list = {
            mrtRow{ encounterID = 100, timestamp = fixedNow - 60,    -- inside
                    itemLink = "|cffa335ee|Hitem:1|h[Fresh]|h|r" },
            mrtRow{ encounterID = 100, timestamp = fixedNow - 600,   -- outside
                    itemLink = "|cffa335ee|Hitem:2|h[Stale]|h|r" },
        } } }
        local added = WGS:ReconcileLootFromMRT(100)
        assert.are.equal(1, added)
        assert.are.equal(1, WGS.db.global.loot[1].itemID)
    end)

    it("skips malformed pipe-delimited rows without crashing", function()
        pretendMRTLoaded(true)
        _G.VMRT = { LootHistory = { list = {
            "garbage-no-hashes",
            "1#2#3",                            -- not enough segments
            42,                                 -- not even a string
            mrtRow{ encounterID = 100, itemLink = "|cffa335ee|Hitem:7|h[OK]|h|r" },
        } } }
        local added = WGS:ReconcileLootFromMRT(100)
        assert.are.equal(1, added)
        assert.are.equal(7, WGS.db.global.loot[1].itemID)
    end)

    it("normalises bare player names with the local realm suffix", function()
        pretendMRTLoaded(true)
        _G.VMRT = { LootHistory = { list = {
            mrtRow{ encounterID = 100, player = "ShortName",
                    itemLink = "|cffa335ee|Hitem:55|h[X]|h|r" },
            mrtRow{ encounterID = 100, player = "CrossRealmer-OtherRealm",
                    itemLink = "|cffa335ee|Hitem:66|h[Y]|h|r" },
        } } }
        WGS:ReconcileLootFromMRT(100)
        assert.are.equal("ShortName-TestRealm",         WGS.db.global.loot[1].player)
        assert.are.equal("CrossRealmer-OtherRealm",     WGS.db.global.loot[2].player)
    end)
end)
