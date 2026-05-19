local helpers = require("spec.helpers")

describe("Exported-data clear snapshot", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    local function loadSampleData()
        WGS.db.global.loot = {
            { item_id = 1, character = "A" },
            { item_id = 2, character = "B" },
        }
        WGS.db.global.attendance = { { startedAt = 1733000000 } }
        WGS.db.global.encounters = { "First Boss" }
        WGS.db.global.raidCompResults = { foo = "bar" }
        WGS.db.global.guildBankMoneyChanges = { 1, 2 }
        WGS.db.global.guildBankTransactions = { { kind = "deposit" } }
    end

    it("snapshots all journal tables before clearing", function()
        loadSampleData()
        WGS:SnapshotExportedData()
        local snap = WGS.db.global.lastClearSnapshot
        assert.is_not_nil(snap.t)
        assert.are.equal(2, #snap.loot)
        assert.are.equal(1, #snap.attendance)
        assert.are.equal(1, #snap.encounters)
        assert.is_table(snap.raidCompResults)
        assert.are.equal(2, #snap.guildBankMoneyChanges)
        assert.are.equal(1, #snap.guildBankTransactions)
    end)

    it("restores from the snapshot when invoked within TTL", function()
        loadSampleData()
        WGS:SnapshotExportedData()
        -- Simulate the post-clear state
        WGS.db.global.loot = {}
        WGS.db.global.attendance = {}
        WGS.db.global.encounters = {}
        WGS.db.global.raidCompResults = {}
        WGS.db.global.guildBankMoneyChanges = {}
        WGS.db.global.guildBankTransactions = {}

        local ok = WGS:RestoreClearedData()
        assert.is_true(ok)
        assert.are.equal(2, #WGS.db.global.loot)
        assert.are.equal(1, #WGS.db.global.attendance)
        assert.are.equal("First Boss", WGS.db.global.encounters[1])
    end)

    it("refuses to restore when the snapshot is older than 24h", function()
        loadSampleData()
        WGS:SnapshotExportedData()
        -- Backdate the snapshot 25h
        WGS.db.global.lastClearSnapshot.t = WGS:GetTimestamp() - (25 * 60 * 60)
        WGS.db.global.loot = {}

        local ok = WGS:RestoreClearedData()
        assert.is_false(ok)
        assert.are.equal(0, #WGS.db.global.loot)
    end)

    it("HasRestorableSnapshot reflects TTL", function()
        assert.is_false(WGS:HasRestorableSnapshot())
        loadSampleData()
        WGS:SnapshotExportedData()
        assert.is_true(WGS:HasRestorableSnapshot())
        WGS.db.global.lastClearSnapshot.t = WGS:GetTimestamp() - (25 * 60 * 60)
        assert.is_false(WGS:HasRestorableSnapshot())
    end)

    it("returns false when no snapshot has ever been taken", function()
        local ok = WGS:RestoreClearedData()
        assert.is_false(ok)
    end)
end)
