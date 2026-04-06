--[[ $Id: CallbackHandler-1.0.lua $ ]]
local MAJOR, MINOR = "CallbackHandler-1.0", 7
local CallbackHandler = LibStub:NewLibrary(MAJOR, MINOR)

if not CallbackHandler then return end -- No upgrade needed

local meta = {__index = function(tbl, key) tbl[key] = {} return tbl[key] end}

-- Lua APIs
local tconcat = table.concat
local assert, error, loadstring = assert, error, loadstring
local setmetatable, rawset, rawget = setmetatable, rawset, rawget
local next, select, pairs, type, tostring = next, select, pairs, type, tostring

-- Global vars/functions
local geterrorhandler, xpcall = geterrorhandler, xpcall

local function errorhandler(err)
    return geterrorhandler()(err)
end

local function Dispatch(handlers, ...)
    local index, method
    index = next(handlers)
    while index do
        local obj = handlers[index]
        method = index
        index = next(handlers, index)
        -- If the handler is a string, look it up on the object
        if type(method) == "string" then
            if type(obj) == "table" and type(obj[method]) == "function" then
                xpcall(obj[method], errorhandler, obj, ...)
            end
        elseif type(method) == "function" then
            xpcall(method, errorhandler, ...)
        end
    end
end

--------------------------------------------------------------------------
-- CallbackHandler:New
--
--   target            - target object to embed public APIs in
--   RegisterName      - name of the "Register" callback (default: "RegisterCallback")
--   UnregisterName    - name of the "Unregister" callback (default: "UnregisterCallback")
--   UnregisterAllName - name of the "UnregisterAll" callback (default: "UnregisterAllCallbacks")

function CallbackHandler:New(target, RegisterName, UnregisterName, UnregisterAllName)
    RegisterName = RegisterName or "RegisterCallback"
    UnregisterName = UnregisterName or "UnregisterCallback"
    UnregisterAllName = UnregisterAllName or "UnregisterAllCallbacks"

    local events = setmetatable({}, meta)
    local registry = { recurse = 0, events = events }

    function registry:Fire(eventname, ...)
        if not rawget(events, eventname) or not next(events[eventname]) then return end
        local oldrecurse = registry.recurse
        registry.recurse = oldrecurse + 1

        Dispatch(events[eventname], eventname, ...)

        registry.recurse = oldrecurse

        -- Fire any deletions queued during recursion
        if registry.insertQueue and oldrecurse == 0 then
            for eventname2, callbacks in pairs(registry.insertQueue) do
                local first = not rawget(events, eventname2) or not next(events[eventname2])
                for self2, func in pairs(callbacks) do
                    events[eventname2][self2] = func
                    if first and registry.OnUsed then
                        registry.OnUsed(registry, target, eventname2)
                        first = nil
                    end
                end
            end
            registry.insertQueue = nil
        end
    end

    -- Registration
    target[RegisterName] = function(self, eventname, method, ... --[[actually just a single arg]])
        if type(eventname) ~= "string" then
            error("Usage: " .. RegisterName .. "(eventname, method[, arg]): 'eventname' - string expected.", 2)
        end

        method = method or eventname

        local first = not rawget(events, eventname) or not next(events[eventname])

        if type(method) ~= "string" and type(method) ~= "function" then
            error("Usage: " .. RegisterName .. "(\"eventname\", \"methodname\"): 'methodname' - string or function expected.", 2)
        end

        local regfunc

        if type(method) == "string" then
            -- self["method"] calling style
            if type(self) ~= "table" then
                error("Usage: " .. RegisterName .. "(\"eventname\", \"methodname\"): self was not a table?", 2)
            elseif self == target then
                error("Usage: " .. RegisterName .. "(\"eventname\", \"methodname\"): do not use Library:" .. RegisterName .. "(), use your own object as self.", 2)
            elseif type(self[method]) ~= "function" then
                error("Usage: " .. RegisterName .. "(\"eventname\", \"methodname\"): 'self." .. method .. "' - function expected.", 2)
            end
            regfunc = self
        else
            -- function ref with optional arg
            if type(self) ~= "table" and type(self) ~= "string" and type(self) ~= "thread" then
                error("Usage: " .. RegisterName .. "(self or \"addonId\", eventname, method): 'self or addonId': table or string expected.", 2)
            end
            regfunc = method
        end

        if registry.recurse > 0 then
            -- We're currently dispatching; queue the registration
            registry.insertQueue = registry.insertQueue or setmetatable({}, meta)
            registry.insertQueue[eventname][self] = regfunc
        else
            events[eventname][self] = regfunc
        end

        if first and registry.OnUsed then
            registry.OnUsed(registry, target, eventname)
        end
    end

    -- Unregistration
    target[UnregisterName] = function(self, eventname)
        if not self or self == target then
            error("Usage: " .. UnregisterName .. "(eventname): bad 'self'", 2)
        end
        if type(eventname) ~= "string" then
            error("Usage: " .. UnregisterName .. "(eventname): 'eventname' - string expected.", 2)
        end
        if rawget(events, eventname) and events[eventname][self] then
            events[eventname][self] = nil
            if registry.OnUnused and not next(events[eventname]) then
                registry.OnUnused(registry, target, eventname)
            end
        end
        if registry.insertQueue and rawget(registry.insertQueue, eventname) and registry.insertQueue[eventname][self] then
            registry.insertQueue[eventname][self] = nil
        end
    end

    -- UnregisterAll
    target[UnregisterAllName] = function(self)
        if self == target then
            error("Usage: " .. UnregisterAllName .. "(): bad 'self'", 2)
        end
        for eventname, callbacks in pairs(events) do
            if callbacks[self] then
                callbacks[self] = nil
                if registry.OnUnused and not next(callbacks) then
                    registry.OnUnused(registry, target, eventname)
                end
            end
        end
        if registry.insertQueue then
            for eventname, callbacks in pairs(registry.insertQueue) do
                if callbacks[self] then
                    callbacks[self] = nil
                end
            end
        end
    end

    return registry
end

-- Upgrades for old registries
function CallbackHandler.OnEmbedded(CallbackHandler, target)
    -- nothing needed
end
