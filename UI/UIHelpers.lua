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

-- Bank is single-view (no sub-nav). Loot history moved to Raids since
-- it's raid-related data, not bank-ledger data.

ui.RAIDS_SUB_COMP      = 1
ui.RAIDS_SUB_READINESS = 2
ui.RAIDS_SUB_BOSSNOTES = 3
ui.RAIDS_SUB_LOOT      = 4
ui.RAIDS_SUB_COUNT     = 4
ui.RAIDS_SUB_NAMES     = { "Raid Comp", "Readiness", "Boss Notes", "Loot History" }

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

-- Sub-nav visual states. The active tab gets a gold underline + bright
-- label; inactives are dimmed; hover splits the difference. Kept here
-- so the colors are tweakable in one place and read alongside the
-- tab construction.
local TAB_COLOR_ACTIVE   = { 1.00, 0.82, 0.00, 1.00 }  -- gold
local TAB_COLOR_INACTIVE = { 0.65, 0.65, 0.65, 1.00 }  -- dim grey
local TAB_COLOR_HOVER    = { 1.00, 1.00, 1.00, 1.00 }  -- white

local function paintTab(btn, active)
    if not btn or not btn.label then return end
    local c = active and TAB_COLOR_ACTIVE or TAB_COLOR_INACTIVE
    btn.label:SetTextColor(c[1], c[2], c[3], c[4])
    if btn.underline then
        if active then btn.underline:Show() else btn.underline:Hide() end
    end
end

-- Generic sub-view selector. Hides all sub-views, shows the selected
-- one, and updates the sub-nav highlight to indicate selection.
function ui.SelectSubView(tab, index, count)
    for i = 1, count do
        tab.subViews[i]:Hide()
        paintTab(tab.subButtons[i], false)
    end
    tab.subViews[index]:Show()
    paintTab(tab.subButtons[index], true)
    tab.selectedSub = index
end

-- Build a sub-navigation row across the top of a tab plus N sub-view
-- frames. onSelect(tab, index) is called when a sub-button is clicked.
--
-- Visual style: text-only tabs with a gold underline indicator on the
-- active one. UIPanelButtonTemplate (the chunky red Blizzard buttons)
-- is reserved for CTAs — Invite, Announce, Export, etc. — so the
-- distinction between "switch views" and "do an action" reads
-- cleanly at a glance.
function ui.BuildSubNav(parent, names, onSelect)
    parent.subButtons = {}
    parent.subViews = {}
    parent.selectedSub = 1
    local count = #names
    local btnW = math.floor(660 / count) - 4
    local btnX = 0
    local btnH = 24

    for i = 1, count do
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(btnW, btnH)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", btnX, 0)

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER", btn, "CENTER", 0, 1)
        label:SetText(names[i])
        btn.label = label

        local underline = btn:CreateTexture(nil, "ARTWORK")
        underline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 6, 0)
        underline:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -6, 0)
        underline:SetHeight(2)
        underline:SetColorTexture(TAB_COLOR_ACTIVE[1], TAB_COLOR_ACTIVE[2], TAB_COLOR_ACTIVE[3], 1)
        underline:Hide()
        btn.underline = underline

        btn:SetScript("OnEnter", function(self)
            -- Hover lift only on non-active tabs; the active one stays gold.
            if parent.selectedSub ~= i then
                self.label:SetTextColor(TAB_COLOR_HOVER[1], TAB_COLOR_HOVER[2], TAB_COLOR_HOVER[3], 1)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            paintTab(self, parent.selectedSub == i)
        end)
        btn:SetScript("OnClick", function() onSelect(parent, i) end)

        paintTab(btn, false)  -- start inactive; SelectSubView paints the chosen one
        parent.subButtons[i] = btn
        btnX = btnX + btnW + 4
    end

    -- Thin separator line under the whole nav row.
    local sep = parent:CreateTexture(nil, "ARTWORK")
    sep:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -btnH)
    sep:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -btnH)
    sep:SetHeight(1)
    sep:SetColorTexture(0.3, 0.3, 0.3, 0.6)

    for i = 1, count do
        local sv = CreateFrame("Frame", nil, parent)
        sv:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(btnH + 4))
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
