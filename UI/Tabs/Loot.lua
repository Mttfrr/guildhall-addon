---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Loot tab: two sub-views.
--   History   — filtered list of captured loot drops (item / player /
--               boss / date), with a search box + count.
--   Wishlists — boss-filtered view of which characters wishlisted
--               which items, sorted by wisher count.

local TAB_INDEX           = ui.TAB_LOOT
local LOOT_SUB_HISTORY    = ui.LOOT_SUB_HISTORY
local LOOT_SUB_WISHLISTS  = ui.LOOT_SUB_WISHLISTS
local LOOT_SUB_COUNT      = ui.LOOT_SUB_COUNT
local LOOT_SUB_NAMES      = ui.LOOT_SUB_NAMES
local ClearContainer      = ui.ClearContainer
local SelectSubView       = ui.SelectSubView
local BuildSubNav         = ui.BuildSubNav

local ITEM_QUALITY_COLORS = {
    [2] = "ff1eff00",  -- Uncommon (green)
    [3] = "ff0070dd",  -- Rare (blue)
    [4] = "ffa335ee",  -- Epic (purple)
    [5] = "ffff8000",  -- Legendary (orange)
    [6] = "ffe6cc80",  -- Artifact (gold)
    [7] = "ff00ccff",  -- Heirloom
}

---------------------------------------------------------------------------
-- History sub-view
---------------------------------------------------------------------------

local function BuildLootHistorySubView(sv)
    local searchLbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    searchLbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -2)
    searchLbl:SetText("Filter:")

    local searchBox = CreateFrame("EditBox", nil, sv, "InputBoxTemplate")
    searchBox:SetSize(250, 22)
    searchBox:SetPoint("LEFT", searchLbl, "RIGHT", 10, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnTextChanged", function(self)
        sv.filterText = (self:GetText() or ""):lower()
        if sv._refreshFn then sv._refreshFn() end
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    sv.searchBox = searchBox

    local countText = sv:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countText:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)
    sv.countText = countText

    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -28)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
    sv.filterText = ""
end

