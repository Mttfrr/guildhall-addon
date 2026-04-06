---@type WoWGuildSync
local WGS = WoWGuildSync
local L = WoWGuildSync_L

local mainFrame = nil

---------------------------------------------------------------------------
-- Teams panel (scrollable list of imported teams with guild roster linking)
---------------------------------------------------------------------------
local function CreateTeamsPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -250)
    panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -10, 35)

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 5, 0)
    header:SetText("|cffffd100Imported Teams|r")

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -18)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(scrollFrame:GetWidth())
    content:SetHeight(1) -- will be resized dynamically
    scrollFrame:SetScrollChild(content)

    panel.content = content
    panel.scrollFrame = scrollFrame
    return panel
end

local function PopulateTeamsPanel(panel)
    -- Hide and recycle previous children (WoW frames can't be GC'd, so reuse)
    local children = { panel.content:GetChildren() }
    for _, child in ipairs(children) do
        child:Hide()
    end
    -- Hide font strings from previous population
    local regions = { panel.content:GetRegions() }
    for _, region in ipairs(regions) do
        region:Hide()
    end

    local teams = WGS.db.global.teams
    if not teams or #teams == 0 then
        local noData = panel.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 5, -5)
        noData:SetText("No teams imported yet. Use /wgs import to paste the export string from the web app.")
        panel.content:SetHeight(30)
        return
    end

    -- Get guild roster for cross-referencing
    local roster = WGS:GetGuildRosterLookup()

    local yOffset = 0
    local contentWidth = panel.scrollFrame:GetWidth() - 5

    for _, team in ipairs(teams) do
        -- Team header row
        local teamRow = CreateFrame("Frame", nil, panel.content)
        teamRow:SetSize(contentWidth, 20)
        teamRow:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, yOffset)

        local teamName = teamRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        teamName:SetPoint("LEFT", teamRow, "LEFT", 5, 0)
        local memberCount = team.members and #team.members or 0
        teamName:SetText("|cffffd100" .. (team.name or "?") .. "|r  |cff888888(" .. (team.type or "Team") .. " — " .. memberCount .. " members)|r")

        yOffset = yOffset - 22

        -- Member list
        if team.members and #team.members > 0 then
            for _, memberName in ipairs(team.members) do
                local memberRow = CreateFrame("Frame", nil, panel.content)
                memberRow:SetSize(contentWidth, 16)
                memberRow:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, yOffset)

                -- Look up in guild roster (strip realm from member name for matching)
                local shortName = memberName:match("^([^%-]+)")
                local guildInfo = roster[shortName]

                -- Online indicator
                local indicator = memberRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                indicator:SetPoint("LEFT", memberRow, "LEFT", 12, 0)

                if guildInfo then
                    if guildInfo.online then
                        indicator:SetText("|cff00ff00\194\183|r") -- green dot
                    else
                        indicator:SetText("|cff555555\194\183|r") -- grey dot
                    end
                else
                    indicator:SetText("|cffff4444\194\183|r") -- red dot (not in guild)
                end

                -- Character name (class-colored if in guild)
                local nameText = memberRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                nameText:SetPoint("LEFT", indicator, "RIGHT", 4, 0)

                if guildInfo then
                    local colorHex = WGS.CLASS_COLORS[guildInfo.class] or "ffffffff"
                    nameText:SetText("|c" .. colorHex .. shortName .. "|r")
                else
                    nameText:SetText("|cff666666" .. shortName .. "|r")
                end

                -- Level and rank if in guild
                if guildInfo then
                    local infoText = memberRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    infoText:SetPoint("LEFT", nameText, "RIGHT", 6, 0)
                    infoText:SetText("|cff555555Lv" .. guildInfo.level .. " " .. guildInfo.rank .. "|r")
                end

                yOffset = yOffset - 16
            end
        else
            local noMembers = CreateFrame("Frame", nil, panel.content)
            noMembers:SetSize(contentWidth, 16)
            noMembers:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, yOffset)
            local txt = noMembers:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            txt:SetPoint("LEFT", noMembers, "LEFT", 16, 0)
            txt:SetText("(no members)")
            yOffset = yOffset - 16
        end

        yOffset = yOffset - 6 -- spacing between teams
    end

    panel.content:SetHeight(math.abs(yOffset) + 10)
