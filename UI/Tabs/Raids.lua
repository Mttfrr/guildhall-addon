---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Raids tab: four sub-views, all raid-flow data.
--   Raid Comp     — current planned comp for today's event (data via
--                   WGS:PopulateRaidComp in UI/RaidCompFrame.lua)
--   Readiness     — gear-readiness audit (WGS:PopulateReadiness in
--                   UI/ReadinessCheck.lua) + announce-to-raid button
--   Boss Notes    — per-boss notes panel with a custom dropdown
--                   (PopulateBossNotes in UI/BossNotesFrame.lua, plus
--                   MRTNotes read-through when MRT is loaded)
--   Loot History  — chronological list of captured loot drops with a
--                   search box. Moved here from the Bank tab — loot is
--                   raid-flow data, not bank-ledger data.
--
-- The Events sub-view that used to live here was promoted to a
-- top-level tab; see UI/Tabs/Events.lua.

local TAB_INDEX            = ui.TAB_RAIDS
local RAIDS_SUB_COMP       = ui.RAIDS_SUB_COMP
local RAIDS_SUB_READINESS  = ui.RAIDS_SUB_READINESS
local RAIDS_SUB_BOSSNOTES  = ui.RAIDS_SUB_BOSSNOTES
local RAIDS_SUB_LOOT       = ui.RAIDS_SUB_LOOT
local RAIDS_SUB_COUNT      = ui.RAIDS_SUB_COUNT
local RAIDS_SUB_NAMES      = ui.RAIDS_SUB_NAMES
local ClearContainer       = ui.ClearContainer
local CreateScrollContent  = ui.CreateScrollContent
local SelectSubView        = ui.SelectSubView
local BuildSubNav          = ui.BuildSubNav

local ITEM_QUALITY_COLORS = {
    [2] = "ff1eff00",
    [3] = "ff0070dd",
    [4] = "ffa335ee",
    [5] = "ffff8000",
    [6] = "ffe6cc80",
    [7] = "ff00ccff",
}

