---@type GuildHall
local WGS = GuildHall

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

    -- Build tab content. Each tab file in UI/Tabs/*.lua registers
    -- itself into ui.tabs at file scope; the shell here just walks
    -- that registry. New tab = new file + new entry in UI.xml + a
    -- bump to ui.TAB_COUNT — no edits to this loop.
    for i = 1, TAB_COUNT do
        local entry = ui.tabs[i]
        if entry and entry.build then
            entry.build(f.tabContents[i])
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
