-- Ace3 and addon type stubs for LuaLS
-- This file is NOT loaded at runtime (not listed in .toc).
-- It exists only to satisfy the Lua Language Server type checker.

---@class AceAddon-3.0
---@field RegisterEvent fun(self: any, event: string, callback?: string|function)
---@field UnregisterEvent fun(self: any, event: string)
---@field RegisterChatCommand fun(self: any, command: string, callback: string|function)
---@field Print fun(self: any, ...: any)
---@field NewModule fun(self: any, name: string, ...: string): AceModule
---@field GetModule fun(self: any, name: string): AceModule

---@class AceConsole-3.0
---@field RegisterChatCommand fun(self: any, command: string, callback: string|function)
---@field Print fun(self: any, ...: any)

---@class AceEvent-3.0
---@field RegisterEvent fun(self: any, event: string, callback?: string|function)
---@field UnregisterEvent fun(self: any, event: string)

---@class AceModule: AceEvent-3.0
---@field RegisterEvent fun(self: any, event: string, callback?: string|function)
---@field UnregisterEvent fun(self: any, event: string)
---@field [string] any

---@class AceDB-3.0
---@field global table
---@field profile table

---@class WGSTeamPickerFrame
---@field callback function?
---@field PopulateTeams fun(self: WGSTeamPickerFrame, teams: table)
---@field Show fun(self: WGSTeamPickerFrame)
---@field Hide fun(self: WGSTeamPickerFrame)
---@field [string] any

---@class WGSPlayerInfo
---@field displayName string        -- Human-readable player label
---@field main string               -- Main character in "CharName-Realm" format
---@field alts string[]             -- Array of alt characters in "CharName-Realm" format

---@class WGSPlayerMember
---@field playerId string           -- Opaque player ID from web platform
---@field main string               -- Main character in "CharName-Realm" format

---@class WoWGuildSync: AceAddon-3.0, AceConsole-3.0, AceEvent-3.0
---@field db AceDB-3.0
---@field version string
---@field CLASS_COLORS table<string, string>
---@field BuildCharacterLookup fun(self: WoWGuildSync): table<string, string>
---@field ResolvePlayerForCharacter fun(self: WoWGuildSync, characterName: string): string?, WGSPlayerInfo?
---@field [string] any
