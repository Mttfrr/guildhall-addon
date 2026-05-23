---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Raids tab: three sub-views.
--   Raid Comp  — current planned comp for today's event (data via
--                WGS:PopulateRaidComp in UI/RaidCompFrame.lua)
--   Readiness  — gear-readiness audit (WGS:PopulateReadiness in
--                UI/ReadinessCheck.lua) + announce-to-raid button
--   Boss Notes — per-boss notes panel with a custom dropdown
--                (PopulateBossNotes in UI/BossNotesFrame.lua, plus
--                MRTNotes read-through when MRT is loaded)
--
-- The Events sub-view that used to live here was promoted to a
-- top-level tab; see UI/Tabs/Events.lua.

local TAB_INDEX            = ui.TAB_RAIDS
local RAIDS_SUB_COMP       = ui.RAIDS_SUB_COMP
local RAIDS_SUB_READINESS  = ui.RAIDS_SUB_READINESS
local RAIDS_SUB_BOSSNOTES  = ui.RAIDS_SUB_BOSSNOTES
local RAIDS_SUB_COUNT      = ui.RAIDS_SUB_COUNT
local RAIDS_SUB_NAMES      = ui.RAIDS_SUB_NAMES
local CreateScrollContent  = ui.CreateScrollContent
local SelectSubView        = ui.SelectSubView

local function SelectRaidsSubView(tab, index)
    SelectSubView(tab, index, RAIDS_SUB_COUNT)
end

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

local function BuildRaidsTab(parent)
    parent.subViews = {}
    parent.subButtons = {}
    parent.selectedSub = RAIDS_SUB_COMP

    local btnX = 0
    local btnW = math.floor(660 / RAIDS_SUB_COUNT) - 4
    for i = 1, RAIDS_SUB_COUNT do
        local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        btn:SetSize(btnW, 22)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", btnX, 0)
        btn:SetText(RAIDS_SUB_NAMES[i])
        btn:SetScript("OnClick", function() SelectRaidsSubView(parent, i) end)
        parent.subButtons[i] = btn
        btnX = btnX + btnW + 4
    end

    for i = 1, RAIDS_SUB_COUNT do
        local sv = CreateFrame("Frame", nil, parent)
        sv:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
        sv:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
        sv:Hide()
        parent.subViews[i] = sv
    end

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

    SelectRaidsSubView(parent, RAIDS_SUB_COMP)
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
    end
end

ui.tabs[TAB_INDEX] = { build = BuildRaidsTab, refresh = RefreshRaidsSubView }
