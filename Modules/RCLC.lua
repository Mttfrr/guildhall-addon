---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

-- RCLootCouncil bridge. Two independent surfaces, each behind its own
-- profile toggle and both inert when RCLC isn't loaded (WGS:GetRCLC in
-- Util/Interop.lua is the gate):
--
--   * Award capture (rclcCapture) — subscribe to RCLC's "history" /
--     "delete_history" comms on its "RCLC" prefix. The ML broadcasts
--     every award decision to the whole raid (when its sendHistory
--     setting is on, default on), so EVERY GuildHall user in the raid
--     records the council's verdict — response text, votes, award
--     reason — onto the loot ledger, upgrading the CHAT_MSG_LOOT/MRT
--     row for the same drop in place when one exists.
--
--   * Wishlist injection (rclcWishlistColumn) — a "GuildHall" column on
--     RCLC's voting frame showing each candidate's imported wish
--     priority for the session's item, the player's own wish appended
--     to their roll window, and a per-item freshness share on our own
--     "GHall" prefix so the council sees the newest import in the raid
--     even when the ML's is stale.
--
-- Everything that touches RCLC internals runs inside pcall — an RCLC
-- version drifting its surface must degrade to a silent no-op, never
-- break GuildHall's load. Contract reference: docs/INTEROP.md
-- (verified against RCLootCouncil 3.23.0).

---@class WGSRCLCModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("RCLC", "AceEvent-3.0")

-- The shared Epic+ floor (WGS.LOOT_QUALITY_THRESHOLD, declared in
-- Modules/Loot.lua which loads before this file). Only applied on
-- fresh inserts when the item's quality is actually cached — 0 means
-- "uncached", tolerated like the MRT gap-fill path does.
local QUALITY_THRESHOLD = WGS.LOOT_QUALITY_THRESHOLD or 4

-- Shared "same drop" window (WGS.RCLC_AWARD_MATCH_WINDOW, declared in
-- Modules/Loot.lua): much wider than the MRT dedup window (60s)
-- because a council deliberates — the award routinely lands minutes
-- after the physical loot event. Loot.lua's chat capture applies the
-- same window for its award-arrived-first dedup.
local AWARD_MATCH_WINDOW = WGS.RCLC_AWARD_MATCH_WINDOW or 900

-- Our own comm prefix on RCLC's transport (Comms:GetSender auto-
-- registers it). Carries the "gh_wish" per-item wishlist share.
local GH_PREFIX = "GHall"

-- Priority label → weight. Labels are the platform's wishlist
-- vocabulary.
local PRIORITY_WEIGHT = { BiS = 4, High = 3, Medium = 2, Low = 1 }

--- Colour escape ("|cff…") for a priority label, derived at CALL time
--- from the canonical hex table in UI/UIHelpers.lua
--- (ui.PRIORITY_COLORS, stored WITHOUT the "|c" prefix). Modules load
--- before UI/, so the table can't be read at file scope — but every
--- caller here runs long after load (cell updates, roll windows).
--- Deriving instead of keeping a private "|cff…" copy is what prevents
--- the doubled-|c bug a same-form copy-paste across that boundary
--- produces. White fallback when UI isn't loaded (spec environments).
local function PriorityColorEscape(priority)
    local ui = WGS._ui
    local hex = ui and ui.PRIORITY_COLORS and ui.PRIORITY_COLORS[priority]
    return hex and ("|c" .. hex) or "|cffffffff"
end

---------------------------------------------------------------------------
-- HistoryEntry mapping
---------------------------------------------------------------------------

-- Thin aliases over the canonical helpers (WGS:ShortName in
-- Util/Roster.lua; WGS:ItemIDFromLink in Modules/Loot.lua — number
-- pass-through included). Note ShortName returns "" (not nil) for
-- absent input.
local function shortName(full)
    return WGS:ShortName(full)
end

local function ItemIDFromLink(link)
    return WGS:ItemIDFromLink(link)
end

--- HistoryEntry.instance is "InstanceName-DifficultyName" concatenated
--- with a bare hyphen (ml_core.lua). Difficulty names never contain a
--- hyphen, instance names can — split on the LAST one and keep the
--- instance part. Falls back to the whole string if no hyphen.
local function ParseInstanceName(instance)
    if type(instance) ~= "string" or instance == "" then return "Unknown" end
    local name = instance:match("^(.+)%-[^%-]*$")
    return name or instance