local function PopulateLootHistory(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local loot = WGS.db.global.loot or {}
    local filter = tab.filterText or ""
    local roster = WGS:GetGuildRosterLookup()

    -- Sort by timestamp descending (newest first)
    local sorted = {}
    for i = #loot, 1, -1 do sorted[#sorted + 1] = loot[i] end

    local yOff = 0
    local shown = 0
    local MAX_ROWS = 200

    for _, entry in ipairs(sorted) do
        if shown >= MAX_ROWS then break end

        -- Apply filter
        local matches = filter == ""
        if not matches then
            local itemName = (entry.itemName or ""):lower()
            local player = (entry.player or ""):lower()
            local boss = (entry.boss or ""):lower()
            if itemName:find(filter, 1, true) or player:find(filter, 1, true) or boss:find(filter, 1, true) then
                matches = true
            end
        end

        if matches then
            local row = CreateFrame("Frame", nil, tab.content)
            row:SetSize(660, 18)
            row:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

            -- Item name (quality colored)
            local qColor = ITEM_QUALITY_COLORS[entry.itemQuality or 4] or "ffa335ee"
            local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            itemText:SetPoint("LEFT", row, "LEFT", 5, 0)
            itemText:SetWidth(220)
            itemText:SetJustifyH("LEFT")
            itemText:SetText("|c" .. qColor .. (entry.itemName or "Unknown") .. "|r")

            -- Player (class colored)
            local short = (entry.player or ""):match("^([^%-]+)") or entry.player or "?"
            local gi = roster[short]
            local pColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local playerText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            playerText:SetPoint("LEFT", itemText, "RIGHT", 4, 0)
            playerText:SetWidth(120)
            playerText:SetJustifyH("LEFT")
            playerText:SetText("|c" .. pColor .. short .. "|r")

            -- Boss
            local bossText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            bossText:SetPoint("LEFT", playerText, "RIGHT", 4, 0)
            bossText:SetWidth(140)
            bossText:SetJustifyH("LEFT")
            local bossStr = entry.boss and entry.boss ~= "" and entry.boss or "\226\128\148"
            bossText:SetText("|cff888888" .. bossStr .. "|r")

            -- Date
            local dateText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            dateText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            dateText:SetWidth(120)
            dateText:SetJustifyH("RIGHT")
            dateText:SetText("|cff555555" .. date("%m/%d %H:%M", entry.timestamp or 0) .. "|r")

            yOff = yOff - 18
            shown = shown + 1
        end
    end

    if shown == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText(filter == "" and "No loot recorded yet." or "No loot matching filter.")
        tab.content:SetHeight(30)
    else
        tab.content:SetHeight(math.abs(yOff) + 10)
    end

    tab.countText:SetText(string.format("|cff888888Showing %d of %d|r", shown, #loot))
end

---------------------------------------------------------------------------
-- Wishlists sub-view
---------------------------------------------------------------------------

local PRIORITY_ORDER = { BiS = 1, High = 2, Medium = 3, Low = 4 }
local PRIORITY_COLORS = {
    BiS    = "ffff8000",  -- Orange
    High   = "ffa335ee",  -- Purple
    Medium = "ff0070dd",  -- Blue
    Low    = "ff1eff00",  -- Green
}

local function BuildWishlistsSubView(sv)
    local lbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -2)
    lbl:SetText("Boss:")

    sv.dropBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.dropBtn:SetSize(280, 22)
    sv.dropBtn:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    sv.dropBtn:SetText("(All items)")
    sv.selectedBoss = nil

    sv.dropMenu = CreateFrame("Frame", nil, sv, "BackdropTemplate")
    sv.dropMenu:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    sv.dropMenu:SetBackdropColor(0, 0, 0, 0.95)
    sv.dropMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    sv.dropMenu:Hide()
    sv.dropMenuButtons = {}

    sv.dropBtn:SetScript("OnClick", function()
        if sv.dropMenu:IsShown() then sv.dropMenu:Hide(); return end

        for _, btn in ipairs(sv.dropMenuButtons) do btn:Hide() end

        local bossSet = {}
        for _, entry in ipairs(WGS.db.global.loot or {}) do
            if entry.boss and entry.boss ~= "" then bossSet[entry.boss] = true end
        end
        local bosses = { "(All items)" }
        for name in pairs(bossSet) do bosses[#bosses + 1] = name end
        table.sort(bosses, function(a, b)
            if a == "(All items)" then return true end
            if b == "(All items)" then return false end
            return a < b
        end)

        local bh = 22
        sv.dropMenu:SetSize(280, #bosses * bh + 8)
        sv.dropMenu:ClearAllPoints()
        sv.dropMenu:SetPoint("TOPLEFT", sv.dropBtn, "BOTTOMLEFT", 0, -2)

        for i, name in ipairs(bosses) do
            local btn = sv.dropMenuButtons[i]
            if not btn then
                btn = CreateFrame("Button", nil, sv.dropMenu)
                btn:SetSize(272, bh)
                btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                btn.text:SetAllPoints()
                btn.text:SetJustifyH("LEFT")
                sv.dropMenuButtons[i] = btn
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", sv.dropMenu, "TOPLEFT", 4, -(i - 1) * bh - 4)
            btn.text:SetText("  " .. name)
            btn:SetScript("OnClick", function()
                sv.selectedBoss = (name == "(All items)") and nil or name
                sv.dropBtn:SetText(name)
                sv.dropMenu:Hide()
                if sv._refreshFn then sv._refreshFn() end
            end)
            btn:Show()
        end
        sv.dropMenu:Show()
    end)

    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -28)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
end

local function PopulateWishlists(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local wishlists = WGS.db.global.wishlists or {}
    if #wishlists == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText("No wishlists imported. Import from web app first.")
        tab.content:SetHeight(30)
        return
    end

    -- Build item -> wishers map
    local itemWishers = {}  -- [itemID] = { { playerName, priority, note }, ... }
    local itemNames = {}    -- [itemID] = last-seen name (from loot history or wishlist entry)
    for _, entry in ipairs(wishlists) do
        if entry.items then
            for _, item in ipairs(entry.items) do
                if item.itemID then
                    itemWishers[item.itemID] = itemWishers[item.itemID] or {}
                    table.insert(itemWishers[item.itemID], {
                        playerName = entry.playerName,
                        priority = item.priority,
                        note = item.note,
                    })
                end
            end
        end
    end

    -- Fill item names from loot history
    for _, lootEntry in ipairs(WGS.db.global.loot or {}) do
        if lootEntry.itemID and lootEntry.itemName and not itemNames[lootEntry.itemID] then
            itemNames[lootEntry.itemID] = lootEntry.itemName
        end
    end
    -- Fill from C_Item cache for items we haven't seen drop
    for itemID in pairs(itemWishers) do
        if not itemNames[itemID] then
            local name = C_Item.GetItemInfo(itemID)
            if name then itemNames[itemID] = name end
        end
    end

    -- If a boss is selected, restrict to items seen dropping from that boss
    local allowedIds = nil
    if tab.selectedBoss then
        allowedIds = {}
        for _, lootEntry in ipairs(WGS.db.global.loot or {}) do
            if lootEntry.boss == tab.selectedBoss and lootEntry.itemID then
                allowedIds[lootEntry.itemID] = true
            end
        end
    end

    -- Collect items to render (sorted by wisher count descending, then itemID)
    local itemsToShow = {}
    for itemID, wishers in pairs(itemWishers) do
        if not allowedIds or allowedIds[itemID] then
            itemsToShow[#itemsToShow + 1] = { itemID = itemID, wishers = wishers }
        end
    end
    table.sort(itemsToShow, function(a, b)
        if #a.wishers ~= #b.wishers then return #a.wishers > #b.wishers end
        return a.itemID < b.itemID
    end)

    if #itemsToShow == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        if tab.selectedBoss then
            noData:SetText("No wishlisted items from " .. tab.selectedBoss .. " in loot history yet.")
        else
            noData:SetText("No wishlisted items found.")
        end
        tab.content:SetHeight(30)
        return
    end

    local roster = WGS:GetGuildRosterLookup()
    local yOff = 0

    for _, item in ipairs(itemsToShow) do
        -- Item header row
        local header = CreateFrame("Frame", nil, tab.content)
        header:SetSize(660, 20)
        header:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

        local headerText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        headerText:SetPoint("LEFT", header, "LEFT", 5, 0)
        local name = itemNames[item.itemID] or ("Item " .. item.itemID)
        headerText:SetText(string.format("|cffa335ee%s|r  |cff888888(%d wisher%s)|r",
            name, #item.wishers, #item.wishers == 1 and "" or "s"))
        yOff = yOff - 20

        -- Sort wishers by priority
        table.sort(item.wishers, function(a, b)
            return (PRIORITY_ORDER[a.priority] or 99) < (PRIORITY_ORDER[b.priority] or 99)
        end)

        for _, w in ipairs(item.wishers) do
            local row = CreateFrame("Frame", nil, tab.content)
            row:SetSize(660, 16)
            row:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

            local short = (w.playerName or ""):match("^([^%-]+)") or w.playerName or "?"
            local gi = roster[short]
            local pColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local pText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            pText:SetPoint("LEFT", row, "LEFT", 25, 0)
            pText:SetText("|c" .. pColor .. short .. "|r")

            local prColor = PRIORITY_COLORS[w.priority] or "ffffffff"
            local prText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            prText:SetPoint("LEFT", pText, "RIGHT", 10, 0)
            prText:SetText("|c" .. prColor .. (w.priority or "?") .. "|r")

            if w.note and w.note ~= "" then
                local nText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                nText:SetPoint("LEFT", prText, "RIGHT", 8, 0)
                nText:SetText("|cff888888(" .. w.note .. ")|r")
            end

            yOff = yOff - 16
        end

        yOff = yOff - 4
    end

    tab.content:SetHeight(math.abs(yOff) + 10)
end

---------------------------------------------------------------------------
-- Tab wiring
---------------------------------------------------------------------------

local function BuildLootTab(parent)
    BuildSubNav(parent, LOOT_SUB_NAMES, function(p, i)
        SelectSubView(p, i, LOOT_SUB_COUNT)
        if i == LOOT_SUB_HISTORY then
            PopulateLootHistory(p.subViews[i])
        elseif i == LOOT_SUB_WISHLISTS then
            PopulateWishlists(p.subViews[i])
        end
    end)
    BuildLootHistorySubView(parent.subViews[LOOT_SUB_HISTORY])
    BuildWishlistsSubView(parent.subViews[LOOT_SUB_WISHLISTS])

    -- Back-pointers used by the search box (History) and boss-dropdown
    -- (Wishlists). Lived in MainFrame.CreateMainFrame previously; moved
    -- here so the tab owns its own re-render wiring.
    parent.subViews[LOOT_SUB_HISTORY]._refreshFn = function()
        PopulateLootHistory(parent.subViews[LOOT_SUB_HISTORY])
    end
    parent.subViews[LOOT_SUB_WISHLISTS]._refreshFn = function()
        PopulateWishlists(parent.subViews[LOOT_SUB_WISHLISTS])
    end

    SelectSubView(parent, LOOT_SUB_HISTORY, LOOT_SUB_COUNT)
end

local function RefreshLootSubView(tab)
    if not tab or not tab:IsVisible() then return end
    local sub = tab.selectedSub or LOOT_SUB_HISTORY
    if sub == LOOT_SUB_HISTORY then
        PopulateLootHistory(tab.subViews[sub])
    elseif sub == LOOT_SUB_WISHLISTS then
        PopulateWishlists(tab.subViews[sub])
    end
end

ui.tabs[TAB_INDEX] = { build = BuildLootTab, refresh = RefreshLootSubView }
