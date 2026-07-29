---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

-- "You're about to raid — start tracking?" prompt.
--
-- Modules/Attendance.lua decides WHEN to prompt (raid formed, a scheduled
-- event lines up, not already tracking — see WGS:ShouldPromptRaidTracking)
-- and calls WGS:ShowRaidTrackingPrompt here to actually put the window on
-- screen. Keeping the popup in the UI layer means the module stays pure
-- logic and testable without a frame stub, mirroring the other module→UI
-- hand-offs (LootDistHelper, ExportReminder).
--
-- The chrome is the shared WGS:ShowActionDialog builder (UI/UIHelpers.lua)
-- — the SAME panel the end-of-raid "Export Now" reminder uses, so the two
-- read as one consistent GuildHall prompt style.

-- Put the prompt on screen for `event`. Thin glue over the shared dialog;
-- the decision to call it lives in Attendance.lua.
function WGS:ShowRaidTrackingPrompt(event)
    local title = (event and event.title and event.title ~= "" and event.title)
        or L["TRACK_PROMPT_FALLBACK"]
    self:ShowActionDialog({
        key         = "raidtrack",
        title       = L["TRACK_PROMPT_TITLE"],
        body        = string.format(L["TRACK_PROMPT_TEXT"], title),
        acceptText  = L["TRACK_PROMPT_ACCEPT"],
        -- Same entry point as the silent auto-start, so the session is
        -- tagged to the scheduled event identically. If the raid already
        -- started tracking between prompt and click, Start* no-ops.
        onAccept    = function() WGS:StartAttendanceAutoTagged() end,
        declineText = L["TRACK_PROMPT_DECLINE"],
    })
end
