---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Logs tab: capture-log surfaces. Replaces the standalone Bank and
-- Raids tabs from before the IA rationalisation. Sub-views:
--
--   Loot         — loot capture history (was Raids tab, full content).
--   Bank         — guild-bank balance + transactions (was Bank tab).
--   Attendance   — captured raid sessions (NEW; lands in the next commit).
--
-- Each sub-view is single-frame; no nested chrome. The shared sub-nav
-- comes from UI/UIHelpers.lua's BuildSubNav helper — same pattern as
-- the Teams tab.

local TAB_INDEX             = ui.TAB_LOGS
local LOGS_SUB_LOOT         = ui.LOGS_SUB_LOOT
local LOGS_SUB_BANK         = ui.LOGS_SUB_BANK
local LOGS_SUB_ATTENDANCE   = ui.LOGS_SUB_ATTENDANCE
local LOGS_SUB_COUNT        = ui.LOGS_SUB_COUNT
local LOGS_SUB_NAMES        = ui.LOGS_SUB_NAMES
local ClearContainer        = ui.ClearContainer
local SelectSubView         = ui.SelectSubView
local BuildSubNav           = ui.BuildSubNav

---------------------------------------------------------------------------
-- Loot sub-view (lifted from the deleted UI/Tabs/Raids.lua)
---------------------------------------------------------------------------

local ITEM_QUALITY_COLORS = {
    [2] = "ff1eff00",
    [3] = "ff0070dd",
    [4] = "ffa335ee",
    [5] = "ffff8000",
    [6] = "ffe6cc80",
    [7] = "ff00ccff",
}

-- Build a per-team event window list for the loot date-range filter.
-- Returns an array of { startTs, endTs } pairs covering each event of
-- the picked team (event start → +5h). Until loot capture tags rows
-- with team_id at parse time (follow-up commit), this is the best we
-- can do — show loot whose capture timestamp falls inside any of the
-- picked team's event windows. Imperfect (off-team pugs in a team
-- event will leak in; loot during off-cycle clears won't show) but
-- useful in the common case.
local function BuildEventWindowsForTeam(teamId)
    if not teamId then return nil end
    local events = WGS.db.global.events or {}
    local windows = {}
    for _, ev in ipairs(events) do
        if (ev.team_id == teamId or ev.teamId == teamId) and ev.date then
            local y, mo, d = ev.date:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
            if y then
                local h, mi = (ev.time or "20:00"):match("^(%d%d):(%d%d)$")
                local startTs = time({
                    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                    hour = tonumber(h or 20), min = tonumber(mi or 0), sec = 0,
                })
                windows[#windows + 1] = { startTs, startTs + 5 * 3600 }
            end
        end
    end
    return windows
end

local function InAnyWindow(ts, windows)
    if not windows then return true end
    if not ts then return false end
    for _, w in ipairs(windows) do
        if ts >= w[1] and ts <= w[2] then return true end
    end
    return false
end

local function BuildLootSubView(sv)
    local searchLbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    searchLbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -2)
    searchLbl:SetText("Filter:")

    local searchBox = CreateFrame("EditBox", nil, sv, "InputBoxTemplate")
    searchBox:SetSize(250, 22)
    searchBox:SetPoint("LEFT", searchLbl, "RIGHT", 10, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnTextChanged", function(self)
        sv.filterText = (self:GetText() or ""):lower()
        if sv._refreshFn then sv._refreshFn() end
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    sv.searchBox = searchBox

    local countText = sv:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countText:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)
    sv.countText = countText

    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -28)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
    sv.filterText = ""
end

