-- luacheck configuration for the GuildHall WoW addon.
--
-- WoW runs Lua 5.1. The global namespace is populated by the client
-- (UI APIs, slash command APIs, item/inventory APIs, etc.) plus a few
-- by Ace3. We declare those as read-only globals so typos still fail.

std = "lua51"

-- Vendored libraries should not be linted — they have their own conventions
-- and warnings, and we don't own the code.
exclude_files = {
    "Libs/**",
}

-- Suppress noise that isn't a real bug for a WoW addon codebase.
ignore = {
    "212",  -- Unused argument (very common in event handlers with WoW's fixed signatures)
    "213",  -- Unused loop variable (`for _, v in ipairs(...)` legitimately ignores k)
    "432",  -- Shadowing `self` in nested frame methods (`function f:Method()` inside `function WGS:Build()`) — standard WoW addon pattern, the inner `self` is the frame
    "631",  -- Line is too long (Blizzard-formatted UI builders run wide)
}

-- The addon owns these globals (set in Core.lua + the .toc SavedVariables).
globals = {
    "GuildHall",
    "GuildHall_L",
    "GuildHallDB",
    "GuildHall_OnAddonCompartmentClick",
    "SLASH_GUILDHALL1",
    "SLASH_GUILDHALL2",
    "StaticPopupDialogs",
}

read_globals = {
    -- Standard Lua 5.1 extras WoW exposes that std=lua51 doesn't cover
    "bit", "date", "time", "wipe", "strsplit", "strjoin", "strtrim",
    "strconcat", "strmatch", "strsplittable", "format", "tContains",
    "tIndexOf", "tDeleteItem", "CopyTable", "Mixin", "CreateFromMixins",
    "tinsert", "tremove", "tconcat", "tinvert",

    -- Ace3 / LibStub
    "LibStub",

    -- Frame + UI construction
    "CreateFrame", "UIParent", "GameTooltip", "PanelTemplates_SetTab",
    "BasicFrameTemplateWithInset", "BackdropTemplate",
    "PanelTemplates_SetNumTabs", "PanelTemplates_GetSelectedTab",
    "PanelTemplates_Tab_OnClick", "PanelTemplates_TabResize",

    -- Static popups / chat
    "StaticPopup_Show", "StaticPopup_Hide", "UISpecialFrames",
    "DEFAULT_CHAT_FRAME", "SendChatMessage", "ChatFrame_AddMessageEventFilter",
    "ChatFrame_RemoveMessageEventFilter", "C_ChatInfo",

    -- Roster / unit / party / raid APIs
    "UnitName", "UnitFullName", "UnitClass", "UnitLevel", "UnitExists",
    "UnitGUID", "UnitIsConnected", "UnitInRaid", "UnitInParty",
    "UnitIsGroupLeader", "UnitIsGroupAssistant", "UnitGroupRolesAssigned",
    "GetNumGroupMembers", "GetNumSubgroupMembers", "GetRaidRosterInfo",
    "IsInGroup", "IsInRaid", "IsInGuild", "GetGuildInfo",
    "GetGuildRosterInfo", "GetNumGuildMembers", "GuildRoster",
    "C_GuildInfo", "GetNormalizedRealmName", "GetRealmName",
    "InviteUnit", "C_PartyInfo", "SetRaidSubgroup", "SwapRaidSubgroup",
    "PromoteToLeader", "PromoteToAssistant",

    -- Item / inventory / equipment
    "GetItemInfo", "GetItemInfoInstant", "GetItemStats", "C_Item",
    "C_Container", "C_EquipmentSet", "GetInventoryItemLink",
    "GetInventoryItemID", "GetItemSpell",

    -- Loot / encounter
    "GetLootInfo", "GetLootRollItemInfo", "GetCurrentLootRollID",
    "EJ_GetCurrentInstance", "EJ_GetEncounterInfo", "EJ_GetEncounterInfoByIndex",
    "EJ_GetInstanceForMap",

    -- Calendar / scheduled events
    "C_Calendar", "C_DateAndTime",

    -- Money / guild bank
    "GetMoney", "GetCoinTextureString", "GetCoinIcon",
    "GetGuildBankMoney", "GetCurrentGuildBankTab", "GetGuildBankTransaction",
    "GetNumGuildBankTransactions", "GetGuildBankMoneyTransaction",
    "GetNumGuildBankMoneyTransactions", "QueryGuildBankLog",
    "GuildBankFrame", "GetGuildBankItemInfo", "GetGuildBankItemLink",

    -- Map / instance
    "C_Map", "GetInstanceInfo", "IsInInstance", "GetDifficultyInfo",

    -- Tooltip data processor
    "TooltipDataProcessor", "Enum", "ItemRefTooltip",

    -- Globals provided by Blizzard's UI frame XML templates
    "InCombatLockdown", "InterfaceOptionsFrame_OpenToCategory",
    "Settings", "SettingsPanel",

    -- AddOns
    "C_AddOns", "GetAddOnMetadata", "IsAddOnLoaded",

    -- Player / character
    "GetAverageItemLevel", "GetSpecialization", "GetSpecializationInfo",
    "GetSpecializationRole", "GetInspectSpecialization",
    "NotifyInspect", "ClearInspectPlayer", "CanInspect",

    -- Timer / hook / callback
    "C_Timer", "hooksecurefunc",

    -- Quality / class colors
    "ITEM_QUALITY_COLORS", "RAID_CLASS_COLORS", "CLASS_ICON_TCOORDS",
    "LOCALIZED_CLASS_NAMES_MALE", "LOCALIZED_CLASS_NAMES_FEMALE",

    -- Chat events used by Loot.lua loot-parsing
    "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE",
    "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
    "LOOT_ITEM", "LOOT_ITEM_MULTIPLE",
}
