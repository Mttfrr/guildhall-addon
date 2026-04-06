--- AceEvent-3.0 provides event registration and secure dispatching.
-- All dispatching is done using CallbackHandler-1.0.
-- AceEvent is a mixin and target for embeds.
-- @class file
-- @name AceEvent-3.0
local MAJOR, MINOR = "AceEvent-3.0", 4
local AceEvent = LibStub:NewLibrary(MAJOR, MINOR)

if not AceEvent then return end

-- Lua APIs
local pairs = pairs

local CallbackHandler = LibStub("CallbackHandler-1.0")

AceEvent.frame = AceEvent.frame or CreateFrame("Frame", "AceEvent30Frame")
AceEvent.embeds = AceEvent.embeds or {}

-- APIs and mixins to embed into the target object
local mixins = {
    "RegisterEvent", "UnregisterEvent",
    "RegisterMessage", "UnregisterMessage",
    "SendMessage",
    "UnregisterAllEvents", "UnregisterAllMessages",
}

-- AceEvent uses CallbackHandler for message dispatching
AceEvent.messages = AceEvent.messages or CallbackHandler:New(AceEvent, "RegisterMessage", "UnregisterMessage", "UnregisterAllMessages")

-- The events registry
AceEvent.events = AceEvent.events or {}

function AceEvent:RegisterEvent(event, method, ...)
    if type(event) ~= "string" then
        error("Usage: RegisterEvent(event, method): 'event' - string expected.", 2)
    end

    method = method or event

    -- Register our frame to receive the Blizzard event
    AceEvent.frame:RegisterEvent(event)

    -- Store the callback
    if not AceEvent.events[event] then
        AceEvent.events[event] = {}
    end

    if type(method) == "string" then
        AceEvent.events[event][self] = method
    else
        AceEvent.events[event][self] = method
    end
end

function AceEvent:UnregisterEvent(event)
    if AceEvent.events[event] then
        AceEvent.events[event][self] = nil
        -- If no more listeners, unregister the Blizzard event
        if not next(AceEvent.events[event]) then
            AceEvent.frame:UnregisterEvent(event)
            AceEvent.events[event] = nil
        end
    end
end

function AceEvent:UnregisterAllEvents()
    for event, handlers in pairs(AceEvent.events) do
        if handlers[self] then
            handlers[self] = nil
            if not next(handlers) then
                AceEvent.frame:UnregisterEvent(event)
                AceEvent.events[event] = nil
            end
        end
    end
end

function AceEvent:SendMessage(message, ...)
    AceEvent.messages:Fire(message, ...)
end

-- Frame event handler
AceEvent.frame:SetScript("OnEvent", function(this, event, ...)
    local handlers = AceEvent.events[event]
    if handlers then
        for target, method in pairs(handlers) do
            if type(method) == "string" then
                if type(target[method]) == "function" then
                    target[method](target, event, ...)
                end
            elseif type(method) == "function" then
                method(event, ...)
            end
        end
    end
end)

--- Embedding
function AceEvent:Embed(target)
    AceEvent.embeds[target] = true
    for _, name in pairs(mixins) do
        target[name] = AceEvent[name]
    end
    return target
end

function AceEvent:OnEmbedDisable(target)
    target:UnregisterAllEvents()
    target:UnregisterAllMessages()
end

-- Upgrade existing embeds
for target, _ in pairs(AceEvent.embeds) do
    AceEvent:Embed(target)
end
