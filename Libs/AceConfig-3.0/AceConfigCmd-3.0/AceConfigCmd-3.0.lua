--- AceConfigCmd-3.0 handles access to an options table through the "command line" interface via the chat window.
-- @class file
-- @name AceConfigCmd-3.0
local MAJOR, MINOR = "AceConfigCmd-3.0", 14
local AceConfigCmd = LibStub:NewLibrary(MAJOR, MINOR)

if not AceConfigCmd then return end

-- Lua APIs
local select, pairs, type, tostring, tonumber = select, pairs, type, tostring, tonumber
local strsub, strsplit, strlower, strmatch, strtrim = string.sub, strsplit, string.lower, string.match, strtrim
local format = string.format
local tinsert, tsort = table.insert, table.sort

local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
local AceConsole -- optional, loaded later

-- Handle a slash command option
local function HandleCommand(slashcmd, appName, input)
    local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
    local options = AceConfigRegistry:GetOptionsTable(appName, "cmd")
    if not options then
        return
    end

    if not input or input:trim() == "" then
        -- Just print info about the addon
        local name = options.name or appName
        print("|cff33ff99" .. tostring(name) .. "|r:")
        if options.args then
            for k, v in pairs(options.args) do
                if type(v) == "table" and v.type ~= "description" then
                    local name_str = v.name or k
                    local desc = v.desc or ""
                    print(format("  |cffffff78%s|r - %s", k, desc))
                end
            end
        end
        return
    end

    -- Parse the input
    local parts = { strsplit(" ", input) }
    local current = options
    local path = {}

    for i, part in ipairs(parts) do
        part = strtrim(part)
        if part ~= "" then
            if current.args and current.args[part] then
                tinsert(path, part)
                current = current.args[part]
            else
                -- This might be a value
                local optType = current.type
                if optType == "toggle" then
                    if current.set then
                        local val = not (current.get and current.get(unpack(path)))
                        current.set(unpack(path), val)
                        print(format("|cff33ff99%s|r set to %s", path[#path] or "", tostring(val)))
                    end
                    return
                elseif optType == "input" then
                    if current.set then
                        local val = table.concat(parts, " ", i)
                        current.set(unpack(path), val)
                        print(format("|cff33ff99%s|r set to %s", path[#path] or "", val))
                    end
                    return
                elseif optType == "range" then
                    if current.set then
                        local val = tonumber(part)
                        if val then
                            current.set(unpack(path), val)
                            print(format("|cff33ff99%s|r set to %s", path[#path] or "", tostring(val)))
                        end
                    end
                    return
                elseif optType == "select" then
                    if current.set then
                        current.set(unpack(path), part)
                        print(format("|cff33ff99%s|r set to %s", path[#path] or "", part))
                    end
                    return
                elseif optType == "execute" then
                    if current.func then
                        current.func(unpack(path))
                    end
                    return
                else
                    print(format("Unknown option: %s", part))
                    return
                end
            end
        end
    end

    -- If we ended on a group, list its contents
    if current.type == "group" and current.args then
        local name = current.name or path[#path] or appName
        print("|cff33ff99" .. tostring(name) .. "|r:")
        for k, v in pairs(current.args) do
            if type(v) == "table" then
                local desc = v.desc or v.name or ""
                print(format("  |cffffff78%s|r - %s", k, desc))
            end
        end
    elseif current.type == "execute" then
        if current.func then current.func(unpack(path)) end
    elseif current.type == "toggle" then
        if current.set then
            local val = not (current.get and current.get(unpack(path)))
            current.set(unpack(path), val)
            print(format("|cff33ff99%s|r set to %s", path[#path] or "", tostring(val)))
        end
    end
end

--- Create a chat command for the given options table.
function AceConfigCmd:CreateChatCommand(slashcmd, appName)
    if not AceConsole then
        AceConsole = LibStub("AceConsole-3.0", true)
    end

    slashcmd = strlower(slashcmd)
    local name = "ACECONFIGCMD_" .. slashcmd:upper()
    _G["SLASH_" .. name .. "1"] = "/" .. slashcmd

    SlashCmdList[name] = function(input)
        HandleCommand(slashcmd, appName, input)
    end
end

--- Handle a slash command
function AceConfigCmd:HandleCommand(slashcmd, appName, input)
    HandleCommand(slashcmd, appName, input)
end
