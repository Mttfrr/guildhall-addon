local helpers = require("spec.helpers")

-- Sync/PeerMessage.lua — peer-to-peer transport layer (encode →
-- chunk → fragment → reassemble → decode). LibDeflate is loaded for
-- real via the existing helper so we exercise the actual compression
-- + chat-safe encoding path end to end.

local function setupWithLibDeflate()
    local WGS = helpers.setup()
    helpers.loadLibDeflate()
    WGS:_ResetCompressionCache()
    WGS:_PeerMessageResetBuffer()
    return WGS
end

describe("WGS:EncodePeerMessage", function()
    local WGS
    before_each(function() WGS = setupWithLibDeflate() end)

    it("encodes a small delta into one or more well-framed chunks", function()
        local chunks, err = WGS:EncodePeerMessage({ table = "loot", row = { itemID = 12345, player = "Foo-Realm" } })
        assert.is_nil(err)
        assert.is_table(chunks)
        assert.is_true(#chunks >= 1)
        for _, c in ipairs(chunks) do
            assert.is_string(c)
            -- WGS|<msgId>|<idx>/<total>|<payload>
            assert.is_truthy(c:match("^WGS|[%w]+|%d+/%d+|"))
            -- Whole message must fit WoW's 255-byte addon-message cap.
            assert.is_true(#c <= 255)
        end
    end)

    it("fragments a payload that exceeds one chunk", function()
        -- A row big enough to force at least 2 chunks after compression.
        -- Realistic shape: a session memberList with many entries.
        local members = {}
        for i = 1, 80 do
            members[i] = {
                name = "Player" .. i .. "-Realm",
                class = "DEATHKNIGHT", role = "DAMAGER",
                isGuildMember = true, joinedAt = 1733000000 + i,
            }
        end
        local delta = { table = "attendance", row = {
            startedAt = 1733000000, endedAt = 1733010000,
            startedBy = "GMain-Realm", instanceName = "Nerub-ar Palace",
            memberList = members,
        }}
        local chunks = assert(WGS:EncodePeerMessage(delta))
        assert.is_true(#chunks >= 2, "expected multi-chunk; got " .. #chunks)
    end)

    it("returns nil + reason when LibDeflate is unavailable", function()
        -- Force the cache to "probed, not available"
        WGS._libDeflate = false
        local origLibStub = _G.LibStub
        _G.LibStub = setmetatable({}, {
            __call = function(_, name)
                if name == "LibDeflate" then return nil end
                return origLibStub(name)
            end,
            __index = getmetatable(origLibStub).__index,
        })
        WGS._libDeflate = nil  -- force re-probe

        local chunks, err = WGS:EncodePeerMessage({ table = "loot", row = {} })

        _G.LibStub = origLibStub
        WGS._libDeflate = nil

        assert.is_nil(chunks)
        assert.is_truthy(err and err:find("LibDeflate"))
    end)

    it("rejects non-table input", function()
        local chunks, err = WGS:EncodePeerMessage("not a table")
        assert.is_nil(chunks)
        assert.is_truthy(err)
    end)
end)

describe("WGS:DecodePeerMessage round-trip", function()
    local WGS
    before_each(function() WGS = setupWithLibDeflate() end)

    it("round-trips a single-chunk message", function()
        local original = { table = "loot", row = { itemID = 555, player = "Alice-Realm" } }
        local chunks = assert(WGS:EncodePeerMessage(original))
        assert.are.equal(1, #chunks)

        local got = WGS:DecodePeerMessage("Alice-Realm", chunks[1])
        assert.is_table(got)
        assert.are.equal("loot", got.table)
        assert.are.equal(555, got.row.itemID)
    end)

    it("round-trips a multi-chunk message delivered in order", function()
        local big = {}
        for i = 1, 80 do big[i] = { name = "P" .. i, ilvl = 600 + i } end
        local original = { table = "attendance", row = { memberList = big } }
        local chunks = assert(WGS:EncodePeerMessage(original))
        assert.is_true(#chunks >= 2)

        local got
        for _, c in ipairs(chunks) do
            got = WGS:DecodePeerMessage("Bob-Realm", c)
        end
        assert.is_table(got)
        assert.are.equal(80, #got.row.memberList)
        assert.are.equal("P1", got.row.memberList[1].name)
        assert.are.equal("P80", got.row.memberList[80].name)
    end)

    it("round-trips a multi-chunk message delivered OUT of order", function()
        -- Real WoW addon-messaging can reorder, especially across raid/party
        -- boundaries. The reassembler addresses chunks by explicit index;
        -- arrival order must not matter.
        --
        -- Use less-compressible content (varied bodies + a long random-ish
        -- note per row) so deflate can't squash everything into one chunk.
        local big = {}
        for i = 1, 80 do
            big[i] = {
                name = "X" .. i .. "-Realm",
                class = (i % 3 == 0 and "WARRIOR" or i % 3 == 1 and "MAGE" or "PRIEST"),
                role  = (i % 2 == 0 and "TANK" or "HEALER"),
                group = i,
                note = string.rep(string.char(64 + (i % 26)), 12) .. tostring(i * 7919),
            }
        end
        local original = { table = "raidCompResults", row = { slots = big } }
        local chunks = assert(WGS:EncodePeerMessage(original))
        assert.is_true(#chunks >= 2, "expected multi-chunk; got " .. #chunks)

        -- Reverse delivery order.
        local got
        for i = #chunks, 1, -1 do
            got = WGS:DecodePeerMessage("Carol-Realm", chunks[i])
        end
        assert.is_table(got)
        assert.are.equal(80, #got.row.slots)
        assert.are.equal("X1-Realm", got.row.slots[1].name)
        assert.are.equal("X80-Realm", got.row.slots[80].name)
    end)

    it("returns nil while still partial; clean state when complete", function()
        local original = { table = "attendance", row = { memberList = (function()
            local t = {}
            for i = 1, 80 do t[i] = { name = "P" .. i } end
            return t
        end)() } }
        local chunks = assert(WGS:EncodePeerMessage(original))
        assert.is_true(#chunks >= 2)

        assert.are.equal(0, WGS:_PeerMessageBufferCount())

        -- Send all but the last → buffer holds one partial state.
        for i = 1, #chunks - 1 do
            local got = WGS:DecodePeerMessage("Dave-Realm", chunks[i])
            assert.is_nil(got, "partial returns nil; got chunk " .. i)
        end
        assert.are.equal(1, WGS:_PeerMessageBufferCount())

        -- Final chunk completes → returns delta; buffer empties.
        local got = WGS:DecodePeerMessage("Dave-Realm", chunks[#chunks])
        assert.is_table(got)
        assert.are.equal(0, WGS:_PeerMessageBufferCount())
    end)

    it("two independent senders don't cross-pollinate", function()
        local a = assert(WGS:EncodePeerMessage({ table = "loot", row = { itemID = 1 } }))
        local b = assert(WGS:EncodePeerMessage({ table = "loot", row = { itemID = 2 } }))
        local fromA = WGS:DecodePeerMessage("Alice-Realm", a[1])
        local fromB = WGS:DecodePeerMessage("Bob-Realm", b[1])
        assert.are.equal(1, fromA.row.itemID)
        assert.are.equal(2, fromB.row.itemID)
    end)

    it("rejects malformed frames silently (returns nil)", function()
        assert.is_nil(WGS:DecodePeerMessage("Eve-Realm", "garbage-no-pipes"))
        assert.is_nil(WGS:DecodePeerMessage("Eve-Realm", "WGS|notdigits"))
        assert.is_nil(WGS:DecodePeerMessage("Eve-Realm", ""))
    end)

    it("rejects missing senderKey", function()
        local chunks = assert(WGS:EncodePeerMessage({ table = "loot", row = {} }))
        assert.is_nil(WGS:DecodePeerMessage("", chunks[1]))
        assert.is_nil(WGS:DecodePeerMessage(nil, chunks[1]))
    end)
end)
