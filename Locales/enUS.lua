local L = {}

L["ADDON_NAME"] = "GuildHall"
L["SLASH_HELP"] = "Commands: /gh show | teams | bank | loot | wishlists | rostercheck | events | readiness | bossnotes <name> | attendance | invite | sortgroups | export | import | config | help"
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

GuildHall_L = L