end

---------------------------------------------------------------------------
-- Main frame
---------------------------------------------------------------------------
local function CreateMainFrame()
    local f = CreateFrame("Frame", "WoWGuildSyncMainFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(500, 560)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")

    f.TitleBg:SetHeight(30)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", f.TitleBg, "TOPLEFT", 5, -3)
    f.title:SetText("GuildHall |cffff8800[BETA]|r")

    -- Status bar at bottom
    f.statusBar = CreateFrame("Frame", nil, f)
    f.statusBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10)
    f.statusBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    f.statusBar:SetHeight(20)

    f.statusText = f.statusBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.statusText:SetPoint("LEFT")
    f.statusText:SetTextColor(0.5, 0.5, 0.5)

    -- Content area
    local contentTop = -35
    local buttonWidth = 220
    local buttonHeight = 26
    local spacing = 4
    local col1X = 15
    local col2X = 255

    -- === Column 1: Capture Data ===
    local captureHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    captureHeader:SetPoint("TOPLEFT", f, "TOPLEFT", col1X, contentTop)
    captureHeader:SetText("|cffffd100Capture Data|r")

    local btnY = contentTop - 20

    -- Toggle Attendance
    f.btnAttendance = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.btnAttendance:SetSize(buttonWidth, buttonHeight)
    f.btnAttendance:SetPoint("TOPLEFT", f, "TOPLEFT", col1X, btnY)
    f.btnAttendance:SetText("Start Attendance Tracking")
    f.btnAttendance:SetScript("OnClick", function()
        WGS:ToggleAttendance()
        if WGS:IsTrackingAttendance() then
            f.btnAttendance:SetText("Stop Attendance Tracking")
        else
            f.btnAttendance:SetText("Start Attendance Tracking")
        end
    end)
    btnY = btnY - buttonHeight - spacing

    -- Capture Bank Gold
    local btnCaptureGold = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnCaptureGold:SetSize(buttonWidth, buttonHeight)
    btnCaptureGold:SetPoint("TOPLEFT", f, "TOPLEFT", col1X, btnY)
    btnCaptureGold:SetText("Capture Bank Gold")
    btnCaptureGold:SetScript("OnClick", function()
        WGS:CaptureGold()
        WGS:UpdateMainFrameSummary()
    end)
    btnY = btnY - buttonHeight - spacing

    -- Scan Bank Transactions
    local btnScanTx = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnScanTx:SetSize(buttonWidth, buttonHeight)
    btnScanTx:SetPoint("TOPLEFT", f, "TOPLEFT", col1X, btnY)
    btnScanTx:SetText("Scan Bank Transactions")
    btnScanTx:SetScript("OnClick", function()
        WGS:ScanBankTransactions()
        WGS:UpdateMainFrameSummary()
    end)

    -- === Column 2: Export / Import + Summary ===
    local exportHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    exportHeader:SetPoint("TOPLEFT", f, "TOPLEFT", col2X, contentTop)
    exportHeader:SetText("|cffffd100Sync with Web App|r")

    btnY = contentTop - 20

    -- Export All
    local btnExportAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnExportAll:SetSize(buttonWidth, buttonHeight)
    btnExportAll:SetPoint("TOPLEFT", f, "TOPLEFT", col2X, btnY)
    btnExportAll:SetText("Export All Data")
    btnExportAll:SetScript("OnClick", function() WGS:ShowExportFrame() end)
    btnY = btnY - buttonHeight - spacing

    -- Import from Web
    local btnImport = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnImport:SetSize(buttonWidth, buttonHeight)
    btnImport:SetPoint("TOPLEFT", f, "TOPLEFT", col2X, btnY)
    btnImport:SetText("Import from Web App")
    btnImport:SetScript("OnClick", function() WGS:ShowImportFrame() end)
    btnY = btnY - buttonHeight - spacing

    -- Raid Comp Viewer
    local btnRaidComp = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnRaidComp:SetSize(buttonWidth, buttonHeight)
    btnRaidComp:SetPoint("TOPLEFT", f, "TOPLEFT", col2X, btnY)
    btnRaidComp:SetText("Raid Comp")
    btnRaidComp:SetScript("OnClick", function() WGS:ToggleRaidCompFrame() end)
    btnY = btnY - buttonHeight - spacing

    -- Events Viewer
    local btnEvents = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnEvents:SetSize(buttonWidth, buttonHeight)
    btnEvents:SetPoint("TOPLEFT", f, "TOPLEFT", col2X, btnY)
    btnEvents:SetText("Upcoming Events")
    btnEvents:SetScript("OnClick", function() WGS:ToggleEventsFrame() end)
    btnY = btnY - buttonHeight - spacing

    -- Raid Readiness
    local btnReadiness = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnReadiness:SetSize(buttonWidth, buttonHeight)
    btnReadiness:SetPoint("TOPLEFT", f, "TOPLEFT", col2X, btnY)
    btnReadiness:SetText("Raid Readiness")
    btnReadiness:SetScript("OnClick", function() WGS:ToggleReadinessFrame() end)
    btnY = btnY - buttonHeight - spacing

    -- Compact summary in column 2
    local summaryY = btnY - 8
    f.summaryText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.summaryText:SetPoint("TOPLEFT", f, "TOPLEFT", col2X, summaryY)
    f.summaryText:SetWidth(buttonWidth)
    f.summaryText:SetJustifyH("LEFT")
    f.summaryText:SetJustifyV("TOP")

    -- Info text below column 1
    local infoText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    infoText:SetPoint("TOPLEFT", f, "TOPLEFT", col1X, contentTop - 115)
    infoText:SetWidth(buttonWidth)
    infoText:SetJustifyH("LEFT")
    infoText:SetText("|cff888888guildhall.run|r\nFeedback? Whisper an officer\nor visit the web app.")

    -- Settings button
    local btnSettings = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnSettings:SetSize(80, 22)
    btnSettings:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 8)
    btnSettings:SetText("Settings")
    btnSettings:SetScript("OnClick", function() WGS:OpenConfig() end)

    -- === Teams panel ===
    f.teamsPanel = CreateTeamsPanel(f)

    -- Update on show
    f:SetScript("OnShow", function()
        WGS:UpdateMainFrameSummary()
    end)

    f:Hide()
    return f
