---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

-- "You're about to raid — start tracking?" prompt.
--
-- Modules/Attendance.lua decides WHEN to prompt (raid formed, a scheduled
-- event lines up, not already tracking — see WGS:ShouldPromptRaidTracking)
-- and calls WGS:ShowRaidTrackingPrompt here to actually put the window on
-- screen. Keeping the popup in the UI layer means the module stays pure
-- logic and testable without a StaticPopup stub, mirroring the other
-- module→UI hand-offs (LootDistHelper, ExportReminder).
--
-- Registered at file scope so it's ready on first use. %s in the text is
-- filled by StaticPopup_Show's second argument (the event title).
StaticPopupDialogs["GUILDHALL_START_TRACKING_PROMPT"] = {
    text = L["TRACK_PROMPT_TEXT"],
    button1 = L["TRACK_PROMPT_ACCEPT"],
    button2 = L["TRACK_PROMPT_DECLINE"],
    OnAccept = function()
        -- Same entry point as the silent auto-start, so the session is
        -- tagged to the scheduled event identically. If the raid already
        -- started tracking between prompt and click, Start* no-ops.
        WGS:StartAttendanceAutoTagged()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,   -- avoid taint from the default popup pool
}

-- Put the prompt on screen for `event`. Thin glue over Blizzard's
-- StaticPopup system; the decision to call it lives in Attendance.lua.
function WGS:ShowRaidTrackingPrompt(event)
    local title = (event and event.title and event.title ~= "" and event.title)
        or "your scheduled raid"
    StaticPopup_Show("GUILDHALL_START_TRACKING_PROMPT", title)
end
