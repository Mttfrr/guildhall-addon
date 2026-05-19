---@type GuildHall
local WGS = GuildHall

-- Confirmation dialog used by the Sync tab's "Clear Exported Data" button.
-- Registered at file scope so it's available on first use.
StaticPopupDialogs["WGS_CONFIRM_CLEAR_EXPORTED"] = {
    text = "Clear all exported data (loot, attendance, encounters, bank transactions)?\n\nDo this AFTER you've pasted the export into your web app. You can recover within 24h via /gh restore.",
    button1 = "Clear",
    button2 = "Cancel",
    OnAccept = function()
        -- Snapshot first so /gh restore can undo for 24h. Bank gold balance
        -- is left alone because it's a single absolute value, not a journal.
        WGS:SnapshotExportedData()
        WGS.db.global.loot = {}
        WGS.db.global.attendance = {}
        WGS.db.global.encounters = {}
        WGS.db.global.raidCompResults = {}
        WGS.db.global.guildBankMoneyChanges = {}
        WGS.db.global.guildBankTransactions = {}
        WGS:Print("Exported data cleared. Type /gh restore within 24h to undo.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- Open the Sync tab and immediately generate + select the export string,
-- so the post-raid reminder is a single click away from copy-paste.
function WGS:ShowExportFrame()
    self:SelectMainFrameTab(5)
    self:PopulateExportEditBox()
end

function WGS:ShowImportFrame()
    self:SelectMainFrameTab(5)
end
