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

-- Tables that participate in catch-up + their per-row timestamp field.
-- Listed here once so probe/offer/request all agree on the set.
local CATCHUP_TABLES = {
    loot            = "timestamp",
    attendance      = "startedAt",
    encounters      = "timestamp",
    raidCompResults = "startedAt",
}

-- Whole-payload catchup surface. Distinct from CATCHUP_TABLES because
-- events / teams / signups / etc. come from the platform as a single
-- import payload that wholesale-replaces the matching db.global fields
-- (see Modules/Import.lua), not as append-only row streams. We can't
-- diff them per-row without a server-side updatedAt, so the sync unit
-- is the entire import snapshot, version-stamped by db.global.lastImport.
--
-- SNAPSHOT_FIELDS is kept in lockstep with IMPORTERS in Modules/Import.lua —
-- if you add an importer there, add the corresponding db.global key here
-- so the snapshot exchange covers it. db.profile.guildWebId (inviteCode)
-- is intentionally omitted: each officer joins their own guild scope.
local SNAPSHOT_FIELDS = {
    "characters", "teams", "wishlists", "bossNotes", "raidComps",
    "events", "gearAudit", "characterDetails", "signups", "targetIlvl",
    "serverMinAddonVersion",
}

-- Two officers who imported the same platform dump within this window
-- count as equivalent — the per-officer lastImport stamps will differ by
-- a few seconds even when the underlying data is byte-identical, and
-- without a server-issued dump ID we can't tell apart "same dump, two
-- imports" from "two truly different dumps." A 30s grace prevents
-- thrashy re-imports on every catchup while still picking up genuinely
-- newer imports promptly. Revisit if the platform starts stamping the
-- payload with an exportId.
local SNAPSHOT_DEDUP_GRACE = 30

-- Catch-up tuning. The probe debounce keeps GROUP_ROSTER_UPDATE storms
-- from flooding the channel; the history cap stops a peer with months
-- of saved data from replaying everything on a fresh install.
local CATCHUP_DEBOUNCE        = 60        -- seconds between probes
local CATCHUP_OFFER_WAIT      = 5         -- seconds to collect offers before requesting
local CATCHUP_MAX_HISTORY     = 86400 * 7 -- never replay older than 7 days

local lastProbeAt    = 0
local catchupSession = nil   -- { startedAt, offers = { [peerKey] = { [tableName] = ts } } }

