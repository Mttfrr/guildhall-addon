---@type GuildHall
local WGS = GuildHall

-- This file used to hold a 60×180 "Tracking" HUD anchored TOPRIGHT that
-- showed live member count + raid duration. Attendance capture became
-- silent automation (RAID_INSTANCE_WELCOME → auto-start, GROUP_LEFT →
-- auto-stop), so the HUD was removed. The export-reminder popup below
-- is what's left — still useful as the one end-of-raid prompt that
-- nudges the officer to paste the export string into the web app.
--
-- The popup chrome itself lives in the shared WGS:ShowActionDialog
-- builder (UI/UIHelpers.lua) so this reminder and the raid-start
-- tracking prompt read identically — one panel style for every
-- GuildHall nudge.
--
-- File name kept (`AttendanceFrame.lua`) instead of renamed to
-- `ExportReminder.lua` to avoid churning UI.xml + the .toc.

---------------------------------------------------------------------------
-- Export Reminder popup (shown at end of raid)
---------------------------------------------------------------------------

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

    self:ShowActionDialog({
        key         = "export",
        title       = "|cffffd100GuildHall: Raid Over!|r",
        body        = table.concat(lines, "\n"),
        acceptText  = "Export Now",
        onAccept    = function() WGS:ShowExportFrame() end,
        declineText = "Later",
    })
end
