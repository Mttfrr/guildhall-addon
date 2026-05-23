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

    -- Ace3 / LibStub stub. NewAddon hands back a plain table; the addon
    -- mixes methods onto it. NewLibrary is unused at load time but kept
    -- defensive in case a vendored Lib is dofile'd later.
    _G.LibStub = function()
        return {
            NewAddon = function() return {} end,
            NewLibrary = function() return {}, true end,
            GetLibrary = function() return {} end,
        }
    end

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
    dofile("Sync/Encoder.lua")
    dofile("Sync/Decoder.lua")

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
            gearAudit = {}, signups = {}, targetIlvl = 0, webMOTD = "",
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

    return GuildHall
end

return M
