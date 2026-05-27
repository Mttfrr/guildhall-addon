---@type GuildHall
local WGS = GuildHall
local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

-- Right-click quick-action menu. Right-click used to go straight to
-- /gh config, but most users want the addon's other quick actions —
-- sync, attendance status, jumping to the Sync tab — without having
-- to remember the slash commands. Settings stays in the menu so the
-- old muscle memory still resolves in one extra click.
local function OpenMinimapMenu()
    local menu = {
        { text = "GuildHall", isTitle = true, notCheckable = true },
        {
            text = "Show / hide main frame",
            notCheckable = true,
            func = function() WGS:ToggleMainFrame() end,
        },
        {
            text = "Sync now (officer peer-sync)",
            notCheckable = true,
            func = function() WGS:PeerSync_ManualCatchup() end,
        },
        {
            text = WGS:IsTrackingAttendance() and "Stop attendance tracking"
                                              or "Start attendance tracking",
            notCheckable = true,
            func = function()
                if WGS:IsTrackingAttendance() then
                    WGS:StopAttendance()
                else
                    WGS:StartAttendanceAutoTagged()
                end
            end,
        },
        {
            text = "Open Sync tab",
            notCheckable = true,
            func = function()
                local ui = WGS._ui
                if ui then WGS:SelectMainFrameTab(ui.TAB_SYNC) end
            end,
        },
        { text = "", isTitle = true, notCheckable = true },
        {
            text = "Settings…",
            notCheckable = true,
            func = function() WGS:OpenConfig() end,
        },
    }
    if not _G.GuildHallMinimapDropdown then
        _G.GuildHallMinimapDropdown = CreateFrame("Frame", "GuildHallMinimapDropdown",
            UIParent, "UIDropDownMenuTemplate")
    end
    EasyMenu(menu, _G.GuildHallMinimapDropdown, "cursor", 0, 0, "MENU")
end

local dataObj = LDB:NewDataObject("GuildHall", {
    type = "launcher",
    text = "GuildHall",
    icon = "Interface\\Icons\\INV_Misc_Gear_01",
    OnClick = function(self, button)
        if button == "LeftButton" then
            -- Shift-left-click toggles attendance tracking. Useful
            -- mid-raid when the addon isn't open and the officer needs
            -- to start/stop capture without going through the Logs tab.
            if IsShiftKeyDown() then
                if WGS:IsTrackingAttendance() then
                    WGS:StopAttendance()
                else
                    WGS:StartAttendanceAutoTagged()
                end
            else
                WGS:ToggleMainFrame()
            end
        elseif button == "RightButton" then
            OpenMinimapMenu()
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
        tooltip:AddLine("|cff888888Shift-left-click:|r Start / stop attendance")
        tooltip:AddLine("|cff888888Right-click:|r Quick actions menu")
    end,
})

-- Called from Core.lua OnInitialize
function WGS:SetupMinimapIcon()
    LDBIcon:Register("GuildHall", dataObj, self.db.profile.minimap)
end
