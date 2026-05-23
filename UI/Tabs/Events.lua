---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Events tab: upcoming-events list. Promoted from a Raid sub-view to
-- a top-level tab so users can see the calendar without going into
-- raid tooling.
--
-- The actual list-render is in UI/EventsFrame.lua (WGS:PopulateEvents)
-- which already existed and renders into a parent.scrollFrame /
-- parent.content pair. The build here is just the scroll chrome.

local TAB_INDEX           = ui.TAB_EVENTS
local CreateScrollContent = ui.CreateScrollContent

local function BuildEventsTab(parent)
    parent.scrollFrame, parent.content = CreateScrollContent(parent)
end

local function RefreshEvents(tab)
    if not tab or not tab:IsVisible() then return end
    WGS:PopulateEvents(tab)
end

ui.tabs[TAB_INDEX] = { build = BuildEventsTab, refresh = RefreshEvents }
