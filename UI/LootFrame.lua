---@type GuildHall
local WGS = GuildHall

-- Confirmation dialog used by the Sync tab's "Clear Exported Data" button.
-- Registered at file scope so it's available on first use.
StaticPopupDialogs["WGS_CONFIRM_CLEAR_EXPORTED"] = {
    text = "Clear all exported data (loot, attendance, encounters, bank transactions)?\n\nDo this AFTER you've pasted the export into your web app.",
    button1 = "Clear",
    button2 = "Cancel",
    OnAccept = function()
        WGS.db.global.loot = {}
        WGS.db.global.attendance = {}
        WGS.db.global.encounters = {}
        WGS.db.global.raidCompResults = {}
        WGS.db.global.guildBankMoneyChanges = {}
        WGS.db.global.guildBankTransactions = {}
        WGS:Print("Exported data cleared. Bank gold balance preserved.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- Both functions just open the Import/Export tab on the main frame.
function WGS:ShowExportFrame()
    self:SelectMainFrameTab(5)
end

function WGS:ShowImportFrame()
    self:SelectMainFrameTab(5)
end
