---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

local mainFrame = nil

local TAB_DASHBOARD = 1
local TAB_ROSTER    = 2
local TAB_RAID      = 3
local TAB_LOOT      = 4
local TAB_SYNC      = 5
local TAB_COUNT     = 5
local TAB_NAMES     = { "Dashboard", "Roster", "Raid", "Loot", "Import/Export" }

local RAID_SUB_COMP      = 1
local RAID_SUB_READINESS = 2
local RAID_SUB_EVENTS    = 3
local RAID_SUB_BOSSNOTES = 4
local RAID_SUB_COUNT     = 4
local RAID_SUB_NAMES     = { "Raid Comp", "Readiness", "Events", "Boss Notes" }

local ROSTER_SUB_TEAMS = 1
local ROSTER_SUB_CHECK = 2
local ROSTER_SUB_COUNT = 2
local ROSTER_SUB_NAMES = { "Teams", "Roster Check" }

local LOOT_SUB_HISTORY   = 1
local LOOT_SUB_WISHLISTS = 2
local LOOT_SUB_COUNT     = 2
local LOOT_SUB_NAMES     = { "History", "Wishlists" }

-- Forward declarations: these are defined later in the file, but referenced
-- earlier (e.g. inside BuildRosterTab's sub-nav callback). Without this,
-- the closures would capture _ENV.X (a nil global) instead of the local.
local BuildRosterCheckSubView
local PopulateRosterCheck

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ClearContainer(container)
    for _, child in ipairs({ container:GetChildren() }) do child:Hide() end
    for _, region in ipairs({ container:GetRegions() }) do region:Hide() end
end

local function CreateScrollContent(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    return sf, content
end

--- Generic sub-view selector. Hides all sub-views, shows the selected one,
--- and updates button font weight to indicate selection.
local function SelectSubView(tab, index, count)
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

--- Build a sub-navigation row across the top of a tab plus N sub-view frames.
--- onSelect(tab, index) is called when a sub-button is clicked.
local function BuildSubNav(parent, names, onSelect)
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
-- Tab 1: Dashboard
---------------------------------------------------------------------------

local function BuildDashboardTab(parent)
    local col1X, col2X = 5, 310
    local btnW, btnH, gap = 260, 26, 4

    -- Quick Actions
    local hdr = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", col1X, 0)
    hdr:SetText("|cffffd100Quick Actions|r")

    local y = -22
    parent.btnAttendance = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    parent.btnAttendance:SetSize(btnW, btnH)
    parent.btnAttendance:SetPoint("TOPLEFT", parent, "TOPLEFT", col1X, y)
    parent.btnAttendance:SetText("Start Attendance Tracking")
    y = y - btnH - gap

    local btnGold = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnGold:SetSize(btnW, btnH)
    btnGold:SetPoint("TOPLEFT", parent, "TOPLEFT", col1X, y)
    btnGold:SetText("Capture Bank Gold")
    btnGold:SetScript("OnClick", function()
        WGS:CaptureGold()
        WGS:RefreshMainFrame()
    end)
    y = y - btnH - gap

    local btnScan = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnScan:SetSize(btnW, btnH)
    btnScan:SetPoint("TOPLEFT", parent, "TOPLEFT", col1X, y)
    btnScan:SetText("Scan Bank Transactions")
    btnScan:SetScript("OnClick", function()
        WGS:ScanBankTransactions()
        WGS:RefreshMainFrame()
    end)
    y = y - btnH - gap * 4

    local info = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("TOPLEFT", parent, "TOPLEFT", col1X, y)
    info:SetWidth(btnW)
    info:SetJustifyH("LEFT")
    info:SetText("|cff888888guildhall.run|r")

    -- Settings
    local btnSettings = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnSettings:SetSize(80, 22)
    btnSettings:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", col1X, 0)
    btnSettings:SetText("Settings")
    btnSettings:SetScript("OnClick", function() WGS:OpenConfig() end)

    -- Summary column
    local hdr2 = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdr2:SetPoint("TOPLEFT", parent, "TOPLEFT", col2X, 0)
    hdr2:SetText("|cffffd100Summary|r")

    parent.summaryText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    parent.summaryText:SetPoint("TOPLEFT", parent, "TOPLEFT", col2X, -22)
    parent.summaryText:SetWidth(270)
    parent.summaryText:SetJustifyH("LEFT")
    parent.summaryText:SetJustifyV("TOP")

    parent.attendanceStatus = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    parent.attendanceStatus:SetPoint("TOPLEFT", parent, "TOPLEFT", col2X, -140)
    parent.attendanceStatus:SetWidth(270)
    parent.attendanceStatus:SetJustifyH("LEFT")
end

local function RefreshDashboard(tab)
    if not tab or not tab:IsVisible() then return end
    local db = WGS.db.global
    local lines = {}
    lines[#lines + 1] = "|cff888888Loot:|r " .. (db.loot and #db.loot or 0)
        .. "  |cff888888Attend:|r " .. (db.attendance and #db.attendance or 0)
    lines[#lines + 1] = "|cff888888Bank Tx:|r " .. (db.guildBankTransactions and #db.guildBankTransactions or 0)
    local gold = WGS.GetGuildGoldFormatted and WGS:GetGuildGoldFormatted() or nil
    if gold then lines[#lines + 1] = "|cff888888Gold:|r " .. gold end
    if db.lastExport > 0 then
        lines[#lines + 1] = "|cff555555Exported: " .. date("%m/%d %H:%M", db.lastExport) .. "|r"
    end
    if db.lastImport > 0 then
        lines[#lines + 1] = "|cff555555Imported: " .. date("%m/%d %H:%M", db.lastImport) .. "|r"
    end
    tab.summaryText:SetText(table.concat(lines, "\n"))

    if WGS:IsTrackingAttendance() then
        tab.btnAttendance:SetText("Stop Attendance Tracking")
        tab.attendanceStatus:SetText("|cff00ff00Attendance tracking active|r")
    else
        tab.btnAttendance:SetText("Start Attendance Tracking")
        tab.attendanceStatus:SetText("")
    end
end

---------------------------------------------------------------------------
-- Tab 2: Roster (Teams + Roster Check sub-views)
---------------------------------------------------------------------------

local function BuildTeamsSubView(sv)
    local sf, content = CreateScrollContent(sv)
    sf:ClearAllPoints()
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    sv.scrollFrame = sf
    sv.content = content
end

local function PopulateTeams(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local teams = WGS.db.global.teams
    if not teams or #teams == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText("No teams imported yet. Use the Sync tab to import data.")
        tab.content:SetHeight(30)
        return
    end

    local roster = WGS:GetGuildRosterLookup()
    local characters = WGS.db.global.characters or {}
    local yOff = 0
    local cw = 660

    for _, team in ipairs(teams) do
        local row = CreateFrame("Frame", nil, tab.content)
        row:SetSize(cw, 20)
        row:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)
        local tn = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tn:SetPoint("LEFT", row, "LEFT", 5, 0)
        local mc = team.playerMembers and #team.playerMembers or (team.members and #team.members or 0)
        tn:SetText("|cffffd100" .. (team.name or "?") .. "|r  |cff888888("
            .. (team.type or "Team") .. " \226\128\148 " .. mc .. " members)|r")
        yOff = yOff - 22

        if team.playerMembers and #team.playerMembers > 0 then
            for _, pm in ipairs(team.playerMembers) do
                local pi = characters[pm.playerId]
                local mainName = pm.main or (pi and pi.main) or "Unknown"
                local short = mainName:match("^([^%-]+)") or mainName
                local gi = roster[short]

                local anyOnline = gi and gi.online
                if not anyOnline and pi and pi.alts then
                    for _, alt in ipairs(pi.alts) do
                        local ag = roster[alt:match("^([^%-]+)")]
                        if ag and ag.online then anyOnline = true; break end
                    end
                end

                local mr = CreateFrame("Frame", nil, tab.content)
                mr:SetSize(cw, 16)
                mr:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

                local dot = mr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                dot:SetPoint("LEFT", mr, "LEFT", 12, 0)
                dot:SetText(gi and (anyOnline and "|cff00ff00\194\183|r" or "|cff555555\194\183|r") or "|cffff4444\194\183|r")

                local nt = mr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                nt:SetPoint("LEFT", dot, "RIGHT", 4, 0)
                if gi then
                    nt:SetText("|c" .. (WGS.CLASS_COLORS[gi.class] or "ffffffff") .. short .. "|r")
                else
                    nt:SetText("|cff666666" .. short .. "|r")
                end

                local nAlts = pi and pi.alts and #pi.alts or 0
                if nAlts > 0 then
                    local ab = mr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    ab:SetPoint("LEFT", nt, "RIGHT", 6, 0)
                    ab:SetText("|cff888888+" .. nAlts .. " alt" .. (nAlts > 1 and "s" or "") .. "|r")
                end
                if gi then
                    local it = mr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    it:SetPoint("RIGHT", mr, "RIGHT", -4, 0)
                    it:SetText("|cff555555Lv" .. gi.level .. " " .. gi.rank .. "|r")
                end

                if nAlts > 0 then
                    mr:EnableMouse(true)
                    mr._alts = pi.alts
                    mr._main = mainName
                    mr._short = short
                    mr:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:AddLine(self._short .. "'s Characters")
                        GameTooltip:AddLine("Main: " .. self._main, 1, 1, 1)
                        for _, alt in ipairs(self._alts) do
                            local as = alt:match("^([^%-]+)")
                            local ag = roster[as]
                            if ag then
                                GameTooltip:AddLine("|c" .. (WGS.CLASS_COLORS[ag.class] or "ffffffff") .. as .. "|r  "
                                    .. (ag.online and "|cff00ff00online|r" or "|cff555555offline|r"))
                            else
                                GameTooltip:AddLine("|cff666666" .. as .. "|r  (not in guild)")
                            end
                        end
                        GameTooltip:Show()
                    end)
                    mr:SetScript("OnLeave", function() GameTooltip:Hide() end)
                end
                yOff = yOff - 16
            end
        elseif team.members and #team.members > 0 then
            for _, mn in ipairs(team.members) do
                local short = mn:match("^([^%-]+)")
                local gi = roster[short]
                local mr = CreateFrame("Frame", nil, tab.content)
                mr:SetSize(cw, 16)
                mr:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)
                local dot = mr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                dot:SetPoint("LEFT", mr, "LEFT", 12, 0)
                dot:SetText(gi and (gi.online and "|cff00ff00\194\183|r" or "|cff555555\194\183|r") or "|cffff4444\194\183|r")
                local nt = mr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                nt:SetPoint("LEFT", dot, "RIGHT", 4, 0)
                if gi then
                    nt:SetText("|c" .. (WGS.CLASS_COLORS[gi.class] or "ffffffff") .. short .. "|r")
                else
                    nt:SetText("|cff666666" .. short .. "|r")
                end
                if gi then
                    local it = mr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    it:SetPoint("LEFT", nt, "RIGHT", 6, 0)
                    it:SetText("|cff555555Lv" .. gi.level .. " " .. gi.rank .. "|r")
                end
                yOff = yOff - 16
            end
        else
            local noM = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            noM:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 16, yOff)
            noM:SetText("(no members)")
            yOff = yOff - 16
        end
        yOff = yOff - 6
    end
    tab.content:SetHeight(math.abs(yOff) + 10)
end

local function BuildRosterTab(parent)
    BuildSubNav(parent, ROSTER_SUB_NAMES, function(p, i)
        SelectSubView(p, i, ROSTER_SUB_COUNT)
        if i == ROSTER_SUB_TEAMS then
            PopulateTeams(p.subViews[i])
        elseif i == ROSTER_SUB_CHECK then
            PopulateRosterCheck(p.subViews[i])
        end
    end)
    BuildTeamsSubView(parent.subViews[ROSTER_SUB_TEAMS])
    BuildRosterCheckSubView(parent.subViews[ROSTER_SUB_CHECK])
    SelectSubView(parent, ROSTER_SUB_TEAMS, ROSTER_SUB_COUNT)
end

local function RefreshRosterSubView(tab)
    if not tab or not tab:IsVisible() then return end
    local sub = tab.selectedSub or ROSTER_SUB_TEAMS
    if sub == ROSTER_SUB_TEAMS then
        PopulateTeams(tab.subViews[sub])
    elseif sub == ROSTER_SUB_CHECK then
        PopulateRosterCheck(tab.subViews[sub])
    end
end

---------------------------------------------------------------------------
-- Tab 3: Raid (sub-navigation)
---------------------------------------------------------------------------

local function SelectRaidSubView(tab, index)
    SelectSubView(tab, index, RAID_SUB_COUNT)
end

local function BuildBossNotesSubView(sv)
    local lbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, 0)
    lbl:SetText("Boss:")

    sv.dropBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.dropBtn:SetSize(250, 22)
    sv.dropBtn:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    sv.dropBtn:SetText("Select a boss...")
    sv.selectedBoss = nil

    -- Dropdown menu
    sv.dropMenu = CreateFrame("Frame", nil, sv, "BackdropTemplate")
    sv.dropMenu:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    sv.dropMenu:SetBackdropColor(0, 0, 0, 0.95)
    sv.dropMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    sv.dropMenu:Hide()
    sv.dropMenuButtons = {}

    sv.dropBtn:SetScript("OnClick", function()
        if sv.dropMenu:IsShown() then
            sv.dropMenu:Hide()
            return
        end
        -- Populate dropdown
        for _, btn in ipairs(sv.dropMenuButtons) do btn:Hide() end
        local bosses = WGS:GetBossNotesList()
        if #bosses == 0 then return end

        local bh = 22
        sv.dropMenu:SetSize(250, #bosses * bh + 8)
        sv.dropMenu:ClearAllPoints()
        sv.dropMenu:SetPoint("TOPLEFT", sv.dropBtn, "BOTTOMLEFT", 0, -2)

        for i, name in ipairs(bosses) do
            local btn = sv.dropMenuButtons[i]
            if not btn then
                btn = CreateFrame("Button", nil, sv.dropMenu)
                btn:SetSize(242, bh)
                btn:SetNormalFontObject("GameFontHighlightSmall")
                btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                btn.text:SetAllPoints()
                btn.text:SetJustifyH("LEFT")
                sv.dropMenuButtons[i] = btn
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", sv.dropMenu, "TOPLEFT", 4, -(i - 1) * bh - 4)
            btn.text:SetText("  " .. name)
            btn:SetScript("OnClick", function()
                sv.selectedBoss = name
                sv.dropBtn:SetText(name)
                sv.dropMenu:Hide()
                WGS:PopulateBossNotes(sv, name)
            end)
            btn:Show()
        end
        sv.dropMenu:Show()
    end)

    -- Notes display area
    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -28)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
    sv.noteText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sv.noteText:SetPoint("TOPLEFT", content, "TOPLEFT", 5, -5)
    sv.noteText:SetPoint("TOPRIGHT", content, "TOPRIGHT", -5, -5)
    sv.noteText:SetJustifyH("LEFT")
    sv.noteText:SetJustifyV("TOP")
    sv.noteText:SetWordWrap(true)
end

local function BuildRaidTab(parent)
    parent.subViews = {}
    parent.subButtons = {}
    parent.selectedSub = RAID_SUB_COMP

    local btnX = 0
    for i = 1, RAID_SUB_COUNT do
        local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        btn:SetSize(138, 22)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", btnX, 0)
        btn:SetText(RAID_SUB_NAMES[i])
        btn:SetScript("OnClick", function() SelectRaidSubView(parent, i) end)
        parent.subButtons[i] = btn
        btnX = btnX + 142
    end

    for i = 1, RAID_SUB_COUNT do
        local sv = CreateFrame("Frame", nil, parent)
        sv:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
        sv:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
        sv:Hide()
        parent.subViews[i] = sv
    end

    -- Raid Comp sub-view
    local sv1 = parent.subViews[RAID_SUB_COMP]
    sv1.scrollFrame, sv1.content = CreateScrollContent(sv1)

    -- Readiness sub-view
    local sv2 = parent.subViews[RAID_SUB_READINESS]
    sv2.summary = sv2:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sv2.summary:SetPoint("TOPLEFT", sv2, "TOPLEFT", 5, 0)
    sv2.summary:SetWidth(660)
    sv2.summary:SetJustifyH("LEFT")

    local rsf = CreateFrame("ScrollFrame", nil, sv2, "UIPanelScrollFrameTemplate")
    rsf:SetPoint("TOPLEFT", sv2, "TOPLEFT", 0, -35)
    rsf:SetPoint("BOTTOMRIGHT", sv2, "BOTTOMRIGHT", -22, 30)
    local rc = CreateFrame("Frame", nil, rsf)
    rc:SetWidth(660)
    rc:SetHeight(1)
    rsf:SetScrollChild(rc)
    sv2.scrollFrame = rsf
    sv2.content = rc

    sv2.announceBtn = CreateFrame("Button", nil, sv2, "UIPanelButtonTemplate")
    sv2.announceBtn:SetSize(160, 26)
    sv2.announceBtn:SetPoint("BOTTOMLEFT", sv2, "BOTTOMLEFT", 5, 0)
    sv2.announceBtn:SetText("Announce to Raid")

    -- Events sub-view
    local sv3 = parent.subViews[RAID_SUB_EVENTS]
    sv3.scrollFrame, sv3.content = CreateScrollContent(sv3)

    -- Boss Notes sub-view
    BuildBossNotesSubView(parent.subViews[RAID_SUB_BOSSNOTES])

    -- Show first sub-view
    SelectRaidSubView(parent, RAID_SUB_COMP)
end

local function RefreshRaidSubView(tab)
    if not tab or not tab:IsVisible() then return end
    local sub = tab.selectedSub or RAID_SUB_COMP
    local sv = tab.subViews[sub]
    if sub == RAID_SUB_COMP then
        WGS:PopulateRaidComp(sv)
    elseif sub == RAID_SUB_READINESS then
        WGS:PopulateReadiness(sv)
    elseif sub == RAID_SUB_EVENTS then
        WGS:PopulateEvents(sv)
    elseif sub == RAID_SUB_BOSSNOTES then
        WGS:PopulateBossNotes(sv, sv.selectedBoss)
    end
end

---------------------------------------------------------------------------
-- Tab 4: Loot (History + Wishlists sub-views)
---------------------------------------------------------------------------

local ITEM_QUALITY_COLORS = {
    [2] = "ff1eff00",  -- Uncommon (green)
    [3] = "ff0070dd",  -- Rare (blue)
    [4] = "ffa335ee",  -- Epic (purple)
    [5] = "ffff8000",  -- Legendary (orange)
    [6] = "ffe6cc80",  -- Artifact (gold)
    [7] = "ff00ccff",  -- Heirloom
}

local function BuildLootHistorySubView(sv)
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

local function PopulateLootHistory(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local loot = WGS.db.global.loot or {}
    local filter = tab.filterText or ""
    local roster = WGS:GetGuildRosterLookup()

    -- Sort by timestamp descending (newest first)
    local sorted = {}
    for i = #loot, 1, -1 do sorted[#sorted + 1] = loot[i] end

    local yOff = 0
    local shown = 0
    local MAX_ROWS = 200

    for _, entry in ipairs(sorted) do
        if shown >= MAX_ROWS then break end

        -- Apply filter
        local matches = filter == ""
        if not matches then
            local itemName = (entry.itemName or ""):lower()
            local player = (entry.player or ""):lower()
            local boss = (entry.boss or ""):lower()
            if itemName:find(filter, 1, true) or player:find(filter, 1, true) or boss:find(filter, 1, true) then
                matches = true
            end
        end

        if matches then
            local row = CreateFrame("Frame", nil, tab.content)
            row:SetSize(660, 18)
            row:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

            -- Item name (quality colored)
            local qColor = ITEM_QUALITY_COLORS[entry.itemQuality or 4] or "ffa335ee"
            local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            itemText:SetPoint("LEFT", row, "LEFT", 5, 0)
            itemText:SetWidth(220)
            itemText:SetJustifyH("LEFT")
            itemText:SetText("|c" .. qColor .. (entry.itemName or "Unknown") .. "|r")

            -- Player (class colored)
            local short = (entry.player or ""):match("^([^%-]+)") or entry.player or "?"
            local gi = roster[short]
            local pColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local playerText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            playerText:SetPoint("LEFT", itemText, "RIGHT", 4, 0)
            playerText:SetWidth(120)
            playerText:SetJustifyH("LEFT")
            playerText:SetText("|c" .. pColor .. short .. "|r")

            -- Boss
            local bossText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            bossText:SetPoint("LEFT", playerText, "RIGHT", 4, 0)
            bossText:SetWidth(140)
            bossText:SetJustifyH("LEFT")
            local bossStr = entry.boss and entry.boss ~= "" and entry.boss or "—"
            bossText:SetText("|cff888888" .. bossStr .. "|r")

            -- Date
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
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText(filter == "" and "No loot recorded yet." or "No loot matching filter.")
        tab.content:SetHeight(30)
    else
        tab.content:SetHeight(math.abs(yOff) + 10)
    end

    tab.countText:SetText(string.format("|cff888888Showing %d of %d|r", shown, #loot))
end

---------------------------------------------------------------------------
-- Wishlists sub-view (lives inside Tab 4: Loot)
---------------------------------------------------------------------------

local PRIORITY_ORDER = { BiS = 1, High = 2, Medium = 3, Low = 4 }
local PRIORITY_COLORS = {
    BiS    = "ffff8000",  -- Orange
    High   = "ffa335ee",  -- Purple
    Medium = "ff0070dd",  -- Blue
    Low    = "ff1eff00",  -- Green
}

local function BuildWishlistsSubView(sv)
    local lbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -2)
    lbl:SetText("Boss:")

    sv.dropBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.dropBtn:SetSize(280, 22)
    sv.dropBtn:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    sv.dropBtn:SetText("(All items)")
    sv.selectedBoss = nil

    sv.dropMenu = CreateFrame("Frame", nil, sv, "BackdropTemplate")
    sv.dropMenu:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    sv.dropMenu:SetBackdropColor(0, 0, 0, 0.95)
    sv.dropMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    sv.dropMenu:Hide()
    sv.dropMenuButtons = {}

    sv.dropBtn:SetScript("OnClick", function()
        if sv.dropMenu:IsShown() then sv.dropMenu:Hide(); return end

        for _, btn in ipairs(sv.dropMenuButtons) do btn:Hide() end

        local bossSet = {}
        for _, entry in ipairs(WGS.db.global.loot or {}) do
            if entry.boss and entry.boss ~= "" then bossSet[entry.boss] = true end
        end
        local bosses = { "(All items)" }
        for name in pairs(bossSet) do bosses[#bosses + 1] = name end
        table.sort(bosses, function(a, b)
            if a == "(All items)" then return true end
            if b == "(All items)" then return false end
            return a < b
        end)

        local bh = 22
        sv.dropMenu:SetSize(280, #bosses * bh + 8)
        sv.dropMenu:ClearAllPoints()
        sv.dropMenu:SetPoint("TOPLEFT", sv.dropBtn, "BOTTOMLEFT", 0, -2)

        for i, name in ipairs(bosses) do
            local btn = sv.dropMenuButtons[i]
            if not btn then
                btn = CreateFrame("Button", nil, sv.dropMenu)
                btn:SetSize(272, bh)
                btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                btn.text:SetAllPoints()
                btn.text:SetJustifyH("LEFT")
                sv.dropMenuButtons[i] = btn
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", sv.dropMenu, "TOPLEFT", 4, -(i - 1) * bh - 4)
            btn.text:SetText("  " .. name)
            btn:SetScript("OnClick", function()
                sv.selectedBoss = (name == "(All items)") and nil or name
                sv.dropBtn:SetText(name)
                sv.dropMenu:Hide()
                if sv._refreshFn then sv._refreshFn() end
            end)
            btn:Show()
        end
        sv.dropMenu:Show()
    end)

    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -28)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
end

local function PopulateWishlists(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local wishlists = WGS.db.global.wishlists or {}
    if #wishlists == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText("No wishlists imported. Import from web app first.")
        tab.content:SetHeight(30)
        return
    end

    -- Build item -> wishers map
    local itemWishers = {}  -- [itemID] = { { playerName, priority, note }, ... }
    local itemNames = {}    -- [itemID] = last-seen name (from loot history or wishlist entry)
    for _, entry in ipairs(wishlists) do
        if entry.items then
            for _, item in ipairs(entry.items) do
                if item.itemID then
                    itemWishers[item.itemID] = itemWishers[item.itemID] or {}
                    table.insert(itemWishers[item.itemID], {
                        playerName = entry.playerName,
                        priority = item.priority,
                        note = item.note,
                    })
                end
            end
        end
    end

    -- Fill item names from loot history
    for _, lootEntry in ipairs(WGS.db.global.loot or {}) do
        if lootEntry.itemID and lootEntry.itemName and not itemNames[lootEntry.itemID] then
            itemNames[lootEntry.itemID] = lootEntry.itemName
        end
    end
    -- Fill from C_Item cache for items we haven't seen drop
    for itemID in pairs(itemWishers) do
        if not itemNames[itemID] then
            local name = C_Item.GetItemInfo(itemID)
            if name then itemNames[itemID] = name end
        end
    end

    -- If a boss is selected, restrict to items seen dropping from that boss
    local allowedIds = nil
    if tab.selectedBoss then
        allowedIds = {}
        for _, lootEntry in ipairs(WGS.db.global.loot or {}) do
            if lootEntry.boss == tab.selectedBoss and lootEntry.itemID then
                allowedIds[lootEntry.itemID] = true
            end
        end
    end

    -- Collect items to render (sorted by wisher count descending, then itemID)
    local itemsToShow = {}
    for itemID, wishers in pairs(itemWishers) do
        if not allowedIds or allowedIds[itemID] then
            itemsToShow[#itemsToShow + 1] = { itemID = itemID, wishers = wishers }
        end
    end
    table.sort(itemsToShow, function(a, b)
        if #a.wishers ~= #b.wishers then return #a.wishers > #b.wishers end
        return a.itemID < b.itemID
    end)

    if #itemsToShow == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        if tab.selectedBoss then
            noData:SetText("No wishlisted items from " .. tab.selectedBoss .. " in loot history yet.")
        else
            noData:SetText("No wishlisted items found.")
        end
        tab.content:SetHeight(30)
        return
    end

    local roster = WGS:GetGuildRosterLookup()
    local yOff = 0

    for _, item in ipairs(itemsToShow) do
        -- Item header row
        local header = CreateFrame("Frame", nil, tab.content)
        header:SetSize(660, 20)
        header:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

        local headerText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        headerText:SetPoint("LEFT", header, "LEFT", 5, 0)
        local name = itemNames[item.itemID] or ("Item " .. item.itemID)
        headerText:SetText(string.format("|cffa335ee%s|r  |cff888888(%d wisher%s)|r",
            name, #item.wishers, #item.wishers == 1 and "" or "s"))
        yOff = yOff - 20

        -- Sort wishers by priority
        table.sort(item.wishers, function(a, b)
            return (PRIORITY_ORDER[a.priority] or 99) < (PRIORITY_ORDER[b.priority] or 99)
        end)

        for _, w in ipairs(item.wishers) do
            local row = CreateFrame("Frame", nil, tab.content)
            row:SetSize(660, 16)
            row:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

            local short = (w.playerName or ""):match("^([^%-]+)") or w.playerName or "?"
            local gi = roster[short]
            local pColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local pText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            pText:SetPoint("LEFT", row, "LEFT", 25, 0)
            pText:SetText("|c" .. pColor .. short .. "|r")

            local prColor = PRIORITY_COLORS[w.priority] or "ffffffff"
            local prText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            prText:SetPoint("LEFT", pText, "RIGHT", 10, 0)
            prText:SetText("|c" .. prColor .. (w.priority or "?") .. "|r")

            if w.note and w.note ~= "" then
                local nText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                nText:SetPoint("LEFT", prText, "RIGHT", 8, 0)
                nText:SetText("|cff888888(" .. w.note .. ")|r")
            end

            yOff = yOff - 16
        end

        yOff = yOff - 4
    end

    tab.content:SetHeight(math.abs(yOff) + 10)
end

local function BuildLootTab(parent)
    BuildSubNav(parent, LOOT_SUB_NAMES, function(p, i)
        SelectSubView(p, i, LOOT_SUB_COUNT)
        if i == LOOT_SUB_HISTORY then
            PopulateLootHistory(p.subViews[i])
        elseif i == LOOT_SUB_WISHLISTS then
            PopulateWishlists(p.subViews[i])
        end
    end)
    BuildLootHistorySubView(parent.subViews[LOOT_SUB_HISTORY])
    BuildWishlistsSubView(parent.subViews[LOOT_SUB_WISHLISTS])
    SelectSubView(parent, LOOT_SUB_HISTORY, LOOT_SUB_COUNT)
end

local function RefreshLootSubView(tab)
    if not tab or not tab:IsVisible() then return end
    local sub = tab.selectedSub or LOOT_SUB_HISTORY
    if sub == LOOT_SUB_HISTORY then
        PopulateLootHistory(tab.subViews[sub])
    elseif sub == LOOT_SUB_WISHLISTS then
        PopulateWishlists(tab.subViews[sub])
    end
end

---------------------------------------------------------------------------
-- Roster Check sub-view (lives inside Tab 2: Roster)
---------------------------------------------------------------------------

function BuildRosterCheckSubView(sv)
    sv.header = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sv.header:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -2)
    sv.header:SetWidth(660)
    sv.header:SetJustifyH("LEFT")

    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -22)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 30)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content

    sv.announceBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.announceBtn:SetSize(180, 26)
    sv.announceBtn:SetPoint("BOTTOMLEFT", sv, "BOTTOMLEFT", 5, 0)
    sv.announceBtn:SetText("Announce Missing to Raid")
    sv.announceBtn:Hide()

    sv.refreshBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.refreshBtn:SetSize(100, 26)
    sv.refreshBtn:SetPoint("LEFT", sv.announceBtn, "RIGHT", 8, 0)
    sv.refreshBtn:SetText("Refresh")
    sv.refreshBtn:SetScript("OnClick", function()
        if sv._refreshFn then sv._refreshFn() end
    end)
end

-- Returns { expected, actual } lists for today's event
local function BuildRosterCheckData()
    local event = WGS.FindTodayEventForTeam and WGS:FindTodayEventForTeam(nil) or nil
    if not event then
        return nil, "No event scheduled for today."
    end

    local teamId = event.team_id or event.teamId
    local team = nil
    if teamId then
        for _, t in ipairs(WGS.db.global.teams or {}) do
            if t.id == teamId then team = t; break end
        end
    end

    if not team then
        return nil, "Today's event has no linked team."
    end

    -- Expected: set of character names (main + alts for each player)
    local expected = {}       -- [charName-realm] = { playerId, isMain, mainName }
    local expectedOrder = {}  -- ordered list of main names

    if team.playerMembers then
        local chars = WGS.db.global.characters or {}
        for _, pm in ipairs(team.playerMembers) do
            local info = chars[pm.playerId]
            local main = pm.main or (info and info.main) or nil
            if main then
                expected[main] = { playerId = pm.playerId, isMain = true, mainName = main }
                expectedOrder[#expectedOrder + 1] = main
                if info and info.alts then
                    for _, alt in ipairs(info.alts) do
                        expected[alt] = { playerId = pm.playerId, isMain = false, mainName = main }
                    end
                end
            end
        end
    elseif team.members then
        for _, m in ipairs(team.members) do
            expected[m] = { isMain = true, mainName = m }
            expectedOrder[#expectedOrder + 1] = m
        end
    end

    -- Actual: characters in current raid (or last session)
    local actual = {}  -- [charName-realm] = true
    local actualSource = nil
    if IsInRaid() or IsInGroup() then
        local members = WGS:GetRaidMembers()
        for name in pairs(members) do actual[name] = true end
        actualSource = "current raid"
    else
        local attendance = WGS.db.global.attendance or {}
        if #attendance > 0 then
            local last = attendance[#attendance]
            if last.memberList then
                for _, m in ipairs(last.memberList) do
                    if m.name then actual[m.name] = true end
                end
                actualSource = "last session"
            end
        end
    end

    if not actualSource then
        return nil, "Not in a raid and no attendance history."
    end

    return {
        event = event,
        team = team,
        expected = expected,
        expectedOrder = expectedOrder,
        actual = actual,
        actualSource = actualSource,
    }
end

function PopulateRosterCheck(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local data, err = BuildRosterCheckData()
    if not data then
        tab.header:SetText("|cff888888" .. (err or "No data") .. "|r")
        tab.announceBtn:Hide()
        tab.content:SetHeight(10)
        return
    end

    tab.header:SetText(string.format("|cffffd100%s|r  |cff888888(%s, vs %s)|r",
        data.event.title or "Event", data.team.name or "?", data.actualSource))

    local roster = WGS:GetGuildRosterLookup()
    local yOff = 0
    local cw = 660

    -- Classify each expected player: present (any of their chars in actual) or missing
    local present = {}
    local missing = {}
    local presentChars = {}  -- track which actual characters matched (for extra detection)

    for _, main in ipairs(data.expectedOrder) do
        local playerId = data.expected[main].playerId
        local matched = nil
        -- Check main first
        if data.actual[main] then
            matched = main
            presentChars[main] = true
        else
            -- Check alts by playerId (reverse-resolve through expected map)
            for altName, info in pairs(data.expected) do
                if info.playerId == playerId and not info.isMain and data.actual[altName] then
                    matched = altName
                    presentChars[altName] = true
                    break
                end
            end
        end
        if matched then
            present[#present + 1] = { main = main, matched = matched }
        else
            missing[#missing + 1] = main
        end
    end

    -- Extra: actual raid members not in expected (pugs, alts of team members annotated)
    local extra = {}
    for actualName in pairs(data.actual) do
        if not presentChars[actualName] and not data.expected[actualName] then
            -- Maybe an alt of someone on the team (resolve via character map)
            local pid = WGS:ResolvePlayerForCharacter(actualName)
            local altOfMain = nil
            if pid then
                for _, info in pairs(data.expected) do
                    if info.playerId == pid then
                        altOfMain = info.mainName
                        break
                    end
                end
            end
            extra[#extra + 1] = { name = actualName, altOfMain = altOfMain }
        end
    end

    local function addSectionHeader(text)
        local h = tab.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, yOff)
        h:SetText(text)
        yOff = yOff - 20
    end

    local function addRow(text)
        local r = CreateFrame("Frame", nil, tab.content)
        r:SetSize(cw, 16)
        r:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)
        local t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t:SetPoint("LEFT", r, "LEFT", 15, 0)
        t:SetText(text)
        yOff = yOff - 16
    end

    addSectionHeader("|cff00ff00Present (" .. #present .. ")|r")
    if #present == 0 then
        addRow("|cff666666(none)|r")
    else
        for _, p in ipairs(present) do
            local short = p.main:match("^([^%-]+)") or p.main
            local gi = roster[short]
            local cColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local label = "|c" .. cColor .. short .. "|r"
            if p.matched ~= p.main then
                local altShort = p.matched:match("^([^%-]+)") or p.matched
                label = label .. " |cff888888(on alt: " .. altShort .. ")|r"
            end
            addRow(label)
        end
    end
    yOff = yOff - 6

    addSectionHeader("|cffff4444Missing (" .. #missing .. ")|r")
    if #missing == 0 then
        addRow("|cff666666(none)|r")
    else
        for _, m in ipairs(missing) do
            local short = m:match("^([^%-]+)") or m
            local gi = roster[short]
            local cColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local status = gi and (gi.online and "|cff00ff00online|r" or "|cff555555offline|r") or "|cffff4444not in guild|r"
            addRow("|c" .. cColor .. short .. "|r  " .. status)
        end
    end
    yOff = yOff - 6

    addSectionHeader("|cffffcc00Extra (" .. #extra .. ")|r")
    if #extra == 0 then
        addRow("|cff666666(none)|r")
    else
        for _, e in ipairs(extra) do
            local short = e.name:match("^([^%-]+)") or e.name
            local gi = roster[short]
            local cColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local label = "|c" .. cColor .. short .. "|r"
            if e.altOfMain then
                local mainShort = e.altOfMain:match("^([^%-]+)") or e.altOfMain
                label = label .. " |cff888888(alt of " .. mainShort .. ")|r"
            else
                label = label .. " |cff888888(pug)|r"
            end
            addRow(label)
        end
    end

    tab.content:SetHeight(math.abs(yOff) + 10)

    -- Announce button wiring
    if #missing > 0 and (IsInRaid() or IsInGroup()) then
        tab.announceBtn:Show()
        tab.announceBtn:SetScript("OnClick", function()
            local channel = IsInRaid() and "RAID" or "PARTY"
            C_ChatInfo.SendChatMessage("[GuildHall] Missing for " .. (data.event.title or "event") .. ":", channel)
            local names = {}
            for _, m in ipairs(missing) do
                names[#names + 1] = m:match("^([^%-]+)") or m
            end
            -- Batch names into chunks to avoid message length limit
            local chunk = ""
            for _, n in ipairs(names) do
                if #chunk + #n + 2 > 200 then
                    C_ChatInfo.SendChatMessage("  " .. chunk, channel)
                    chunk = n
                else
                    chunk = chunk == "" and n or (chunk .. ", " .. n)
                end
            end
            if chunk ~= "" then
                C_ChatInfo.SendChatMessage("  " .. chunk, channel)
            end
        end)
    else
        tab.announceBtn:Hide()
    end
end

---------------------------------------------------------------------------
-- Tab 7: Import/Export (stacked)
---------------------------------------------------------------------------

local function BuildSyncTab(parent)
    local midY = -245

    -- Import section
    local ih = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ih:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, 0)
    ih:SetText("|cffffd100Import from Web App|r")

    local ii = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ii:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -18)
    ii:SetText(L["IMPORT_PROMPT"])

    local isf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    isf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -35)
    isf:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -22, -35)
    isf:SetHeight(160)

    local ieb = CreateFrame("EditBox", nil, isf)
    ieb:SetMultiLine(true)
    ieb:SetAutoFocus(false)
    ieb:SetFontObject("ChatFontNormal")
    ieb:SetWidth(660)
    ieb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    isf:SetScrollChild(ieb)
    isf:EnableMouse(true)
    isf:SetScript("OnMouseDown", function() ieb:SetFocus() end)
    parent.importEditBox = ieb

    local btnImport = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnImport:SetSize(100, 25)
    btnImport:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -200)
    btnImport:SetText("Import")
    btnImport:SetScript("OnClick", function()
        local text = ieb:GetText()
        if text and text ~= "" then
            if WGS:DecodeAndImport(text) then
                ieb:SetText("")
                ieb:ClearFocus()
                WGS:RefreshMainFrame()
            end
        end
    end)

    local btnClearImport = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnClearImport:SetSize(80, 25)
    btnClearImport:SetPoint("LEFT", btnImport, "RIGHT", 8, 0)
    btnClearImport:SetText("Clear")
    btnClearImport:SetScript("OnClick", function()
        ieb:SetText("")
        ieb:SetFocus()
    end)

    -- Divider
    local div = parent:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, midY + 5)
    div:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -5, midY + 5)
    div:SetColorTexture(0.4, 0.4, 0.4, 0.5)

    -- Export section
    local eh = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    eh:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, midY)
    eh:SetText("|cffffd100Export Data|r")

    local ei = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ei:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, midY - 18)
    ei:SetText("Copy the text below and paste it into your guild web app.")

    local esf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    esf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, midY - 35)
    esf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 30)

    local eeb = CreateFrame("EditBox", nil, esf)
    eeb:SetMultiLine(true)
    eeb:SetAutoFocus(false)
    eeb:SetFontObject("ChatFontNormal")
    eeb:SetWidth(660)
    eeb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    esf:SetScrollChild(eeb)
    esf:EnableMouse(true)
    esf:SetScript("OnMouseDown", function() eeb:SetFocus() end)
    parent.exportEditBox = eeb

    local btnExport = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnExport:SetSize(100, 25)
    btnExport:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 5, 0)
    btnExport:SetText("Export")
    btnExport:SetScript("OnClick", function()
        local encoded = WGS:ExportAll()
        if encoded then
            eeb:SetText(encoded)
            eeb:SetFocus()
            eeb:HighlightText()
            WGS.db.global.lastExport = WGS:GetTimestamp()
            WGS:Print(L["EXPORT_COPIED"])
        end
    end)

    local btnSelectAll = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnSelectAll:SetSize(100, 25)
    btnSelectAll:SetPoint("LEFT", btnExport, "RIGHT", 8, 0)
    btnSelectAll:SetText("Select All")
    btnSelectAll:SetScript("OnClick", function()
        eeb:SetFocus()
        eeb:HighlightText()
    end)

    local btnClearExported = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnClearExported:SetSize(160, 25)
    btnClearExported:SetPoint("LEFT", btnSelectAll, "RIGHT", 8, 0)
    btnClearExported:SetText("Clear Exported Data")
    btnClearExported:SetScript("OnClick", function()
        StaticPopup_Show("WGS_CONFIRM_CLEAR_EXPORTED")
    end)
end

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
    local tab = frame.selectedTab or TAB_DASHBOARD
    if tab == TAB_DASHBOARD then
        RefreshDashboard(frame.tabContents[TAB_DASHBOARD])
    elseif tab == TAB_ROSTER then
        RefreshRosterSubView(frame.tabContents[TAB_ROSTER])
    elseif tab == TAB_RAID then
        RefreshRaidSubView(frame.tabContents[TAB_RAID])
    elseif tab == TAB_LOOT then
        RefreshLootSubView(frame.tabContents[TAB_LOOT])
    end
    -- Sync tab doesn't need auto-refresh

    -- Status bar
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

    -- Build tab content
    BuildDashboardTab(f.tabContents[TAB_DASHBOARD])
    BuildRosterTab(f.tabContents[TAB_ROSTER])
    BuildRaidTab(f.tabContents[TAB_RAID])
    BuildLootTab(f.tabContents[TAB_LOOT])
    BuildSyncTab(f.tabContents[TAB_SYNC])

    -- Wire back-pointers so in-tab controls (search box, dropdown, refresh btn)
    -- can trigger a re-render. These point to the actual sub-view, not the tab frame.
    local lootTab = f.tabContents[TAB_LOOT]
    lootTab.subViews[LOOT_SUB_HISTORY]._refreshFn = function()
        PopulateLootHistory(lootTab.subViews[LOOT_SUB_HISTORY])
    end
    lootTab.subViews[LOOT_SUB_WISHLISTS]._refreshFn = function()
        PopulateWishlists(lootTab.subViews[LOOT_SUB_WISHLISTS])
    end
    local rosterTab = f.tabContents[TAB_ROSTER]
    rosterTab.subViews[ROSTER_SUB_CHECK]._refreshFn = function()
        PopulateRosterCheck(rosterTab.subViews[ROSTER_SUB_CHECK])
    end

    -- Wire attendance button (needs mainFrame ref for refresh)
    f.tabContents[TAB_DASHBOARD].btnAttendance:SetScript("OnClick", function()
        WGS:ToggleAttendance()
        RefreshDashboard(f.tabContents[TAB_DASHBOARD])
        RefreshCurrentTab(f)
    end)

    -- Show first tab
    SelectTab(f, TAB_DASHBOARD)
    f.tabContents[TAB_DASHBOARD]:Show()

    -- Refresh on show + periodic ticker while visible
    f:SetScript("OnShow", function(self)
        RefreshCurrentTab(self)
    end)
    f:SetScript("OnUpdate", function(self, elapsed)
        self._tick = (self._tick or 0) + elapsed
        if self._tick < 2 then return end
        self._tick = 0
        if self:IsShown() and self.selectedTab == TAB_DASHBOARD then
            RefreshDashboard(self.tabContents[TAB_DASHBOARD])
        end
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
        if tabIndex == TAB_RAID then
            SelectSubView(mainFrame.tabContents[TAB_RAID], subIndex, RAID_SUB_COUNT)
        elseif tabIndex == TAB_ROSTER then
            SelectSubView(mainFrame.tabContents[TAB_ROSTER], subIndex, ROSTER_SUB_COUNT)
        elseif tabIndex == TAB_LOOT then
            SelectSubView(mainFrame.tabContents[TAB_LOOT], subIndex, LOOT_SUB_COUNT)
        end
    end
    RefreshCurrentTab(mainFrame)
end

function WGS:SelectBossInTab(encounterName)
    if not mainFrame then return end
    local raidTab = mainFrame.tabContents[TAB_RAID]
    if not raidTab then return end
    local sv = raidTab.subViews[RAID_SUB_BOSSNOTES]
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
