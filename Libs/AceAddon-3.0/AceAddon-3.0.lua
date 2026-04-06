--- AceAddon-3.0 provides a framework for creating addon objects.
-- @class file
-- @name AceAddon-3.0
local MAJOR, MINOR = "AceAddon-3.0", 13
local AceAddon, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceAddon then return end

AceAddon.frame = AceAddon.frame or CreateFrame("Frame", "AceAddon30Frame")
AceAddon.addons = AceAddon.addons or {}
AceAddon.statuses = AceAddon.statuses or {}
AceAddon.initializequeue = AceAddon.initializequeue or {}
AceAddon.enablequeue = AceAddon.enablequeue or {}
AceAddon.embeds = AceAddon.embeds or {}
AceAddon.embeds_NewAddon = AceAddon.embeds_NewAddon or {}

-- Lua APIs
local tinsert, tconcat, tremove = table.insert, table.concat, table.remove
local fmt = string.format
local pairs, next, type, unpack, select, tostring = pairs, next, type, unpack, select, tostring
local loadstring, assert, error = loadstring, assert, error
local setmetatable, getmetatable, rawset, rawget = setmetatable, getmetatable, rawset, rawget

-- Blizzard APIs
local _G = _G

-- xpcall safecall implementation
local xpcall = xpcall
local function errorhandler(err)
    return geterrorhandler()(err)
end

local function safecall(func, ...)
    if func then
        return xpcall(func, errorhandler, ...)
    end
end

-- local mixins
local enable, disable

-- called on ADDON_LOADED to initialize addons
local function Addon_Initialize(addon)
    safecall(addon.OnInitialize, addon)

    local embedqueue = AceAddon.embeds_NewAddon[addon]
    if embedqueue then
        for i, lib in pairs(embedqueue) do
            safecall(lib.OnEmbedInitialize, lib, addon)
        end
    end

    AceAddon.initializequeue[addon] = nil
    AceAddon.statuses[addon] = true
end

-- Enable an addon (fires OnEnable callbacks)
function enable(addon)
    if AceAddon.statuses[addon] then
        safecall(addon.OnEnable, addon)
        local embedqueue = AceAddon.embeds_NewAddon[addon]
        if embedqueue then
            for i, lib in pairs(embedqueue) do
                safecall(lib.OnEmbedEnable, lib, addon)
            end
        end
    end
end

function disable(addon)
    safecall(addon.OnDisable, addon)
    local embedqueue = AceAddon.embeds_NewAddon[addon]
    if embedqueue then
        for i, lib in pairs(embedqueue) do
            safecall(lib.OnEmbedDisable, lib, addon)
        end
    end
end

-- Create a new AceAddon-3.0 addon object
function AceAddon:NewAddon(objectorname, ...)
    local object, name
    local i = 1
    if type(objectorname) == "table" then
        object = objectorname
        name = select(1, ...)
        i = 2
    elseif type(objectorname) == "string" then
        name = objectorname
    else
        error(("Usage: NewAddon([object,] name, [lib, lib, ...]): 'name' - string expected got '%s'."):format(type(objectorname)), 2)
    end

    if type(name) ~= "string" then
        error(("Usage: NewAddon([object,] name, [lib, lib, ...]): 'name' - string expected got '%s'."):format(type(name)), 2)
    end
    if self.addons[name] then
        error(("Usage: NewAddon([object,] name, [lib, lib, ...]): 'name' - Addon '%s' already exists."):format(name), 2)
    end

    object = object or {}
    object.name = name

    local addonmeta = {}
    local oldmeta = getmetatable(object)
    if oldmeta then
        for k, v in pairs(oldmeta) do addonmeta[k] = v end
    end
    addonmeta.__tostring = addonmeta.__tostring or function(self) return self.name end
    setmetatable(object, addonmeta)

    self.addons[name] = object
    object.modules = {}
    object.orderedModules = {}
    object.defaultModuleLibraries = {}
    object.defaultModulePrototype = nil
    tinsert(self.initializequeue, object)

    -- Embed requested libraries
    local args = (type(objectorname) == "table") and {select(2, ...)} or {...}
    for idx = 1, #args do
        local libname = args[idx]
        self:EmbedLibrary(object, libname, false, 4)
    end

    return object
end

-- Get an existing addon
function AceAddon:GetAddon(name, silent)
    if not silent and not self.addons[name] then
        error(("Usage: GetAddon(name): 'name' - Cannot find an AceAddon '%s'."):format(tostring(name)), 2)
    end
    return self.addons[name]
end

-- Embed a library into an addon
function AceAddon:EmbedLibrary(addon, libname, silent, offset)
    local lib = LibStub:GetLibrary(libname, true)
    if not lib and not silent then
        error(("Usage: EmbedLibrary(addon, libname, silent, offset): 'libname' - Cannot find a library instance of %q."):format(tostring(libname)), offset or 2)
    elseif lib and type(lib.Embed) == "function" then
        lib:Embed(addon)
        tinsert(self.embeds[addon] or (function() self.embeds[addon] = {} return self.embeds[addon] end)(), lib)
        if not self.embeds_NewAddon[addon] then
            self.embeds_NewAddon[addon] = {}
        end
        tinsert(self.embeds_NewAddon[addon], lib)
        return true
    elseif lib then
        -- Library does not have Embed, just store reference
        return true
    end
