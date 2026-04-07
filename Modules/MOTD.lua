---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

---@class WGSMOTDModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("MOTD", "AceEvent-3.0")

local hasShownThisSession = false

function module:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnLogin")
end

function module:OnLogin()
    if hasShownThisSession then return end
    hasShownThisSession = true

    -- Delay to let chat window settle and not compete with WoW's own MOTD
    C_Timer.After(5, function()
        WGS:ShowWebMOTD()
    end)
end

function WGS:ShowWebMOTD()
    if not self.db.profile.showWebMOTD then return end

    local motd = self.db.global.webMOTD
    if not motd or motd == "" then return end

    -- Show in chat as a distinct message
    self:Print("|cffffd100[Guild Web MOTD]|r " .. motd)
end
