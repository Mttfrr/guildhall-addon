local helpers = require("spec.helpers")

-- Modules/PeerSync.lua — orchestration around the pure transport in
-- Sync/PeerMessage.lua. Tests cover the trust gate, channel selection,
-- broadcast throttle, and dispatch to per-table merge fns.

local function setup()
    local WGS = helpers.setup()
    helpers.loadLibDeflate()
    WGS:_ResetCompressionCache()
    WGS:_PeerMessageResetBuffer()
    WGS:_PeerSyncResetQueue()
    return WGS
end

-- Helper: install a fake guild roster so isOfficerSender can resolve
-- sender ranks. ranks = { ["Name-Realm"] = rankIndex, ... }
local function fakeGuild(ranks)
    _G.IsInGuild = function() return true end
    local list = {}
    for name, rank in pairs(ranks) do
        list[#list + 1] = { name = name, rank = rank }
    end
    _G.GetNumGuildMembers = function() return #list end
    _G.GetGuildRosterInfo = function(i)
        local row = list[i]
        if not row then return nil end
        return row.name, "Officer", row.rank
    end
end

-- Helper: install a fake C_ChatInfo that records every send. Returns
-- the list so tests can assert on it.
local function fakeChat()
    local sent = {}
    _G.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() end,
        SendAddonMessage = function(prefix, msg, channel)
            sent[#sent + 1] = { prefix = prefix, msg = msg, channel = channel }
        end,
    }
    return sent
end

describe("WGS:PeerSync_PreferredChannel", function()
    local WGS
    before_each(function() WGS = setup() end)

    it("prefers RAID over PARTY over GUILD", function()
        _G.IsInRaid, _G.IsInGroup, _G.IsInGuild = function() return true end, function() return true end, function() return true end
        assert.are.equal("RAID", WGS:PeerSync_PreferredChannel())
    end)

    it("falls back to PARTY when not in a raid", function()
        _G.IsInRaid, _G.IsInGroup, _G.IsInGuild = function() return false end, function() return true end, function() return true end
        assert.are.equal("PARTY", WGS:PeerSync_PreferredChannel())
    end)

    it("falls back to GUILD when solo but guilded", function()
        _G.IsInRaid, _G.IsInGroup, _G.IsInGuild = function() return false end, function() return false end, function() return true end
        assert.are.equal("GUILD", WGS:PeerSync_PreferredChannel())
    end)

    it("returns nil when solo and not guilded", function()
        _G.IsInRaid, _G.IsInGroup, _G.IsInGuild = function() return false end, function() return false end, function() return false end
        assert.is_nil(WGS:PeerSync_PreferredChannel())
    end)
end)

describe("WGS:PeerSync_Broadcast", function()
    local WGS, sent
    before_each(function()
        WGS = setup()
        sent = fakeChat()
        -- Default: we ARE an officer, in a raid, and ready to send.
        fakeGuild({ ["Tester-TestRealm"] = 1 })
        _G.IsInRaid = function() return true end
        _G.IsInGroup = function() return true end
        _G.GetGuildInfo = function(unit)
            if unit == "player" then return "TestGuild", "Officer", 1 end
            return nil
        end
    end)

    it("encodes + sends a chunk when conditions are right", function()
        local ok, err = WGS:PeerSync_Broadcast("loot", { itemID = 42, player = "X-TestRealm" })
        assert.is_true(ok)
        assert.is_nil(err)
        assert.is_true(#sent >= 1)
        assert.are.equal("WGS", sent[1].prefix)
        assert.are.equal("RAID", sent[1].channel)
    end)

    it("refuses to send when the local player isn't an officer", function()
        _G.GetGuildInfo = function() return "TestGuild", "Member", 5 end
        local ok, err = WGS:PeerSync_Broadcast("loot", { itemID = 1 })
        assert.is_false(ok)
        assert.is_truthy(err)
        assert.are.equal(0, #sent)
    end)

    it("refuses to send when there's no channel", function()
        _G.IsInRaid, _G.IsInGroup, _G.IsInGuild = function() return false end, function() return false end, function() return false end
        local ok, err = WGS:PeerSync_Broadcast("loot", { itemID = 1 })
        assert.is_false(ok)
        assert.is_truthy(err)
        assert.are.equal(0, #sent)
    end)

    it("rejects empty table names", function()
        local ok, err = WGS:PeerSync_Broadcast("", { itemID = 1 })
        assert.is_false(ok)
        assert.is_truthy(err)
        assert.are.equal(0, #sent)
    end)
end)

describe("WGS:PeerSync_HandleIncoming trust gate", function()
    local WGS
    before_each(function()
        WGS = setup()
        fakeChat()
        fakeGuild({
            ["Officer-TestRealm"] = 1,
            ["Member-TestRealm"]  = 5,
            ["Tester-TestRealm"]  = 0,  -- us, as GM
        })
        _G.IsInRaid = function() return true end
        _G.GetGuildInfo = function(unit)
            if unit == "player" then return "TestGuild", "GM", 0 end
            return nil
        end
    end)

    it("accepts an officer sender", function()
        local applied
        WGS:PeerSync_RegisterMerge("loot", function(row)
            applied = row
            return "added"
        end)

        local chunks = assert(WGS:EncodePeerMessage({ table = "loot", row = { itemID = 99 } }))
        for _, c in ipairs(chunks) do
            WGS:PeerSync_HandleIncoming("Officer-TestRealm", c, false)
        end

        assert.is_table(applied)
        assert.are.equal(99, applied.itemID)
    end)

    it("rejects a non-officer sender (no merge fn fires)", function()
        local applied = false
        WGS:PeerSync_RegisterMerge("loot", function() applied = true; return "added" end)

        local chunks = assert(WGS:EncodePeerMessage({ table = "loot", row = {} }))
        WGS:PeerSync_HandleIncoming("Member-TestRealm", chunks[1], false)

        assert.is_false(applied)
        -- The rejection should emit an internal-error event for ops visibility.
        local sawRejection
        for _, f in ipairs(WGS._fired) do
            if f.event == "WGS_INTERNAL_ERROR" and f.args[1]
               and f.args[1].source == "PeerSync.gate.rejected" then
                sawRejection = true
                break
            end
        end
        assert.is_true(sawRejection)
    end)

    it("drops self-loopback before touching the decoder", function()
        local applied = false
        WGS:PeerSync_RegisterMerge("loot", function() applied = true; return "added" end)

        local chunks = assert(WGS:EncodePeerMessage({ table = "loot", row = {} }))
        WGS:PeerSync_HandleIncoming("Tester-TestRealm", chunks[1], true)

        assert.is_false(applied)
    end)

    it("rejects sender when we aren't in a guild ourselves", function()
        _G.IsInGuild = function() return false end
        local applied = false
        WGS:PeerSync_RegisterMerge("loot", function() applied = true; return "added" end)

        local chunks = assert(WGS:EncodePeerMessage({ table = "loot", row = {} }))
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", chunks[1], false)

        assert.is_false(applied)
    end)
end)

describe("WGS:PeerSync_HandleIncoming dispatch", function()
    local WGS
    before_each(function()
        WGS = setup()
        fakeChat()
        fakeGuild({ ["Officer-TestRealm"] = 1 })
        _G.GetGuildInfo = function() return "TestGuild", "GM", 0 end
    end)

    it("fires WGS_PEER_SYNC_APPLIED with the merge action", function()
        WGS:PeerSync_RegisterMerge("attendance", function(_row, _sender)
            return "updated"
        end)
        local chunks = assert(WGS:EncodePeerMessage({ table = "attendance", row = { startedAt = 1 } }))
        for _, c in ipairs(chunks) do
            WGS:PeerSync_HandleIncoming("Officer-TestRealm", c, false)
        end

        local sawApplied
        for _, f in ipairs(WGS._fired) do
            if f.event == "WGS_PEER_SYNC_APPLIED" then
                sawApplied = f.args[1]
                break
            end
        end
        assert.is_table(sawApplied)
        assert.are.equal("attendance", sawApplied.table)
        assert.are.equal("updated", sawApplied.action)
        assert.are.equal("Officer-TestRealm", sawApplied.from)
    end)

    it("drops payloads for unknown tables silently", function()
        local chunks = assert(WGS:EncodePeerMessage({ table = "unknowntable", row = {} }))
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", chunks[1], false)

        for _, f in ipairs(WGS._fired) do
            assert.are_not.equal("WGS_PEER_SYNC_APPLIED", f.event)
        end
    end)

    it("survives a merge fn that throws (fires INTERNAL_ERROR, no APPLIED)", function()
        WGS:PeerSync_RegisterMerge("loot", function() error("boom") end)
        local chunks = assert(WGS:EncodePeerMessage({ table = "loot", row = {} }))
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", chunks[1], false)

        local sawErr
        for _, f in ipairs(WGS._fired) do
            if f.event == "WGS_INTERNAL_ERROR" and f.args[1]
               and f.args[1].source == "PeerSync.merge.loot" then
                sawErr = true
            end
            assert.are_not.equal("WGS_PEER_SYNC_APPLIED", f.event)
        end
        assert.is_true(sawErr)
    end)
end)

describe("WGS:PeerSync per-table merge fns", function()
    local WGS
    before_each(function() WGS = setup() end)

    describe("loot", function()
        it("inserts a new row", function()
            assert.are.equal("added", WGS._PeerSync_MergeLoot({
                itemID = 1, player = "X-Realm", timestamp = 1000,
            }))
            assert.are.equal(1, #WGS.db.global.loot)
        end)

        it("skips a duplicate within the ±60s window", function()
            WGS.db.global.loot[1] = { itemID = 1, player = "X-Realm", timestamp = 1000 }
            assert.are.equal("skipped", WGS._PeerSync_MergeLoot({
                itemID = 1, player = "X-Realm", timestamp = 1030,
            }))
            assert.are.equal(1, #WGS.db.global.loot)
        end)

        it("treats bare name and Name-Realm as the same player", function()
            WGS.db.global.loot[1] = { itemID = 1, player = "X", timestamp = 1000 }
            assert.are.equal("skipped", WGS._PeerSync_MergeLoot({
                itemID = 1, player = "X-OtherRealm", timestamp = 1001,
            }))
        end)

        it("admits a separate drop outside the dedup window", function()
            WGS.db.global.loot[1] = { itemID = 1, player = "X-Realm", timestamp = 1000 }
            assert.are.equal("added", WGS._PeerSync_MergeLoot({
                itemID = 1, player = "X-Realm", timestamp = 1100,
            }))
            assert.are.equal(2, #WGS.db.global.loot)
        end)

        it("skips garbage payloads", function()
            assert.are.equal("skipped", WGS._PeerSync_MergeLoot(nil))
            assert.are.equal("skipped", WGS._PeerSync_MergeLoot({}))
            assert.are.equal("skipped", WGS._PeerSync_MergeLoot({ itemID = 1 }))
        end)
    end)

    describe("attendance", function()
        it("inserts a new session", function()
            assert.are.equal("added", WGS._PeerSync_MergeAttendance({
                startedAt = 1, startedBy = "GM-Realm", endedAt = 100,
            }))
            assert.are.equal(1, #WGS.db.global.attendance)
        end)

        it("first-wins on (startedAt, startedBy)", function()
            WGS.db.global.attendance[1] = { startedAt = 1, startedBy = "GM-Realm", endedAt = 100 }
            assert.are.equal("skipped", WGS._PeerSync_MergeAttendance({
                startedAt = 1, startedBy = "GM-Realm", endedAt = 200,
            }))
        end)

        it("different startedBy is a different session", function()
            WGS.db.global.attendance[1] = { startedAt = 1, startedBy = "GM-Realm" }
            assert.are.equal("added", WGS._PeerSync_MergeAttendance({
                startedAt = 1, startedBy = "Other-Realm",
            }))
        end)
    end)

    describe("encounters", function()
        it("inserts a new kill", function()
            assert.are.equal("added", WGS._PeerSync_MergeEncounters({
                encounterID = 2902, timestamp = 1000,
            }))
        end)

        it("dedupes within ±2s of the same encounterID", function()
            WGS.db.global.encounters[1] = { encounterID = 2902, timestamp = 1000 }
            assert.are.equal("skipped", WGS._PeerSync_MergeEncounters({
                encounterID = 2902, timestamp = 1001,
            }))
        end)

        it("admits a re-kill outside the window", function()
            WGS.db.global.encounters[1] = { encounterID = 2902, timestamp = 1000 }
            assert.are.equal("added", WGS._PeerSync_MergeEncounters({
                encounterID = 2902, timestamp = 1100,
            }))
        end)
    end)

    describe("raidCompResults", function()
        it("inserts a new snapshot", function()
            assert.are.equal("added", WGS._PeerSync_MergeRaidCompResults({
                startedAt = 1, signature = "abc", slots = {},
            }))
        end)

        it("skips an identical signature for the same session", function()
            WGS.db.global.raidCompResults[1] = { startedAt = 1, signature = "abc" }
            assert.are.equal("skipped", WGS._PeerSync_MergeRaidCompResults({
                startedAt = 1, signature = "abc",
            }))
        end)

        it("admits a new comp signature for the same session", function()
            WGS.db.global.raidCompResults[1] = { startedAt = 1, signature = "abc" }
            assert.are.equal("added", WGS._PeerSync_MergeRaidCompResults({
                startedAt = 1, signature = "def",
            }))
        end)
    end)
end)

describe("WGS:PeerSync standard wiring", function()
    local WGS, sent
    before_each(function()
        WGS = setup()
        sent = fakeChat()
        fakeGuild({ ["Tester-TestRealm"] = 1 })
        _G.IsInRaid = function() return true end
        _G.GetGuildInfo = function(unit)
            if unit == "player" then return "TestGuild", "Officer", 1 end
            return nil
        end
        WGS:_PeerSync_InstallStandardWiring()
    end)

    it("broadcasts on WGS_LOOT_RECORDED", function()
        WGS:FireEvent("WGS_LOOT_RECORDED", { itemID = 42, player = "X-TestRealm", timestamp = 1000 })
        assert.is_true(#sent >= 1)
        assert.are.equal("RAID", sent[1].channel)
    end)

    it("broadcasts on WGS_SESSION_ENDED", function()
        WGS:FireEvent("WGS_SESSION_ENDED", { startedAt = 1, startedBy = "X-TestRealm" })
        assert.is_true(#sent >= 1)
    end)

    it("broadcasts on WGS_ENCOUNTER_RECORDED", function()
        WGS:FireEvent("WGS_ENCOUNTER_RECORDED", { encounterID = 2902, timestamp = 1000 })
        assert.is_true(#sent >= 1)
    end)

    it("broadcasts on WGS_RAID_COMP_SNAPSHOT", function()
        WGS:FireEvent("WGS_RAID_COMP_SNAPSHOT", { startedAt = 1, signature = "abc", slots = {} })
        assert.is_true(#sent >= 1)
    end)

    it("doesn't broadcast when we aren't an officer", function()
        _G.GetGuildInfo = function() return "TestGuild", "Member", 5 end
        WGS:FireEvent("WGS_LOOT_RECORDED", { itemID = 1, player = "X", timestamp = 1 })
        assert.are.equal(0, #sent)
    end)

    it("end-to-end: officer A broadcasts → officer B's merge fn applies it", function()
        -- A broadcasts a loot drop
        WGS:FireEvent("WGS_LOOT_RECORDED", {
            itemID = 999, player = "Y-TestRealm", timestamp = 5000,
        })
        assert.is_true(#sent >= 1)

        -- B receives every chunk we just sent. (Same WGS instance plays
        -- both roles — what matters is that the bytes round-trip and
        -- the merge fn fires.)
        WGS.db.global.loot = {}   -- pretend B starts empty
        for _, s in ipairs(sent) do
            WGS:PeerSync_HandleIncoming("Tester-TestRealm", s.msg, false)
        end

        -- Self-loopback drop fires for sender == self; flip isSelf off
        -- to simulate B as a different officer. Reset and replay through
        -- the real trust gate.
        WGS.db.global.loot = {}
        fakeGuild({ ["Tester-TestRealm"] = 1, ["Sender-TestRealm"] = 1 })
        for _, s in ipairs(sent) do
            WGS:PeerSync_HandleIncoming("Sender-TestRealm", s.msg, false)
        end
        assert.are.equal(1, #WGS.db.global.loot)
        assert.are.equal(999, WGS.db.global.loot[1].itemID)
    end)
end)
