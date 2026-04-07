---@type GuildHall
local WGS = GuildHall

-- Lightweight attendance HUD shown during raids when tracking is active
local hudFrame = nil

local function CreateAttendanceHUD()
    local f = CreateFrame("Frame", "GuildHallAttendanceHUD", UIParent, "BackdropTemplate")
    f:SetSize(180, 60)
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -250, -10)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.8)

    -- Title
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.title:SetPoint("TOP", f, "TOP", 0, -8)
    f.title:SetText("|cff00ff00GuildHall: Tracking|r")

    -- Member count
    f.memberCount = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.memberCount:SetPoint("TOP", f.title, "BOTTOM", 0, -4)
    f.memberCount:SetText("Members: 0")

    -- Duration
    f.duration = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.duration:SetPoint("TOP", f.memberCount, "BOTTOM", 0, -2)
    f.duration:SetText("Duration: 0:00")

    -- Update ticker
    f.elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed < 1 then return end
        self.elapsed = 0
        WGS:UpdateAttendanceHUD()
    end)

    f:Hide()
    return f
end

function WGS:UpdateAttendanceHUD()
    if not hudFrame or not hudFrame:IsShown() then return end
    if not self:IsTrackingAttendance() then
        hudFrame:Hide()
        return
    end

    local members = self:GetRaidMembers()
    local count = 0
    for _ in pairs(members) do count = count + 1 end
    hudFrame.memberCount:SetText("Members: " .. count)

    local startTime = self:GetAttendanceStartTime()
    if startTime then
        local elapsed = time() - startTime
        local minutes = math.floor(elapsed / 60)
        local seconds = elapsed % 60
        hudFrame.duration:SetText(string.format("Duration: %d:%02d", minutes, seconds))
    end
end

function WGS:ShowAttendanceHUD()
    if not hudFrame then
        hudFrame = CreateAttendanceHUD()
    end
    hudFrame:Show()
end

function WGS:HideAttendanceHUD()
    if hudFrame then
        hudFrame:Hide()
    end
end

---------------------------------------------------------------------------
-- Export Reminder popup (shown at end of raid)
---------------------------------------------------------------------------
local reminderFrame = nil

local function CreateExportReminder()
    local f = CreateFrame("Frame", "GuildHallExportReminder", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(340, 200)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("FULLSCREEN_DIALOG")

    f.TitleBg:SetHeight(30)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", f.TitleBg, "TOPLEFT", 5, -3)
    f.title:SetText("|cffffd100GuildHall: Raid Over!|r")

    -- Summary text
    f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.summary:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -40)
    f.summary:SetPoint("TOPRIGHT", f, "TOPRIGHT", -15, -40)
    f.summary:SetJustifyH("LEFT")
    f.summary:SetJustifyV("TOP")
    f.summary:SetWordWrap(true)

    -- Export Now button
    local btnExport = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnExport:SetSize(140, 30)
    btnExport:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 15, 12)
    btnExport:SetText("Export Now")
    btnExport:SetScript("OnClick", function()
        f:Hide()
        WGS:ShowExportFrame()
    end)

    -- Dismiss button
    local btnDismiss = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnDismiss:SetSize(140, 30)
    btnDismiss:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -15, 12)
    btnDismiss:SetText("Later")
    btnDismiss:SetScript("OnClick", function()
        f:Hide()
    end)

    f:Hide()
    return f
end

function WGS:ShowExportReminder()
    local db = self.db.global

    -- Only show if there's actually data to export
    local lootCount = db.loot and #db.loot or 0
    local attendCount = db.attendance and #db.attendance or 0
    local txCount = db.guildBankTransactions and #db.guildBankTransactions or 0
    local goldChanges = db.guildBankMoneyChanges and #db.guildBankMoneyChanges or 0

    if lootCount == 0 and attendCount == 0 and txCount == 0 and goldChanges == 0 then
        return -- nothing to export
    end

    if not reminderFrame then
        reminderFrame = CreateExportReminder()
    end

    -- Build summary
    local lines = {}
    table.insert(lines, "You have unsent data from this raid:")
    table.insert(lines, " ")
    if lootCount > 0 then
        table.insert(lines, "|cffffd100Loot:|r " .. lootCount .. " items")
    end
    if attendCount > 0 then
        table.insert(lines, "|cffffd100Attendance:|r " .. attendCount .. " session(s)")
    end
    if txCount > 0 then
        table.insert(lines, "|cffffd100Bank Transactions:|r " .. txCount)
    end
    if goldChanges > 0 then
        local goldStr = self:GetGuildGoldFormatted()
        table.insert(lines, "|cffffd100Gold Snapshots:|r " .. goldChanges .. (goldStr and (" (" .. goldStr .. ")") or ""))
    end
    table.insert(lines, " ")
    table.insert(lines, "Export now so your guild web app stays up to date!")

    reminderFrame.summary:SetText(table.concat(lines, "\n"))
    reminderFrame:Show()
end

-- Hook attendance start/stop to show/hide HUD
local origStart = WGS.StartAttendanceForTeam
function WGS:StartAttendanceForTeam(teamId, teamName, event)
    origStart(self, teamId, teamName, event)
    if self:IsTrackingAttendance() then
        self:ShowAttendanceHUD()
    end
end

local origStop = WGS.StopAttendance
function WGS:StopAttendance()
    local result = origStop(self)
    self:HideAttendanceHUD()
    return result
end