end

function WGS:UpdateMainFrameSummary()
    if not mainFrame or not mainFrame.summaryText then return end

    local db = self.db.global
    local lines = {}

    local lootCount = db.loot and #db.loot or 0
    local attendCount = db.attendance and #db.attendance or 0
    local txCount = db.guildBankTransactions and #db.guildBankTransactions or 0

    table.insert(lines, "|cff888888Loot:|r " .. lootCount .. "  |cff888888Attend:|r " .. attendCount)
    table.insert(lines, "|cff888888Bank Tx:|r " .. txCount)

    local goldStr = self:GetGuildGoldFormatted()
    if goldStr then
        table.insert(lines, "|cff888888Gold:|r " .. goldStr)
    end

    if db.lastExport and db.lastExport > 0 then
        table.insert(lines, "|cff555555Exported: " .. date("%m/%d %H:%M", db.lastExport) .. "|r")
    end
    if db.lastImport and db.lastImport > 0 then
        table.insert(lines, "|cff555555Imported: " .. date("%m/%d %H:%M", db.lastImport) .. "|r")
    end

    mainFrame.summaryText:SetText(table.concat(lines, "\n"))

    -- Status bar
    if self:IsTrackingAttendance() then
        mainFrame.statusText:SetText("|cff00ff00Attendance tracking active|r")
        mainFrame.btnAttendance:SetText("Stop Attendance Tracking")
    else
        mainFrame.statusText:SetText("Ready")
        mainFrame.btnAttendance:SetText("Start Attendance Tracking")
    end

    -- Refresh teams panel
    PopulateTeamsPanel(mainFrame.teamsPanel)
end

function WGS:ToggleMainFrame()
    if not mainFrame then
        mainFrame = CreateMainFrame()
    end
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
    end
end
