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

describe("WGS:PeerSync_Status", function()
    local WGS
    before_each(function() WGS = setup() end)

    it("reports disabled when override is false", function()
        WGS.db.profile.peerSyncEnabled = false
        local s = WGS:PeerSync_Status()
        assert.is_false(s.enabled)
        assert.is_table(s)
    end)

    it("reports enabled iff officer when no override is set", function()
        WGS.db.profile.peerSyncEnabled = nil  -- default
        -- Stub the officer gate two ways to cover both branches.
        WGS.IsGuildOfficer = function() return true end
        assert.is_true(WGS:PeerSync_Status().enabled)
        WGS.IsGuildOfficer = function() return false end
        assert.is_false(WGS:PeerSync_Status().enabled)
    end)

    it("includes channel + lastSyncAt fields", function()
        _G.IsInRaid, _G.IsInGroup, _G.IsInGuild = function() return true end, function() return true end, function() return true end
        local s = WGS:PeerSync_Status()
        assert.are.equal("RAID", s.channel)
        assert.is_number(s.lastSyncAt)
        assert.is_number(s.lastPeerCount)
        assert.is_boolean(s.inFlight)
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

describe("WGS:PeerSync_Catchup handshake", function()
    local WGS, sent
    before_each(function()
        WGS = setup()
        sent = fakeChat()
        fakeGuild({
            ["Tester-TestRealm"] = 1,    -- us
            ["Officer-TestRealm"] = 1,   -- peer
        })
        _G.IsInRaid = function() return true end
        _G.GetGuildInfo = function(unit)
            if unit == "player" then return "TestGuild", "Officer", 1 end
            return nil
        end
        WGS:_PeerSync_InstallStandardWiring()
    end)

    -- The probe is the user-facing entry point: officer joins a raid
    -- and we ship a __probe so peers can offer their state. Officer
    -- gate + channel gate apply via PeerSync_Broadcast.
    it("Catchup sends a __probe and opens a session", function()
        WGS:PeerSync_Catchup()
        assert.is_true(#sent >= 1)
        -- Decode the chunk to verify the table name.
        local delta = WGS:DecodePeerMessage("Tester-TestRealm", sent[1].msg)
        -- DecodePeerMessage uses the trust-buffer keyed by senderKey, so
        -- decoding our own outbound chunk with our own key works fine
        -- in tests. Production receivers see the same shape.
        assert.is_table(delta)
        assert.are.equal("__probe", delta.table)
        -- The session is open until offers are processed.
        assert.is_table(WGS:_PeerSync_CatchupSession())
    end)

    it("Catchup is debounced (60s window)", function()
        WGS:PeerSync_Catchup()
        local firstCount = #sent
        assert.is_true(firstCount >= 1)
        -- Immediate re-trigger should be a no-op.
        WGS:PeerSync_Catchup()
        assert.are.equal(firstCount, #sent, "second probe within debounce window leaked traffic")
    end)

    it("non-officers don't probe", function()
        _G.GetGuildInfo = function() return "TestGuild", "Member", 5 end
        WGS:_PeerSyncResetQueue()
        WGS:PeerSync_Catchup()
        assert.are.equal(0, #sent)
    end)

    -- A peer receiving __probe responds with its per-table max
    -- timestamps. The response carries replyTo so the joiner can tell
    -- which OFFERs are addressed to them.
    it("handling __probe emits an __offer with local maxes", function()
        WGS.db.global.loot[1]            = { itemID = 1, player = "X", timestamp = 1234 }
        WGS.db.global.attendance[1]      = { startedAt = 5678, startedBy = "Y" }
        WGS.db.global.encounters[1]      = { encounterID = 9, timestamp = 999 }
        WGS.db.global.raidCompResults[1] = { startedAt = 5678, signature = "s" }

        local probe = assert(WGS:EncodePeerMessage({ table = "__probe", row = {} }))
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", probe[1], false)

        -- Decode every outbound chunk and look for an __offer frame.
        local offer
        for _, s in ipairs(sent) do
            local d = WGS:DecodePeerMessage("Tester-TestRealm", s.msg)
            if d and d.table == "__offer" then offer = d.row end
        end
        assert.is_table(offer)
        assert.are.equal("Officer-TestRealm", offer.replyTo)
        assert.are.equal(1234, offer.maxes.loot)
        assert.are.equal(5678, offer.maxes.attendance)
        assert.are.equal(999, offer.maxes.encounters)
        assert.are.equal(5678, offer.maxes.raidCompResults)
    end)

    -- The joiner collects __offer responses inside the open session
    -- and ignores anything not addressed to them.
    it("__offer is only accepted while a catch-up session is open AND addressed to us", function()
        local offerFrame = assert(WGS:EncodePeerMessage({
            table = "__offer",
            row = { replyTo = "Tester-TestRealm", maxes = { loot = 9999 } },
        }))
        -- No session open → dropped.
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", offerFrame[1], false)
        assert.is_nil(WGS:_PeerSync_CatchupSession())

        -- Open a session and replay.
        WGS:PeerSync_Catchup()
        assert.is_table(WGS:_PeerSync_CatchupSession())
        -- The offer above was already decoded once; decoding it a second
        -- time would normally be partial — re-encode fresh.
        offerFrame = assert(WGS:EncodePeerMessage({
            table = "__offer",
            row = { replyTo = "Tester-TestRealm", maxes = { loot = 9999 } },
        }))
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", offerFrame[1], false)
        local session = WGS:_PeerSync_CatchupSession()
        assert.is_table(session.offers["Officer-TestRealm"])
        assert.are.equal(9999, session.offers["Officer-TestRealm"].loot)

        -- An offer addressed to someone else is ignored.
        local otherFrame = assert(WGS:EncodePeerMessage({
            table = "__offer",
            row = { replyTo = "OtherPerson-Realm", maxes = { loot = 11111 } },
        }))
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", otherFrame[1], false)
        assert.are.equal(9999, session.offers["Officer-TestRealm"].loot)
    end)

    -- After offers are collected, the joiner sends a __request per
    -- table to the peer with the highest remote max for that table.
    it("processing offers emits __request for tables where the peer is ahead", function()
        WGS.db.global.loot       = {}    -- we're empty
        WGS.db.global.attendance = { { startedAt = 5000, startedBy = "X" } }

        WGS:PeerSync_Catchup()
        -- Inject an offer manually so we don't depend on a real round trip.
        local session = WGS:_PeerSync_CatchupSession()
        session.offers["Officer-TestRealm"] = { loot = 9999, attendance = 4000, encounters = 0, raidCompResults = 0 }

        local before = #sent
        WGS._PeerSync_ProcessCatchupOffers()

        -- Walk the new chunks and pull out __request payloads.
        local reqs = {}
        for i = before + 1, #sent do
            local d = WGS:DecodePeerMessage("Tester-TestRealm", sent[i].msg)
            if d and d.table == "__request" then reqs[#reqs + 1] = d.row end
        end
        -- Peer leads on loot (9999 > 0) → one request.
        -- Peer trails on attendance (4000 < 5000) → no request.
        assert.are.equal(1, #reqs, "expected exactly one __request (loot only)")
        assert.are.equal("loot", reqs[1].table)
        assert.are.equal("Officer-TestRealm", reqs[1].target)
        assert.are.equal(0, reqs[1].since)
        -- Session is closed after processing.
        assert.is_nil(WGS:_PeerSync_CatchupSession())
    end)

    -- The peer receiving __request replays the matching rows. Each
    -- replayed row goes through the normal broadcast path and so is
    -- subject to dedup on the receiver via the merge fns.
    it("__request triggers replay of post-since rows for the target peer", function()
        -- Realistic timestamps: the replay logic floors below now-7days
        -- to stop a fresh joiner from replaying ancient history, so the
        -- test rows have to be recent for replay to fire at all.
        local now = os.time()
        WGS.db.global.loot = {
            { itemID = 1, player = "X", timestamp = now - 300, recordedBy = "Tester-TestRealm" },
            { itemID = 2, player = "Y", timestamp = now - 200, recordedBy = "Tester-TestRealm" },
            { itemID = 3, player = "Z", timestamp = now - 100, recordedBy = "Tester-TestRealm" },
        }

        local before = #sent
        local reqFrame = assert(WGS:EncodePeerMessage({
            table = "__request",
            row = { table = "loot", since = now - 250, target = "Tester-TestRealm" },
        }))
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", reqFrame[1], false)

        -- Items 2 and 3 are after `since`; item 1 is before.
        local replays = {}
        for i = before + 1, #sent do
            local d = WGS:DecodePeerMessage("Tester-TestRealm", sent[i].msg)
            if d and d.table == "loot" then replays[#replays + 1] = d.row end
        end
        assert.are.equal(2, #replays)
        table.sort(replays, function(a, b) return a.timestamp < b.timestamp end)
        assert.are.equal(now - 200, replays[1].timestamp)
        assert.are.equal(now - 100, replays[2].timestamp)
    end)

    it("__request addressed to someone else is ignored", function()
        WGS.db.global.loot = { { itemID = 1, player = "X", timestamp = os.time() } }
        local before = #sent
        local reqFrame = assert(WGS:EncodePeerMessage({
            table = "__request",
            row = { table = "loot", since = 0, target = "SomeoneElse-Realm" },
        }))
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", reqFrame[1], false)
        assert.are.equal(before, #sent)
    end)
end)

-- Whole-payload snapshot exchange. Distinct from the per-row catchup
-- above: events/teams/signups are platform-imported as a single payload,
-- so the sync unit is the entire import (version-stamped by
-- db.global.lastImport). Tests cover the offer-stamp piggyback, the
-- "newer than us" decision via the grace window, the request handler,
-- and the inbound apply path through ProcessImport.
describe("WGS:PeerSync snapshot exchange", function()
    local WGS, sent
    before_each(function()
        WGS = setup()
        sent = fakeChat()
        fakeGuild({
            ["Tester-TestRealm"]  = 1,
            ["Officer-TestRealm"] = 1,
        })
        _G.IsInRaid = function() return true end
        _G.GetGuildInfo = function(unit)
            if unit == "player" then return "TestGuild", "Officer", 1 end
            return nil
        end
        WGS:_PeerSync_InstallStandardWiring()
    end)

    it("offer carries the local lastImport as __snapshot stamp", function()
        WGS.db.global.lastImport = 50000

        local probe = assert(WGS:EncodePeerMessage({ table = "__probe", row = {} }))
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", probe[1], false)

        local offer
        for _, s in ipairs(sent) do
            local d = WGS:DecodePeerMessage("Tester-TestRealm", s.msg)
            if d and d.table == "__offer" then offer = d.row end
        end
        assert.is_table(offer)
        assert.are.equal(50000, offer.maxes.__snapshot)
    end)

    it("processing offers sends a __snapshot __request when peer is meaningfully ahead", function()
        WGS.db.global.lastImport = 1000
        WGS:PeerSync_Catchup()
        local session = WGS:_PeerSync_CatchupSession()
        -- Peer is 60s ahead — well beyond the 30s grace window.
        session.offers["Officer-TestRealm"] = { __snapshot = 1060 }

        local before = #sent
        WGS._PeerSync_ProcessCatchupOffers()

        local snapReq
        for i = before + 1, #sent do
            local d = WGS:DecodePeerMessage("Tester-TestRealm", sent[i].msg)
            if d and d.table == "__request" and d.row.table == "__snapshot" then
                snapReq = d.row
            end
        end
        assert.is_table(snapReq)
        assert.are.equal("Officer-TestRealm", snapReq.target)
    end)

    it("processing offers does NOT request when peer is within the 30s grace window", function()
        WGS.db.global.lastImport = 1000
        WGS:PeerSync_Catchup()
        local session = WGS:_PeerSync_CatchupSession()
        -- Peer's 20s ahead — inside the grace window; treat as equivalent.
        session.offers["Officer-TestRealm"] = { __snapshot = 1020 }

        local before = #sent
        WGS._PeerSync_ProcessCatchupOffers()

        for i = before + 1, #sent do
            local d = WGS:DecodePeerMessage("Tester-TestRealm", sent[i].msg)
            assert.is_false(d and d.table == "__request" and d.row.table == "__snapshot",
                "should not have sent a snapshot request inside the grace window")
        end
    end)

    it("__snapshot __request triggers a payload broadcast", function()
        WGS.db.global.lastImport = 12345
        WGS.db.global.events     = { { id = 1, title = "Heroic" } }
        WGS.db.global.teams      = { { id = 99, name = "A-Team" } }

        local reqFrame = assert(WGS:EncodePeerMessage({
            table = "__request",
            row   = { table = "__snapshot", target = "Tester-TestRealm" },
        }))
        local before = #sent
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", reqFrame[1], false)

        local snap
        for i = before + 1, #sent do
            local d = WGS:DecodePeerMessage("Tester-TestRealm", sent[i].msg)
            if d and d.table == "__snapshot" then snap = d.row end
        end
        assert.is_table(snap)
        assert.are.equal(12345, snap.stamp)
        assert.is_table(snap.payload)
        assert.are.equal(1, #snap.payload.events)
        assert.are.equal("Heroic", snap.payload.events[1].title)
        assert.are.equal(1, #snap.payload.teams)
    end)

    it("__snapshot __request from someone with nothing to share is a no-op", function()
        WGS.db.global.lastImport = nil   -- never imported
        local reqFrame = assert(WGS:EncodePeerMessage({
            table = "__request",
            row   = { table = "__snapshot", target = "Tester-TestRealm" },
        }))
        local before = #sent
        WGS:PeerSync_HandleIncoming("Officer-TestRealm", reqFrame[1], false)
        assert.are.equal(before, #sent)
    end)

    it("inbound __snapshot newer than ours runs through ProcessImport", function()
        WGS.db.global.lastImport = 1000
        WGS.db.global.events     = {}

        -- Stub ProcessImport so we can assert it was called with our payload.
        local called
        WGS.ProcessImport = function(self, data)
            called = data
            self.db.global.lastImport = 2000
        end

        WGS._PeerSync_MergeSnapshot({
            stamp   = 2000,
            payload = { events = { { id = 7, title = "Mythic" } } },
        })
        assert.is_table(called)
        assert.is_table(called.events)
        assert.are.equal("Mythic", called.events[1].title)
    end)

    it("inbound __snapshot within grace window is skipped", function()
        WGS.db.global.lastImport = 1000
        local called = false
        WGS.ProcessImport = function() called = true end

        local result = WGS._PeerSync_MergeSnapshot({
            stamp   = 1015,   -- 15s newer — inside grace
            payload = { events = {} },
        })
        assert.are.equal("skipped", result)
        assert.is_false(called)
    end)

    it("inbound __snapshot with malformed payload is skipped, no crash", function()
        WGS.db.global.lastImport = 1000
        assert.are.equal("skipped", WGS._PeerSync_MergeSnapshot(nil))
        assert.are.equal("skipped", WGS._PeerSync_MergeSnapshot({ stamp = 2000 }))   -- no payload
        assert.are.equal("skipped", WGS._PeerSync_MergeSnapshot({ stamp = 2000, payload = "bad" }))
    end)
end)

-- Dev-only loopback hook on PeerSync_Broadcast. When the profile flag
-- peerSyncLoopback is set, each outbound chunk is also re-fed through
-- PeerSync_HandleIncoming with our own playerKey as sender — exercising
-- the full encode → decode → trust-gate → merge round-trip from a
-- single client, without bothering other officers with test traffic.
describe("WGS:PeerSync_Broadcast loopback", function()
    local WGS
    before_each(function()
        WGS = setup()
        fakeChat()
        fakeGuild({ ["Tester-TestRealm"] = 1 })
        _G.IsInRaid = function() return true end
        _G.IsInGroup = function() return true end
        _G.GetGuildInfo = function(unit)
            if unit == "player" then return "TestGuild", "Officer", 1 end
            return nil
        end
    end)

    it("does NOT self-deliver when peerSyncLoopback is false (default)", function()
        local merged
        WGS:PeerSync_RegisterMerge("loot", function(row) merged = row end)
        assert.is_falsy(WGS.db.profile.peerSyncLoopback)

        local ok = WGS:PeerSync_Broadcast("loot", { itemID = 42 })
        assert.is_true(ok)
        assert.is_nil(merged, "merge fn must not be called without loopback")
    end)

    it("self-delivers the broadcast row through the merge fn when loopback is on", function()
        WGS.db.profile.peerSyncLoopback = true
        local merged, callCount = nil, 0
        WGS:PeerSync_RegisterMerge("loot", function(row, sender)
            merged = { row = row, sender = sender }
            callCount = callCount + 1
            return "added"
        end)

        local ok = WGS:PeerSync_Broadcast("loot", { itemID = 42, player = "Tester-TestRealm" })
        assert.is_true(ok)
        assert.are.equal(1, callCount, "merge fn should fire exactly once per broadcast")
        assert.are.equal(42, merged.row.itemID,
            "row arrives at the merge fn byte-identical after encode/decode round-trip")
        assert.are.equal("Tester-TestRealm", merged.sender,
            "loopback uses our own playerKey as senderKey so the trust gate accepts it")
    end)

    -- The catch-up handshake (__probe → __offer → __request → table
    -- replay) chains four message types. Loopback should drive all of
    -- them locally so the developer can verify catch-up paths without
    -- a second client.
    it("loopback completes a catch-up probe → offer handshake against self", function()
        WGS.db.profile.peerSyncLoopback = true
        WGS.db.global.loot = { { itemID = 1, timestamp = 1000 }, { itemID = 2, timestamp = 2000 } }

        -- The probe broadcast self-delivers; handleProbe replies with
        -- an __offer broadcast that also self-delivers and gets recorded
        -- as an offer from our own playerKey. handleOffer's replyTo
        -- check expects the offer to be addressed to GetPlayerKey() —
        -- which holds because handleProbe sets replyTo = senderKey and
        -- senderKey is our own key under loopback.
        local ok = WGS:PeerSync_Broadcast("__probe", { from = WGS:GetPlayerKey() })
        assert.is_true(ok)

        -- We should have at least 2 sends queued (the probe + the offer
        -- reply). The exact count depends on chunking but the offer
        -- having been generated is the signal that the handshake chain
        -- completed past handleProbe.
        local sent2 = fakeChat()
        WGS:PeerSync_Broadcast("__probe", { from = WGS:GetPlayerKey() })
        assert.is_true(#sent2 >= 2,
            "probe must trigger handleProbe under loopback, which broadcasts an __offer reply")
    end)
end)
