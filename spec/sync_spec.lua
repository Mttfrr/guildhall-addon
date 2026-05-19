local helpers = require("spec.helpers")

describe("Sync v3 envelope", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("emits a WGS3-prefixed v3 envelope on Encode", function()
        local encoded = WGS:Encode({ loot = {} })
        assert.is_string(encoded)
        assert.are.equal("WGS3", encoded:sub(1, 4))
        -- WGS3 + 8 hex chars + ":" → colon at byte 13
        assert.are.equal(":", encoded:sub(13, 13))
    end)

    it("round-trips a non-trivial payload", function()
        local original = {
            loot = {
                { item_id = 12345, character = "Foo-Realm", t = 1733000000 },
                { item_id = 67890, character = "Bar-Realm", t = 1733000060 },
            },
            attendance = { { startedAt = 1733000000, endedAt = 1733004000 } },
        }
        local encoded = WGS:Encode(original)
        local decoded, err = WGS:Decode(encoded)
        assert.is_nil(err)
        assert.is_table(decoded)
        assert.are.equal(3, decoded.v)
        assert.is_table(decoded.data)
        assert.is_table(decoded.data.loot)
        assert.are.equal(2, #decoded.data.loot)
        assert.are.equal(12345, decoded.data.loot[1].item_id)
        assert.are.equal("Foo-Realm", decoded.data.loot[1].character)
    end)

    it("rejects a truncated envelope with a 'truncated' error", function()
        local encoded = WGS:Encode({ loot = {} })
        local truncated = encoded:sub(1, #encoded - 5)
        local decoded, err = WGS:Decode(truncated)
        assert.is_nil(decoded)
        assert.is_truthy(err)
        assert.is_truthy(err:find("truncated"))
    end)

    it("accepts a legacy v2 envelope (WGS<base64>)", function()
        local b64 = WGS:Base64Encode('{"v":2,"data":{"motd":"hello"}}')
        local v2 = "WGS" .. b64
        local decoded, err = WGS:Decode(v2)
        assert.is_nil(err)
        assert.is_table(decoded)
        assert.are.equal("hello", decoded.data.motd)
    end)

    it("rejects junk with a 'missing header' error", function()
        local decoded, err = WGS:Decode("XYZjunkstring")
        assert.is_nil(decoded)
        assert.is_truthy(err)
        assert.is_truthy(err:find("Invalid"))
    end)

    it("decodes raw JSON (debug/manual path)", function()
        local decoded, err = WGS:Decode('{"v":2,"data":{"motd":"raw"}}')
        assert.is_nil(err)
        assert.is_table(decoded)
        assert.are.equal("raw", decoded.data.motd)
    end)
end)

describe("djb2 HashString", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    -- Reference digests verified against the web's djb2Hex in
    -- /home/user/guildhall/client/src/pages/AddonSync.jsx. If you change
    -- the algorithm on either side, update both — the envelope round-trip
    -- across the web↔addon boundary depends on it.
    it("matches reference digests", function()
        assert.are.equal("00001505", WGS:HashString(""))
        assert.are.equal("0f923099", WGS:HashString("hello"))
    end)

    it("returns 8 lowercase hex chars for arbitrary input", function()
        local out = WGS:HashString("the quick brown fox jumps over the lazy dog")
        assert.are.equal(8, #out)
        assert.is_truthy(out:match("^[0-9a-f]+$"))
    end)
end)

describe("Base64 codec", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("round-trips arbitrary byte sequences", function()
        local samples = {
            "", "a", "ab", "abc", "abcd", "hello world",
            string.rep("X", 1000),
            "\0\1\2\255",
        }
        for _, s in ipairs(samples) do
            local back = WGS:Base64Decode(WGS:Base64Encode(s))
            assert.are.equal(s, back)
        end
    end)
end)

describe("JSON codec", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("round-trips a nested structure", function()
        local data = {
            arr = { 1, 2, 3 },
            obj = { name = "Foo", count = 42 },
            flag = true,
            empty = {},
        }
        local back = WGS:FromJson(WGS:ToJson(data))
        assert.is_table(back)
        assert.are.equal(true, back.flag)
        assert.are.equal("Foo", back.obj.name)
        assert.are.equal(42, back.obj.count)
    end)

    it("escapes quotes and backslashes in strings", function()
        local json = WGS:ToJson({ s = 'a"b\\c' })
        local back = WGS:FromJson(json)
        assert.are.equal('a"b\\c', back.s)
    end)
end)

describe("Version comparison", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("agrees with semver ordering for x.y.z", function()
        assert.are.equal(0,  WGS:CompareVersions("0.6.0", "0.6.0"))
        assert.are.equal(-1, WGS:CompareVersions("0.6.0", "0.7.0"))
        assert.are.equal(1,  WGS:CompareVersions("0.7.0", "0.6.0"))
        assert.are.equal(1,  WGS:CompareVersions("1.0.0", "0.99.99"))
    end)

    it("strips pre-release suffixes (matches server's compareVersions)", function()
        assert.are.equal(0,  WGS:CompareVersions("0.7.0-beta", "0.7.0"))
        assert.are.equal(-1, WGS:CompareVersions("0.6.0-beta", "0.7.0"))
    end)

    it("treats nil/empty as falsy via IsOutdated", function()
        WGS.db.global.serverMinAddonVersion = nil
        assert.is_false(WGS:IsOutdated())
        WGS.db.global.serverMinAddonVersion = ""
        assert.is_false(WGS:IsOutdated())
        WGS.db.global.serverMinAddonVersion = "0.0.1"
        WGS.version = "0.7.0-beta"
        assert.is_false(WGS:IsOutdated())
        WGS.db.global.serverMinAddonVersion = "99.0.0"
        assert.is_true(WGS:IsOutdated())
    end)
end)
