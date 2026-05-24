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

-- Loot rows captured by Modules/Loot.lua now carry teamId + eventId
-- stamps from the active attendance session (see
-- WGS:GetCurrentAttendanceContext). The team filter is an exact match
-- against entry.teamId. Pre-tagging rows (captured before the stamping
-- landed, or captured without an active session) carry nil teamId and
-- are excluded from a team-filtered view — they show up under "All
-- Teams" as before.

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

    -- Exact-match team filter against entry.teamId. nil currentTeamId
    -- (All Teams) shows everything.
    local currentTeamId = WGS.GetCurrentTeamId and WGS:GetCurrentTeamId() or nil

    local sorted = {}
    for i = #loot, 1, -1 do sorted[#sorted + 1] = loot[i] end

    local yOff = 0
    local shown = 0
    local MAX_ROWS = 200
    local matchedTeam = 0

    for _, entry in ipairs(sorted) do
        if shown >= MAX_ROWS then break end

        local passesTeam = (currentTeamId == nil) or (entry.teamId == currentTeamId)
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
            noData:SetText("No loot tagged to this team yet. Older rows captured before this version aren't team-tagged.")
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
        sv.countText:SetText(string.format("|cff888888Showing %d of %d (team-tagged: %d)|r",
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
-- Attendance sub-view
--
-- Lists captured raid sessions from db.global.attendance, reverse
-- chronological (newest first). Each row: date+time · team name ·
-- duration · member count · export status pill. Clicking the row
-- expands it inline to show the member list with class colours and a
-- T/H/D role tally.
--
-- "Exported" is a heuristic: session.endedAt <= db.global.lastExport.
-- The platform is the source of truth; a wrong "✓" just nudges the
-- officer to re-export, which is harmless.
---------------------------------------------------------------------------

local function FormatDuration(startedAt, endedAt)
    if not startedAt or not endedAt or endedAt < startedAt then return "?" end
    local secs = endedAt - startedAt
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

-- WGS:NormalizeRole lives in Util/Roles.lua — handles the DAMAGER ↔ DPS
-- mismatch + the platform's "TANK/HEALER/DPS" enum. All role bucketing
-- in the addon routes through it so a new role bucket on the platform
-- only needs to update one file.

local function BuildAttendanceSubView(sv)
    -- Pure read surface — sessions list only. The manual Start / Stop
    -- toggle moved to the Events detail panel's actions footer where
    -- it can scope to the selected event; the minimap shift-click is
    -- the no-UI fast path. See UI/EventsDetail.lua PopulateActionsFooter.
    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
    -- _expanded[i] = true when session at sorted index i has its
    -- member list expanded. Per-session-index rather than per-session-
    -- object so a re-render survives a re-sort.
    sv._expanded = {}
end

local function PopulateAttendance(sv)
    if not sv or not sv:IsVisible() then return end
    ClearContainer(sv.content)

    local sessions = WGS.db.global.attendance or {}
    local currentTeamId = WGS.GetCurrentTeamId and WGS:GetCurrentTeamId() or nil
    local lastExport = WGS.db.global.lastExport or 0

    -- Reverse chronological (newest first). Filter by team if the
    -- picker is set; nil session.teamId never matches a filter.
    local rows = {}
    for i = #sessions, 1, -1 do
        local s = sessions[i]
        if not currentTeamId or s.teamId == currentTeamId then
            rows[#rows + 1] = { i = i, s = s }
        end
    end

    if #rows == 0 then
        local noData = sv.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", sv.content, "TOPLEFT", 5, -5)
        if currentTeamId then
            noData:SetText("No attendance sessions for the picked team.")
        else
            noData:SetText("No attendance sessions captured yet.")
        end
        sv.content:SetHeight(30)
        return
    end

    local cw = 660
    local ROW_H = 22
    local yOff = 0

    for _, row in ipairs(rows) do
        local s = row.s
        local sessionIdx = row.i
        local expanded = sv._expanded[sessionIdx] == true

        -- Outer row: clickable to toggle expansion. Sized once now,
        -- grown below when the member list is rendered.
        local outer = CreateFrame("Button", nil, sv.content)
        outer:SetSize(cw, ROW_H)
        outer:SetPoint("TOPLEFT", sv.content, "TOPLEFT", 0, yOff)
        outer:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
        local hl = outer:GetHighlightTexture()
        if hl then hl:SetAlpha(0.25) end

        local bg = outer:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(outer)
        bg:SetColorTexture(1, 1, 1, 0.025)

        -- Disclosure triangle
        local disclosure = outer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        disclosure:SetPoint("LEFT", outer, "LEFT", 5, 0)
        disclosure:SetText(expanded and "|cffffd100v|r" or "|cffaaaaaa>|r")

        -- Date + time
        local dateText = outer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        dateText:SetPoint("LEFT", disclosure, "RIGHT", 6, 0)
        dateText:SetWidth(110)
        dateText:SetJustifyH("LEFT")
        dateText:SetText(date("%m/%d %H:%M", s.startedAt or 0))

        -- Team / event tag
        local tagText = outer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tagText:SetPoint("LEFT", dateText, "RIGHT", 4, 0)
        tagText:SetWidth(220)
        tagText:SetJustifyH("LEFT")
        local tag = s.teamName or "|cff888888untagged|r"
        if s.eventTitle and s.eventTitle ~= "" then
            tag = tag .. " |cff666666·|r |cffaaaaaa" .. s.eventTitle .. "|r"
        end
        tagText:SetText(tag)

        -- Duration
        local durText = outer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        durText:SetPoint("LEFT", tagText, "RIGHT", 4, 0)
        durText:SetWidth(70)
        durText:SetJustifyH("RIGHT")
        durText:SetText("|cffcccccc" .. FormatDuration(s.startedAt, s.endedAt) .. "|r")

        -- Member count
        local members = s.memberList or {}
        local countText = outer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        countText:SetPoint("LEFT", durText, "RIGHT", 4, 0)
        countText:SetWidth(60)
        countText:SetJustifyH("RIGHT")
        countText:SetText("|cffaaaaaa" .. #members .. "|r")

        -- Export status pill
        local exported = (s.endedAt or 0) > 0 and (s.endedAt or 0) <= lastExport
        local pillText = outer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pillText:SetPoint("RIGHT", outer, "RIGHT", -5, 0)
        pillText:SetWidth(110)
        pillText:SetJustifyH("RIGHT")
        if exported then
            pillText:SetText("|cff00ff00exported|r")
        else
            pillText:SetText("|cffffaa00unexported|r")
        end

        outer:SetScript("OnClick", function()
            sv._expanded[sessionIdx] = not expanded
            PopulateAttendance(sv)
        end)

        yOff = yOff - ROW_H

        -- Expanded body: role tally + member list. Rendered when the
        -- row was last toggled open.
        if expanded then
            -- Role tally
            local tally = { TANK = 0, HEALER = 0, DPS = 0 }
            for _, m in ipairs(members) do
                local r = WGS:NormalizeRole(m.role)
                tally[r] = (tally[r] or 0) + 1
            end

            local roleBar = CreateFrame("Frame", nil, sv.content)
            roleBar:SetSize(cw, 18)
            roleBar:SetPoint("TOPLEFT", sv.content, "TOPLEFT", 0, yOff)
            local tallyText = roleBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            tallyText:SetPoint("LEFT", roleBar, "LEFT", 26, 0)
            tallyText:SetText(string.format(
                "|cff5599ff%dT|r  |cff00ff00%dH|r  |cffff4444%dD|r  |cff888888·|r  %s  |cff666666·|r  |cffaaaaaastarted by %s|r",
                tally.TANK, tally.HEALER, tally.DPS,
                s.instanceName or "?",
                (s.startedBy or "?"):match("^([^%-]+)") or s.startedBy or "?"))

            yOff = yOff - 18

            -- Member list. Class-coloured, role-grouped (Tanks → Healers
            -- → DPS) so the body reads as a comp snapshot.
            local sorted = {}
            for _, m in ipairs(members) do sorted[#sorted + 1] = m end
            local roleOrder = { TANK = 1, HEALER = 2, DPS = 3 }
            table.sort(sorted, function(a, b)
                local ra = roleOrder[WGS:NormalizeRole(a.role)] or 4
                local rb = roleOrder[WGS:NormalizeRole(b.role)] or 4
                if ra ~= rb then return ra < rb end
                return ((a.name or ""):lower()) < ((b.name or ""):lower())
            end)

            -- 3-column grid
            local COLS = 3
            local COL_W = math.floor(cw / COLS)
            local memberRowH = 16
            local i = 0
            local maxRow = 0
            for _, m in ipairs(sorted) do
                local short = (m.name or ""):match("^([^%-]+)") or m.name or "?"
                local classFile = WGS:NormalizeClassFile(m.class or "")
                local colorHex = WGS.CLASS_COLORS[classFile] or "ffffffff"

                local fs = sv.content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                local col = i % COLS
                local rowIdx = math.floor(i / COLS)
                if rowIdx > maxRow then maxRow = rowIdx end
                fs:SetPoint("TOPLEFT", sv.content, "TOPLEFT",
                    26 + col * COL_W, yOff - rowIdx * memberRowH)
                fs:SetWidth(COL_W - 8)
                fs:SetJustifyH("LEFT")
                fs:SetText("|c" .. colorHex .. short .. "|r")
                i = i + 1
            end

            yOff = yOff - (maxRow + 1) * memberRowH - 6
        end
    end

    sv.content:SetHeight(math.abs(yOff) + 10)
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
