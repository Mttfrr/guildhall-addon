---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

-- Tab/sub-view constants and shared frame helpers live in UI/UIHelpers.lua
-- under the private WGS._ui namespace. Aliased here so the per-tab
-- builder code reads the same as before the extraction.
local ui = WGS._ui

local TAB_DASHBOARD = ui.TAB_DASHBOARD
local TAB_ROSTER    = ui.TAB_ROSTER
local TAB_RAID      = ui.TAB_RAID
local TAB_LOOT      = ui.TAB_LOOT
local TAB_SYNC      = ui.TAB_SYNC
local TAB_COUNT     = ui.TAB_COUNT
local TAB_NAMES     = ui.TAB_NAMES

-- RAID_SUB_*, ROSTER_SUB_*, and LOOT_SUB_* constants moved to their
-- respective UI/Tabs/*.lua files along with the tabs themselves.

local SelectSubView      = ui.SelectSubView

local mainFrame = nil

---------------------------------------------------------------------------
-- Tab 7: Import/Export (stacked)
---------------------------------------------------------------------------

local function BuildSyncTab(parent)
    local midY = -245

    -- Import section
    local ih = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ih:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, 0)
    ih:SetText("|cffffd100Import from Web App|r")

    local ii = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ii:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -18)
    ii:SetText(L["IMPORT_PROMPT"])

    local isf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    isf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -35)
    isf:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -22, -35)
    isf:SetHeight(160)

    local ieb = CreateFrame("EditBox", nil, isf)
    ieb:SetMultiLine(true)
    ieb:SetAutoFocus(false)
    ieb:SetFontObject("ChatFontNormal")
    ieb:SetWidth(660)
    ieb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    isf:SetScrollChild(ieb)
    isf:EnableMouse(true)
    isf:SetScript("OnMouseDown", function() ieb:SetFocus() end)
    parent.importEditBox = ieb

    local btnImport = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnImport:SetSize(100, 25)
    btnImport:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -200)
    btnImport:SetText("Import")
    btnImport:SetScript("OnClick", function()
        local text = ieb:GetText()
        if text and text ~= "" then
            if WGS:DecodeAndImport(text) then
                ieb:SetText("")
                ieb:ClearFocus()
                WGS:RefreshMainFrame()
            end
        end
    end)

    local btnClearImport = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnClearImport:SetSize(80, 25)
    btnClearImport:SetPoint("LEFT", btnImport, "RIGHT", 8, 0)
    btnClearImport:SetText("Clear")
    btnClearImport:SetScript("OnClick", function()
        ieb:SetText("")
        ieb:SetFocus()
    end)

    -- Divider
    local div = parent:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, midY + 5)
    div:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -5, midY + 5)
    div:SetColorTexture(0.4, 0.4, 0.4, 0.5)

    -- Export section
    local eh = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    eh:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, midY)
    eh:SetText("|cffffd100Export Data|r")

    local ei = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ei:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, midY - 18)
    ei:SetText("Copy the text below and paste it into your guild web app.")

    local esf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    esf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, midY - 35)
    esf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 30)

    local eeb = CreateFrame("EditBox", nil, esf)
    eeb:SetMultiLine(true)
    eeb:SetAutoFocus(false)
    eeb:SetFontObject("ChatFontNormal")
    eeb:SetWidth(660)
    eeb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    esf:SetScrollChild(eeb)
    esf:EnableMouse(true)
    esf:SetScript("OnMouseDown", function() eeb:SetFocus() end)
    parent.exportEditBox = eeb

    local function runExport()
        local encoded = WGS:ExportAll()
        if encoded then
            eeb:SetText(encoded)
            eeb:SetFocus()
            eeb:HighlightText()
            WGS.db.global.lastExport = WGS:GetTimestamp()
            WGS:Print(L["EXPORT_COPIED"])
        end
    end

    -- Stash on the parent so WGS:PopulateExportEditBox can invoke it from
    -- anywhere (post-raid reminder → ShowExportFrame in particular).
    parent.runExport = runExport

    local btnExport = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnExport:SetSize(100, 25)
    btnExport:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 5, 0)
    btnExport:SetText("Export")
    btnExport:SetScript("OnClick", runExport)

    local btnSelectAll = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnSelectAll:SetSize(100, 25)
    btnSelectAll:SetPoint("LEFT", btnExport, "RIGHT", 8, 0)
    btnSelectAll:SetText("Select All")
    btnSelectAll:SetScript("OnClick", function()
        eeb:SetFocus()
        eeb:HighlightText()
    end)

    local btnClearExported = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnClearExported:SetSize(160, 25)
    btnClearExported:SetPoint("LEFT", btnSelectAll, "RIGHT", 8, 0)
    btnClearExported:SetText("Clear Exported Data")
    btnClearExported:SetScript("OnClick", function()
        StaticPopup_Show("WGS_CONFIRM_CLEAR_EXPORTED")
    end)
end

---------------------------------------------------------------------------
-- Tab switching
---------------------------------------------------------------------------

local function SelectTab(frame, tabIndex)
    for i = 1, TAB_COUNT do frame.tabContents[i]:Hide() end
    frame.tabContents[tabIndex]:Show()
    frame.selectedTab = tabIndex
    PanelTemplates_SetTab(frame, tabIndex)
end

local function RefreshCurrentTab(frame)
    local tab = frame.selectedTab or TAB_DASHBOARD
    -- Dispatch to the registered refresher. Tabs without a refresh
    -- function (e.g. Sync) are no-ops here — their content updates on
    -- explicit events instead.
    local entry = ui.tabs[tab]
    if entry and entry.refresh then
        entry.refresh(frame.tabContents[tab])
    end

    -- Status bar
    if frame.statusText then
        if WGS:IsTrackingAttendance() then
            frame.statusText:SetText("|cff00ff00Attendance tracking active|r")
        else
            frame.statusText:SetText("Ready")
        end
    end
end

---------------------------------------------------------------------------
-- Main frame creation
---------------------------------------------------------------------------

local function CreateMainFrame()
    local f = CreateFrame("Frame", "GuildHallMainFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(720, 580)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "GuildHallMainFrame")

    f.TitleBg:SetHeight(30)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", f.TitleBg, "TOPLEFT", 5, -3)
    f.title:SetText("GuildHall")

    -- Status bar
    f.statusBar = CreateFrame("Frame", nil, f)
    f.statusBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10)
    f.statusBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    f.statusBar:SetHeight(20)
    f.statusText = f.statusBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.statusText:SetPoint("LEFT")
    f.statusText:SetTextColor(0.5, 0.5, 0.5)

    -- Tab content frames
    f.tabContents = {}
    for i = 1, TAB_COUNT do
        local tab = CreateFrame("Button", "GuildHallMainFrameTab" .. i, f, "PanelTabButtonTemplate")
        tab:SetID(i)
        tab:SetText(TAB_NAMES[i])
        tab:SetScript("OnClick", function(self)
            SelectTab(f, self:GetID())
            RefreshCurrentTab(f)
        end)
        PanelTemplates_TabResize(tab, 0)
        if i == 1 then
            tab:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 5, -30)
        else
            tab:SetPoint("LEFT", "GuildHallMainFrameTab" .. (i - 1), "RIGHT", -14, 0)
        end

        local content = CreateFrame("Frame", nil, f)
        content:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -35)
        content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 35)
        content:Hide()
        f.tabContents[i] = content
    end

    PanelTemplates_SetNumTabs(f, TAB_COUNT)

    -- Build tab content. Per-tab builders live in UI/Tabs/*.lua and
    -- register themselves into ui.tabs at file scope. Tabs that
    -- haven't been extracted yet fall back to the legacy local
    -- builders below; each extraction commit removes its fallback.
    for i = 1, TAB_COUNT do
        local entry = ui.tabs[i]
        if entry and entry.build then
            entry.build(f.tabContents[i])
        elseif i == TAB_SYNC then
            BuildSyncTab(f.tabContents[i])
        end
    end

    -- Show first tab
    SelectTab(f, TAB_DASHBOARD)
    f.tabContents[TAB_DASHBOARD]:Show()

    -- Refresh on show + periodic ticker while visible
    f:SetScript("OnShow", function(self)
        RefreshCurrentTab(self)
    end)
    f:SetScript("OnUpdate", function(self, elapsed)
        self._tick = (self._tick or 0) + elapsed
        if self._tick < 2 then return end
        self._tick = 0
        if self:IsShown() and self.selectedTab == TAB_DASHBOARD then
            local entry = ui.tabs[TAB_DASHBOARD]
            if entry and entry.refresh then
                entry.refresh(self.tabContents[TAB_DASHBOARD])
            end
        end
        if self.statusText then
            if WGS:IsTrackingAttendance() then
                self.statusText:SetText("|cff00ff00Attendance tracking active|r")
            else
                self.statusText:SetText("Ready")
            end
        end
    end)

    f:Hide()
    return f
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function WGS:ToggleMainFrame()
    if not mainFrame then mainFrame = CreateMainFrame() end
    if mainFrame:IsShown() then mainFrame:Hide() else mainFrame:Show() end
end

function WGS:SelectMainFrameTab(tabIndex, subIndex)
    if not mainFrame then mainFrame = CreateMainFrame() end
    if not mainFrame:IsShown() then mainFrame:Show() end
    SelectTab(mainFrame, tabIndex)
    if subIndex then
        if tabIndex == TAB_RAID then
            SelectSubView(mainFrame.tabContents[TAB_RAID], subIndex, ui.RAID_SUB_COUNT)
        elseif tabIndex == TAB_ROSTER then
            SelectSubView(mainFrame.tabContents[TAB_ROSTER], subIndex, ui.ROSTER_SUB_COUNT)
        elseif tabIndex == TAB_LOOT then
            SelectSubView(mainFrame.tabContents[TAB_LOOT], subIndex, ui.LOOT_SUB_COUNT)
        end
    end
    RefreshCurrentTab(mainFrame)
end

function WGS:SelectBossInTab(encounterName)
    if not mainFrame then return end
    local raidTab = mainFrame.tabContents[TAB_RAID]
    if not raidTab then return end
    local sv = raidTab.subViews[ui.RAID_SUB_BOSSNOTES]
    if not sv then return end
    sv.selectedBoss = encounterName
    sv.dropBtn:SetText(encounterName)
    WGS:PopulateBossNotes(sv, encounterName)
end

function WGS:RefreshMainFrame()
    if mainFrame and mainFrame:IsShown() then
        RefreshCurrentTab(mainFrame)
    end
end

-- Programmatically run the Sync tab's export action — same effect as
-- clicking the Export button. Used by ShowExportFrame so the post-raid
-- reminder can land on the Sync tab with the string already in the box.
function WGS:PopulateExportEditBox()
    if not mainFrame then return end
    local syncTab = mainFrame.tabContents and mainFrame.tabContents[TAB_SYNC]
    if syncTab and syncTab.runExport then
        syncTab.runExport()
    end
end
