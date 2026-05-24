---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

---@class WGSLootModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("Loot", "AceEvent-3.0")

-- Item quality threshold (only track Epic+ by default)
local QUALITY_THRESHOLD = 4  -- Epic

-- Boss encounter tracking: stores the name of the last boss killed
-- so loot picked up shortly after can be attributed to that boss.
local lastBossName = ""
local bossNameTimer = nil

-- Build loot message patterns from WoW's global strings (locale-safe)
local function BuildLootPatterns()
    local function escape(s)
        return s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    end
    local function toPattern(globalStr)
        local pat = escape(globalStr)
        pat = pat:gsub("%%%%s", "(.+)")
        pat = pat:gsub("%%%%d", "(%%d+)")
        return pat
    end

    local patterns = {}
    -- "PlayerName receives loot: [Item]."
    if LOOT_ITEM then
        table.insert(patterns, { pattern = toPattern(LOOT_ITEM), selfLoot = false })
    end
    -- "PlayerName receives loot: [Item]x3."
    if LOOT_ITEM_MULTIPLE then
        table.insert(patterns, { pattern = toPattern(LOOT_ITEM_MULTIPLE), selfLoot = false })
    end
    -- "You receive loot: [Item]."
    if LOOT_ITEM_SELF then
        table.insert(patterns, { pattern = toPattern(LOOT_ITEM_SELF), selfLoot = true })
    end
    -- "You receive loot: [Item]x3."
    if LOOT_ITEM_SELF_MULTIPLE then
        table.insert(patterns, { pattern = toPattern(LOOT_ITEM_SELF_MULTIPLE), selfLoot = true })
    end

    -- Fallback English patterns if globals aren't available
    if #patterns == 0 then
        table.insert(patterns, { pattern = "(.+) receives? loot: (.+)", selfLoot = false })
        table.insert(patterns, { pattern = "You receive loot: (.+)", selfLoot = true })
    end

    return patterns
end

local lootPatterns = nil

function module:OnEnable()
    lootPatterns = BuildLootPatterns()
    self:RegisterEvent("CHAT_MSG_LOOT", "OnLootMessage")
    self:RegisterEvent("ENCOUNTER_START", "OnEncounterStart")
    self:RegisterEvent("ENCOUNTER_END", "OnEncounterEnd")
end

-- ENCOUNTER_START fires with: encounterID, encounterName, difficultyID, groupSize
function module:OnEncounterStart(_, encounterID, encounterName, difficultyID, groupSize)
    -- Auto-show boss notes if we have them imported and feature is enabled
    if encounterName and WGS.db.profile.showBossNotes then
        local notes = WGS:GetBossNotes(encounterName)
        if notes then
            WGS:ShowBossNotes(encounterName)
        end
    end
end

-- ENCOUNTER_END fires with: encounterID, encounterName, difficultyID, groupSize, success
function module:OnEncounterEnd(_, encounterID, encounterName, difficultyID, groupSize, success)
    if success == 1 then
        lastBossName = encounterName or ""
        -- Clear boss name after 30 seconds so trash loot is not tagged
        if bossNameTimer then
            bossNameTimer:Cancel()
        end
        bossNameTimer = C_Timer.NewTimer(30, function()
            lastBossName = ""
            bossNameTimer = nil
        end)

        local difficultyName = GetDifficultyInfo and GetDifficultyInfo(difficultyID) or nil

        -- Record the encounter kill for export to web platform
        local encounterEntry = {
            encounterID = encounterID,
            encounterName = encounterName or "",
            difficultyID = difficultyID or 0,
            difficultyName = difficultyName or "",
            groupSize = groupSize or 0,
            instance = GetInstanceInfo() or "Unknown",
            timestamp = WGS:GetTimestamp(),
            recordedBy = WGS:GetPlayerKey(),
        }
        table.insert(WGS.db.global.encounters, encounterEntry)
        WGS:FireEvent("WGS_ENCOUNTER_RECORDED", encounterEntry)

        -- Snapshot raid comp at kill time (deduped against last snapshot)
        WGS:SnapshotRaidComp({
            encounterID = encounterID,
            encounterName = encounterName,
            difficultyID = difficultyID,
            difficultyName = difficultyName,
        })

        -- MRT loot reconciliation: 5s after ENCOUNTER_END (gives the
        -- last CHAT_MSG_LOOT messages time to land in laggy raids) we
        -- walk VMRT.LootHistory.list and gap-fill any drops we missed.
        -- Skips silently when MRT isn't loaded.
        if WGS:HasAddon("MRT") then
            C_Timer.After(5, function()
                WGS:ReconcileLootFromMRT(encounterID)
            end)
        end
    end
end

