---@type WoWGuildSync
local WGS = WoWGuildSync
local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

local dataObj = LDB:NewDataObject("WoWGuildSync", {
    type = "launcher",
    text = "GuildHall",
    icon = "Interface\\Icons\\INV_Misc_Gear_01",
    OnClick = function(self, button)
        if button == "LeftButton" then
            WGS:ToggleMainFrame()
        elseif button == "RightButton" then
            WGS:OpenConfig()
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("GuildHall v" .. WGS.version)
        tooltip:AddLine("|cffff8800BETA — Data may be incomplete or inaccurate|r")
        tooltip:AddLine(" ")

        local db = WGS.db.global
        local lootCount = db.loot and #db.loot or 0
        local attendanceCount = db.attendance and #db.attendance or 0
        local goldChanges = db.guildBankMoneyChanges and #db.guildBankMoneyChanges or 0

        tooltip:AddDoubleLine("Loot Records:", tostring(lootCount), 1, 1, 1, 1, 1, 0)
        tooltip:AddDoubleLine("Attendance Sessions:", tostring(attendanceCount), 1, 1, 1, 1, 1, 0)
        tooltip:AddDoubleLine("Gold Changes:", tostring(goldChanges), 1, 1, 1, 1, 1, 0)

        local goldStr = WGS:GetGuildGoldFormatted()
        if goldStr then
            tooltip:AddDoubleLine("Bank Gold:", goldStr, 1, 1, 1, 0.82, 0.5, 0)
        end

        if WGS:IsTrackingAttendance() then
            tooltip:AddLine(" ")
            tooltip:AddLine("|cff00ff00Attendance tracking active|r")
        end

        tooltip:AddLine(" ")
        tooltip:AddLine("|cff888888Left-click:|r Open main window")
        tooltip:AddLine("|cff888888Right-click:|r Open settings")
    end,
})

-- Called from Core.lua OnInitialize
function WGS:SetupMinimapIcon()
    LDBIcon:Register("WoWGuildSync", dataObj, self.db.profile.minimap)
end
