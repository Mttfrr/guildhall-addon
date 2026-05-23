---@type GuildHall
local WGS = GuildHall

-- Tab/sub-view constants and shared frame helpers live in UI/UIHelpers.lua
-- under the private WGS._ui namespace. Per-tab Build/Refresh functions
-- register themselves into ui.tabs at file scope (UI/Tabs/*.lua);
-- this shell just walks the registry to build + dispatch.
local ui = WGS._ui

-- Tab indices used by the shell. Other tab IDs come through
-- ui.TAB_* directly at their lone call sites in SelectMainFrameTab.
local TAB_TEAMS  = ui.TAB_TEAMS
local TAB_RAIDS  = ui.TAB_RAIDS
local TAB_SYNC   = ui.TAB_SYNC
local TAB_COUNT  = ui.TAB_COUNT
local TAB_NAMES  = ui.TAB_NAMES

local SelectSubView = ui.SelectSubView

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
    local tab = frame.selectedTab or TAB_TEAMS
    local entry = ui.tabs[tab]
    if entry and entry.refresh then
        entry.refresh(frame.tabContents[tab])
    end

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

    -- Build tab content. Each UI/Tabs/*.lua registers into ui.tabs at
    -- file scope; the shell here just walks the registry. Adding a new
    -- tab = new file + new entry in UI.xml + bump ui.TAB_COUNT.
    for i = 1, TAB_COUNT do
        local entry = ui.tabs[i]
        if entry and entry.build then
            entry.build(f.tabContents[i])
        end
    end

    -- Show the Teams tab by default — it's the first thing officers /
    -- raiders care about (who's online, what's the comp).
    SelectTab(f, TAB_TEAMS)
    f.tabContents[TAB_TEAMS]:Show()

    f:SetScript("OnShow", function(self)
        RefreshCurrentTab(self)
    end)

    -- 2s status-bar ticker. Used to also re-render the Dashboard tab
    -- here (when one existed); now it only refreshes the status text.
    f:SetScript("OnUpdate", function(self, elapsed)
        self._tick = (self._tick or 0) + elapsed
        if self._tick < 2 then return end
        self._tick = 0
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
        if tabIndex == TAB_RAIDS then
            SelectSubView(mainFrame.tabContents[TAB_RAIDS], subIndex, ui.RAIDS_SUB_COUNT)
        elseif tabIndex == TAB_TEAMS then
            SelectSubView(mainFrame.tabContents[TAB_TEAMS], subIndex, ui.TEAMS_SUB_COUNT)
        end
    end
    RefreshCurrentTab(mainFrame)
end

function WGS:SelectBossInTab(encounterName)
    if not mainFrame then return end
    local raidsTab = mainFrame.tabContents[TAB_RAIDS]
    if not raidsTab then return end
    local sv = raidsTab.subViews[ui.RAIDS_SUB_BOSSNOTES]
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
