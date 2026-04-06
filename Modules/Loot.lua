---@type WoWGuildSync
local WGS = WoWGuildSync
local L = WoWGuildSync_L

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

        -- Record the encounter kill for export to web platform
        local difficultyName = GetDifficultyInfo and GetDifficultyInfo(difficultyID) or nil
        table.insert(WGS.db.global.encounters, {
            encounterID = encounterID,
            encounterName = encounterName or "",
            difficultyID = difficultyID or 0,
            difficultyName = difficultyName or "",
            groupSize = groupSize or 0,
            instance = GetInstanceInfo() or "Unknown",
            timestamp = WGS:GetTimestamp(),
            recordedBy = WGS:GetPlayerKey(),
        })
    end
end

function module:OnLootMessage(_, msg, ...)
    if not WGS.db.profile.autoTrackLoot then return end
    if not (IsInRaid() or IsInGroup()) then return end

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

    local itemName, _, itemQuality, itemLevel = C_Item.GetItemInfo(itemLink)

    -- If quality is known and below threshold, skip
    if itemQuality and itemQuality < QUALITY_THRESHOLD then return end

    local instanceName, _, difficultyID = GetInstanceInfo()
    local entry = {
        timestamp = WGS:GetTimestamp(),
        player = player,
        itemLink = itemLink,
        itemID = itemID,
        itemName = itemName or "",
        itemQuality = itemQuality or 0,
        itemLevel = itemLevel or 0,
        instance = instanceName or "Unknown",
        difficulty = difficultyID or 0,
        boss = lastBossName,
        recordedBy = WGS:GetPlayerKey(),
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
