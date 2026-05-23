---@type GuildHall
local WGS = GuildHall

-- Peer-to-peer message transport for officer↔officer in-raid sync.
-- Pure functions only — fragmentation, reassembly, encoding. The
-- side-effectful bits (CHAT_MSG_ADDON listener, channel selection,
-- trust gate, dispatch to per-table merge fns) live in
-- Modules/PeerSync.lua so this file stays test-friendly.
--
-- Wire format per chunk (inside one addon-message):
--   WGS|<msgId>|<chunkIdx>/<chunkTotal>|<chunkPayload>
--
-- Full payload after concat + DecodeForWoWAddonChannel + DecompressDeflate
-- + FromJson is a delta object: { table = "loot", row = {...} }.
--
-- Constants:
--   MAX_CHUNK = 220 bytes of payload per addon-message (WoW caps the
--     whole message at 255; framing eats up ~20-25 bytes).
--   REASSEMBLY_TTL = 30 seconds after which a partial message is GC'd.

local PEER_FRAME_PREFIX  = "WGS"
local MAX_CHUNK          = 220
local REASSEMBLY_TTL     = 30

-- Reassembly state: buffer[sender][msgId] = {
--   chunks   = { [idx] = payloadStr, ... },
--   total    = N,
--   received = K,
--   expiresAt = unix timestamp,
-- }
-- Cleared by SweepExpired (called opportunistically by Decode).
local buffer = {}
-- Outgoing msgId counter, monotonic per session.
local msgCounter = 0

---------------------------------------------------------------------------
-- LibDeflate handle (lazy, shared with Encoder/Decoder via WGS._libDeflate)
---------------------------------------------------------------------------

local function GetLibDeflate()
    if WGS._libDeflate ~= nil then return WGS._libDeflate or nil end
    local ok, lib = pcall(LibStub, "LibDeflate")
    if ok and lib
       and type(lib.CompressDeflate) == "function"
       and type(lib.DecompressDeflate) == "function"
       and type(lib.EncodeForWoWAddonChannel) == "function"
       and type(lib.DecodeForWoWAddonChannel) == "function"
    then
        WGS._libDeflate = lib
        return lib
    end
    WGS._libDeflate = false
    return nil
end

---------------------------------------------------------------------------
-- Internals
---------------------------------------------------------------------------

local function fireError(source, err)
    if WGS.FireEvent then
        WGS:FireEvent("WGS_INTERNAL_ERROR", { source = source, error = tostring(err) })
    end
end

-- Generate a new 8-hex-char msgId. Uses the same djb2 hash the rest of
-- the addon uses for envelope checksums (Util/Base64.lua HashString).
-- The counter is incremented on every call so back-to-back broadcasts
-- from the same sender get distinct IDs even within the same second.
local function nextMsgId()
    msgCounter = msgCounter + 1
    local senderKey = WGS:GetPlayerKey() or "anon"
    return WGS:HashString(senderKey .. ":" .. msgCounter .. ":" .. tostring(time()))
end