end

--- Create a new module for the addon.
function AceAddon:NewModule(addon_or_self, name, ...)
    -- Handle both AceAddon:NewModule(addon, name) and addon:NewModule(name)
    local addon
    if type(addon_or_self) == "string" then
        -- Called as addon:NewModule(name, ...)
        addon = self
        name = addon_or_self
        -- ... contains library names
    else
        addon = addon_or_self
    end

    if not addon then
        error("Usage: addon:NewModule(name, [lib, lib, lib, ...]): addon is nil", 2)
    end

    if type(name) ~= "string" then
        error(("Usage: addon:NewModule(name, [lib, lib, lib, ...]): 'name' - string expected got '%s'."):format(type(name)), 2)
    end
    if addon.modules[name] then
        error(("Usage: addon:NewModule(name, [lib, lib, lib, ...]): 'name' - Module '%s' already exists."):format(name), 2)
    end

    -- Create the module as a new addon
    local module = AceAddon:NewAddon(fmt("%s_%s", addon.name or tostring(addon), name))
    module.moduleName = name
    module.IsModule = true

    addon.modules[name] = module
    tinsert(addon.orderedModules, module)

    return module
end

--- Get a module from an addon
function AceAddon:GetModule(addon_or_self, name, silent)
    local addon
    if type(addon_or_self) == "string" then
        addon = self
        name = addon_or_self
        silent = name
    else
        addon = addon_or_self
    end

    if not addon.modules[name] and not silent then
        error(("Usage: GetModule(name, silent): 'name' - Cannot find module '%s'."):format(tostring(name)), 2)
    end
    return addon.modules[name]
end

--- Get an iterator over all modules
function AceAddon:IterateModules(addon_or_self)
    local addon = (addon_or_self ~= AceAddon) and addon_or_self or self
    return pairs(addon.modules)
end

--- Get the default module prototype
function AceAddon:SetDefaultModulePrototype(addon_or_self, prototype)
    local addon = (addon_or_self ~= AceAddon) and addon_or_self or self
    addon.defaultModulePrototype = prototype
end

--- Set default module libraries
function AceAddon:SetDefaultModuleLibraries(addon_or_self, ...)
    local addon = (addon_or_self ~= AceAddon) and addon_or_self or self
    local libs = {...}
    addon.defaultModuleLibraries = libs
end

--- Enable the addon
function AceAddon:EnableAddon(addon)
    if type(addon) == "string" then addon = AceAddon:GetAddon(addon) end
    if AceAddon.statuses[addon] then
        enable(addon)
    end
end

--- Disable the addon
function AceAddon:DisableAddon(addon)
    if type(addon) == "string" then addon = AceAddon:GetAddon(addon) end
    disable(addon)
    AceAddon.statuses[addon] = nil
end

--- Iterate over all registered addons
function AceAddon:IterateAddons() return pairs(self.addons) end

--- Iterate over all addons with status
function AceAddon:IterateAddonStatus() return pairs(self.statuses) end

-- Addon prototype methods
local function GetName(self) return self.name end

-- Mix GetName into all addons
local addonProto = { GetName = GetName, NewModule = function(self, ...) return AceAddon:NewModule(self, ...) end, GetModule = function(self, ...) return AceAddon:GetModule(self, ...) end, IterateModules = function(self) return AceAddon:IterateModules(self) end, SetDefaultModuleLibraries = function(self, ...) return AceAddon:SetDefaultModuleLibraries(self, ...) end, SetDefaultModulePrototype = function(self, ...) return AceAddon:SetDefaultModulePrototype(self, ...) end, Enable = function(self) return AceAddon:EnableAddon(self) end, Disable = function(self) return AceAddon:DisableAddon(self) end }

-- PLAYER_LOGIN / ADDON_LOADED handler
AceAddon.frame:UnregisterAllEvents()
AceAddon.frame:RegisterEvent("ADDON_LOADED")
AceAddon.frame:RegisterEvent("PLAYER_LOGIN")

AceAddon.frame:SetScript("OnEvent", function(this, event, ...)
    if event == "ADDON_LOADED" then
        -- Initialize any queued addons
        for i = #AceAddon.initializequeue, 1, -1 do
            local addon = AceAddon.initializequeue[i]
            if type(addon) == "table" then
                Addon_Initialize(addon)
            end
        end
    elseif event == "PLAYER_LOGIN" then
        -- Enable all initialized addons
        for name, addon in pairs(AceAddon.addons) do
            if AceAddon.statuses[addon] then
                enable(addon)
            end
        end
    end
end)

-- Inject addon prototype methods for NewAddon
local orig_NewAddon = AceAddon.NewAddon
function AceAddon:NewAddon(...)
    local addon = orig_NewAddon(self, ...)
    for k, v in pairs(addonProto) do
        if not addon[k] then
            addon[k] = v
        end
    end
    return addon
end
