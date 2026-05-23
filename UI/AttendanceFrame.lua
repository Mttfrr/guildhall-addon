---@type GuildHall
local WGS = GuildHall

-- This file used to hold a 60×180 "Tracking" HUD anchored TOPRIGHT that
-- showed live member count + raid duration. Attendance capture became
-- silent automation (RAID_INSTANCE_WELCOME → auto-start, GROUP_LEFT →
-- auto-stop), so the HUD was removed. The export-reminder popup below
-- is what's left — still useful as the one end-of-raid prompt that
-- nudges the officer to paste the export string into the web app.
--
-- File name kept (`AttendanceFrame.lua`) instead of renamed to
-- `ExportReminder.lua` to avoid churning UI.xml + the .toc.

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