function module:OnLootMessage(_, msg, ...)
    if not WGS.db.profile.autoTrackLoot then return end
    if not WGS:IsInAnyGroup() then return end

    -- Guild group filter
    if WGS.db.profile.guildGroupsOnly and not WGS:IsGuildGroup() then return end

    local player, itemLink = self:ParseLootMessage(msg)
    if not player or not itemLink then return end

    -- Ensure player has realm suffix for consistent naming with attendance data
    if player and not player:find("-") then
        player = player .. "-" .. (GetNormalizedRealmName() or "")
    end

    local itemID = self:GetItemIDFromLink(itemLink)
    if not itemID then return end

    local playerId = WGS:ResolvePlayerForCharacter(player)

    local itemName, _, itemQuality, itemLevel = C_Item.GetItemInfo(itemLink)

    -- If quality is known and below threshold, skip
    if itemQuality and itemQuality < QUALITY_THRESHOLD then return end

    local instanceName, _, difficultyID = GetInstanceInfo()

    -- Stamp the row with the active attendance session's team + event,
    -- if any. Lets the Logs → Loot UI filter by team without falling
    -- back to the date-window heuristic, and gives the platform an
    -- exact event link per loot row instead of having to reconstruct
    -- it from the timestamp.
    local ctx = WGS.GetCurrentAttendanceContext and WGS:GetCurrentAttendanceContext() or nil

    local entry = {
        timestamp = WGS:GetTimestamp(),
        player = player,
        playerId = playerId, -- nil if character not in player map
        itemLink = itemLink,
        itemID = itemID,
        itemName = itemName or "",
        itemQuality = itemQuality or 0,
        itemLevel = itemLevel or 0,
        instance = instanceName or "Unknown",
        difficulty = difficultyID or 0,
        boss = lastBossName,
        recordedBy = WGS:GetPlayerKey(),
        eventId  = ctx and ctx.eventId or nil,
        teamId   = ctx and ctx.teamId  or nil,
    }

    -- If item info wasn't cached, backfill after a short delay
    if not itemName then
        C_Timer.After(1, function()
            local name, _, quality, ilvl = C_Item.GetItemInfo(itemLink)
            if name then
                entry.itemName = name
                entry.itemQuality = quality or entry.itemQuality
                entry.itemLevel = ilvl or entry.itemLevel
                -- Remove if below threshold after all
                if quality and quality < QUALITY_THRESHOLD then
                    local loot = WGS.db.global.loot
                    for i = #loot, 1, -1 do
                        if loot[i] == entry then
                            table.remove(loot, i)
                            break
                        end
                    end
                    return -- Don't show distribution helper for sub-epic items
                end
            end
            -- Deferred: now that quality is confirmed, trigger distribution helper
            WGS:CheckLootDistribution(itemLink, itemID, player)
        end)
    else
        -- Quality was already known and passed threshold — trigger immediately
        WGS:CheckLootDistribution(itemLink, itemID, player)
    end

    table.insert(WGS.db.global.loot, entry)
    WGS:Print(string.format(L["LOOT_RECORDED"], itemLink, player))

    WGS:FireEvent("WGS_LOOT_RECORDED", entry)
end

function module:ParseLootMessage(msg)
    if not lootPatterns then return nil, nil end

    for _, pat in ipairs(lootPatterns) do
        if pat.selfLoot then
            -- Self-loot patterns: first capture is the item link
            local itemLink = msg:match(pat.pattern)
            if itemLink then
                return WGS:GetPlayerKey(), itemLink
            end
        else
            -- Other-player patterns: first capture is player name, second is item link
            local player, itemLink = msg:match(pat.pattern)
            if player and itemLink then
                return player, itemLink
            end
        end
    end
    return nil, nil
end

function module:GetItemIDFromLink(link)
    if not link then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

---------------------------------------------------------------------------
-- MRT loot reconciliation
---------------------------------------------------------------------------

-- How far back from "now" we trust an MRT loot row to belong to the
-- encounter that just ended. Big enough to absorb laggy MRT writes,
-- small enough to avoid pulling in loot from earlier pulls.
local MRT_LOOT_WINDOW_SECONDS = 300

-- Tolerance for "is this MRT row the same drop as one we already have".
-- 60s is generous — CHAT_MSG_LOOT and MRT's ENCOUNTER_LOOT_RECEIVED
-- usually fire within ~1s of each other; the window only matters when
-- the player's clock has drifted.
local MRT_LOOT_DEDUP_WINDOW = 60