end

--- Award timestamp. entry.id is "<serverTime>-<counter>" stamped by the
--- ML at award time — the epoch prefix is the authoritative clock.
--- Fallback chain for malformed ids: entry.date ("YYYY/MM/DD", slashes,
--- UTC) + entry.time ("HH:MM:SS", UTC) via time{} — which interprets in
--- the local timezone, so this path can skew by the UTC offset; it only
--- runs when the id is broken. Last resort: now.
local function AwardTimestamp(entry)
    local id = entry and entry.id
    if type(id) == "string" then
        local epoch = tonumber(id:match("^(%d+)"))
        if epoch and epoch > 0 then return epoch end
    end
    if entry and type(entry.date) == "string" and type(entry.time) == "string" then
        local y, mo, d = entry.date:match("^(%d+)/(%d+)/(%d+)$")
        local h, mi, s = entry.time:match("^(%d+):(%d+):(%d+)$")
        if y and h then
            local ok, ts = pcall(time, {
                year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
            })
            if ok and type(ts) == "number" then return ts end
        end
    end
    if GetServerTime then return GetServerTime() end
    return WGS:GetTimestamp()
end

--- Map one RCLC HistoryEntry to a GuildHall loot row. The award-field
--- names (awardResponse / awardResponseId / awardIsReason / awardVotes /
--- rclcId) and source = "rclc" are a wire contract with the platform —
--- Sync/Encoder.lua's CleanLootForExport copies every field except
--- itemLink, so they reach the export automatically.
---
--- awardResponseId mirrors entry.responseID verbatim: a button index
--- for real responses, `reason.sort - 400` when isAwardReason, and a
--- string ("PL", "BONUS_ROLL") for RCLC's personal-loot modes. The
--- response TEXT is the durable label — see docs/INTEROP.md.
local function MapAward(winner, entry, opts)
    if type(winner) ~= "string" or winner == "" or type(entry) ~= "table" then return nil end
    local itemLink = entry.lootWon
    local itemID = ItemIDFromLink(itemLink)
    if not itemID then return nil end

    local player = winner
    if not player:find("-") then
        player = player .. "-" .. (GetNormalizedRealmName() or "")
    end

    -- Item info from the link when cached; ""/0 otherwise (the web
    -- hydrates from itemID, same tolerance as the MRT gap-fill rows).
    local itemName, itemQuality, itemLevel
    if C_Item and C_Item.GetItemInfo then
        local name, _, quality, ilvl = C_Item.GetItemInfo(itemLink)
        itemName, itemQuality, itemLevel = name, quality, ilvl
    end

    -- Live captures get the active attendance session's event/team
    -- stamp like every other capture source; backfilled history is
    -- from past raids, so no stamp.
    local ctx
    if not (opts and opts.backfill) then
        ctx = WGS.GetCurrentAttendanceContext and WGS:GetCurrentAttendanceContext() or nil
    end

    local ts = AwardTimestamp(entry)
    -- Pre-2.7 RCLC entries have no id; synthesize a stable stand-in
    -- from the timestamp so backfilling them stays idempotent.
    local awardId = entry.id ~= nil and tostring(entry.id) or (tostring(ts) .. "-x")

    return {
        timestamp   = ts,
        player      = player,
        playerId    = WGS:ResolvePlayerForCharacter(player),
        itemLink    = itemLink,
        itemID      = itemID,
        itemName    = itemName or "",
        itemQuality = itemQuality or 0,
        itemLevel   = itemLevel or 0,
        instance    = ParseInstanceName(entry.instance),
        difficulty  = entry.difficultyID or 0,
        boss        = entry.boss or "",
        recordedBy  = WGS:GetPlayerKey(),
        source      = "rclc",
        eventId     = ctx and ctx.eventId or nil,
        teamId      = ctx and ctx.teamId  or nil,
        awardResponse   = entry.response,
        awardResponseId = entry.responseID,
        awardIsReason   = entry.isAwardReason and true or nil,
        awardVotes      = entry.votes,
        rclcId          = winner .. "@" .. awardId,
    }
