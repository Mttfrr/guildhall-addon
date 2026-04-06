--- LibDataBroker-1.1
--- A central registry for addons that supply/consume data (minimap buttons, panels, etc.)
--- @class file
--- @name LibDataBroker-1.1

local MAJOR, MINOR = "LibDataBroker-1.1", 4
local lib, oldminor = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)
lib.attributestorage = lib.attributestorage or {}
lib.domt = lib.domt or {}
lib.proxystorage = lib.proxystorage or {}

local attributestorage = lib.attributestorage
local callbacks = lib.callbacks
local domt = lib.domt
local proxystorage = lib.proxystorage

function domt.__index(self, key)
    local storage = attributestorage[self]
    return storage and storage[key]
end

function domt.__newindex(self, key, value)
    local storage = attributestorage[self]
    if not storage then return end
    if storage[key] == value then return end
    storage[key] = value
    local name = storage.dataobj_name
    if name then
        callbacks:Fire("LibDataBroker_AttributeChanged", self, key, value, name)
        callbacks:Fire("LibDataBroker_AttributeChanged_" .. name, self, key, value)
        callbacks:Fire("LibDataBroker_AttributeChanged_" .. name .. "_" .. key, self, key, value)
    end
end

--- Create a new data object.
-- @param name A unique name for this data object
-- @param dataobj (optional) A table of initial attributes. If provided, this table becomes the proxy.
-- @return The data object proxy
function lib:NewDataObject(name, dataobj)
    if proxystorage[name] then return end

    if type(name) ~= "string" then
        error("Usage: NewDataObject(name, dataobj): 'name' - string expected.", 2)
    end

    local storage = {}
    if dataobj then
        for k, v in pairs(dataobj) do
            storage[k] = v
        end
    end
    storage.dataobj_name = name

    local proxy = dataobj or {}
    attributestorage[proxy] = storage
    setmetatable(proxy, domt)
    proxystorage[name] = proxy

    callbacks:Fire("LibDataBroker_DataObjectCreated", name, proxy)
    return proxy
end

--- Get an iterator over all data objects.
-- @return An iterator (name, dataobj) pairs
function lib:DataObjectIterator()
    return pairs(proxystorage)
end

--- Get a data object by name.
-- @param name The data object name
-- @return The data object proxy, or nil
function lib:GetDataObjectByName(name)
    return proxystorage[name]
end

--- Get the name of a data object.
-- @param dataobj The data object proxy
-- @return The name string, or nil
function lib:GetNameByDataObject(dataobj)
    local storage = attributestorage[dataobj]
    return storage and storage.dataobj_name
end

--- Get a data object by name, or create it with the given defaults.
-- @param name The data object name
-- @param defaults A table of default attributes
-- @return The data object proxy
function lib:GetDataObjectByNameOrNew(name, defaults)
    return proxystorage[name] or lib:NewDataObject(name, defaults)
end
