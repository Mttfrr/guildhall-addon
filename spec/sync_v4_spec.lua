local helpers = require("spec.helpers")

-- Sync envelope v4: LibDeflate compression + chat-safe print encoding.
-- These specs load the real LibDeflate source (helpers.loadLibDeflate)
-- rather than mocking the codec — the goal is to catch regressions in
-- the Encoder/Decoder dispatch logic when paired with the actual
-- library, not to re-test LibDeflate itself.

describe("Sync v4 envelope (with LibDeflate loaded)", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
        helpers.loadLibDeflate()
        WGS:_ResetCompressionCache()
    end)

    it("emits a WGS4-prefixed envelope when LibDeflate is present", function()
        local encoded = WGS:Encode({ loot = {} })
        assert.is_string(encoded)
        assert.are.equal("WGS4", encoded:sub(1, 4))
        -- WGS4 + 8 hex chars + ":" → colon at byte 13
        assert.are.equal(":", encoded:sub(13, 13))
    end)

    it("uses a chat-safe alphabet (no + / which would break edit boxes)", function()
        local encoded = WGS:Encode({
            attendance = {
                { startedAt = 1, endedAt = 2, instanceName = "Nerub-ar Palace" },
            },
        })
        local body = encoded:sub(14)  -- everything after the header+sum+":"
        -- LibDeflate's EncodeForPrint alphabet: a-z A-Z 0-9 ( )
        assert.is_truthy(body:match("^[%a%d()]+$"),
            "v4 body must be chat-safe alphanumeric + parens, got: " .. body:sub(1, 32))
    end)

    it("round-trips a non-trivial payload via the full Encode/Decode pipeline", function()
        local original = {
            loot = {
                { item_id = 12345, character = "Foo-Realm", t = 1733000000 },
                { item_id = 67890, character = "Bar-Realm", t = 1733000060 },
            },
            attendance = { { startedAt = 1733000000, endedAt = 1733004000 } },
        }
        local encoded = WGS:Encode(original)
        assert.are.equal("WGS4", encoded:sub(1, 4))

        local decoded, err = WGS:Decode(encoded)
        assert.is_nil(err)
        assert.is_table(decoded)
        assert.are.equal(4, decoded.v)
        assert.is_table(decoded.data)
        assert.are.equal(12345, decoded.data.loot[1].item_id)
        assert.are.equal("Foo-Realm", decoded.data.loot[1].character)
        assert.are.equal(1733000000, decoded.data.attendance[1].startedAt)
    end)

    it("compresses repetitive payloads to under 60% of the v3 size", function()
        -- A realistic-shape payload: lots of repeated keys + class names,
        -- which is where deflate wins big. Spec asserts ≥40% shrink — well
        -- below the typical 60-75% that LibDeflate hits on real exports.
        local roster = {}
        for i = 1, 50 do
            roster[i] = {
                name = "Player" .. i .. "-TestRealm",
                class = "DEATHKNIGHT", role = "DAMAGER",
                isGuildMember = true, joinedAt = 1733000000 + i, leftAt = nil,
            }
        end
        local payload = {
            attendance = {
                {
                    startedAt = 1733000000, endedAt = 1733010000,
                    instanceName = "Nerub-ar Palace",
                    teamId = 7, teamName = "MainRaid",
                    memberList = roster,
                },
            },
        }
        local v4 = WGS:Encode(payload)
        assert.are.equal("WGS4", v4:sub(1, 4))

        -- Force the v3 path by clearing the cache and removing LibDeflate
        WGS:_ResetCompressionCache()
        local origLibStub = _G.LibStub
        _G.LibStub = setmetatable({}, {
            __call = function(_, name)
                if name == "LibDeflate" then return nil end
                return origLibStub(name)
            end,
            __index = getmetatable(origLibStub).__index,
        })
        local v3 = WGS:Encode(payload)
        _G.LibStub = origLibStub
        WGS:_ResetCompressionCache()

        assert.are.equal("WGS3", v3:sub(1, 4))
        local ratio = #v4 / #v3
        assert(ratio < 0.6,
            string.format("expected v4 to be <60%% of v3 (got %d/%d = %.2f)", #v4, #v3, ratio))
    end)

    it("rejects a truncated v4 envelope with a 'truncated' error", function()
        local encoded = WGS:Encode({ loot = { { x = 1 }, { x = 2 }, { x = 3 } } })
        local truncated = encoded:sub(1, #encoded - 5)
        local decoded, err = WGS:Decode(truncated)
        assert.is_nil(decoded)
        assert.is_truthy(err)
        assert.is_truthy(err:find("truncated"))
    end)

    it("still accepts v3 strings when LibDeflate is loaded (backward compat)", function()
        -- Build a v3 envelope by hand: base64(JSON) + djb2 checksum.
        local json = '{"v":3,"data":{"motd":"old-export-string"}}'
        local b64 = WGS:Base64Encode(json)
        local sum = WGS:HashString(b64)
        local v3 = "WGS3" .. sum .. ":" .. b64

        local decoded, err = WGS:Decode(v3)
        assert.is_nil(err)
        assert.is_table(decoded)
        assert.are.equal("old-export-string", decoded.data.motd)
    end)

    it("errors gracefully on a v4 string when LibDeflate is missing", function()
        local encoded = WGS:Encode({ loot = {} })
        assert.are.equal("WGS4", encoded:sub(1, 4))

        -- Strip LibDeflate from LibStub + reset the Decoder's cache to
        -- simulate a fresh session where the library wasn't vendored.
        local origLibStub = _G.LibStub
        _G.LibStub = setmetatable({}, {
            __call = function(_, name)
                if name == "LibDeflate" then return nil end
                return origLibStub(name)
            end,
            __index = getmetatable(origLibStub).__index,
        })
        WGS:_ResetCompressionCache()

        local decoded, err = WGS:Decode(encoded)
        _G.LibStub = origLibStub
        WGS:_ResetCompressionCache()

        assert.is_nil(decoded)
        assert.is_truthy(err)
        assert.is_truthy(err:find("LibDeflate"))
    end)
end)