end

---------------------------------------------------------------------------
-- Award capture
---------------------------------------------------------------------------

--- Insert-or-upgrade one council award. Dedup order matters:
---   1. A row with the same rclcId → we've seen this exact award
---      (idempotent against comms re-delivery, the ML's double-fire of
---      RCMLLootHistorySend + "history", and backfill re-runs).
---   2. An unclaimed chat/MRT row for the same drop (itemID + short
---      player name, ±AWARD_MATCH_WINDOW) → UPGRADE in place: award
---      fields + rclcId land on the existing row, source stays as-is,
---      rev bumps so the WGS_LOOT_EDITED broadcast wins LWW on peers.
---   3. Otherwise a fresh insert (Epic+ floor when quality is cached).
--- Returns "added" | "updated" | "skipped".
function WGS:RecordRCLCAward(winner, entry, opts)
    local mapped = MapAward(winner, entry, opts)
    if not mapped then return "skipped" end
    local loot = self.db and self.db.global and self.db.global.loot
    if type(loot) ~= "table" then return "skipped" end

    for _, row in ipairs(loot) do
        if row.rclcId == mapped.rclcId then return "skipped" end
    end

    local short = shortName(mapped.player)
    for i, row in ipairs(loot) do
        if not row.rclcId
           and row.itemID == mapped.itemID
           and shortName(row.player) == short
           and math.abs((row.timestamp or 0) - mapped.timestamp) <= AWARD_MATCH_WINDOW
        then
            row.awardResponse   = mapped.awardResponse
            row.awardResponseId = mapped.awardResponseId
            row.awardIsReason   = mapped.awardIsReason
            row.awardVotes      = mapped.awardVotes
            row.rclcId          = mapped.rclcId
            row.rev             = (tonumber(row.rev) or 0) + 1
            -- Broadcast a snapshot, not the live row — the peer encode
            -- can run a beat later and must not see subsequent edits.
            local copy = {}
            for k, v in pairs(row) do copy[k] = v end
            self:FireEvent("WGS_LOOT_EDITED", { index = i, row = copy, kind = "award" })
            return "updated"
        end
    end

    -- Quality gate BEFORE the holder-row retirement below: a cached
    -- sub-Epic award used to delete the holder's chat row and then
    -- skip its own insert — net data loss for an award we weren't
    -- going to record anyway.
    if mapped.itemQuality > 0 and mapped.itemQuality < QUALITY_THRESHOLD then
        return "skipped"
    end

    -- Retail council flow: the boss drop lands on a random raider, the
    -- council votes, the holder trades the item to the winner. The chat
    -- capture recorded the HOLDER (entry.owner) — once the award names
    -- someone else, that row is a false ledger attribution: retire it
    -- through the tombstone path (quietly — no officer acted) so peers
    -- drop it too, and the winner's award row below stays the only one.
    --
    -- Owner-absent fallback: RCLC doesn't always populate entry.owner
    -- (older entries, some flows). The holder's chat row would then
    -- survive next to the award row. When exactly ONE un-award-tagged
    -- row for the same item sits in the window under a different
    -- player, that's the stray holder row — retire it. Two or more
    -- candidates means multiple copies of the item genuinely dropped;
    -- guessing which row is the holder's would risk deleting a real
    -- drop, so ambiguity leaves everything alone.
    local owner = entry.owner
    if type(owner) == "string" and owner ~= "" and shortName(owner) ~= short then
        local ownerShort = shortName(owner)
        for i, row in ipairs(loot) do
            if not row.rclcId
               and row.itemID == mapped.itemID
               and shortName(row.player) == ownerShort
               and math.abs((row.timestamp or 0) - mapped.timestamp) <= AWARD_MATCH_WINDOW
            then
                self:DeleteLootRow(i, { silent = true })
                break
            end
        end
    elseif owner == nil then
        local candidate, candidates = nil, 0
        for i, row in ipairs(loot) do
            if not row.rclcId
               and row.itemID == mapped.itemID
               and shortName(row.player) ~= short
               and math.abs((row.timestamp or 0) - mapped.timestamp) <= AWARD_MATCH_WINDOW
            then
                candidates = candidates + 1
                candidate = i
            end
        end
        if candidates == 1 then
            self:DeleteLootRow(candidate, { silent = true })
        end
    end

    table.insert(loot, mapped)
    self:FireEvent("WGS_LOOT_RECORDED", mapped)
    if not (opts and opts.backfill) then
        self:Print(string.format(L["RCLC_AWARD_RECORDED"], mapped.itemLink, mapped.player))
    end
    return "added"
