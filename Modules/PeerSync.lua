---@type GuildHall
local WGS = GuildHall

---@class WGSPeerSyncModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("PeerSync", "AceEvent-3.0")

-- Officer↔officer in-raid sync. Side-effectful glue around the pure
-- transport in Sync/PeerMessage.lua:
--
--   * channel selection (RAID > PARTY > GUILD)
--   * trust gate on incoming chunks (sender must be an officer)
--   * outgoing throttle (WoW silently drops on GUILD if we spam)
--   * dispatch of fully-decoded deltas to per-table merge fns
--     (registered by Phase 2 via WGS:PeerSync_RegisterMerge)
--
-- The transport and merge layers are split so this module can be
-- enabled/disabled wholesale via the settings toggle (Phase 4) without
-- the per-table call-sites needing to know.

local PEER_FRAME_PREFIX = "WGS"

-- Per-channel minimum gap between outbound sends, in seconds. WoW's
-- hidden global addon-channel rate-limit is roughly 10/s on RAID/PARTY
-- and ~1/s on GUILD; going faster than this causes silent message drops.
local CHANNEL_THROTTLE = {
    RAID    = 0.1,
    PARTY   = 0.1,
    GUILD   = 2.0,
}

-- Per-table merge functions. Phase 2 fills this in via
--   WGS:PeerSync_RegisterMerge("loot", function(row, senderKey) ... end)
-- A merge fn returns one of "added" | "updated" | "skipped" so the
-- WGS_PEER_SYNC_APPLIED event downstream UIs can react selectively.
local mergeFns = {}

-- Outbound queue + last-send timestamps per channel. Used by the
-- throttle path: when called faster than the channel allows, the
-- payload is queued and flushed on a C_Timer.After tail.
local outQueue = {}                    -- list of { channel, chunkStr }
local lastSendAt = {}                  -- { [channel] = unix-seconds }
local flushScheduled = false

---------------------------------------------------------------------------
-- Channel + permission
---------------------------------------------------------------------------

-- Highest-priority channel we can broadcast on right now, or nil if
-- we're solo and not in a guild (nothing to broadcast to).
function WGS:PeerSync_PreferredChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    if IsInGuild() then return "GUILD" end
    return nil
end

-- Is `senderKey` someone we accept peer-sync writes from? Mirrors the
-- IsGuildOfficer threshold (rank index ≤ 2) but on a remote sender.
-- Requires that the sender is in our guild — we trust guild rank as
-- the source of authority, consistent with the rest of the addon.
local function isOfficerSender(senderKey)
    if type(senderKey) ~= "string" or senderKey == "" then return false end
    if not IsInGuild() then return false end
    -- Strip realm: GetGuildRosterInfo returns "Name-Realm" for cross-realm
    -- guilds, "Name" for same-realm — normalise to "Name-Realm" both ways
    -- via the addon's existing helper.
    local total = GetNumGuildMembers() or 0
    for i = 1, total do
        local name, _, rankIndex = GetGuildRosterInfo(i)
        if name then
            local normalised = name
            if not normalised:find("-") then
                normalised = normalised .. "-" .. (GetNormalizedRealmName() or "")
            end
            if normalised == senderKey then
                return rankIndex ~= nil and rankIndex <= 2
            end
        end
    end
    return false
end
WGS._PeerSync_IsOfficerSender = isOfficerSender  -- exposed for tests

---------------------------------------------------------------------------
-- Outgoing
---------------------------------------------------------------------------

local function nowSeconds()
    return time()
end

local function sendOne(channel, chunkStr)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    C_ChatInfo.SendAddonMessage(PEER_FRAME_PREFIX, chunkStr, channel)
    lastSendAt[channel] = nowSeconds()
end