local function BuildBossNotesSubView(sv)
    local lbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, 0)
    lbl:SetText("Boss:")

    sv.dropBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.dropBtn:SetSize(250, 22)
    sv.dropBtn:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    sv.dropBtn:SetText("Select a boss...")
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
        if sv.dropMenu:IsShown() then
            sv.dropMenu:Hide()
            return
        end
        for _, btn in ipairs(sv.dropMenuButtons) do btn:Hide() end
        local bosses = WGS:GetBossNotesList()
        if #bosses == 0 then return end

        local bh = 22
        sv.dropMenu:SetSize(250, #bosses * bh + 8)
        sv.dropMenu:ClearAllPoints()
        sv.dropMenu:SetPoint("TOPLEFT", sv.dropBtn, "BOTTOMLEFT", 0, -2)

        for i, name in ipairs(bosses) do
            local btn = sv.dropMenuButtons[i]
            if not btn then
                btn = CreateFrame("Button", nil, sv.dropMenu)
                btn:SetSize(242, bh)
                btn:SetNormalFontObject("GameFontHighlightSmall")
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
                sv.selectedBoss = name
                sv.dropBtn:SetText(name)
                sv.dropMenu:Hide()
                WGS:PopulateBossNotes(sv, name)
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
    sv.noteText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sv.noteText:SetPoint("TOPLEFT", content, "TOPLEFT", 5, -5)
    sv.noteText:SetPoint("TOPRIGHT", content, "TOPRIGHT", -5, -5)
    sv.noteText:SetJustifyH("LEFT")
    sv.noteText:SetJustifyV("TOP")
    sv.noteText:SetWordWrap(true)
end

---------------------------------------------------------------------------
-- Loot History sub-view (moved from the Bank tab)
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

    local sorted = {}
    for i = #loot, 1, -1 do sorted[#sorted + 1] = loot[i] end

    local yOff = 0
    local shown = 0
    local MAX_ROWS = 200

    for _, entry in ipairs(sorted) do
        if shown >= MAX_ROWS then break end

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

            local qColor = ITEM_QUALITY_COLORS[entry.itemQuality or 4] or "ffa335ee"
            local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            itemText:SetPoint("LEFT", row, "LEFT", 5, 0)
            itemText:SetWidth(220)
            itemText:SetJustifyH("LEFT")
            itemText:SetText("|c" .. qColor .. (entry.itemName or "Unknown") .. "|r")

            local short = (entry.player or ""):match("^([^%-]+)") or entry.player or "?"
            local gi = roster[short]
            local pColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local playerText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            playerText:SetPoint("LEFT", itemText, "RIGHT", 4, 0)
            playerText:SetWidth(120)
            playerText:SetJustifyH("LEFT")
            playerText:SetText("|c" .. pColor .. short .. "|r")

            local bossText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            bossText:SetPoint("LEFT", playerText, "RIGHT", 4, 0)
            bossText:SetWidth(140)
            bossText:SetJustifyH("LEFT")
            local bossStr = entry.boss and entry.boss ~= "" and entry.boss or "\226\128\148"
            bossText:SetText("|cff888888" .. bossStr .. "|r")

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

local function BuildRaidsTab(parent)
    BuildSubNav(parent, RAIDS_SUB_NAMES, function(p, i)
        SelectSubView(p, i, RAIDS_SUB_COUNT)
        local sv = p.subViews[i]
        if i == RAIDS_SUB_COMP then
            WGS:PopulateRaidComp(sv)
        elseif i == RAIDS_SUB_READINESS then
            WGS:PopulateReadiness(sv)
        elseif i == RAIDS_SUB_BOSSNOTES then
            WGS:PopulateBossNotes(sv, sv.selectedBoss)
        elseif i == RAIDS_SUB_LOOT then
            PopulateLootHistory(sv)
        end
    end)

    -- Raid Comp sub-view
    local sv1 = parent.subViews[RAIDS_SUB_COMP]
    sv1.scrollFrame, sv1.content = CreateScrollContent(sv1)

    -- Readiness sub-view
    local sv2 = parent.subViews[RAIDS_SUB_READINESS]
    sv2.summary = sv2:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sv2.summary:SetPoint("TOPLEFT", sv2, "TOPLEFT", 5, 0)
    sv2.summary:SetWidth(660)
    sv2.summary:SetJustifyH("LEFT")

    local rsf = CreateFrame("ScrollFrame", nil, sv2, "UIPanelScrollFrameTemplate")
    rsf:SetPoint("TOPLEFT", sv2, "TOPLEFT", 0, -35)
    rsf:SetPoint("BOTTOMRIGHT", sv2, "BOTTOMRIGHT", -22, 30)
    local rc = CreateFrame("Frame", nil, rsf)
    rc:SetWidth(660)
    rc:SetHeight(1)
    rsf:SetScrollChild(rc)
    sv2.scrollFrame = rsf
    sv2.content = rc

    sv2.announceBtn = CreateFrame("Button", nil, sv2, "UIPanelButtonTemplate")
    sv2.announceBtn:SetSize(160, 26)
    sv2.announceBtn:SetPoint("BOTTOMLEFT", sv2, "BOTTOMLEFT", 5, 0)
    sv2.announceBtn:SetText("Announce to Raid")

    -- Boss Notes sub-view
    BuildBossNotesSubView(parent.subViews[RAIDS_SUB_BOSSNOTES])

    -- Loot History sub-view
    BuildLootHistorySubView(parent.subViews[RAIDS_SUB_LOOT])
    parent.subViews[RAIDS_SUB_LOOT]._refreshFn = function()
        PopulateLootHistory(parent.subViews[RAIDS_SUB_LOOT])
    end

    SelectSubView(parent, RAIDS_SUB_COMP, RAIDS_SUB_COUNT)
end

local function RefreshRaidsSubView(tab)
    if not tab or not tab:IsVisible() then return end
    local sub = tab.selectedSub or RAIDS_SUB_COMP
    local sv = tab.subViews[sub]
    if sub == RAIDS_SUB_COMP then
        WGS:PopulateRaidComp(sv)
    elseif sub == RAIDS_SUB_READINESS then
        WGS:PopulateReadiness(sv)
    elseif sub == RAIDS_SUB_BOSSNOTES then
        WGS:PopulateBossNotes(sv, sv.selectedBoss)
    elseif sub == RAIDS_SUB_LOOT then
        PopulateLootHistory(sv)
    end
end

ui.tabs[TAB_INDEX] = { build = BuildRaidsTab, refresh = RefreshRaidsSubView }
