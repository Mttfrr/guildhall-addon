---@type GuildHall
local WGS = GuildHall

-- Private UI namespace shared across UI/MainFrame.lua and the per-tab
-- builders in UI/Tabs/*. Anything that more than one tab needs lives
-- here. Keep it small — public API on WGS:* should stay public.
WGS._ui = WGS._ui or {}
local ui = WGS._ui

---------------------------------------------------------------------------
-- Tab + sub-view constants
---------------------------------------------------------------------------

-- Tab order mirrors the platform layout: roster → bank → calendar →
-- raid tooling → sync settings. Dashboard tab was removed (its
-- summary tiles weren't pulling their weight) and Loot folded into
-- Bank (loot history is capture-log data, same as transactions)
-- and Teams (wishlists are per-player data).
ui.TAB_TEAMS  = 1
ui.TAB_BANK   = 2
ui.TAB_EVENTS = 3
ui.TAB_RAIDS  = 4
ui.TAB_SYNC   = 5
ui.TAB_COUNT  = 5
ui.TAB_NAMES  = { "Teams", "Bank", "Events", "Raids", "Import/Export" }

ui.TEAMS_SUB_TEAMS     = 1
ui.TEAMS_SUB_CHECK     = 2
ui.TEAMS_SUB_WISHLISTS = 3
ui.TEAMS_SUB_COUNT     = 3
ui.TEAMS_SUB_NAMES     = { "Teams", "Roster Check", "Wishlists" }

ui.BANK_SUB_LEDGER = 1
ui.BANK_SUB_LOOT   = 2
ui.BANK_SUB_COUNT  = 2
ui.BANK_SUB_NAMES  = { "Ledger", "Loot History" }

ui.RAIDS_SUB_COMP      = 1
ui.RAIDS_SUB_READINESS = 2
ui.RAIDS_SUB_BOSSNOTES = 3
ui.RAIDS_SUB_COUNT     = 3
ui.RAIDS_SUB_NAMES     = { "Raid Comp", "Readiness", "Boss Notes" }

---------------------------------------------------------------------------
-- Shared frame helpers
---------------------------------------------------------------------------

-- Hide every child + region of a container so the next populate-pass
-- starts with a blank slate. Used by Roster/Loot/etc. before
-- repopulating after a refresh.
function ui.ClearContainer(container)
    for _, child in ipairs({ container:GetChildren() }) do child:Hide() end
    for _, region in ipairs({ container:GetRegions() }) do region:Hide() end
end

-- Create a scrolling region pinned to the parent's edges (leaving
-- room for the scrollbar). Returns (scrollFrame, content) — the
-- caller attaches widgets to `content`.
function ui.CreateScrollContent(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    return sf, content
end

-- Generic sub-view selector. Hides all sub-views, shows the selected
-- one, and updates button font weight to indicate selection.
function ui.SelectSubView(tab, index, count)
    for i = 1, count do
        tab.subViews[i]:Hide()
        if tab.subButtons[i] then
            tab.subButtons[i]:SetNormalFontObject("GameFontNormalSmall")
        end
    end
    tab.subViews[index]:Show()
    if tab.subButtons[index] then
        tab.subButtons[index]:SetNormalFontObject("GameFontHighlightSmall")
    end
    tab.selectedSub = index
end

-- Build a sub-navigation row across the top of a tab plus N sub-view
-- frames. onSelect(tab, index) is called when a sub-button is clicked.
function ui.BuildSubNav(parent, names, onSelect)
    parent.subButtons = {}
    parent.subViews = {}
    parent.selectedSub = 1
    local count = #names
    local btnW = math.floor(660 / count) - 4
    local btnX = 0
    for i = 1, count do
        local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        btn:SetSize(btnW, 22)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", btnX, 0)
        btn:SetText(names[i])
        btn:SetScript("OnClick", function() onSelect(parent, i) end)
        parent.subButtons[i] = btn
        btnX = btnX + btnW + 4
    end
    for i = 1, count do
        local sv = CreateFrame("Frame", nil, parent)
        sv:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
        sv:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
        sv:Hide()
        parent.subViews[i] = sv
    end
end

---------------------------------------------------------------------------
-- Per-tab builder registry
--
-- Each tab file (UI/Tabs/*.lua) registers itself via
--   ui.tabs[ui.TAB_X] = { build = fn(parent), refresh = fn(tab) }
-- MainFrame.lua walks this table in CreateMainFrame / RefreshCurrentTab
-- so adding a tab is a one-file change (define + register) instead of
-- editing a giant switch.
---------------------------------------------------------------------------

ui.tabs = ui.tabs or {}
