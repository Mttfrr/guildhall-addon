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