-- Per-session results, exposed via WGS:PeerSync_Status() for the UI.
-- Updated when a catchup round completes (processCatchupOffers).
local lastSyncAt     = 0     -- timestamp of the last completed probe round
local lastPeerCount  = 0     -- number of peers that replied to the last probe

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
    -- still-blocked item. Without a scheduler (test env), the throttle
    -- can't be enforced — there's nothing to drain the queue later —
    -- so just send everything inline. Production always has C_Timer.
    local canDefer = C_Timer and C_Timer.After
    local now = nowSeconds()
    local kept = {}
    local soonestWait
    for _, item in ipairs(outQueue) do
        local gap = CHANNEL_THROTTLE[item.channel] or 0
        local elapsed = now - (lastSendAt[item.channel] or 0)
        if not canDefer or elapsed >= gap then
            sendOne(item.channel, item.chunkStr)
            now = nowSeconds()
        else
            kept[#kept + 1] = item
            local wait = gap - elapsed
            if not soonestWait or wait < soonestWait then soonestWait = wait end
        end
    end
    outQueue = kept

    if #outQueue > 0 and soonestWait and canDefer and not flushScheduled then
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

    -- Dev-only loopback: re-feed each chunk through our own dispatch
    -- path so the developer can exercise the full encode → decode →
    -- merge → catch-up handshake round-trip from a single client,
    -- without bothering other officers with test broadcasts. Off by
    -- default; toggled via `/gh peerloopback` or `peerSyncLoopback`
    -- in saved variables.
    --
    -- We pass our own playerKey as senderKey (so the trust gate's
    -- guild-roster lookup naturally accepts us) and force isSelf =
    -- false to bypass the self-drop guard. The catch-up __probe /
    -- __offer / __request handlers then see "us" as a valid peer and
    -- complete the handshake against ourselves — including replaying
    -- table contents through the merge fns, which dedup against the
    -- rows already in db.global so no churn beyond the work itself.
    if WGS.db and WGS.db.profile and WGS.db.profile.peerSyncLoopback then
        local selfKey = self:GetPlayerKey()
        for _, c in ipairs(chunks) do
            self:PeerSync_HandleIncoming(selfKey, c, false)
        end
    end

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

---------------------------------------------------------------------------
-- Catch-up handshake (PROBE / OFFER / REQUEST)
--
-- An officer logging in mid-raid has none of the captures the others
-- have already broadcast. The catch-up flow gives them a way to pull
-- the missing rows without bothering anyone:
--
--   joiner  →  __probe         "what's everyone's max(timestamp) per table?"
--   peers   →  __offer         "mine are: { loot=ts, attendance=ts, ... }"
--   joiner  →  __request       "send me everything since ts for table X (peer Y)"
--   peer    →  normal deltas   (replayed via the existing PeerSync_Broadcast)
--
-- The reserved table names "__probe" / "__offer" / "__request" travel
-- through the existing encode / chunk / trust-gate path; the dispatcher
-- intercepts them before the per-table merge lookup. This way the wire
-- format stays unchanged and the trust gate (officer rank, in-guild)
-- governs catch-up the same way it governs deltas.
---------------------------------------------------------------------------

-- Largest row timestamp in db.global[tableName]. Used both to build
-- the local OFFER and to filter rows in REQUEST replay.
local function maxTimestampForTable(tableName)
    local rows = WGS.db and WGS.db.global and WGS.db.global[tableName]
    if type(rows) ~= "table" then return 0 end
    local tsField = CATCHUP_TABLES[tableName]
    if not tsField then return 0 end
    local maxTs = 0
    for _, row in ipairs(rows) do
        local ts = tonumber(row[tsField]) or 0
        if ts > maxTs then maxTs = ts end
    end
    return maxTs
end

-- Local snapshot stamp = the most recent successful platform import.
-- Zero means "we have nothing to offer for the snapshot exchange" —
-- a brand-new install with no imports yet.
local function getLocalSnapshotStamp()
    return (WGS.db and WGS.db.global and tonumber(WGS.db.global.lastImport)) or 0
end

-- Returns true if the peer's stamp is meaningfully newer than ours,
-- using SNAPSHOT_DEDUP_GRACE to absorb the common case of two officers
-- importing the same payload a few seconds apart.
local function isPeerSnapshotNewer(peerStamp, localStamp)
    if type(peerStamp) ~= "number" or peerStamp <= 0 then return false end
    return peerStamp > (localStamp + SNAPSHOT_DEDUP_GRACE)
end

local function buildLocalOffer()
    local offer = {}
    for tbl in pairs(CATCHUP_TABLES) do
        offer[tbl] = maxTimestampForTable(tbl)
    end
    -- Snapshot stamp piggybacks on the offer so the existing probe →
    -- offer → request handshake also covers whole-payload tables.
    offer.__snapshot = getLocalSnapshotStamp()
    return offer
end

local function handleProbe(senderKey)
    -- A peer is asking for our offer. Reply with our per-table maxes.
    -- The OFFER carries replyTo so the joiner knows which OFFERs are
    -- responses to their probe (peers see each other's OFFERs too).
    WGS:PeerSync_Broadcast("__offer", {
        replyTo = senderKey,
        maxes   = buildLocalOffer(),
    })
end

local function handleOffer(senderKey, row)
    -- Only listen to offers if we have an open catch-up session AND
    -- the offer is a reply to our probe. Otherwise it's another
    -- officer's catch-up traffic — ignore.
    if not catchupSession then return end
    if type(row) ~= "table" or type(row.maxes) ~= "table" then return end
    if row.replyTo ~= WGS:GetPlayerKey() then return end
    catchupSession.offers[senderKey] = row.maxes
end

-- Replay rows from a single table whose timestamp > `since`. Capped at
-- CATCHUP_MAX_HISTORY so a fresh joiner doesn't request the entire
-- history. Returns the number of rows broadcast.
local function replayTable(tableName, since)
    local rows = WGS.db and WGS.db.global and WGS.db.global[tableName]
    if type(rows) ~= "table" then return 0 end
    local tsField = CATCHUP_TABLES[tableName]
    if not tsField then return 0 end
    local floor = math.max(since or 0, (tonumber(time and time()) or 0) - CATCHUP_MAX_HISTORY)
    local sent = 0
    for _, row in ipairs(rows) do
        local ts = tonumber(row[tsField]) or 0
        if ts > floor then
            WGS:PeerSync_Broadcast(tableName, row)
            sent = sent + 1
        end
    end
    return sent
end

local function handleRequest(_senderKey, row)
    if type(row) ~= "table" then return end
    if row.target ~= WGS:GetPlayerKey() then return end   -- not addressed to us
    -- Whole-payload snapshot request: ship the current import payload
    -- back to the requester (broadcast — other stale officers benefit
    -- too). Distinct from the per-row replay path because the unit is
    -- a single big payload, not a stream of timestamped rows.
    if row.table == "__snapshot" then
        if getLocalSnapshotStamp() <= 0 then return end   -- nothing to share
        local payload = {}
        for _, field in ipairs(SNAPSHOT_FIELDS) do
            payload[field] = WGS.db.global[field]
        end
        WGS:PeerSync_Broadcast("__snapshot", {
            stamp   = getLocalSnapshotStamp(),
            payload = payload,
        })
        return
    end
    if not CATCHUP_TABLES[row.table] then return end       -- unknown table
    replayTable(row.table, tonumber(row.since) or 0)
end

-- Inspect collected OFFERs and send one REQUEST per table to the peer
-- with the highest remote max for that table. Idempotent across the
-- catch-up window — only called once when the offer-collection timeout
-- fires.
local function processCatchupOffers()
    if not catchupSession then return end
    local localMaxes = buildLocalOffer()
    for tbl in pairs(CATCHUP_TABLES) do
        local bestPeer, bestTs = nil, localMaxes[tbl] or 0
        for peer, offer in pairs(catchupSession.offers) do
            local ts = tonumber(offer[tbl]) or 0
            if ts > bestTs then bestPeer, bestTs = peer, ts end
        end
        if bestPeer then
            WGS:PeerSync_Broadcast("__request", {
                table  = tbl,
                since  = localMaxes[tbl] or 0,
                target = bestPeer,
            })
        end
    end

    -- Snapshot exchange: pick the peer with the freshest import stamp
    -- (if meaningfully newer than ours via the grace window) and ask
    -- them to broadcast their payload. Single request even if multiple
    -- peers are ahead — they'd all ship the same data.
    do
        local localStamp = getLocalSnapshotStamp()
        local bestPeer, bestStamp = nil, localStamp
        for peer, offer in pairs(catchupSession.offers) do
            local ts = tonumber(offer.__snapshot) or 0
            if isPeerSnapshotNewer(ts, bestStamp) then
                bestPeer, bestStamp = peer, ts
            end
        end
        if bestPeer then
            WGS:PeerSync_Broadcast("__request", {
                table  = "__snapshot",
                target = bestPeer,
            })
        end
    end

    -- Snapshot per-session results for the UI.
    local peerCount = 0
    for _ in pairs(catchupSession.offers) do peerCount = peerCount + 1 end
    lastSyncAt = tonumber(time and time()) or 0
    lastPeerCount = peerCount

    catchupSession = nil
end
WGS._PeerSync_ProcessCatchupOffers = processCatchupOffers   -- for tests

-- Public trigger. Called from GROUP_ROSTER_UPDATE on entering a raid,
-- or directly via /gh sync for manual recovery. Debounced so a
-- raid-frame storm can't flood the channel.
function WGS:PeerSync_Catchup()
    if not self:IsGuildOfficer() then return end
    if not self:PeerSync_PreferredChannel() then return end
    local now = tonumber(time and time()) or 0
    if now - lastProbeAt < CATCHUP_DEBOUNCE then return end
    lastProbeAt = now

    catchupSession = { startedAt = now, offers = {} }
    self:PeerSync_Broadcast("__probe", { from = self:GetPlayerKey() })

    if C_Timer and C_Timer.After then
        C_Timer.After(CATCHUP_OFFER_WAIT, processCatchupOffers)
    end
    -- Without a scheduler (test env), the caller drives via
    -- WGS._PeerSync_ProcessCatchupOffers when they're ready.
end

-- /gh sync entry point. Same as PeerSync_Catchup but bypasses the
-- 60s debounce — when an officer hits the command, they want
-- something to happen now. Returns a reason string when the request
-- is dropped (no officer rank, no channel) so the slash handler can
-- print it.
function WGS:PeerSync_ManualCatchup()
    if not self:IsGuildOfficer() then
        self:Print("Officer sync: needs guild officer rank (officer, GM, or assistant GM).")
        return
    end
    local channel = self:PeerSync_PreferredChannel()
    if not channel then
        self:Print("Officer sync: no eligible channel (need raid, party, or guild membership).")
        return
    end
    lastProbeAt = 0   -- force-bypass debounce
    self:Print("Officer sync: probing peers on " .. channel .. "…")
    self:PeerSync_Catchup()
end

-- Status snapshot for the UI (Sync tab's Officer Sync section). Returns
-- a single table so the caller can render every line without poking the
-- module's file-locals. All fields are read-only — flip the user-
-- override toggle via the existing Config UI.
--
--   isOfficer       — true iff IsGuildOfficer() right now
--   channel         — string or nil (RAID / PARTY / GUILD)
--   enabled         — effective enabled state (officer-default ∘ override)
--   lastSyncAt      — unix ts of the last completed catchup (0 if never)
--   lastPeerCount   — number of peers that replied to the last catchup
--   inFlight        — true iff a probe round is still collecting offers
function WGS:PeerSync_Status()
    local override = self.db and self.db.profile and self.db.profile.peerSyncEnabled
    local isOfficer = self:IsGuildOfficer()
    local effective
    if override == nil then effective = isOfficer
    else                     effective = override and true or false end
    return {
        isOfficer     = isOfficer,
        channel       = self:PeerSync_PreferredChannel(),
        enabled       = effective,
        lastSyncAt    = lastSyncAt,
        lastPeerCount = lastPeerCount,
        inFlight      = catchupSession ~= nil,
        -- Exposed so the Sync tab can show "import: 2h ago" alongside
        -- the peer-sync status. Snapshot exchange bumps this when a
        -- newer payload arrives from a peer, so it doubles as the
        -- visible signal that snapshot catchup worked.
        lastImportAt  = getLocalSnapshotStamp(),
    }
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

    -- Catch-up control messages: handled inline, no merge fn lookup.
    if delta.table == "__probe"   then return handleProbe(senderKey) end
    if delta.table == "__offer"   then return handleOffer(senderKey, delta.row) end
    if delta.table == "__request" then return handleRequest(senderKey, delta.row) end

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
-- Per-table merge functions
--
-- Each fn takes (row, senderKey) and returns one of "added", "updated",
-- "skipped". The contract is intentionally narrow: a merge fn touches
-- db.global.<table> directly (no re-firing of the capture event, which
-- would loop) and returns the action so WGS_PEER_SYNC_APPLIED subscribers
-- can decide whether to re-render.
--
-- Dedup keys come from the natural identity of each capture surface:
--   * loot:            (itemID, player short name) within a ±60s window,
--                      first-wins. Two officers seeing the same drop will
--                      record near-identical timestamps but may disagree
--                      on the realm suffix in `player` (cross-realm raids
--                      sometimes hand back the bare name to one client and
--                      the full name to another); short-name match handles
--                      that, the 60s window absorbs clock drift.
--   * attendance:      (startedAt, startedBy), first-wins. Sessions are
--                      immutable once endedAt is set; we don't yet deep-
--                      merge the memberList from another officer's view.
--   * encounters:      (encounterID, timestamp ±2s), first-wins. ENCOUNTER_END
--                      fires on every client within a second or two of the
--                      kill, so any two officers will agree on the same
--                      kill via that window.
--   * raidCompResults: (startedAt, signature), first-wins. Signature is
--                      already a stable hash of the slots list
--                      (Modules/Attendance.lua), so two officers capturing
--                      the same comp produce identical signatures.
---------------------------------------------------------------------------

local LOOT_DEDUP_WINDOW = 60      -- seconds
local ENCOUNTER_DEDUP_WINDOW = 2  -- seconds

local function shortName(full)
    if not full then return nil end
    return full:match("^([^%-]+)") or full
end

local function mergeLoot(row)
    if type(row) ~= "table" or not row.itemID or not row.player or not row.timestamp then
        return "skipped"
    end
    local loot = WGS.db and WGS.db.global and WGS.db.global.loot
    if not loot then return "skipped" end
    local incomingShort = shortName(row.player)
    for _, existing in ipairs(loot) do
        if existing.itemID == row.itemID
           and shortName(existing.player) == incomingShort
           and math.abs((existing.timestamp or 0) - row.timestamp) <= LOOT_DEDUP_WINDOW then
            return "skipped"
        end
    end
    loot[#loot + 1] = row
    return "added"
end

local function mergeAttendance(row)
    if type(row) ~= "table" or not row.startedAt then return "skipped" end
    local attendance = WGS.db and WGS.db.global and WGS.db.global.attendance
    if not attendance then return "skipped" end
    for _, existing in ipairs(attendance) do
        if existing.startedAt == row.startedAt
           and (existing.startedBy or "") == (row.startedBy or "") then
            return "skipped"
        end
    end
    attendance[#attendance + 1] = row
    return "added"
end

local function mergeEncounters(row)
    if type(row) ~= "table" or not row.encounterID or not row.timestamp then
        return "skipped"
    end
    local encs = WGS.db and WGS.db.global and WGS.db.global.encounters
    if not encs then return "skipped" end
    for _, existing in ipairs(encs) do
        if existing.encounterID == row.encounterID
           and math.abs((existing.timestamp or 0) - row.timestamp) <= ENCOUNTER_DEDUP_WINDOW then
            return "skipped"
        end
    end
    encs[#encs + 1] = row
    return "added"
end

local function mergeRaidCompResults(row)
    if type(row) ~= "table" or not row.startedAt or not row.signature then
        return "skipped"
    end
    local results = WGS.db and WGS.db.global and WGS.db.global.raidCompResults
    if not results then return "skipped" end
    for _, existing in ipairs(results) do
        if existing.startedAt == row.startedAt
           and existing.signature == row.signature then
            return "skipped"
        end
    end
    results[#results + 1] = row
    return "added"
end

-- Whole-payload snapshot merge. Distinct from the per-row merges above:
-- the incoming `row` is the entire import payload, and applying it
-- means running ProcessImport so all the normal import-side effects
-- (BuildCharacterLookup, WGS_IMPORT_APPLIED fire, etc.) happen.
--
-- Guards:
--   * Stamp check rejects payloads that aren't meaningfully newer than
--     ours (covers the cross-talk case where multiple officers respond
--     to one request, and the race where we just imported locally).
--   * No re-broadcast loop: PeerSync subscribes only to record-time
--     capture events (loot, session ended, etc.), not to
--     WGS_IMPORT_APPLIED, so the import triggered here doesn't echo
--     back onto the wire.
local function mergeSnapshot(row)
    if type(row) ~= "table" then return "skipped" end
    local incomingStamp = tonumber(row.stamp) or 0
    if not isPeerSnapshotNewer(incomingStamp, getLocalSnapshotStamp()) then
        return "skipped"
    end
    if type(row.payload) ~= "table" then return "skipped" end
    WGS:ProcessImport(row.payload)
    return "updated"
end

-- Exposed for tests to invoke directly without the full encode/decode trip.
WGS._PeerSync_MergeLoot            = mergeLoot
WGS._PeerSync_MergeAttendance      = mergeAttendance
WGS._PeerSync_MergeEncounters      = mergeEncounters
WGS._PeerSync_MergeRaidCompResults = mergeRaidCompResults
WGS._PeerSync_MergeSnapshot        = mergeSnapshot

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Register the standard four-table merge surface + subscribe to capture
-- events so locally-captured rows are broadcast to peers. Split out
-- from OnEnable so tests can wire the subscriptions without an
-- AceModule lifecycle.
function WGS:_PeerSync_InstallStandardWiring()
    self:PeerSync_RegisterMerge("loot",            mergeLoot)
    self:PeerSync_RegisterMerge("attendance",      mergeAttendance)
    self:PeerSync_RegisterMerge("encounters",      mergeEncounters)
    self:PeerSync_RegisterMerge("raidCompResults", mergeRaidCompResults)
    -- Snapshot is pull-only: peers ask for it when their lastImport
    -- lags ours by more than SNAPSHOT_DEDUP_GRACE, so no broadcast
    -- subscription needed here. The arrival path goes through the same
    -- merge-fn lookup as the row-stream tables.
    self:PeerSync_RegisterMerge("__snapshot",      mergeSnapshot)

    -- Each broadcast checks officer rank + channel availability
    -- internally — failure is a silent no-op so capture sites don't
    -- need to know whether sync is reachable right now.
    GuildHall.RegisterCallback(self, "WGS_LOOT_RECORDED", function(_, row)
        WGS:PeerSync_Broadcast("loot", row)
    end)
    GuildHall.RegisterCallback(self, "WGS_SESSION_ENDED", function(_, row)
        WGS:PeerSync_Broadcast("attendance", row)
    end)
    GuildHall.RegisterCallback(self, "WGS_ENCOUNTER_RECORDED", function(_, row)
        WGS:PeerSync_Broadcast("encounters", row)
    end)
    GuildHall.RegisterCallback(self, "WGS_RAID_COMP_SNAPSHOT", function(_, row)
        WGS:PeerSync_Broadcast("raidCompResults", row)
    end)
end

function module:OnEnable()
    -- Settings gate. Officers default-on, everyone else default-off;
    -- if the user has flipped it explicitly, respect that.
    local enabled = WGS.db and WGS.db.profile and WGS.db.profile.peerSyncEnabled
    if enabled == false then return end
    if enabled == nil and not WGS:IsGuildOfficer() then return end

    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PEER_FRAME_PREFIX)
    end
    self:RegisterEvent("CHAT_MSG_ADDON", "OnAddonMessage")
    -- GROUP_ROSTER_UPDATE fires on raid entry, member churn, and zone
    -- changes inside an instance. The 60s debounce inside
    -- PeerSync_Catchup keeps the noisy ones cheap; one probe per raid
    -- entry is what we actually care about.
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnGroupRosterUpdate")
    WGS:_PeerSync_InstallStandardWiring()
end

function module:OnGroupRosterUpdate()
    if not IsInRaid or not IsInRaid() then return end
    WGS:PeerSync_Catchup()
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
    lastProbeAt = 0
    catchupSession = nil
end

function WGS:_PeerSyncOutQueueCount() return #outQueue end

function WGS:_PeerSync_CatchupSession() return catchupSession end