local function flushQueue()
    flushScheduled = false
    if #outQueue == 0 then return end

    -- Walk the queue: send anything whose channel-throttle has elapsed,
    -- requeue the rest, and schedule another flush for the soonest
    -- still-blocked item.
    local now = nowSeconds()
    local kept = {}
    local soonestWait
    for _, item in ipairs(outQueue) do
        local gap = CHANNEL_THROTTLE[item.channel] or 0
        local elapsed = now - (lastSendAt[item.channel] or 0)
        if elapsed >= gap then
            sendOne(item.channel, item.chunkStr)
            now = nowSeconds()
        else
            kept[#kept + 1] = item
            local wait = gap - elapsed
            if not soonestWait or wait < soonestWait then soonestWait = wait end
        end
    end
    outQueue = kept

    if #outQueue > 0 and soonestWait and C_Timer and C_Timer.After and not flushScheduled then
        flushScheduled = true
        C_Timer.After(soonestWait + 0.05, flushQueue)
    end
end

-- Encode `delta` (a per-table row payload) and broadcast it on the
-- preferred channel. Throttled per-channel so a flurry of loot drops on
-- GUILD doesn't get silently dropped by WoW's rate limit.
--
-- Returns true on enqueue, false + reason on early-out (wrong rank,
-- no channel, encoder failure). UI/Modules should treat false as
-- "don't bother, conditions aren't right" — not user-facing errors.
function WGS:PeerSync_Broadcast(tableName, row)
    if type(tableName) ~= "string" or tableName == "" then return false, "bad table" end
    if not self:IsGuildOfficer() then return false, "not officer" end
    local channel = self:PeerSync_PreferredChannel()
    if not channel then return false, "no channel" end

    local chunks, err = self:EncodePeerMessage({ table = tableName, row = row })
    if not chunks then
        self:FireEvent("WGS_INTERNAL_ERROR", { source = "PeerSync.Broadcast", error = err })
        return false, err
    end

    for _, c in ipairs(chunks) do
        outQueue[#outQueue + 1] = { channel = channel, chunkStr = c }
    end
    flushQueue()
    return true
end

---------------------------------------------------------------------------
-- Incoming
---------------------------------------------------------------------------

-- Register a merge function for `tableName`. Called by per-table
-- subscribers in Phase 2. Idempotent: re-registering replaces the
-- prior fn (useful during /reload).
function WGS:PeerSync_RegisterMerge(tableName, fn)
    if type(tableName) ~= "string" or type(fn) ~= "function" then return end
    mergeFns[tableName] = fn
end

function WGS:_PeerSync_GetMergeFn(tableName)
    return mergeFns[tableName]
end

-- Trust gate + dispatch for a single received chunk. Called by the
-- CHAT_MSG_ADDON listener in OnEnable, and directly by tests.
--
--   senderKey: normalised "Name-Realm" of the sender
--   chunkStr:  raw frame as received
--   isSelf:    boolean, true if the sender is us (loopback to drop)
function WGS:PeerSync_HandleIncoming(senderKey, chunkStr, isSelf)
    if isSelf then return end
    if not isOfficerSender(senderKey) then
        self:FireEvent("WGS_INTERNAL_ERROR", {
            source = "PeerSync.gate.rejected",
            error  = "non-officer: " .. tostring(senderKey),
        })
        return
    end

    local delta = self:DecodePeerMessage(senderKey, chunkStr)
    if not delta then return end   -- partial, malformed, or decode failure

    if type(delta) ~= "table" or type(delta.table) ~= "string" then
        self:FireEvent("WGS_INTERNAL_ERROR", {
            source = "PeerSync.dispatch",
            error  = "decoded payload missing table field",
        })
        return
    end

    local fn = mergeFns[delta.table]
    if not fn then
        -- No subscriber for this table yet — common during a rolling
        -- upgrade where one officer has Phase 2 wired and another
        -- doesn't. Drop silently rather than nag the user.
        return
    end

    local ok, action = pcall(fn, delta.row, senderKey)
    if not ok then
        self:FireEvent("WGS_INTERNAL_ERROR", {
            source = "PeerSync.merge." .. delta.table,
            error  = tostring(action),
        })
        return
    end

    self:FireEvent("WGS_PEER_SYNC_APPLIED", {
        table  = delta.table,
        row    = delta.row,
        action = action or "added",
        from   = senderKey,
    })
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function module:OnEnable()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PEER_FRAME_PREFIX)
    end
    self:RegisterEvent("CHAT_MSG_ADDON", "OnAddonMessage")
end

function module:OnAddonMessage(_, prefix, msg, _channel, sender)
    if prefix ~= PEER_FRAME_PREFIX then return end
    -- Normalise sender to "Name-Realm" so the trust gate's roster
    -- lookup matches regardless of WoW's same-realm short form.
    local senderKey = sender
    if senderKey and not senderKey:find("-") then
        senderKey = senderKey .. "-" .. (GetNormalizedRealmName() or "")
    end
    local isSelf = senderKey == WGS:GetPlayerKey()
    WGS:PeerSync_HandleIncoming(senderKey, msg, isSelf)
end

---------------------------------------------------------------------------
-- Test hooks
---------------------------------------------------------------------------

function WGS:_PeerSyncResetQueue()
    outQueue = {}
    lastSendAt = {}
    flushScheduled = false
    mergeFns = {}
end

function WGS:_PeerSyncOutQueueCount() return #outQueue end
