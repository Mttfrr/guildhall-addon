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

-- Shared event-picker menu builder for the correction surfaces. Walks
-- db.global.events, filters to ±opts.windowSec (default 4h) of the
-- reference timestamp, sorts by closest-in-time, and returns a list of
-- context-menu entries — one per candidate event, plus an "empty"
-- placeholder when nothing's in range and an optional separator + clear
-- entry at the bottom.
--
-- Used by OpenLootRowMenu (wraps the result in a "Re-tag event ▸"
-- submenu) and OpenSessionEventMenu (renders the result flat under a
-- "Bind to event" title). Each caller passes its own onPick + onClear
-- so the helper stays decoupled from which mutator runs on selection.
local function BuildEventCandidateItems(refTs, opts)
    opts = opts or {}
    local windowSec = opts.windowSec or (4 * 60 * 60)

    local candidates = {}
    for _, ev in ipairs(WGS.db.global.events or {}) do
        local startTs = WGS:GetEventPullTime(ev)
        if startTs and math.abs(startTs - refTs) <= windowSec then
            candidates[#candidates + 1] = {
                ev      = ev,
                startTs = startTs,
                delta   = math.abs(startTs - refTs),
            }
        end
    end
    table.sort(candidates, function(a, b) return a.delta < b.delta end)

    local items = {}
    for _, c in ipairs(candidates) do
        local teamName = WGS.GetTeamName and WGS:GetTeamName(c.ev.team_id) or "?"
        items[#items + 1] = {
            text = string.format("%s \194\183 %s \194\183 %s",
                date("%m/%d %H:%M", c.startTs), teamName, c.ev.title or "?"),
            notCheckable = true,
            func = function() opts.onPick(c.ev) end,
        }
    end
    if #candidates == 0 and opts.emptyLabel then
        items[#items + 1] = {
            text = opts.emptyLabel,
            disabled = true,
            notCheckable = true,
        }
    end
    if opts.clearLabel and opts.onClear then
        items[#items + 1] = { text = "", isTitle = true, notCheckable = true }
        items[#items + 1] = {
            text = opts.clearLabel,
            notCheckable = true,
            func = opts.onClear,
        }
    end
    return items
end

-- Right-click context menu for a Logs → Loot row. Builds an event
-- candidate list from db.global.events within ±4h of the row's
-- timestamp (matches the wider window used by
-- WGS:ReconcileAttendanceEventBindings), each one offered as a
-- re-tag target. Always includes "Untag" and "Delete row" entries.
--
-- Dispatched via ui.OpenContextMenu (MenuUtil.CreateContextMenu under
-- the hood — EasyMenu was removed from retail in the 11.0 interface).
local function OpenLootRowMenu(rowIndex)
    local row = WGS.db.global.loot and WGS.db.global.loot[rowIndex]
    if not row then return end

    local retagItems = BuildEventCandidateItems(tonumber(row.timestamp) or 0, {
        onPick     = function(ev) WGS:RetagLootRow(rowIndex, ev.id, ev.team_id) end,
        emptyLabel = "(no events within \194\1774h of this row)",
        clearLabel = "Untag (clear event/team)",
        onClear    = function() WGS:RetagLootRow(rowIndex, nil, nil) end,
    })

    local menu = {
        { text = "Re-tag event", notCheckable = true, hasArrow = true, menuList = retagItems },
        { text = "", isTitle = true, notCheckable = true },
        { text = "Delete row", notCheckable = true,
          func = function() WGS:DeleteLootRow(rowIndex) end },
    }

    ui.OpenContextMenu(menu)
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

    -- Live refresh when an officer edits a loot row (re-tag or delete).
    -- Uses the existing _refreshFn pattern that the search box already
    -- shares — wired in BuildLogsTab below; resolved at fire time.
    GuildHall.RegisterCallback(sv, "WGS_LOOT_EDITED", function()
        if sv._refreshFn then sv._refreshFn() end
    end)
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

    -- Pair each sorted entry with its index in the unsorted
    -- db.global.loot table so the right-click menu can pass it to the
    -- mutator API (which is index-based — sorted-list position would
    -- shift on every re-render).
    local sorted = {}
    for i = #loot, 1, -1 do
        sorted[#sorted + 1] = { entry = loot[i], idx = i }
    end

    local yOff = 0
    local shown = 0
    local MAX_ROWS = 200
    local matchedTeam = 0

    for _, pair in ipairs(sorted) do
        if shown >= MAX_ROWS then break end
        local entry, originalIndex = pair.entry, pair.idx

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
            -- Button (not Frame) so the row can receive right-clicks for
            -- the correction menu. Left-click intentionally a no-op
            -- today; reserved for a future "expand for details" view.
            local row = CreateFrame("Button", nil, sv.content)
            row:SetSize(660, 18)
            row:SetPoint("TOPLEFT", sv.content, "TOPLEFT", 0, yOff)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(_, button)
                if button == "RightButton" then OpenLootRowMenu(originalIndex) end
            end)

            local qColor = ITEM_QUALITY_COLORS[entry.itemQuality or 4] or "ffa335ee"
            local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            itemText:SetPoint("LEFT", row, "LEFT", 5, 0)
            itemText:SetWidth(220)
            itemText:SetJustifyH("LEFT")
            itemText:SetText("|c" .. qColor .. (entry.itemName or "Unknown") .. "|r")

            local short = (entry.player or ""):match("^([^%-]+)") or entry.player or "?"
            local gi = roster[short]
            local pColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            -- Player cell is its own Button overlay (instead of a bare
            -- FontString on the row Button) so right-click here opens
            -- the player context menu — distinct from right-clicking
            -- elsewhere on the row, which still opens the loot row
            -- menu (Re-tag event / Delete row).
            local playerCell = CreateFrame("Button", nil, row)
            playerCell:SetSize(120, 18)
            playerCell:SetPoint("LEFT", itemText, "RIGHT", 4, 0)
            playerCell:RegisterForClicks("RightButtonUp")
            local playerText = playerCell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            playerText:SetAllPoints(playerCell)
            playerText:SetJustifyH("LEFT")
            playerText:SetText("|c" .. pColor .. short .. "|r")
            local cellPlayer = entry.player    -- closure captures
            local cellClass = gi and gi.class
            playerCell:SetScript("OnClick", function(_, mouseBtn)
                if mouseBtn == "RightButton" then
                    ui.OpenPlayerContextMenu(cellPlayer, cellClass)
                end
            end)

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

-- Forward decl so the WGS_BANK_CAPTURED callback registered inside
-- BuildBankSubView can resolve PopulateBank — `local function` decls
-- only create the slot at their own line, so the callback closure
-- would otherwise capture nil.
local PopulateBank

local function BuildBankSubView(sv)
    sv.balance = sv:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    sv.balance:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -4)

    sv.balanceSub = sv:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sv.balanceSub:SetPoint("TOPLEFT", sv.balance, "BOTTOMLEFT", 0, -2)

    -- Manual capture button. The auto-capture flow (on GUILDBANKFRAME_OPENED
    -- + GUILDBANKLOG_UPDATE) covers the common case, but events sometimes
    -- get missed — addons loaded after the bank UI, a /reload while the
    -- bank is open, a server hiccup that drops the GUILDBANKLOG_UPDATE.
    -- The button is the always-works escape hatch: it issues the
    -- money-log query and schedules a capture, exactly as the
    -- bank-open handler does. Bank must be open for the query to land
    -- (Blizzard requires GuildBankFrame to be shown), so the click
    -- prints a hint if the bank UI isn't there.
    sv.captureBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.captureBtn:SetSize(110, 22)
    sv.captureBtn:SetPoint("TOPRIGHT", sv, "TOPRIGHT", -8, -4)
    sv.captureBtn:SetText("Capture now")
    sv.captureBtn:SetScript("OnClick", function()
        if not (GuildBankFrame and GuildBankFrame.IsShown and GuildBankFrame:IsShown()) then
            WGS:Print("Open the guild bank first, then click Capture now.")
            return
        end
        WGS:_HandleBankOpened()
    end)

    -- Team-filter no-op disclaimer; shown only when the picker is set.
    -- Bank is guild-wide finance; per-team scoping doesn't apply.
    -- Anchored below the capture button so the two don't collide.
    sv.teamNote = sv:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sv.teamNote:SetPoint("TOPRIGHT", sv.captureBtn, "BOTTOMRIGHT", 0, -2)
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

    -- Live refresh when new bank data lands. Without this the user
    -- has to switch tabs to see anything they just captured (manual
    -- button click, or the auto-flow firing while the Bank sub-view
    -- is already on screen). WGS_BANK_CAPTURED fires from
    -- CaptureNewTransactions (when added > 0) and from CaptureGold
    -- (when the balance changed). PopulateBank guards on
    -- sv:IsVisible() so subscriptions on hidden sub-views no-op.
    GuildHall.RegisterCallback(sv, "WGS_BANK_CAPTURED", function()
        PopulateBank(sv)
    end)
