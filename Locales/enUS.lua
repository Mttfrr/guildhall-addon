local L = {}

L["ADDON_NAME"] = "GuildHall"
L["SLASH_HELP"] = "Commands: /gh show | events | teams | logs | sync | loot | bank | attendance | wishlists | rostercheck | bossnotes <name> | team <name|all> | invite | sortgroups | config | help"
L["EXPORT_COPIED"] = "Export string ready. Copy and paste it into your guild web app."
L["IMPORT_PROMPT"] = "Paste the import string from your guild web app below:"
L["IMPORT_SUCCESS"] = "Successfully imported %d items."
L["IMPORT_FAILED"] = "Import failed: invalid or corrupted data."
L["ATTENDANCE_START"] = "Attendance tracking started for this raid."
L["ATTENDANCE_STOP"] = "Attendance tracking stopped. %d members recorded."
L["LOOT_RECORDED"] = "%s looted by %s."
L["BANK_SCANNED"] = "Guild bank scanned: %d items across %d tabs."
L["GOLD_CHANGE"] = "Guild bank gold changed: %s"
L["NO_GUILD"] = "You are not in a guild."
L["NOT_IN_RAID"] = "You are not in a raid group."

-- Permission gates for /gh invite + /gh sortgroups. Each is shown to
-- the user as a single chat line, red so it's hard to miss.
L["ERR_RAID_LEAD_FOR_INVITE"] = "|cffff4444You must be raid leader or assistant to auto-invite.|r"
L["ERR_PARTY_LEAD_FOR_INVITE"] = "|cffff4444You must be party leader to auto-invite.|r"
L["ERR_NEED_GUILD"]            = "|cffff4444You must be in a guild.|r"
L["ERR_NEED_OFFICER_INVITE"]   = "|cffff4444Auto-invite requires officer rank or higher.|r"
L["ERR_NEED_RAID_TO_SORT"]     = "|cffff4444Must be in a raid to sort groups.|r"
L["ERR_RAID_LEAD_FOR_SORT"]    = "|cffff4444Must be raid leader or assistant to sort groups.|r"

-- /gh invite + /gh sortgroups outcomes.
L["NO_EVENT_TODAY"]    = "No event found for today."
L["EVENT_NO_ID"]       = "Event has no ID — can't match raid comp."
L["NO_COMP_FOR_EVENT"] = "No raid comp found for this event."
L["INVITE_NONE_FOR"]   = "No members to invite for: %s"
L["INVITE_SUMMARY"]    = "|cffffd100Inviting %d member(s) for %s (from %s)|r"
L["INVITE_ALL_IN"]     = "All members are already in group or offline."
L["SORT_SUMMARY"]      = "|cffffd100Sorted %d player(s) into raid groups.|r"
L["SORT_NONE"]         = "All players already in correct groups."

-- Attendance status read-out (/gh attendance).
L["ATTENDANCE_NOT_RECORDING"] = "Attendance: not recording."
L["ATTENDANCE_RECORDING"]     = "Attendance: recording since %s (%s)."

-- "You're about to raid — start tracking?" prompt (UI/RaidTrackingPrompt).
-- %s is the scheduled event's title; TITLE is the window title bar;
-- FALLBACK fills in when the event has no title.
L["TRACK_PROMPT_TEXT"]     = "You're about to raid |cffffd100%s|r.\nStart attendance tracking?"
L["TRACK_PROMPT_ACCEPT"]   = "Start Tracking"
L["TRACK_PROMPT_DECLINE"]  = "Not Now"
L["TRACK_PROMPT_TITLE"]    = "|cffffd100GuildHall: Raid Starting|r"
L["TRACK_PROMPT_FALLBACK"] = "your scheduled raid"

-- Raid Status snapshot + Organize Groups (UI/EventsDetail.lua). The
-- SUMMARY format takes the four counts in order: in-raid, waiting,
-- to-invite, offline (\194\183 is the middot separator).
L["RAID_STATUS_HEADER"]      = "Raid Status"
L["RAID_STATUS_SUMMARY"]     = "|cff55dd55%d in|r \194\183 |cffffa040%d waiting|r \194\183 |cffffd100%d to invite|r \194\183 |cffff5555%d offline|r"
L["RAID_STATUS_IN_RAID"]     = "In raid"
L["RAID_STATUS_INVITED"]     = "Invited (waiting)"
L["RAID_STATUS_NOT_INVITED"] = "Not invited"
L["RAID_STATUS_OFFLINE"]     = "Offline"
L["ORGANIZE_GROUPS"]         = "Organize Groups"

-- End-of-raid export reminder (UI/AttendanceFrame.lua). The body lines
-- take counts; GOLD's second %s is the optional " (123g)" suffix.
L["EXPORT_REMINDER_TITLE"]  = "|cffffd100GuildHall: Raid Over!|r"
L["EXPORT_NOW"]             = "Export Now"
L["LATER"]                  = "Later"
L["EXPORT_REMINDER_INTRO"]  = "You have unsent data from this raid:"
L["EXPORT_REMINDER_LOOT"]   = "|cffffd100Loot:|r %d items"
L["EXPORT_REMINDER_ATTEND"] = "|cffffd100Attendance:|r %d session(s)"
L["EXPORT_REMINDER_BANK"]   = "|cffffd100Bank Transactions:|r %d"
L["EXPORT_REMINDER_GOLD"]   = "|cffffd100Gold Snapshots:|r %d%s"
L["EXPORT_REMINDER_FOOTER"] = "Export now so your guild web app stays up to date!"

GuildHall_L = L
