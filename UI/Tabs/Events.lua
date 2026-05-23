---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Events tab: master-detail surface for upcoming raid nights.
--
-- The left "rail" is a narrow scroll of imported events sorted by date;
-- click a row to load that event's detail (signups + raid comp + boss
-- notes + share actions) in the wide panel on the right. The rail
-- replaces the previous full-width sortable table; the detail panel
-- replaces the standalone Raids → Raid Comp and Raids → Readiness
-- sub-views (which were event-shaped concepts living in the wrong tab).
--
-- Layout numbers chosen to fit the 720px main frame:
--   rail   = 210 px (date · title · status pill fit in a single line)
--   gap    = 10  px
--   detail = remainder (~440 px), enough for role-grouped comp + the
--           5-column roster grid below.

local TAB_INDEX = ui.TAB_EVENTS

local RAIL_W = 210
local GAP_W  = 10

-- Inner-content width estimates per panel. The detail panel pin its
-- right side to parent edge, so the content width is approximate —
-- only used so child widgets know how wide to draw.
local RAIL_CONTENT_W   = RAIL_W - 22   -- minus scrollbar
local DETAIL_CONTENT_W = 420           -- approximate; widgets clamp to scroll width

local function BuildEventsTab(parent)
    -- Rail (left): pinned to the left edge, RAIL_W wide.
    local railSf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    railSf:SetPoint("TOPLEFT",     parent, "TOPLEFT",     0, 0)
    railSf:SetPoint("BOTTOMLEFT",  parent, "BOTTOMLEFT",  0, 0)
    railSf:SetWidth(RAIL_W)
    local railContent = CreateFrame("Frame", nil, railSf)
    railContent:SetWidth(RAIL_CONTENT_W)
    railContent:SetHeight(1)
    railSf:SetScrollChild(railContent)
    parent.railScrollFrame = railSf
    parent.railContent     = railContent

    -- Detail (right): starts after rail + gap, runs to the right edge.
    local detailSf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    detailSf:SetPoint("TOPLEFT",     parent, "TOPLEFT",     RAIL_W + GAP_W, 0)
    detailSf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)
    local detailContent = CreateFrame("Frame", nil, detailSf)
    detailContent:SetWidth(DETAIL_CONTENT_W)
    detailContent:SetHeight(1)
    detailSf:SetScrollChild(detailContent)
    parent.detailScrollFrame = detailSf
    parent.detailContent     = detailContent

    -- Thin vertical separator so the two panels read as distinct columns.
    local sep = parent:CreateTexture(nil, "ARTWORK")
    sep:SetPoint("TOPLEFT",    parent, "TOPLEFT", RAIL_W + math.floor(GAP_W / 2), -2)
    sep:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", RAIL_W + math.floor(GAP_W / 2), 2)
    sep:SetWidth(1)
    sep:SetColorTexture(0.3, 0.3, 0.3, 0.6)
end

local function RefreshEvents(tab)
    if not tab or not tab:IsVisible() then return end
    WGS:PopulateEvents(tab)
end

ui.tabs[TAB_INDEX] = { build = BuildEventsTab, refresh = RefreshEvents }