-- Walk the reassembly buffer and drop partial messages whose expiresAt
-- is in the past. Called from Decode each invocation — cheap O(senders).
local function sweepExpired(now)
    for sender, msgs in pairs(buffer) do
        for msgId, state in pairs(msgs) do
            if state.expiresAt < now then
                msgs[msgId] = nil
            end
        end
        if next(msgs) == nil then
            buffer[sender] = nil
        end
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Encode a delta object into a list of chunk strings ready to be sent
-- over C_ChatInfo.SendAddonMessage. Returns nil + error on failure.
--
--   delta: { table = "<tableName>", row = {...} } or any JSON-serialisable table
--   returns: { chunkString1, chunkString2, ... }, nil    on success
--            nil, "reason"                                on failure
function WGS:EncodePeerMessage(delta)
    if type(delta) ~= "table" then
        return nil, "delta must be a table"
    end

    local lib = GetLibDeflate()
    if not lib then return nil, "LibDeflate not available" end

    local json = self:ToJson(delta)
    if not json then return nil, "ToJson failed" end

    local compressed = lib:CompressDeflate(json)
    if not compressed then return nil, "CompressDeflate failed" end

    local encoded = lib:EncodeForWoWAddonChannel(compressed)
    if not encoded then return nil, "EncodeForWoWAddonChannel failed" end

    local msgId = nextMsgId()
    local total = math.ceil(#encoded / MAX_CHUNK)
    if total == 0 then total = 1 end   -- empty payload still ships one (empty) chunk

    local chunks = {}
    for i = 1, total do
        local payload = encoded:sub((i - 1) * MAX_CHUNK + 1, i * MAX_CHUNK)
        chunks[i] = string.format("%s|%s|%d/%d|%s", PEER_FRAME_PREFIX, msgId, i, total, payload)
    end
    return chunks, nil
end

-- Receive one chunk from a sender. Returns the fully-decoded delta
-- table once the final chunk completes — nil otherwise. Out-of-order
-- arrival is fine; chunks are addressed by their explicit index.
--
--   senderKey: the sender's full character key ("Name-Realm")
--   chunkString: the raw addon-message payload as received
--   returns: delta table on completion, nil on partial / on error
function WGS:DecodePeerMessage(senderKey, chunkString)
    if type(senderKey) ~= "string" or senderKey == "" then
        fireError("PeerMessage.Decode", "missing senderKey")
        return nil
    end
    if type(chunkString) ~= "string" or chunkString == "" then
        fireError("PeerMessage.Decode", "empty chunk")
        return nil
    end

    sweepExpired(time())

    -- Parse the frame. Strict: anything that doesn't match the format
    -- is dropped silently (someone else's prefix-collision traffic).
    local msgId, idxStr, totalStr, payload =
        chunkString:match("^" .. PEER_FRAME_PREFIX .. "|([%w]+)|(%d+)/(%d+)|(.*)$")
    if not msgId then return nil end

    local idx, total = tonumber(idxStr), tonumber(totalStr)
    if not idx or not total or idx < 1 or total < 1 or idx > total then
        fireError("PeerMessage.Decode", "bad frame: " .. chunkString:sub(1, 40))
        return nil
    end

    -- Stash the chunk in the reassembly buffer.
    buffer[senderKey] = buffer[senderKey] or {}
    local state = buffer[senderKey][msgId]
    if not state then
        state = { chunks = {}, total = total, received = 0, expiresAt = time() + REASSEMBLY_TTL }
        buffer[senderKey][msgId] = state
    elseif state.total ~= total then
        -- Defence against a peer sending a re-using msgId with a different
        -- chunk count — drop the in-flight state and start fresh.
        state = { chunks = {}, total = total, received = 0, expiresAt = time() + REASSEMBLY_TTL }
        buffer[senderKey][msgId] = state
    end

    if state.chunks[idx] then
        -- Duplicate chunk — likely a retransmit. Idempotent: keep state.
        return nil
    end

    state.chunks[idx] = payload
    state.received = state.received + 1
    state.expiresAt = time() + REASSEMBLY_TTL

    if state.received < state.total then
        return nil   -- still waiting for more chunks
    end

    -- All chunks received — assemble + decode. Clear state up-front so
    -- a failure here doesn't leave a zombie entry.
    local parts = {}
    for i = 1, state.total do
        if not state.chunks[i] then
            -- Should be impossible (received == total checked above), but
            -- guard against accounting bugs.
            buffer[senderKey][msgId] = nil
            fireError("PeerMessage.Decode", "received count mismatch")
            return nil
        end
        parts[i] = state.chunks[i]
    end
    buffer[senderKey][msgId] = nil
    if next(buffer[senderKey]) == nil then buffer[senderKey] = nil end

    local encoded = table.concat(parts)

    local lib = GetLibDeflate()
    if not lib then
        fireError("PeerMessage.Decode", "LibDeflate not available at decode time")
        return nil
    end

    local compressed = lib:DecodeForWoWAddonChannel(encoded)
    if not compressed then
        fireError("PeerMessage.Decode", "DecodeForWoWAddonChannel failed")
        return nil
    end

    local json = lib:DecompressDeflate(compressed)
    if not json then
        fireError("PeerMessage.Decode", "DecompressDeflate failed")
        return nil
    end

    local delta = self:FromJson(json)
    if type(delta) ~= "table" then
        fireError("PeerMessage.Decode", "FromJson returned non-table")
        return nil
    end

    return delta
end

---------------------------------------------------------------------------
-- Test-only hooks (production code never calls these)
---------------------------------------------------------------------------

-- Drop all reassembly state. Production code only depends on the TTL
-- sweep; tests use this to keep cases isolated from each other.
function WGS:_PeerMessageResetBuffer()
    buffer = {}
    msgCounter = 0
end

-- Inspect current buffer size for assertions about GC behaviour.
function WGS:_PeerMessageBufferCount()
    local n = 0
    for _, msgs in pairs(buffer) do
        for _ in pairs(msgs) do n = n + 1 end
    end
    return n
end
