local helpers = require("spec.helpers")

-- Util/Announce.lua centralises the chat-output helpers used by the
-- Roster Check announce, the Readiness announce, and the new Events
-- detail action buttons. These specs lock in the prefix, the 200-byte
-- chunk rule, and the token-packing logic.

describe("WGS:SendChatLine", function()
    local WGS, sent
    before_each(function()
        WGS = helpers.setup()
        sent = {}
        _G.C_ChatInfo = {
            SendChatMessage = function(msg, channel)
                sent[#sent + 1] = { msg = msg, channel = channel }
            end,
        }
    end)

    it("prefixes the message with [GuildHall]", function()
        WGS:SendChatLine("hello", "RAID")
        assert.are.equal(1, #sent)
        assert.are.equal("[GuildHall] hello", sent[1].msg)
        assert.are.equal("RAID", sent[1].channel)
    end)

    it("returns false and sends nothing when given empty input", function()
        assert.is_false(WGS:SendChatLine("", "RAID"))
        assert.is_false(WGS:SendChatLine(nil, "RAID"))
        assert.are.equal(0, #sent)
    end)

    it("falls back to GetGroupChannel when channel is omitted", function()
        _G.IsInRaid = function() return true end
        assert.is_true(WGS:SendChatLine("hi"))
        assert.are.equal("RAID", sent[1].channel)
    end)

    it("returns false when no channel is reachable", function()
        _G.IsInRaid  = function() return false end
        _G.IsInGroup = function() return false end
        assert.is_false(WGS:SendChatLine("nope"))
    end)
end)

describe("WGS:SendChatChunked", function()
    local WGS, sent
    before_each(function()
        WGS = helpers.setup()
        sent = {}
        _G.C_ChatInfo = {
            SendChatMessage = function(msg, channel)
                sent[#sent + 1] = { msg = msg, channel = channel }
            end,
        }
    end)

    it("sends each line as its own message with the indent + prefix", function()
        WGS:SendChatChunked({ "first", "second", "third" }, "RAID")
        assert.are.equal(3, #sent)
        assert.are.equal("[GuildHall]   first",  sent[1].msg)
        assert.are.equal("[GuildHall]   second", sent[2].msg)
        assert.are.equal("[GuildHall]   third",  sent[3].msg)
    end)

    it("accepts a single string and chunks it if needed", function()
        local long = string.rep("a", 250)
        WGS:SendChatChunked(long, "RAID")
        -- The line is longer than the 200-byte cap minus prefix+indent,
        -- so it must come out as more than one message.
        assert.is_true(#sent >= 2, "expected the long line to be split")
        for _, s in ipairs(sent) do
            assert.is_true(#s.msg <= 200,
                "chunk exceeded the 200-byte cap: " .. #s.msg)
        end
    end)

    it("splits at whitespace when possible (no mid-word cuts)", function()
        local words = {}
        for i = 1, 40 do words[i] = "word" .. i end
        local line = table.concat(words, " ")     -- > 200 chars
        WGS:SendChatChunked(line, "RAID")
        -- Each chunk should begin and end with a complete word — i.e.
        -- never end mid-"wordN" (no trailing partial). Verify by
        -- checking each chunk's last whitespace-separated token is
        -- present in the original word list.
        for _, s in ipairs(sent) do
            local body = s.msg:gsub("^%[GuildHall%]%s+", "")
            local lastTok = body:match("(%S+)$")
            assert.is_truthy(lastTok)
            assert.is_truthy(lastTok:match("^word%d+$"),
                "chunk ended mid-word: '" .. tostring(lastTok) .. "'")
        end
    end)

    it("returns false and sends nothing when channel unreachable", function()
        _G.IsInRaid  = function() return false end
        _G.IsInGroup = function() return false end
        assert.is_false(WGS:SendChatChunked({ "x" }))
        assert.are.equal(0, #sent)
    end)
end)

describe("WGS:PackChatTokens", function()
    local WGS
    before_each(function() WGS = helpers.setup() end)

    it("packs short tokens into a single line when they fit", function()
        local lines = WGS:PackChatTokens({ "alice", "bob", "carol" })
        assert.are.equal(1, #lines)
        assert.are.equal("alice, bob, carol", lines[1])
    end)

    it("breaks across multiple lines when the cap is exceeded", function()
        local tokens = {}
        for i = 1, 50 do tokens[i] = "Player" .. i .. "Realm" end
        local lines = WGS:PackChatTokens(tokens)
        assert.is_true(#lines >= 2)
        for _, line in ipairs(lines) do
            -- Pack target = 200 - len(prefix) - 2 (indent) = ~186
            assert.is_true(#line <= 200)
        end
    end)

    it("uses a custom separator when provided", function()
        local lines = WGS:PackChatTokens({ "a", "b", "c" }, " | ")
        assert.are.equal("a | b | c", lines[1])
    end)

    it("returns an empty list for empty input", function()
        assert.are.equal(0, #WGS:PackChatTokens({}))
        assert.are.equal(0, #WGS:PackChatTokens(nil))
    end)

    it("ignores nil and empty-string tokens", function()
        local lines = WGS:PackChatTokens({ "alice", "", "bob" })
        assert.are.equal("alice, bob", lines[1])
    end)
end)
