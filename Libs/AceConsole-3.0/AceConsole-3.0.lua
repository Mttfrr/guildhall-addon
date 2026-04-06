--- AceConsole-3.0 provides methods for registering slash commands and printing to chat.
-- @class file
-- @name AceConsole-3.0
local MAJOR, MINOR = "AceConsole-3.0", 7
local AceConsole = LibStub:NewLibrary(MAJOR, MINOR)

if not AceConsole then return end

-- Lua APIs
local pairs, select, type, tostring = pairs, select, type, tostring
local format, strfind, strsub, strlower = string.format, string.find, string.sub, string.lower
local tconcat = table.concat

AceConsole.embeds = AceConsole.embeds or {}

local mixins = {
    "Print",
    "Printf",
    "RegisterChatCommand",
    "UnregisterChatCommand",
}

-- Storage for slash commands
AceConsole.commands = AceConsole.commands or {}

--- Print to the default chat frame.
-- Output is prefixed with the addon name if available.
function AceConsole:Print(...)
    local text = ""
    local n = select("#", ...)
    for i = 1, n do
        local v = select(i, ...)
        text = text .. (i > 1 and " " or "") .. tostring(v)
    end

    -- Try to get the addon name for prefix
    local name = self.name or self.moduleName or MAJOR
    if name then
        text = "|cff33ff99" .. tostring(name) .. "|r: " .. text
    end

    DEFAULT_CHAT_FRAME:AddMessage(text)
end

--- Print a formatted string to the default chat frame.
function AceConsole:Printf(fmt_str, ...)
    local text = format(fmt_str, ...)
    self:Print(text)
end

--- Register a chat command (slash command).
-- @param command The slash command (without leading /)
-- @param func The function to call or a method name on self
-- @param persist Whether the command persists across disable
function AceConsole:RegisterChatCommand(command, func, persist)
    if type(command) ~= "string" then
        error("Usage: RegisterChatCommand(command, func): 'command' - string expected.", 2)
    end

    if type(func) ~= "function" and type(func) ~= "string" then
        error("Usage: RegisterChatCommand(command, func): 'func' - function or string expected.", 2)
    end

    command = strlower(command)

    -- Register the slash command globally
    local name = "ACECONSOLE_" .. command:upper()
    _G["SLASH_" .. name .. "1"] = "/" .. command

    SlashCmdList[name] = function(msg)
        if type(func) == "string" then
            if type(self[func]) == "function" then
                self[func](self, msg)
            end
        else
            func(msg)
        end
    end

    AceConsole.commands[command] = {
        self = self,
        func = func,
        persist = persist,
    }
end

--- Unregister a chat command.
function AceConsole:UnregisterChatCommand(command)
    command = strlower(command)
    local name = "ACECONSOLE_" .. command:upper()
    _G["SLASH_" .. name .. "1"] = nil
    SlashCmdList[name] = nil
    AceConsole.commands[command] = nil
end

--- Get the args from a chat command input string
-- @param str The raw input string from the slash command
-- @return The individual arguments
function AceConsole:GetArgs(str, numargs, startpos)
    numargs = numargs or 1
    startpos = startpos or 1

    local pos = startpos
    local args = {}

    for i = 1, numargs do
        -- Skip whitespace
        local _, npos = strfind(str, "%s*", pos)
        pos = (npos or pos) + 1

        if pos > #str then
            break
        end

        if i == numargs then
            -- Last arg gets the rest of the string
            args[i] = strsub(str, pos)
            pos = #str + 1
        else
            -- Find next space
            local spacePos = strfind(str, "%s", pos)
            if spacePos then
                args[i] = strsub(str, pos, spacePos - 1)
                pos = spacePos
            else
                args[i] = strsub(str, pos)
                pos = #str + 1
            end
        end
    end

    -- Return args and the position
    local nargs = #args
    if nargs == 0 then
        return "", pos
    end

    local results = {}
    for i = 1, nargs do
        results[i] = args[i] or ""
    end
    results[nargs + 1] = pos

    return unpack(results)
end

--- Embedding
function AceConsole:Embed(target)
    AceConsole.embeds[target] = true
    for _, name in pairs(mixins) do
        target[name] = AceConsole[name]
    end
    return target
end

-- Upgrade existing embeds
for target, _ in pairs(AceConsole.embeds) do
    AceConsole:Embed(target)
end