--- Parse one MRT VMRT.LootHistory.list entry. Format (verified in
--- docs/INTEROP.md against akbyrd/method-raid-tools):
---   "timestamp#encounterID#instanceID#difficulty#playerName#classID#quantity#itemLink"
--- Returns a table with named fields, or nil if the row is malformed.
local function ParseMRTLootRow(s)
    if type(s) ~= "string" then return nil end
    -- Split on "#"; itemLink may contain "|" but never "#", so 8 segments
    local segs = {}
    for seg in s:gmatch("([^#]+)") do segs[#segs + 1] = seg end
    if #segs < 8 then return nil end

    local timestamp = tonumber(segs[1])
    local encounterID = tonumber(segs[2])
    if not timestamp or not encounterID then return nil end

    return {
        timestamp   = timestamp,
        encounterID = encounterID,
        instanceID  = tonumber(segs[3]) or 0,
        difficulty  = tonumber(segs[4]) or 0,
        player      = segs[5] or "",
        classID     = tonumber(segs[6]) or 0,
        quantity    = tonumber(segs[7]) or 1,
        itemLink    = segs[8] or "",
    }
end

--- Extract itemID from an item link. Used both for our existing rows
--- and for MRT-sourced rows so reconciliation compares apples to apples.
local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

--- Does our db.global.loot already contain a row matching this MRT
--- drop? Match by (itemID + player + timestamp ±60s). Player names
--- are compared with realm normalisation — our rows always carry the
--- realm suffix (OnLootMessage at line ~123) while MRT can store
--- either form depending on whether the drop was cross-realm.
local function HasExistingMatch(mrtRow)
    local existing = WGS.db.global.loot
    if not existing then return false end

    local mrtItemID = ItemIDFromLink(mrtRow.itemLink)
    if not mrtItemID then return false end

    local mrtPlayerShort = mrtRow.player:match("^([^%-]+)") or mrtRow.player

    for _, row in ipairs(existing) do
        if row.itemID == mrtItemID then
            local rowShort = (row.player or ""):match("^([^%-]+)") or row.player or ""
            if rowShort == mrtPlayerShort then
                local dt = math.abs((row.timestamp or 0) - mrtRow.timestamp)
                if dt <= MRT_LOOT_DEDUP_WINDOW then
                    return true
                end
            end
        end
    end
    return false
end

--- Walk VMRT.LootHistory.list for rows that belong to the encounter
--- that just ended, and insert any we don't already have into
--- db.global.loot tagged source = "mrt". Returns the count of
--- gap-filled rows (0 if nothing new). Idempotent: a second call for
--- the same encounter is a no-op because HasExistingMatch will now
--- find the rows we just inserted.
function WGS:ReconcileLootFromMRT(endedEncounterID)
    if not self:HasAddon("MRT") then return 0 end
    local vmrt = _G.VMRT
    local hist = vmrt and vmrt.LootHistory and vmrt.LootHistory.list
    if type(hist) ~= "table" then return 0 end

    local now = self:GetTimestamp()
    local windowStart = now - MRT_LOOT_WINDOW_SECONDS

    -- Stamp MRT gap-fill rows with the same attendance context as
    -- CHAT_MSG_LOOT rows so the Logs → Loot team filter applies
    -- uniformly across both capture sources.
    local ctx = WGS.GetCurrentAttendanceContext and WGS:GetCurrentAttendanceContext() or nil

    local added = 0
    for _, raw in ipairs(hist) do
        local row = ParseMRTLootRow(raw)
        if row
           and row.encounterID == endedEncounterID
           and row.timestamp >= windowStart
           and row.timestamp <= now
        then
            if not HasExistingMatch(row) then
                local itemID = ItemIDFromLink(row.itemLink) or 0
                local player = row.player
                if player ~= "" and not player:find("-") then
                    player = player .. "-" .. (GetNormalizedRealmName() or "")
                end
                local entry = {
                    timestamp   = row.timestamp,
                    player      = player,
                    playerId    = WGS:ResolvePlayerForCharacter(player),
                    itemLink    = row.itemLink,
                    itemID      = itemID,
                    itemName    = "",       -- MRT doesn't carry it; web hydrates from itemID
                    itemQuality = 0,        -- ditto; threshold check skipped (MRT pre-filtered)
                    itemLevel   = 0,
                    instance    = GetInstanceInfo() or "Unknown",
                    difficulty  = row.difficulty,
                    boss        = lastBossName,
                    recordedBy  = WGS:GetPlayerKey(),
                    source      = "mrt",    -- distinguishes gap-fill rows from CHAT_MSG_LOOT
                    eventId     = ctx and ctx.eventId or nil,
                    teamId      = ctx and ctx.teamId  or nil,
                }
                table.insert(WGS.db.global.loot, entry)
                WGS:FireEvent("WGS_LOOT_RECORDED", entry)
                added = added + 1
            end
        end
    end
    return added
end
