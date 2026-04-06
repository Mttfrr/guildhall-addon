--- AceConfig-3.0 is a convenience library that wraps AceConfigRegistry and AceConfigCmd.
-- @class file
-- @name AceConfig-3.0
local MAJOR, MINOR = "AceConfig-3.0", 3
local AceConfig = LibStub:NewLibrary(MAJOR, MINOR)

if not AceConfig then return end

local cfgreg = LibStub("AceConfigRegistry-3.0")
local cfgcmd = LibStub("AceConfigCmd-3.0")

--- Register an options table with AceConfigRegistry and optionally create a chat command.
-- @param appName The application/addon name
-- @param options The options table or a function returning one
-- @param slashcmd The slash command to register (optional)
function AceConfig:RegisterOptionsTable(appName, options, slashcmd)
    cfgreg:RegisterOptionsTable(appName, options)
    if slashcmd then
        cfgcmd:CreateChatCommand(slashcmd, appName)
    end
end