end

--- ML retracted an award (delete_history comm, payload is the entry
--- id). rclcId is "<winner>@<id>" and the delete comm carries only the
--- id, so match by suffix across all winners, then route through the
--- existing DeleteLootRow machinery (tombstone + rev bump +
--- WGS_LOOT_EDITED kind="delete") so peers converge identically.
function WGS:HandleRCLCDeleteHistory(id)
    if id == nil then return false end
    local loot = self.db and self.db.global and self.db.global.loot
    if type(loot) ~= "table" then return false end
    local suffix = "@" .. tostring(id)
    for i, row in ipairs(loot) do
        if type(row.rclcId) == "string" and row.rclcId:sub(-#suffix) == suffix then
            return self:DeleteLootRow(i)
        end
    end
    return false
end

--- An officer edited an award's response in RCLC's history UI
--- (RCHistory_ResponseEdit — fires locally on the editing client).
--- Payload is the history frame's lib-st row: cols[3].args.id carries
--- the entry id, cols[6].args the post-edit { response, responseID }
--- (Modules/History/lootHistory.lua:1438-1540 in RCLC 3.23.0). The
--- entry id is the only durable handle — bail when it's absent.
--- isAwardReason isn't in the payload, so it's left untouched.
function WGS:HandleRCLCResponseEdit(data)
    if type(data) ~= "table" or type(data.cols) ~= "table" then return false end
    local idCell, respCell = data.cols[3], data.cols[6]
    local id = idCell and type(idCell.args) == "table" and idCell.args.id or nil
    local args = respCell and type(respCell.args) == "table" and respCell.args or nil
    if id == nil or not args then return false end
    local loot = self.db and self.db.global and self.db.global.loot
    if type(loot) ~= "table" then return false end
    local suffix = "@" .. tostring(id)
    for i, row in ipairs(loot) do
        if type(row.rclcId) == "string" and row.rclcId:sub(-#suffix) == suffix then
            row.awardResponse   = args.response
            row.awardResponseId = args.responseID
            row.rev             = (tonumber(row.rev) or 0) + 1
            local copy = {}
            for k, v in pairs(row) do copy[k] = v end
            self:FireEvent("WGS_LOOT_EDITED", { index = i, row = copy, kind = "award" })
            return true
        end
    end
    return false
end

--- Bulk-import RCLC's saved award history (/gh rclc import).
--- GetHistoryDB() → { ["Name-Realm"] = { entry, ... } }. Every entry
--- runs through the same map + dedup path as live capture (no
--- event/team stamp — past raids), so a re-run adds nothing. Returns
--- the count of rows added.
function WGS:ImportRCLCHistory()
    local rc = self:GetRCLC()
    if not rc then return 0 end
    local ok, hist = pcall(rc.GetHistoryDB, rc)
    if not ok or type(hist) ~= "table" then return 0 end
    local added = 0
    for winner, entries in pairs(hist) do
        if type(entries) == "table" then
            for _, entry in ipairs(entries) do
                if self:RecordRCLCAward(winner, entry, { backfill = true }) == "added" then
                    added = added + 1
                end
            end
        end
    end
    return added
end

---------------------------------------------------------------------------
-- Comms wiring
---------------------------------------------------------------------------

-- Live subscription handles, so a re-install (RCLC re-enabling wipes
-- every Comms subscription, ours included) can drop the old ones first
-- instead of stacking a second delivery per award.
local awardSubs = nil
local wishSubs = nil
local sendGH = nil

local function dropSubs(subs)
    if type(subs) ~= "table" then return end
    for _, s in ipairs(subs) do
        pcall(function() s:unsubscribe() end)
    end
end

--- Subscribe to RCLC's "history" / "delete_history" comms. Split from
--- OnEnable (PeerSync pattern) so specs can wire against a fake RCLC
--- without the AceModule lifecycle. Idempotent: re-installing replaces
--- the prior subscriptions. Returns true when wired.
function WGS:_RCLC_InstallAwardComms(rc)
    rc = rc or self:GetRCLC()
    if not rc then return false end
    local ok, err = pcall(function()
        local Comms = rc.Require("Services.Comms")
        dropSubs(awardSubs)
        awardSubs = Comms:BulkSubscribe(rc.PREFIXES.MAIN, {
            history = function(data)
                if type(data) ~= "table" then return end
                -- Payload is (winner, history_table); pin the arity so
                -- extra args can't slide into the opts parameter.
                local ok2, err2 = pcall(WGS.RecordRCLCAward, WGS, unpack(data, 1, 2))
                if not ok2 then
                    WGS:FireEvent("WGS_INTERNAL_ERROR", { source = "RCLC.history", error = tostring(err2) })
                end
            end,
            delete_history = function(data)
                if type(data) ~= "table" then return end
                local ok2, err2 = pcall(WGS.HandleRCLCDeleteHistory, WGS, unpack(data, 1, 1))
                if not ok2 then
                    WGS:FireEvent("WGS_INTERNAL_ERROR", { source = "RCLC.delete_history", error = tostring(err2) })
                end
            end,
        })
    end)
    if not ok then
        self:FireEvent("WGS_INTERNAL_ERROR", { source = "RCLC.InstallAwardComms", error = tostring(err) })
        return false
    end
    return true
end

--- Wire the "GHall" prefix: the gh_wish share subscription + our send
--- function. GetSender MUST come first — it auto-registers the custom
--- prefix that Comms:Subscribe asserts on. Idempotent like the award
--- install. Returns true when wired.
function WGS:_RCLC_InstallWishComms(rc)
    rc = rc or self:GetRCLC()
    if not rc then return false end
    local ok, err = pcall(function()
        local Comms = rc.Require("Services.Comms")
        sendGH = Comms:GetSender(GH_PREFIX)
        dropSubs(wishSubs)
        wishSubs = Comms:BulkSubscribe(GH_PREFIX, {
            gh_wish = function(data)
                if type(data) ~= "table" then return end
                local ok2, err2 = pcall(WGS._RCLC_NoteSharedWishes, WGS, unpack(data, 1, 3))
                if not ok2 then
                    WGS:FireEvent("WGS_INTERNAL_ERROR", { source = "RCLC.gh_wish", error = tostring(err2) })
                end
            end,
        })
    end)
    if not ok then
        self:FireEvent("WGS_INTERNAL_ERROR", { source = "RCLC.InstallWishComms", error = tostring(err) })
        return false
    end
    return true
end

---------------------------------------------------------------------------
-- Wishlist freshness share
---------------------------------------------------------------------------

-- Session-local overlay of wishes shared by peers with a fresher
-- platform import than ours: { [itemID] = { ts, wishes } }. Deliberately
-- not persisted — it exists to keep one council session honest, and the
-- next import supersedes it.
local sharedWishes = {}

--- Receive one item's wishes from a peer. Kept only when newer than
--- what the overlay already holds; the local-vs-overlay decision
--- happens at read time so a later import wins without cleanup.
function WGS:_RCLC_NoteSharedWishes(itemID, wishes, importedAt)
    itemID = tonumber(itemID)
    importedAt = tonumber(importedAt) or 0
    if not itemID or type(wishes) ~= "table" then return end
    local cur = sharedWishes[itemID]
    if cur and (cur.ts or 0) >= importedAt then return end
    sharedWishes[itemID] = { ts = importedAt, wishes = wishes }
end

--- Wishes for an item, preferring a peer-shared overlay strictly newer
--- than our own import.
function WGS:_RCLC_WishesForItem(itemID)
    local overlay = sharedWishes[itemID]
    local localTs = tonumber(self.db.global.wishlistImportedAt) or 0
    if overlay and (overlay.ts or 0) > localTs then
        return overlay.wishes
    end
    return self:GetWishlistForItem(itemID)
end

--- A single player's best wish for an item (highest priority wins when
--- the platform lists several). Short-name comparison — realm-suffix
--- presence varies between RCLC candidate names and the platform's
--- wishlist playerName, same rule the loot dedup paths use.
function WGS:_RCLC_WishForPlayer(itemID, playerName)
    local short = shortName(playerName)
    if short == "" or not itemID then return nil end
    local best
    for _, w in ipairs(self:_RCLC_WishesForItem(itemID) or {}) do
        if shortName(w.playerName) == short then
            if not best or (PRIORITY_WEIGHT[w.priority] or 0) > (PRIORITY_WEIGHT[best.priority] or 0) then
                best = w
            end
        end
    end
    return best
end

--- ML added an item to a session (RCMLAddItem) — broadcast that item's
--- wishes stamped with our import time so every receiver can overlay
--- them when fresher than its own import. Skips when we've never
--- imported (nothing authoritative to share).
function WGS:_RCLC_ShareWishesForItem(item)
    if not sendGH then return end
    local itemID = ItemIDFromLink(item)
    if not itemID then return end
    local importedAt = tonumber(self.db.global.wishlistImportedAt) or 0
    if importedAt <= 0 then return end
    local wishes = self:GetWishlistForItem(itemID)
    if not wishes or #wishes == 0 then return end
    pcall(sendGH, "group", "gh_wish", itemID, wishes, importedAt)
end

---------------------------------------------------------------------------
-- Voting-frame column
---------------------------------------------------------------------------

local votingColumnInstalled = false

local function currentSessionItemID(rc)
    local ok, itemID = pcall(function()
        local vf = rc:GetActiveModule("votingframe")
        local lootTable = rc:GetLootTable()
        local item = vf and lootTable and lootTable[vf:GetCurrentSession()]
        return item and item.itemID
    end)
    if ok then return itemID end
    return nil
end

--- Render a wish as "<Priority> +N.N%" — the priority in its canonical
--- colour, the Droptimizer gain (platform's per-wish simPct, when the
--- wisher imported a sim) dimmed-gold beside it. Shared by the voting
--- column cell and the roll-window annotation.
local function FormatWish(wish)
    local text = PriorityColorEscape(wish.priority) .. (wish.priority or "?") .. "|r"
    local pct = tonumber(wish.simPct)
    if pct then
        text = text .. string.format(" |cffffd100%+.1f%%|r", pct)
    end
    return text
end

--- lib-st DoCellUpdate for the "GuildHall" column. MUST always write
--- cols[column].value — lib-st sorts on it even for rows that were
--- never on screen. Body pcall-guarded per the module's contract: an
--- RCLC surface drift degrades this cell to "-", never a Lua error
--- inside RCLC's render loop.
local function WishCellUpdate(rowFrame, frame, data, cols, row, realrow, column, fShow)
    local text, weight = "-", 0
    local ok, err = pcall(function()
        local rc = WGS:GetRCLC()
        local rowData = data and data[realrow]
        local candidate = rowData and rowData.name
        local itemID = rc and currentSessionItemID(rc)
        local wish = (candidate and itemID) and WGS:_RCLC_WishForPlayer(itemID, candidate) or nil
        if wish then
            weight = PRIORITY_WEIGHT[wish.priority] or 0
            text = FormatWish(wish)
        end
    end)
    if not ok then
        WGS:FireEvent("WGS_INTERNAL_ERROR", { source = "RCLC.WishCellUpdate", error = tostring(err) })
    end
    if frame and frame.text then frame.text:SetText(text) end
    local rowData = data and data[realrow]
    if rowData and rowData.cols and rowData.cols[column] then
        rowData.cols[column].value = weight
    end
end

--- lib-st comparesort (`st` is the ScrollingTable). BiS=4 > High=3 >
--- Medium=2 > Low=1 > absent=0. pcall-guarded — a drifted lib-st
--- surface must yield a stable (false) comparison, not break RCLC's
--- sort pass.
local function WishCompareSort(st, rowa, rowb, sortbycol)
    local ok, result = pcall(function()
        local rc = WGS:GetRCLC()
        local itemID = rc and currentSessionItemID(rc)
        local function weightOf(rowIndex)
            local rowData = st:GetRow(rowIndex)
            local wish = (rowData and rowData.name and itemID)
                and WGS:_RCLC_WishForPlayer(itemID, rowData.name) or nil
            return wish and (PRIORITY_WEIGHT[wish.priority] or 0) or 0
        end
        local a, b = weightOf(rowa), weightOf(rowb)
        if a == b then return false end
        local column = st.cols[sortbycol]
        local direction = column.sort or column.defaultsort or 1
        if direction == 1 then return a < b end
        return a > b
    end)
    if not ok then
        WGS:FireEvent("WGS_INTERNAL_ERROR", { source = "RCLC.WishCompareSort", error = tostring(result) })
        return false
    end
    return result
end

--- Install the "GuildHall" column after "response" via RCLC's official
--- Column API (3.23+). The voting frame builds scrollCols inside RCLC's
--- own OnInitialize, which can land after ours — poll-retry once a
--- second, same approach as the wowaudit plugin. Gives up after 30
--- attempts (RCLC present but its voting frame never came up).
function WGS:_RCLC_InstallVotingColumn(rc, attempt)
    if votingColumnInstalled then return true end
    rc = rc or self:GetRCLC()
    if not rc then return false end
    local ok, done = pcall(function()
        local vf = rc:GetActiveModule("votingframe")
        if not (vf and vf.scrollCols and vf.AddColumn) then return false end
        if vf.GetColumnIndex and vf:GetColumnIndex("guildhall_wish") then return true end
        vf:AddColumn({
            colName      = "guildhall_wish",
            name         = "GuildHall",
            width        = 110,
            align        = "CENTER",
            DoCellUpdate = WishCellUpdate,
            comparesort  = WishCompareSort,
            sortnext     = "name",
        }, "response", "after")
        return true
    end)
    if ok and done then
        votingColumnInstalled = true
        return true
    end
    -- Bounded retry: at most 30 one-second pcall probes, then give up
    -- for the session. Deliberately NOT cancelled early on a failed
    -- probe — "voting frame not built yet" and "voting frame never
    -- coming" are indistinguishable from out here, and 30 cheap pcalls
    -- is an acceptable worst case for the RCLC-present-but-frame-absent
    -- corner.
    attempt = (attempt or 0) + 1
    if attempt < 30 and C_Timer and C_Timer.After then
        C_Timer.After(1, function() WGS:_RCLC_InstallVotingColumn(rc, attempt) end)
    end
    return false
end

---------------------------------------------------------------------------
-- Roll-frame annotation (the candidate's own loot window)
---------------------------------------------------------------------------

local lootFrameHooked = false
local hookedEntries = {}

--- Append the player's OWN wish for the entry's item to the itemLvl
--- line ("GH: BiS +4.2%" style — priority plus the Droptimizer gain
--- when the player's sim shipped one). Nothing when absent. Safe
--- against stacking: entry:Update rebuilds the itemLvl text from
--- scratch before our post-hook appends. pcall-guarded per the
--- module's contract — a drifted roll-entry shape must no-op, not
--- error inside RCLC's Update.
local function AnnotateRollEntry(rc, entry)
    local ok, err = pcall(function()
        if not (entry and entry.itemLvl and entry.item) then return end
        local session = entry.item.sessions and entry.item.sessions[1]
        local itemID
        if session then
            local ok2, lt = pcall(rc.GetLootTable, rc)
            itemID = ok2 and lt and lt[session] and lt[session].itemID or nil
        end
        itemID = itemID or ItemIDFromLink(entry.item.link)
        if not itemID then return end
        local wish = WGS:_RCLC_WishForPlayer(itemID, WGS:GetPlayerKey())
        if not wish then return end
        local text = entry.itemLvl:GetText() or ""
        entry.itemLvl:SetText(text .. "  |cffffd100GH:|r " .. FormatWish(wish))
    end)
    if not ok then
        WGS:FireEvent("WGS_INTERNAL_ERROR", { source = "RCLC.AnnotateRollEntry", error = tostring(err) })
    end
end

--- Hook the roll window's EntryManager (the wowaudit pattern, via
--- hooksecurefunc since GuildHall doesn't embed AceHook). GetEntry(item)
--- memoizes into entries[item], so the post-hook picks the entry up and
--- hooks its Update exactly once; the immediate annotate covers the
--- Update that already ran inside GetEntry before our hook existed.
--- Entries recycled through the trash pool stay hooked.
function WGS:_RCLC_HookLootFrame(rc)
    if lootFrameHooked then return true end
    rc = rc or self:GetRCLC()
    if not rc then return false end
    local ok = pcall(function()
        local lf = rc:GetActiveModule("lootframe")
        assert(lf and lf.EntryManager and lf.EntryManager.GetEntry, "lootframe EntryManager unavailable")
        hooksecurefunc(lf.EntryManager, "GetEntry", function(mgr, item)
            local entry = item and mgr.entries and mgr.entries[item]
            if not entry or hookedEntries[entry] then return end
            hookedEntries[entry] = true
            hooksecurefunc(entry, "Update", function(e) AnnotateRollEntry(rc, e) end)
            AnnotateRollEntry(rc, entry)
        end)
    end)
    if ok then lootFrameHooked = true end
    return lootFrameHooked
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function module:OnEnable()
    local profile = WGS.db and WGS.db.profile or {}
    if not profile.rclcCapture and not profile.rclcWishlistColumn then return end
    local rc = WGS:GetRCLC()
    if not rc then return end   -- no RCLC → zero-cost no-op

    if profile.rclcCapture then
        WGS:_RCLC_InstallAwardComms(rc)
        -- ML-side fallback: RCMLLootHistorySend fires on the ML's client
        -- even when its sendHistory setting is off (no comms broadcast
        -- then). With sendHistory on, both paths fire on the ML —
        -- rclcId idempotency absorbs the duplicate.
        self:RegisterMessage("RCMLLootHistorySend", "OnMLHistorySend")
        self:RegisterMessage("RCHistory_ResponseEdit", "OnResponseEdit")
    end

    if profile.rclcWishlistColumn then
        WGS:_RCLC_InstallWishComms(rc)
        self:RegisterMessage("RCMLAddItem", "OnMLAddItem")
        WGS:_RCLC_InstallVotingColumn(rc)
        WGS:_RCLC_HookLootFrame(rc)
    end

    -- RCLC's Comms:OnDisable wipes EVERY subscription on its transport
    -- (ours included). Re-wire when it comes back; the installs replace
    -- their old handles, so this can't stack double deliveries.
    -- Re-read db.profile at fire time — capturing the `profile` local
    -- would resurrect toggles the user has since switched off.
    pcall(hooksecurefunc, rc, "OnEnable", function()
        local p = WGS.db and WGS.db.profile or {}
        if p.rclcCapture then WGS:_RCLC_InstallAwardComms(rc) end
        if p.rclcWishlistColumn then WGS:_RCLC_InstallWishComms(rc) end
    end)
end

-- RCMLLootHistorySend args: (history_table, winner, responseID, boss,
-- reason, session, candData) — note the table comes FIRST, unlike the
-- comms payload's (winner, history_table).
function module:OnMLHistorySend(_, historyTable, winner)
    local ok, err = pcall(WGS.RecordRCLCAward, WGS, winner, historyTable)
    if not ok then
        WGS:FireEvent("WGS_INTERNAL_ERROR", { source = "RCLC.OnMLHistorySend", error = tostring(err) })
    end
end

function module:OnResponseEdit(_, data)
    local ok, err = pcall(WGS.HandleRCLCResponseEdit, WGS, data)
    if not ok then
        WGS:FireEvent("WGS_INTERNAL_ERROR", { source = "RCLC.OnResponseEdit", error = tostring(err) })
    end
end

function module:OnMLAddItem(_, item)
    local ok, err = pcall(WGS._RCLC_ShareWishesForItem, WGS, item)
    if not ok then
        WGS:FireEvent("WGS_INTERNAL_ERROR", { source = "RCLC.OnMLAddItem", error = tostring(err) })
    end
end

---------------------------------------------------------------------------
-- Test hooks
---------------------------------------------------------------------------

function WGS:_RCLC_ResetState()
    awardSubs = nil
    wishSubs = nil
    sendGH = nil
    sharedWishes = {}
    votingColumnInstalled = false
    lootFrameHooked = false
    hookedEntries = {}
end
