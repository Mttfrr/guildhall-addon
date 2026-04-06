--- AceConfigRegistry-3.0 handles central registration of options tables in use by AceConfigDialog and AceConfigCmd.
-- @class file
-- @name AceConfigRegistry-3.0
local MAJOR, MINOR = "AceConfigRegistry-3.0", 21
local AceConfigRegistry = LibStub:NewLibrary(MAJOR, MINOR)

if not AceConfigRegistry then return end

local CallbackHandler = LibStub("CallbackHandler-1.0")

AceConfigRegistry.tables = AceConfigRegistry.tables or {}

if not AceConfigRegistry.callbacks then
    AceConfigRegistry.callbacks = CallbackHandler:New(AceConfigRegistry)
end

-- Lua APIs
local type, pairs, error, tostring = type, pairs, error, tostring
local select, setmetatable = select, setmetatable
local format = string.format

-- Validate an options table
local function validateOptionsTable(options, name, errlvl)
    -- Basic structure check
    if type(options) ~= "table" then
        error(format("Options table %q is not a table.", name), errlvl or 2)
    end
    if not options.type then
        error(format("Options table %q has no 'type' member.", name), errlvl or 2)
    end
end

--- Register an options table
-- @param appName The application/addon name
-- @param options A table or function that returns a table
-- @param slashcmd (optional) Set this to a slash command string for AceConfigCmd
function AceConfigRegistry:RegisterOptionsTable(appName, options, slashcmd)
    if type(appName) ~= "string" then
        error("Usage: RegisterOptionsTable(appName, options): 'appName' - string expected.", 2)
    end
    if type(options) ~= "table" and type(options) ~= "function" then
        error("Usage: RegisterOptionsTable(appName, options): 'options' - table or function expected.", 2)
    end

    -- If options is a table, validate it
    if type(options) == "table" then
        -- Wrap it in a function for consistent handling
        local optTable = options
        options = function() return optTable end
    end

    AceConfigRegistry.tables[appName] = options

    -- Notify listeners
    AceConfigRegistry.callbacks:Fire("ConfigTableChange", appName)
end

--- Get the options table for an app
-- @param appName The application name
-- @param uiType (optional) "cmd" or "dialog" - the type of UI
-- @return The options table
function AceConfigRegistry:GetOptionsTable(appName, uiType)
    local options = AceConfigRegistry.tables[appName]
    if not options then return nil end

    if type(options) == "function" then
        options = options(uiType or "dialog", MAJOR)
    end

    if type(options) == "table" then
        if not options.type then
            options.type = "group"
        end
        if not options.name then
            options.name = appName
        end
    end

    return options
end

--- Iterate registered options tables
function AceConfigRegistry:IterateOptionsTables()
    return pairs(AceConfigRegistry.tables)
end

--- Notify that an options table changed
function AceConfigRegistry:NotifyChange(appName)
    if not AceConfigRegistry.tables[appName] then return end
    AceConfigRegistry.callbacks:Fire("ConfigTableChange", appName)
end