local function PopulateLoot(sv)
    if not sv or not sv:IsVisible() then return end
    ClearContainer(sv.content)

    local loot = WGS.db.global.loot or {}
    local filter = sv.filterText or ""
    local roster = WGS:GetGuildRosterLookup()

    -- Date-range pre-filter when the team picker is set. nil = "All Teams".
    local currentTeamId = WGS.GetCurrentTeamId and WGS:GetCurrentTeamId() or nil
    local windows = BuildEventWindowsForTeam(currentTeamId)

    local sorted = {}
    for i = #loot, 1, -1 do sorted[#sorted + 1] = loot[i] end

    local yOff = 0
    local shown = 0
    local MAX_ROWS = 200
    local matchedTeam = 0

    for _, entry in ipairs(sorted) do
        if shown >= MAX_ROWS then break end

        local passesTeam = InAnyWindow(entry.timestamp, windows)
        if passesTeam then matchedTeam = matchedTeam + 1 end

        local matches = passesTeam and filter == ""
        if passesTeam and filter ~= "" then
            local itemName = (entry.itemName or ""):lower()
            local player = (entry.player or ""):lower()
            local boss = (entry.boss or ""):lower()
            if itemName:find(filter, 1, true) or player:find(filter, 1, true) or boss:find(filter, 1, true) then
                matches = true
            end
        end

        if matches then
            local row = CreateFrame("Frame", nil, sv.content)
            row:SetSize(660, 18)
            row:SetPoint("TOPLEFT", sv.content, "TOPLEFT", 0, yOff)

            local qColor = ITEM_QUALITY_COLORS[entry.itemQuality or 4] or "ffa335ee"
            local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            itemText:SetPoint("LEFT", row, "LEFT", 5, 0)
            itemText:SetWidth(220)
            itemText:SetJustifyH("LEFT")
            itemText:SetText("|c" .. qColor .. (entry.itemName or "Unknown") .. "|r")

            local short = (entry.player or ""):match("^([^%-]+)") or entry.player or "?"
            local gi = roster[short]
            local pColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local playerText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            playerText:SetPoint("LEFT", itemText, "RIGHT", 4, 0)
            playerText:SetWidth(120)
            playerText:SetJustifyH("LEFT")
            playerText:SetText("|c" .. pColor .. short .. "|r")

            local bossText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            bossText:SetPoint("LEFT", playerText, "RIGHT", 4, 0)
            bossText:SetWidth(140)
            bossText:SetJustifyH("LEFT")
            local bossStr = entry.boss and entry.boss ~= "" and entry.boss or "\226\128\148"
            bossText:SetText("|cff888888" .. bossStr .. "|r")

            local dateText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            dateText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            dateText:SetWidth(120)
            dateText:SetJustifyH("RIGHT")
            dateText:SetText("|cff555555" .. date("%m/%d %H:%M", entry.timestamp or 0) .. "|r")

            yOff = yOff - 18
            shown = shown + 1
        end
    end

    if shown == 0 then
        local noData = sv.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", sv.content, "TOPLEFT", 5, -5)
        if currentTeamId and matchedTeam == 0 then
            noData:SetText("No loot captured during this team's events.")
        elseif filter ~= "" then
            noData:SetText("No loot matching filter.")
        else
            noData:SetText("No loot recorded yet.")
        end
        sv.content:SetHeight(30)
    else
        sv.content:SetHeight(math.abs(yOff) + 10)
    end

    if currentTeamId then
        sv.countText:SetText(string.format("|cff888888Showing %d of %d (team-filtered: %d)|r",
            shown, #loot, matchedTeam))
    else
        sv.countText:SetText(string.format("|cff888888Showing %d of %d|r", shown, #loot))
    end
end

---------------------------------------------------------------------------
-- Bank sub-view (lifted from the deleted UI/Tabs/Bank.lua)
---------------------------------------------------------------------------

local function BuildBankSubView(sv)
    sv.balance = sv:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    sv.balance:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -4)

    sv.balanceSub = sv:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sv.balanceSub:SetPoint("TOPLEFT", sv.balance, "BOTTOMLEFT", 0, -2)

    -- Team-filter no-op disclaimer; shown only when the picker is set.
    -- Bank is guild-wide finance; per-team scoping doesn't apply.
    sv.teamNote = sv:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sv.teamNote:SetPoint("TOPRIGHT", sv, "TOPRIGHT", -5, -4)
    sv.teamNote:SetJustifyH("RIGHT")
    sv.teamNote:Hide()

    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -48)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
end

local function PopulateBank(sv)
    if not sv or not sv:IsVisible() then return end
    ClearContainer(sv.content)

    local db = WGS.db.global
    local gold = WGS:GetGuildGoldFormatted()
    if gold then
        sv.balance:SetText("|cffffd100" .. gold .. "|r")
    else
        sv.balance:SetText("|cff888888No bank data yet|r")
    end

    local changes = db.guildBankMoneyChanges or {}
    local txs = db.guildBankTransactions or {}
    sv.balanceSub:SetText(string.format(
        "|cff555555%d gold snapshots, %d transactions captured|r",
        #changes, #txs))

    if WGS.GetCurrentTeamId and WGS:GetCurrentTeamId() then
        sv.teamNote:SetText("|cff888888(guild-wide; team filter does not apply)|r")
        sv.teamNote:Show()
    else
        sv.teamNote:Hide()
    end

    if #txs == 0 then
        local noData = sv.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", sv.content, "TOPLEFT", 5, -5)
        noData:SetText("No transactions yet. Open the guild bank to capture some.")
        sv.content:SetHeight(30)
        return
    end

    local sorted = {}
    for i = #txs, 1, -1 do sorted[#sorted + 1] = txs[i] end

    local yOff = 0
    local cw = 660
    local MAX_ROWS = 300
    local shown = 0
    for _, tx in ipairs(sorted) do
        if shown >= MAX_ROWS then break end
        local row = CreateFrame("Frame", nil, sv.content)
        row:SetSize(cw, 18)
        row:SetPoint("TOPLEFT", sv.content, "TOPLEFT", 0, yOff)

        local typeColor = tx.type == "withdrawal" and "ffff8800" or "ff00ff00"
        local sign      = tx.type == "withdrawal" and "-"        or "+"
        local typeText  = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        typeText:SetPoint("LEFT", row, "LEFT", 5, 0)
        typeText:SetWidth(90)
        typeText:SetJustifyH("LEFT")
        typeText:SetText("|c" .. typeColor .. (tx.type or "?") .. "|r")

        local playerText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        playerText:SetPoint("LEFT", typeText, "RIGHT", 4, 0)
        playerText:SetWidth(180)
        playerText:SetJustifyH("LEFT")
        playerText:SetText(tx.player or "Unknown")

        local amountText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        amountText:SetPoint("LEFT", playerText, "RIGHT", 4, 0)
        amountText:SetWidth(180)
        amountText:SetJustifyH("LEFT")
        amountText:SetText("|c" .. typeColor .. sign .. (tx.amountFormatted or WGS:FormatGold(tx.amount or 0)) .. "|r")

        local dateText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        dateText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        dateText:SetWidth(120)
        dateText:SetJustifyH("RIGHT")
        dateText:SetText("|cff555555" .. date("%m/%d %H:%M", tx.timestamp or 0) .. "|r")

        yOff = yOff - 18
        shown = shown + 1
    end

    sv.content:SetHeight(math.abs(yOff) + 10)
end

---------------------------------------------------------------------------
-- Attendance sub-view (NEW; lands in the next commit — Phase 6)
---------------------------------------------------------------------------

local function BuildAttendanceSubView(sv)
    sv.placeholder = sv:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sv.placeholder:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -5)
    sv.placeholder:SetText("Attendance log — lands in the next commit.")
end

local function PopulateAttendance(sv)
    -- Placeholder; real implementation in Phase 6.
    if not sv or not sv:IsVisible() then return end
end

---------------------------------------------------------------------------
-- Tab wiring
---------------------------------------------------------------------------

local function BuildLogsTab(parent)
    BuildSubNav(parent, LOGS_SUB_NAMES, function(p, i)
        SelectSubView(p, i, LOGS_SUB_COUNT)
        if i == LOGS_SUB_LOOT then
            PopulateLoot(p.subViews[i])
        elseif i == LOGS_SUB_BANK then
            PopulateBank(p.subViews[i])
        elseif i == LOGS_SUB_ATTENDANCE then
            PopulateAttendance(p.subViews[i])
        end
    end)
    BuildLootSubView(parent.subViews[LOGS_SUB_LOOT])
    BuildBankSubView(parent.subViews[LOGS_SUB_BANK])
    BuildAttendanceSubView(parent.subViews[LOGS_SUB_ATTENDANCE])

    -- Loot's filter EditBox + Bank's transaction stream both want a way
    -- to re-render their own sub-view (filter change, refresh ticker).
    -- Stash the per-sub refresh fn so the sub-view itself can call it
    -- without poking the parent.
    parent.subViews[LOGS_SUB_LOOT]._refreshFn = function()
        PopulateLoot(parent.subViews[LOGS_SUB_LOOT])
    end

    SelectSubView(parent, LOGS_SUB_LOOT, LOGS_SUB_COUNT)
end

local function RefreshLogsTab(tab)
    if not tab or not tab:IsVisible() then return end
    local sub = tab.selectedSub or LOGS_SUB_LOOT
    if sub == LOGS_SUB_LOOT then
        PopulateLoot(tab.subViews[sub])
    elseif sub == LOGS_SUB_BANK then
        PopulateBank(tab.subViews[sub])
    elseif sub == LOGS_SUB_ATTENDANCE then
        PopulateAttendance(tab.subViews[sub])
    end
end

ui.tabs[TAB_INDEX] = { build = BuildLogsTab, refresh = RefreshLogsTab }
