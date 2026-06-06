---@type GuildHall
local WGS = GuildHall

-- Tab/sub-view constants and shared frame helpers live in UI/UIHelpers.lua
-- under the private WGS._ui namespace. Per-tab Build/Refresh functions
-- register themselves into ui.tabs at file scope (UI/Tabs/*.lua);
-- this shell just walks the registry to build + dispatch.
local ui = WGS._ui

-- Tab indices used by the shell. Other tab IDs come through
-- ui.TAB_* directly at their lone call sites in SelectMainFrameTab.
local TAB_EVENTS = ui.TAB_EVENTS
local TAB_TEAMS  = ui.TAB_TEAMS
local TAB_SYNC   = ui.TAB_SYNC
local TAB_COUNT  = ui.TAB_COUNT
local TAB_NAMES  = ui.TAB_NAMES

local SelectSubView = ui.SelectSubView

local mainFrame = nil

---------------------------------------------------------------------------
-- Stale-data banner
---------------------------------------------------------------------------

-- Persistent banner across the top of the main frame when the last
-- platform import is more than STALE_AFTER seconds old. Officers
-- routinely forget to re-import; rosters / events / signups drift
-- silently and the addon's already-correct data quietly becomes
-- already-wrong. One line + a "Sync now" button that jumps to the
-- Sync tab so the fix is two clicks away.
--
-- lastImport == 0 means "never imported" (fresh install / freshly-
-- cleared profile). We don't show the banner in that case because
-- there's nothing useful to say — the empty Sync tab already explains.
local STALE_AFTER_SECONDS = 7 * 86400

local function UpdateStaleBanner(frame)
    if not frame.staleBanner then return end
    local lastImport = (WGS.db and WGS.db.global and WGS.db.global.lastImport) or 0
    local now = time()
    local stale = lastImport > 0 and (now - lastImport) > STALE_AFTER_SECONDS

    if stale then
        local daysAgo = math.floor((now - lastImport) / 86400)
        frame.staleBanner.text:SetText(string.format(
            "|cffffaa00\226\154\160 Data is %d days old.|r " ..
            "Re-import from guildhall.run to refresh signups, events, and rosters.",
            daysAgo))
        frame.staleBanner:Show()
    else
        frame.staleBanner:Hide()
    end

    -- Re-anchor tab contents so they don't overlap the banner when shown.
    -- The fixed-y anchor (TOPLEFT, f, TOPLEFT, 10, -35) used to live in
    -- CreateMainFrame's tab-content loop; this dynamic version restores
    -- the same geometry when stale=false and pushes content below the
    -- banner when stale=true.
    for i = 1, TAB_COUNT do
        local content = frame.tabContents and frame.tabContents[i]
        if content then
            content:ClearAllPoints()
            if stale then
                content:SetPoint("TOPLEFT", frame.staleBanner, "BOTTOMLEFT", -10, -4)
                content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 35)
            else
                content:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -35)
                content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 35)
            end
        end
    end
end

local function BuildStaleBanner(frame)
    local banner = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    banner:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -30)
    banner:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -30)
    banner:SetHeight(24)
    banner:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    banner:SetBackdropColor(0.4, 0.3, 0.05, 0.85)
    banner:SetBackdropBorderColor(1, 0.7, 0.1, 0.6)
    banner:Hide()

    banner.text = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    banner.text:SetPoint("LEFT", banner, "LEFT", 8, 0)
    banner.text:SetPoint("RIGHT", banner, "RIGHT", -90, 0)
    banner.text:SetJustifyH("LEFT")
    banner.text:SetWordWrap(false)

    local syncBtn = CreateFrame("Button", nil, banner, "UIPanelButtonTemplate")
    syncBtn:SetSize(80, 18)
    syncBtn:SetPoint("RIGHT", banner, "RIGHT", -4, 0)
    syncBtn:SetText("Sync now")
    syncBtn:SetScript("OnClick", function()
        WGS:SelectMainFrameTab(ui.TAB_SYNC)
    end)

    return banner
end

---------------------------------------------------------------------------
-- Tab switching
---------------------------------------------------------------------------

local function SelectTab(frame, tabIndex)
    for i = 1, TAB_COUNT do frame.tabContents[i]:Hide() end
    frame.tabContents[tabIndex]:Show()
    frame.selectedTab = tabIndex
    PanelTemplates_SetTab(frame, tabIndex)
    -- Re-check the stale banner on every tab switch so the freshness
    -- state stays current even if a long-lived main-frame session
    -- crossed the 7-day threshold between switches.
    UpdateStaleBanner(frame)
end

local function RefreshCurrentTab(frame)
    local tab = frame.selectedTab or TAB_EVENTS
    local entry = ui.tabs[tab]
    if entry and entry.refresh then
        entry.refresh(frame.tabContents[tab])
    end

    if frame.statusText then
        -- Only show the bar when there's something meaningful to say.
        -- The idle "Ready" text was misleading — it read like a raid-
        -- readiness signal, but actually meant "addon is loaded". The
        -- addon is always loaded when this frame is visible, so the
        -- text carried no information.
        if WGS:IsTrackingAttendance() then
            frame.statusText:SetText("|cff00ff00Attendance tracking active|r")
            frame.statusText:Show()
        else
            frame.statusText:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Current-team picker
--
-- The Get/SetCurrentTeamId API lives in Core.lua (pure db.profile state
-- + a WGS_CURRENT_TEAM_CHANGED event). The widget below is the title-bar
-- chrome that drives Set and reflects Get; it subscribes to the change
-- event so slash-command sets refresh the label without poking the
-- mainFrame upvalue from outside this file.
---------------------------------------------------------------------------

-- Resolve the display label for the current picker state. "Team: All ▾"
-- when no filter is active; "Team: <name> ▾" otherwise. Falls back to
-- the team id if the name lookup misses (shouldn't happen in practice —
-- GetCurrentTeamId already coerces orphans to nil — but keeps the
-- widget from breaking if the db is mid-import).
local function TeamPickerLabel()
    local id = WGS:GetCurrentTeamId()
    if not id then return "Team: All" end
    local teams = WGS.db and WGS.db.global and WGS.db.global.teams or {}
    for _, t in ipairs(teams) do
        if t.id == id then return "Team: " .. (t.name or tostring(id)) end
    end
    return "Team: " .. tostring(id)
end

-- Build the title-bar picker. Anchored to the LEFT of the CloseButton
-- (the X provided by BasicFrameTemplateWithInset). Plain text button
-- with a subtle border + hover highlight — NOT UIPanelButtonTemplate,
-- which is the chunky red Blizz button reserved for CTAs (per the
-- convention in BuildSubNav). The picker is a chooser, not an action.
local function BuildTeamPicker(parent)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(180, 22)
    -- BasicFrameTemplateWithInset's CloseButton sits at the top-right;
    -- pin our picker just to its left so the title text on the far left
    -- and the picker on the right read as the frame's two header items.
    btn:SetPoint("TOPRIGHT", parent.CloseButton or parent, "TOPLEFT", -2, -4)

    -- Subtle 1px border + faint dark fill so the hit-area reads as
    -- clickable without competing visually with the CTAs below.
    btn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    btn:SetBackdropColor(0, 0, 0, 0.35)
    btn:SetBackdropBorderColor(0.35, 0.35, 0.35, 0.8)

    btn:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    local hl = btn:GetHighlightTexture()
    if hl then hl:SetAlpha(0.25) end

    -- Label + chevron rendered as separate font strings so the label
    -- sits flush-left and the chevron sits flush-right inside the
    -- backdrop.
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", btn, "LEFT", 6, 0)
    label:SetPoint("RIGHT", btn, "RIGHT", -16, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetText(TeamPickerLabel())
    btn.label = label

    local chevron = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    chevron:SetPoint("RIGHT", btn, "RIGHT", -4, 0)
    chevron:SetText("|cffaaaaaav|r")

    local menu = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    menu:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    menu:SetBackdropColor(0, 0, 0, 0.95)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:Hide()
    menu.buttons = {}

    local function rebuildMenu()
        for _, b in ipairs(menu.buttons) do b:Hide() end
        local entries = { { id = nil, name = "All Teams" } }
        local teams = WGS.db and WGS.db.global and WGS.db.global.teams or {}
        for _, t in ipairs(teams) do
            entries[#entries + 1] = { id = t.id, name = t.name or ("Team " .. tostring(t.id)) }
        end

        local rowH = 20
        menu:SetSize(180, #entries * rowH + 8)
        menu:ClearAllPoints()
        menu:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)

        local currentId = WGS:GetCurrentTeamId()
        for i, entry in ipairs(entries) do
            local row = menu.buttons[i]
            if not row then
                row = CreateFrame("Button", nil, menu)
                row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.text:SetAllPoints()
                row.text:SetJustifyH("LEFT")
                menu.buttons[i] = row
            end
            row:SetSize(172, rowH)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -(i - 1) * rowH - 4)
            local prefix = (entry.id == currentId) and "  > " or "    "
            row.text:SetText(prefix .. entry.name)
            row:SetScript("OnClick", function()
                WGS:SetCurrentTeamId(entry.id)
                menu:Hide()
            end)
            row:Show()
        end
    end

    btn:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide(); return end
        rebuildMenu()
        menu:Show()
    end)

    -- Refresh hook used by SetCurrentTeamId so the label updates without
    -- a tab re-render. Keeps the menu hidden — slash commands shouldn't
    -- pop a UI dropdown open.
    return {
        button  = btn,
        menu    = menu,
        refresh = function()
            btn.label:SetText(TeamPickerLabel())
            if menu:IsShown() then rebuildMenu() end
        end,
    }
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

    -- "What's new" badge — appears to the right of the title when the
    -- running addon version is newer than db.profile.lastSeenVersion.
    -- Replaces the older PLAYER_ENTERING_WORLD modal pop, which fired
    -- on every login after an update and felt intrusive. Click → opens
    -- the modal + the dialog's "Got it" bumps lastSeenVersion which
    -- re-evaluates this badge to hidden on the next OnShow.
    f.whatsNewBadge = CreateFrame("Button", nil, f)
    f.whatsNewBadge:SetSize(110, 18)
    f.whatsNewBadge:SetPoint("LEFT", f.title, "RIGHT", 10, 0)
    local badgeFs = f.whatsNewBadge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    badgeFs:SetAllPoints(f.whatsNewBadge)
    badgeFs:SetJustifyH("LEFT")
    badgeFs:SetText("|cffffd100\226\152\133 What's new \226\134\146|r")
    f.whatsNewBadge:SetScript("OnEnter", function(self)
        badgeFs:SetText("|cffffe066\226\152\133 What's new \226\134\146|r")
    end)
    f.whatsNewBadge:SetScript("OnLeave", function(self)
        badgeFs:SetText("|cffffd100\226\152\133 What's new \226\134\146|r")
    end)
    f.whatsNewBadge:SetScript("OnClick", function()
        if WGS.ShowWhatsNew then WGS:ShowWhatsNew() end
    end)
    f.whatsNewBadge:Hide()

    -- Title-bar team picker. Sits left of the CloseButton; persists to
    -- db.profile.currentTeamId via WGS:SetCurrentTeamId. Tab readers
    -- pick it up via WGS:GetCurrentTeamId() on the next render. Stays in
    -- sync with non-widget setters (e.g. `/gh team`) by subscribing to
    -- WGS_CURRENT_TEAM_CHANGED, which Set fires.
    f.teamPicker = BuildTeamPicker(f)
    if WGS.RegisterCallback then
        WGS.RegisterCallback(f, "WGS_CURRENT_TEAM_CHANGED", function()
            if f.teamPicker and f.teamPicker.refresh then
                f.teamPicker.refresh()
            end
            if f:IsShown() then RefreshCurrentTab(f) end
        end)
    end

    -- Stale-data banner. Built once at frame creation; visibility +
    -- copy update through UpdateStaleBanner, which fires on tab switch
    -- and on every successful import (via WGS_IMPORT_APPLIED below).
    f.staleBanner = BuildStaleBanner(f)
    if WGS.RegisterCallback then
        WGS.RegisterCallback(f, "WGS_IMPORT_APPLIED", function()
            UpdateStaleBanner(f)
        end)
    end

    -- Live UI refresh dispatcher — single source of truth for which
    -- public events should re-render the visible tab. Each tab's
    -- `refresh` fn no-ops when its frame isn't visible, so off-screen
    -- events don't pay the cost. Adding a new tab doesn't require
    -- remembering to re-subscribe.
    if WGS.RegisterCallback then
        local refreshEvents = {
            "WGS_SIGNUP_EDITED",       -- Events Roster Mark-status
            "WGS_LOOT_EDITED",         -- Logs → Loot retag/delete
            "WGS_ATTENDANCE_EDITED",   -- Logs → Attendance rebind/remove/delete
            "WGS_SESSION_STARTED",     -- live-raid badges + Teams RosterCheck
            "WGS_SESSION_ENDED",       -- new attendance row + post-raid state
            "WGS_LOOT_RECORDED",       -- new drop appears in Logs → Loot
            "WGS_ENCOUNTER_RECORDED",  -- boss tag column on recent loot rows
            "WGS_RAID_COMP_SNAPSHOT",  -- Events planned-vs-actual diff
        }
        for _, ev in ipairs(refreshEvents) do
            WGS.RegisterCallback(f, ev, function()
                if f:IsShown() then RefreshCurrentTab(f) end
            end)
        end
    end

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

    -- Show the Events tab by default — after the event-centric rework
    -- it's the officer's daily driver (today's raid + signups + comp +
    -- boss notes all live there). Teams moves to position 2.
    SelectTab(f, TAB_EVENTS)
    f.tabContents[TAB_EVENTS]:Show()

    f:SetScript("OnShow", function(self)
        if self.teamPicker and self.teamPicker.refresh then
            self.teamPicker.refresh()
        end
        -- Re-check stale state on every OnShow so the banner appears
        -- if the data crossed the 7-day threshold while the main frame
        -- was hidden (tab switch already handles in-session updates).
        UpdateStaleBanner(self)
        -- Re-check the "What's new" badge — visible when the running
        -- version is newer than lastSeenVersion. Modal's "Got it" path
        -- bumps lastSeenVersion which flips this back to hidden.
        if self.whatsNewBadge then
            if WGS.HasUnreadWhatsNew and WGS:HasUnreadWhatsNew() then
                self.whatsNewBadge:Show()
            else
                self.whatsNewBadge:Hide()
            end
        end
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
                self.statusText:Show()
            else
                self.statusText:Hide()
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
        if tabIndex == TAB_TEAMS then
            SelectSubView(mainFrame.tabContents[TAB_TEAMS], subIndex, ui.TEAMS_SUB_COUNT)
        elseif tabIndex == ui.TAB_LOGS then
            SelectSubView(mainFrame.tabContents[ui.TAB_LOGS], subIndex, ui.LOGS_SUB_COUNT)
        end
    end
    RefreshCurrentTab(mainFrame)
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
