---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Teams tab master: just the sub-nav wiring. The three sub-views each
-- own their build + populate in their own file, registered on the
-- ui.teams namespace:
--
--   ui.teams.roster        UI/Teams/Roster.lua       — table of teams
--                                                      with main/alt rollup +
--                                                      per-member gear gaps
--   ui.teams.rosterCheck   UI/Teams/RosterCheck.lua  — today's event:
--                                                      Present/Missing/Extra
--                                                      against live raid or
--                                                      last attendance
--   ui.teams.wishlists     UI/Teams/Wishlists.lua    — boss-filtered
--                                                      view of who wishlisted
--                                                      what
--
-- All three respect the global current-team picker (Util/SignupStatus
-- + WGS:GetCurrentTeamId) — see each sub-view file for the per-view
-- filter logic.

local TAB_INDEX            = ui.TAB_TEAMS
local TEAMS_SUB_TEAMS      = ui.TEAMS_SUB_TEAMS
local TEAMS_SUB_CHECK      = ui.TEAMS_SUB_CHECK
local TEAMS_SUB_WISHLISTS  = ui.TEAMS_SUB_WISHLISTS
local TEAMS_SUB_COUNT      = ui.TEAMS_SUB_COUNT
local TEAMS_SUB_NAMES      = ui.TEAMS_SUB_NAMES
local SelectSubView        = ui.SelectSubView
local BuildSubNav          = ui.BuildSubNav

-- The sub-view modules each set ui.teams.<name> at file scope. The
-- master is loaded last in UI.xml so all three are present by the time
-- BuildTeamsTab runs (which itself runs at CreateMainFrame time, well
-- after every script has loaded).
local function subView(name)
    local t = ui.teams and ui.teams[name]
    if not t then
        error("UI/Teams/" .. name .. ".lua did not register itself on ui.teams." .. name)
    end
    return t
end

local function BuildTeamsTab(parent)
    local roster      = subView("roster")
    local rosterCheck = subView("rosterCheck")
    local wishlists   = subView("wishlists")

    BuildSubNav(parent, TEAMS_SUB_NAMES, function(p, i)
        SelectSubView(p, i, TEAMS_SUB_COUNT)
        if     i == TEAMS_SUB_TEAMS     then roster.populate(p.subViews[i])
        elseif i == TEAMS_SUB_CHECK     then rosterCheck.populate(p.subViews[i])
        elseif i == TEAMS_SUB_WISHLISTS then wishlists.populate(p.subViews[i])
        end
    end)
    roster.build(parent.subViews[TEAMS_SUB_TEAMS])
    rosterCheck.build(parent.subViews[TEAMS_SUB_CHECK])
    wishlists.build(parent.subViews[TEAMS_SUB_WISHLISTS])

    -- Back-pointers used by the Refresh button inside RosterCheck and
    -- the boss-dropdown inside Wishlists. Sub-view-owned re-renders.
    parent.subViews[TEAMS_SUB_CHECK]._refreshFn = function()
        rosterCheck.populate(parent.subViews[TEAMS_SUB_CHECK])
    end
    parent.subViews[TEAMS_SUB_WISHLISTS]._refreshFn = function()
        wishlists.populate(parent.subViews[TEAMS_SUB_WISHLISTS])
    end

    SelectSubView(parent, TEAMS_SUB_TEAMS, TEAMS_SUB_COUNT)
end

local function RefreshTeamsSubView(tab)
    if not tab or not tab:IsVisible() then return end
    local sub = tab.selectedSub or TEAMS_SUB_TEAMS
    if     sub == TEAMS_SUB_TEAMS     then subView("roster").populate(tab.subViews[sub])
    elseif sub == TEAMS_SUB_CHECK     then subView("rosterCheck").populate(tab.subViews[sub])
    elseif sub == TEAMS_SUB_WISHLISTS then subView("wishlists").populate(tab.subViews[sub])
    end
end

ui.tabs[TAB_INDEX] = { build = BuildTeamsTab, refresh = RefreshTeamsSubView }
