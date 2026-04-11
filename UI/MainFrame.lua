---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

local mainFrame = nil

local TAB_DASHBOARD = 1
local TAB_ROSTER    = 2
local TAB_RAID      = 3
local TAB_SYNC      = 4
local TAB_COUNT     = 4
local TAB_NAMES     = { "Dashboard", "Roster", "Raid", "Import/Export" }

local RAID_SUB_COMP      = 1
local RAID_SUB_READINESS = 2
local RAID_SUB_EVENTS    = 3
local RAID_SUB_BOSSNOTES = 4
local RAID_SUB_COUNT     = 4
local RAID_SUB_NAMES     = { "Raid Comp", "Readiness", "Events", "Boss Notes" }

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
    content:SetWidth(560)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    return sf, content
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
-- Tab 2: Roster
---------------------------------------------------------------------------

local function BuildRosterTab(parent)
    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, 0)
    header:SetText("|cffffd100Teams|r")

    local sf, content = CreateScrollContent(parent)
    sf:ClearAllPoints()
    sf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -18)
    sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)
    content:SetWidth(560)

    parent.scrollFrame = sf
    parent.content = content
end

local function RefreshRoster(tab)
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
    local cw = 560

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

---------------------------------------------------------------------------
-- Tab 3: Raid (sub-navigation)
---------------------------------------------------------------------------

local function SelectRaidSubView(tab, index)
    for i = 1, RAID_SUB_COUNT do
        tab.subViews[i]:Hide()
        tab.subButtons[i]:SetNormalFontObject("GameFontNormalSmall")
    end
    tab.subViews[index]:Show()
    tab.subButtons[index]:SetNormalFontObject("GameFontHighlightSmall")
    tab.selectedSub = index
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
    content:SetWidth(560)
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
    sv2.summary:SetWidth(560)
    sv2.summary:SetJustifyH("LEFT")

    local rsf = CreateFrame("ScrollFrame", nil, sv2, "UIPanelScrollFrameTemplate")
    rsf:SetPoint("TOPLEFT", sv2, "TOPLEFT", 0, -35)
    rsf:SetPoint("BOTTOMRIGHT", sv2, "BOTTOMRIGHT", -22, 30)
    local rc = CreateFrame("Frame", nil, rsf)
    rc:SetWidth(560)
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
-- Tab 4: Import/Export (stacked)
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
    ieb:SetWidth(560)
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
    eeb:SetWidth(560)
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
        RefreshRoster(frame.tabContents[TAB_ROSTER])
    elseif tab == TAB_RAID then
        RefreshRaidSubView(frame.tabContents[TAB_RAID])
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
    f:SetSize(620, 580)
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
    BuildSyncTab(f.tabContents[TAB_SYNC])

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

function WGS:SelectMainFrameTab(tabIndex, raidSubView)
    if not mainFrame then mainFrame = CreateMainFrame() end
    if not mainFrame:IsShown() then mainFrame:Show() end
    SelectTab(mainFrame, tabIndex)
    if raidSubView and tabIndex == TAB_RAID then
        SelectRaidSubView(mainFrame.tabContents[TAB_RAID], raidSubView)
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

-- Backward compat
function WGS:UpdateMainFrameSummary()
    self:RefreshMainFrame()
end
