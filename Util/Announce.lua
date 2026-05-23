---@type GuildHall
local WGS = GuildHall

-- Centralised chat-output helpers. Anything user-facing that the addon
-- broadcasts via SendChatMessage funnels through here so the channel
-- selection, prefix, and chunking rules live in one place.
--
-- The 200-byte chunk cap matches WoW's per-message limit on regular
-- chat (255 minus ~50 for the speaker name + decorations). We chunk
-- lazily — short lines pass through unmodified; long lines are split
-- at the last whitespace before the limit, never mid-word.

local CHAT_LIMIT = 200
local PREFIX     = "[GuildHall] "

-- Send a single line, prefixed. No splitting. Returns true if the
-- send actually went out (i.e. the channel was reachable). Used by
-- short header lines like "Officer sync: probing peers on RAID…".
function WGS:SendChatLine(line, channel)
    if type(line) ~= "string" or line == "" then return false end
    channel = channel or self:GetGroupChannel()
    if not channel or not C_ChatInfo or not C_ChatInfo.SendChatMessage then return false end
    C_ChatInfo.SendChatMessage(PREFIX .. line, channel)
    return true
end

-- Send a list of payload lines as separate messages, each prefixed
-- with `[GuildHall]` and an optional `indent` (used for follow-up
-- lines under a header). Each line is independently chunked at the
-- 200-byte limit, splitting at whitespace where possible.
--
-- `lines` may be either:
--   - a list of strings (each becomes its own indented message)
--   - a single string (sent as one message, chunked if needed)
function WGS:SendChatChunked(lines, channel, indent)
    if not lines then return false end
    channel = channel or self:GetGroupChannel()
    if not channel or not C_ChatInfo or not C_ChatInfo.SendChatMessage then return false end
    indent = indent or "  "

    local list = type(lines) == "string" and { lines } or lines
    local maxBody = CHAT_LIMIT - #PREFIX - #indent

    for _, line in ipairs(list) do
        if type(line) == "string" and line ~= "" then
            local remaining = line
            while #remaining > maxBody do
                -- Split at the last whitespace before maxBody, falling
                -- back to a hard cut if the line is one long token.
                local cut = remaining:sub(1, maxBody):match("^(.*)%s%S*$") or remaining:sub(1, maxBody)
                C_ChatInfo.SendChatMessage(PREFIX .. indent .. cut, channel)
                remaining = remaining:sub(#cut + 1):gsub("^%s+", "")
            end
            if #remaining > 0 then
                C_ChatInfo.SendChatMessage(PREFIX .. indent .. remaining, channel)
            end
        end
    end
    return true
end

-- "Pack" a list of short tokens (typically character names) into the
-- minimum number of comma-joined chat lines that fit under the limit.
-- Returns the packed lines as a list ready for SendChatChunked. The
-- header is *not* included — call SendChatLine separately for that.
function WGS:PackChatTokens(tokens, separator)
    separator = separator or ", "
    local maxBody = CHAT_LIMIT - #PREFIX - 2   -- 2 for the indent
    local lines, current = {}, ""
    for _, t in ipairs(tokens or {}) do
        if type(t) == "string" and t ~= "" then
            if current == "" then
                current = t
            elseif #current + #separator + #t > maxBody then
                lines[#lines + 1] = current
                current = t
            else
                current = current .. separator .. t
            end
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    return lines
end
