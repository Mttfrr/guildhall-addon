-- Test bootstrap: load the addon's Core/Sync files with the WoW + Ace3
-- surface stubbed out, so tests can exercise the codec/protocol logic
-- without running WoW.
--
-- We dofile the real source files. Anything called at file scope (mostly
-- table literals + method definitions) runs against the stubs below.
-- Anything called from inside a method only runs when the test invokes it,
-- which means tests can swap stubs per-case.

local M = {}

local function clearGlobals()
    -- Tear down any GuildHall left over from a prior describe block so
    -- each setup() starts from a clean slate.
    _G.GuildHall = nil
end

function M.setup()
    clearGlobals()

    -- Ace3 / LibStub stub. Real LibStub looks up registered libraries
    -- by name; we mimic that so vendored libs that register themselves
    -- at file scope (LibDeflate) can be dofile'd and retrieved.
    --
    -- Pre-register stubs for the Ace3 namespaces used at load time
    -- (AceAddon, AceDB, CallbackHandler). Each is a permissive dummy
    -- whose methods return empty tables — enough for Core.lua to
    -- complete its OnInitialize without errors. Libraries not
    -- pre-registered return nil from LibStub() so the caller's own
    -- fallback path (e.g. Encoder.lua's "no LibDeflate → use v3") is
    -- exercised. Specs that want a real lib loaded call M.loadLibDeflate.
    local libs = {}
    local function permissiveStub()
        return setmetatable({}, {
            __index = function() return function() return {} end end,
        })
    end
    libs["AceAddon-3.0"]         = permissiveStub()
    libs["AceDB-3.0"]            = permissiveStub()
    libs["AceEvent-3.0"]         = permissiveStub()
    libs["AceConsole-3.0"]       = permissiveStub()
    libs["CallbackHandler-1.0"]  = permissiveStub()
    local lib_stub_meta = {
        NewAddon = function() return {} end,
        NewLibrary = function(_, name, _minor)
            local t = libs[name]
            if not t then
                t = {}
                libs[name] = t
            end
            return t, true
        end,
        GetLibrary = function(_, name, silent)
            if libs[name] then return libs[name], libs[name]._MINOR end
            if silent then return nil end
            error("LibStub: " .. tostring(name) .. " not registered", 2)
        end,
    }
    _G.LibStub = setmetatable({}, {
        __call = function(_, name, _silent)
            return libs[name]
        end,
        __index = lib_stub_meta,
    })

    -- Locale table: any key resolves to itself. The codec never reads it.
    _G.GuildHall_L = setmetatable({}, { __index = function(_, k) return k end })

    -- WoW globals touched at file scope or by GetTimestamp/GetPlayerKey.
    _G.time = os.time
    _G.UnitFullName = function() return "Tester", "TestRealm" end
    _G.GetNormalizedRealmName = function() return "TestRealm" end
    _G.IsInGuild = function() return false end
    _G.GetNumGuildMembers = function() return 0 end
    _G.GetGuildRosterInfo = function() return nil end
    _G.IsInGroup = function() return false end
    _G.IsInRaid = function() return false end
    _G.GetNumGroupMembers = function() return 0 end
    _G.UnitExists = function() return false end
    _G.GetGuildInfo = function() return nil end

    dofile("Core.lua")
    -- Mirror the .toc load order: Util/* depend on WGS being defined in
    -- Core.lua, and Sync/* depend on Util/JSON.lua + Util/Base64.lua for
    -- ToJson + Base64Encode + HashString.
    dofile("Util/Time.lua")
    dofile("Util/JSON.lua")
    dofile("Util/Base64.lua")
    dofile("Util/Roster.lua")
    dofile("Util/Roles.lua")
    dofile("Util/SignupStatus.lua")
    dofile("Util/Interop.lua")
    dofile("Util/Group.lua")
    dofile("Util/Announce.lua")
    dofile("Sync/Encoder.lua")
    dofile("Sync/Decoder.lua")
    dofile("Sync/PeerMessage.lua")

    -- AceConsole-3.0 normally mixes Print in; stub it as a no-op so methods
    -- that log status messages don't blow up during tests.
    function GuildHall:Print(_) end

    -- Ace3's AceAddon module system: in WoW, `WGS:NewModule(name, mixins...)`
    -- returns a sub-addon table. Tests don't care about that machinery
    -- beyond "doesn't NPE when modules register their handlers", so a
    -- stub that returns a plain table with no-op event registration
    -- is enough.
    function GuildHall:NewModule(_, ...)
        return setmetatable({}, {
            __index = function() return function() end end,
        })
    end

    -- AceDB normally builds this; we provide a hand-rolled equivalent so
    -- methods that touch self.db.* don't NPE.
    GuildHall.db = {
        profile = { guildWebId = "TESTGUILD" },
        global = {
            attendance = {}, loot = {}, encounters = {}, raidCompResults = {},
            guildBankMoneyChanges = {}, guildBankTransactions = {},
            characters = {}, characterLookup = {}, teams = {},
            wishlists = {}, bossNotes = {}, raidComps = {}, events = {},
            gearAudit = {}, characterDetails = {}, signups = {}, targetIlvl = 0,
            lastExport = 0, lastImport = 0, lastKnownGold = 0,
            exportHistory = {},
            lastClearSnapshot = { t = 0 },
            serverMinAddonVersion = nil,
        },
    }
    GuildHall.version = "test"

    -- EventScheduler + Import register `WGS:GetEventInviteList`,
    -- `WGS:GetEventSignups`, `WGS:ProcessImport`, `WGS:GetRaidComp` etc.
    -- Attendance now lives here too — once the in-game team-picker frame
    -- was removed, the module is pure logic and safe to dofile without
    -- a CreateFrame stub.
    dofile("Modules/Import.lua")
    dofile("Modules/EventScheduler.lua")
    dofile("Modules/Attendance.lua")
    dofile("Modules/MRTNotes.lua")
    dofile("Modules/GuildBank.lua")
    dofile("Modules/PeerSync.lua")

    -- Test shim for the public event bus. The real registry is wired
    -- in WGS:OnInitialize via CallbackHandler-1.0, which isn't loaded
    -- in tests. Modules use WGS:FireEvent which already nil-guards
    -- on `self.callbacks`, so unit tests would silently drop emissions
    -- without this shim. Tests that care can read GuildHall._fired.
    --
    -- The shim also implements GuildHall.RegisterCallback as a real
    -- dispatcher (CallbackHandler-1.0 surface) so peer-sync subscribers
    -- that broadcast on capture events can be exercised end to end.
    GuildHall._fired = {}
    local listeners = {}
    GuildHall.callbacks = {
        Fire = function(_, event, ...)
            table.insert(GuildHall._fired, { event = event, args = { ... } })
            for _, fn in ipairs(listeners[event] or {}) do fn(event, ...) end
        end,
    }
    function GuildHall.RegisterCallback(_handler, event, fnOrMethodName)
        listeners[event] = listeners[event] or {}
        if type(fnOrMethodName) == "function" then
            table.insert(listeners[event], fnOrMethodName)
        end
    end
    function GuildHall.UnregisterCallback(_handler, event)
        listeners[event] = nil
    end

    return GuildHall
end

--- Opt-in loader for the UI shim layer. Specs that exercise UI code
--- (frame builders, menu helpers, popups) call this AFTER M.setup()
--- to install minimal stubs for CreateFrame, MenuUtil, UIParent,
--- StaticPopupDialogs, GameTooltip, etc. + load UI/UIHelpers.lua.
---
--- The shims are intentionally tiny — full-fidelity WoW UI rendering
--- isn't the goal, just "loads without nil-call errors" so the UI
--- code's own logic (menu construction, popup wiring, layout calls)
--- can be observed.
---
--- After loading, specs can read:
---   GuildHall._ui.OpenContextMenu(...)    -- exercises the dispatcher
---   _G._capturedMenus                     -- array of menu descriptions
---                                            produced by MenuUtil mock
function M.loadUIShims()
    -- Chainable frame mock. Every unknown method returns self so
    -- chained calls (frame:SetSize():SetPoint():Show()) don't blow
    -- up. A handful of methods need real behaviour so the UI's own
    -- assertions about state work — those override the catch-all.
    local function makeMockFrame(frameType, name, parent)
        local mock = {
            _type     = frameType,
            _name     = name,
            _parent   = parent,
            _scripts  = {},
            _shown    = false,
            _enabled  = true,
        }
        function mock:SetScript(scriptName, fn) self._scripts[scriptName] = fn end
        function mock:GetScript(scriptName) return self._scripts[scriptName] end
        function mock:HasScript(scriptName) return self._scripts[scriptName] ~= nil end
        function mock:Show() self._shown = true end
        function mock:Hide() self._shown = false end
        function mock:IsShown() return self._shown end
        function mock:SetShown(v) self._shown = v and true or false end
        function mock:Enable() self._enabled = true end
        function mock:Disable() self._enabled = false end
        function mock:IsEnabled() return self._enabled end
        function mock:SetEnabled(v) self._enabled = v and true or false end
        function mock:GetParent() return self._parent end
        function mock:GetWidth() return 0 end
        function mock:GetHeight() return 0 end
        function mock:GetStringHeight() return 14 end
        function mock:GetCursorPosition() return 0, 0 end
        function mock:CreateFontString() return makeMockFrame("FontString", nil, self) end
        function mock:CreateTexture() return makeMockFrame("Texture", nil, self) end
        function mock:CreateLine() return makeMockFrame("Line", nil, self) end
        function mock:GetChildren() return end
        function mock:GetRegions() return end
        function mock:GetHighlightTexture() return makeMockFrame("Texture", nil, self) end
        -- Catch-all: any other method becomes a no-op returning self.
        return setmetatable(mock, {
            __index = function(t, k)
                local fn = function(self_) return self_ end
                rawset(t, k, fn)
                return fn
            end,
        })
    end

    _G.UIParent = makeMockFrame("Frame", "UIParent")
    _G.GameTooltip = makeMockFrame("GameTooltip", "GameTooltip")
    _G.UISpecialFrames = {}
    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show = function() return makeMockFrame("Frame") end
    _G.StaticPopup_Hide = function() end
    _G.ITEM_QUALITY_COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
    _G.CreateFrame = function(frameType, name, parent)
        return makeMockFrame(frameType, name, parent)
    end

    -- MenuUtil mock: records every CreateContextMenu invocation +
    -- the menu description tree the callback built, so specs can
    -- assert on what was constructed without having to render it.
    _G._capturedMenus = {}
    local function makeMenuNode(label, fn)
        local node = { label = label, func = fn, _children = {}, _enabled = true }
        function node:CreateTitle(text)
            local child = { kind = "title", text = text }
            table.insert(self._children, child)
            return child
        end
        function node:CreateButton(text, callback)
            local child = makeMenuNode(text, callback)
            child.kind = "button"
            table.insert(self._children, child)
            return child
        end
        function node:CreateDivider()
            local child = { kind = "divider" }
            table.insert(self._children, child)
            return child
        end
        function node:SetEnabled(v) self._enabled = v end
        function node:IsEnabled() return self._enabled end
        return node
    end
    _G.MenuUtil = {
        CreateContextMenu = function(owner, builder)
            local root = makeMenuNode("(root)")
            root.kind = "root"
            builder(owner, root)
            table.insert(_G._capturedMenus, root)
            return root
        end,
    }

    -- Bring in UI/UIHelpers.lua now that the globals it expects
    -- exist. Tests can then call GuildHall._ui.OpenContextMenu(...)
    -- directly.
    dofile("UI/UIHelpers.lua")
end

--- Opt-in loader for the vendored LibDeflate library. Specs that
--- exercise the v4 (deflate) envelope call this AFTER M.setup() so
--- the LibStub stub already exists. We dofile the real source rather
--- than mock it — round-tripping a payload through the actual
--- CompressDeflate / EncodeForPrint catches regressions Encoder.lua's
--- own logic can't.
function M.loadLibDeflate()
    -- string.pack is used by LibDeflate for Adler32 hashing; busted
    -- runs on Lua 5.1 by default, which doesn't ship it. Provide a
    -- minimal shim so the library loads cleanly. (We don't exercise
    -- Adler32 in tests, but the function table is built at load time.)
    -- luacheck: push ignore 142 143
    if not string.pack then
        string.pack = function() return "" end
        string.unpack = function() return 0 end
    end
    -- luacheck: pop
    dofile("Libs/LibDeflate/LibDeflate.lua")
end

return M