end

function PopulateBank(sv)
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

-- Confirmation popup for session delete. Registered once at file
-- scope so multiple Logs sub-views (or addon reloads) don't double-
-- register. Pending sessionIdx is passed via popup.data (set right
-- before StaticPopup_Show) — StaticPopup OnAccept reads it back.
StaticPopupDialogs["GUILDHALL_CONFIRM_SESSION_DELETE"] = {
    text         = "Delete the attendance session from %s?\n" ..
                   "This removes %d member(s) and %d raid-comp snapshot(s).\n" ..
                   "Cannot be undone.",
    button1      = "Delete",
    button2      = "Cancel",
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    OnAccept     = function(self, data)
        if data and data.idx then
            WGS:DeleteAttendanceSession(data.idx)
        end
    end,
}

-- Event picker for an attendance session. Renders the candidate list
-- flat (no submenu — the use case is "fix this session's binding"
-- rather than "browse") under a "Bind to event" title.
local function OpenSessionEventMenu(sessionIdx)
    local session = WGS.db.global.attendance and WGS.db.global.attendance[sessionIdx]
    if not session then return end

    local items = BuildEventCandidateItems(tonumber(session.startedAt) or 0, {
        onPick     = function(ev) WGS:RebindAttendanceSession(sessionIdx, ev.id, ev.title) end,
        emptyLabel = "(no events within \194\1774h of this session)",
        clearLabel = "Clear binding",
        onClear    = function() WGS:RebindAttendanceSession(sessionIdx, nil, nil) end,
    })

    local menu = { { text = "Bind to event", isTitle = true, notCheckable = true } }
    for _, it in ipairs(items) do menu[#menu + 1] = it end

    ui.OpenContextMenu(menu)
end

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

    -- Live refresh when an officer rebinds / edits / deletes a
    -- session. Same pattern as the loot sub-view's WGS_LOOT_EDITED
    -- callback; resolved via _refreshFn wired in BuildLogsTab.
    GuildHall.RegisterCallback(sv, "WGS_ATTENDANCE_EDITED", function()
        if sv._refreshFn then sv._refreshFn() end
    end)
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

        -- Expanded body: actions row + role tally + member list.
        -- Rendered when the row was last toggled open.
        if expanded then
            -- Actions row. Two side-by-side buttons above the tally.
            -- Indented to align with the disclosure triangle's right
            -- edge so the visual hierarchy reads "this session > its
            -- actions > its members."
            local actionsBar = CreateFrame("Frame", nil, sv.content)
            actionsBar:SetSize(cw, 22)
            actionsBar:SetPoint("TOPLEFT", sv.content, "TOPLEFT", 0, yOff)

            local bindBtn = CreateFrame("Button", nil, actionsBar, "UIPanelButtonTemplate")
            bindBtn:SetSize(120, 20)
            bindBtn:SetPoint("LEFT", actionsBar, "LEFT", 26, 0)
            bindBtn:SetText("Bind to event…")
            bindBtn:SetScript("OnClick", function() OpenSessionEventMenu(sessionIdx) end)

            local deleteBtn = CreateFrame("Button", nil, actionsBar, "UIPanelButtonTemplate")
            deleteBtn:SetSize(110, 20)
            deleteBtn:SetPoint("LEFT", bindBtn, "RIGHT", 6, 0)
            deleteBtn:SetText("Delete session")
            deleteBtn:SetScript("OnClick", function()
                -- Count snapshots for the popup message so the user
                -- knows what they're about to lose.
                local snapCount = 0
                for _, snap in ipairs(WGS.db.global.raidCompResults or {}) do
                    if snap.startedAt == s.startedAt then snapCount = snapCount + 1 end
                end
                local popup = StaticPopup_Show("GUILDHALL_CONFIRM_SESSION_DELETE",
                    date("%m/%d %H:%M", s.startedAt or 0),
                    #(s.memberList or {}),
                    snapCount)
                if popup then popup.data = { idx = sessionIdx } end
            end)

            yOff = yOff - 22

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

            -- 3-column grid. Each cell hosts: the class-coloured name
            -- on the left + a tiny "x" remove button on the right.
            -- Click → WGS:RemoveMemberFromSession (cascades into the
            -- session's raidCompResults snapshots). Cell layout:
            --   [ name text (COL_W - 22 wide) ] [ x (16x16) ]
            local COLS = 3
            local COL_W = math.floor(cw / COLS)
            local memberRowH = 16
            local i = 0
            local maxRow = 0
            for _, m in ipairs(sorted) do
                local short = (m.name or ""):match("^([^%-]+)") or m.name or "?"
                local classFile = WGS:NormalizeClassFile(m.class or "")
                local colorHex = WGS.CLASS_COLORS[classFile] or "ffffffff"

                local col = i % COLS
                local rowIdx = math.floor(i / COLS)
                if rowIdx > maxRow then maxRow = rowIdx end

                -- Each cell is a Button so we can hang the player
                -- context menu (Whisper / Invite / Inspect / Copy name /
                -- Copy profile link) off right-click. Left-click is a
                -- no-op today; the `x` button covers the remove action.
                local cellBtn = CreateFrame("Button", nil, sv.content)
                cellBtn:SetSize(COL_W - 22, memberRowH)
                cellBtn:SetPoint("TOPLEFT", sv.content, "TOPLEFT",
                    26 + col * COL_W, yOff - rowIdx * memberRowH)

                local fs = cellBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetAllPoints(cellBtn)
                fs:SetJustifyH("LEFT")
                fs:SetText("|c" .. colorHex .. short .. "|r")

                local memberClass = classFile
                ui.AttachPlayerContextMenu(cellBtn,
                    function() return m.name end,
                    function() return memberClass end)

                local memberName = m.name   -- capture for the closure
                local xBtn = CreateFrame("Button", nil, sv.content)
                xBtn:SetSize(14, 14)
                xBtn:SetPoint("TOPLEFT", sv.content, "TOPLEFT",
                    26 + col * COL_W + (COL_W - 20),
                    yOff - rowIdx * memberRowH - 1)
                local xText = xBtn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                xText:SetAllPoints(xBtn)
                xText:SetText("|cff888888x|r")
                xText:SetJustifyH("CENTER")
                xBtn:SetScript("OnEnter", function()
                    xText:SetText("|cffff5555x|r")
                end)
                xBtn:SetScript("OnLeave", function()
                    xText:SetText("|cff888888x|r")
                end)
                xBtn:SetScript("OnClick", function()
                    WGS:RemoveMemberFromSession(sessionIdx, memberName)
                end)

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
    parent.subViews[LOGS_SUB_ATTENDANCE]._refreshFn = function()
        PopulateAttendance(parent.subViews[LOGS_SUB_ATTENDANCE])
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
