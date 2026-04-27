---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L

local options = {
    name = "GuildHall |cffff8800[BETA]|r",
    type = "group",
    args = {
        general = {
            order = 1,
            type = "group",
            name = "General",
            inline = true,
            args = {
                guildWebId = {
                    order = 1,
                    type = "input",
                    name = "Guild ID",
                    desc = "Your guild's ID from guildhall.run. Found in Guild Settings or on the Addon Sync page. Links this addon to your guild so exported data syncs to the right place.",
                    width = "full",
                    get = function() return WGS.db.profile.guildWebId end,
                    set = function(_, val) WGS.db.profile.guildWebId = val end,
                },
                headerTracking = {
                    order = 10,
                    type = "header",
                    name = "Auto-Tracking",
                },
                autoTrackAttendance = {
                    order = 11,
                    type = "toggle",
                    name = "Auto-Track Attendance",
                    desc = "Automatically record raid attendance when you join a raid group.",
                    width = "full",
                    get = function() return WGS.db.profile.autoTrackAttendance end,
                    set = function(_, val) WGS.db.profile.autoTrackAttendance = val end,
                },
                autoTrackLoot = {
                    order = 12,
                    type = "toggle",
                    name = "Auto-Track Loot",
                    desc = "Automatically record loot drops in raids and dungeons.",
                    width = "full",
                    get = function() return WGS.db.profile.autoTrackLoot end,
                    set = function(_, val) WGS.db.profile.autoTrackLoot = val end,
                },
                guildGroupsOnly = {
                    order = 13,
                    type = "toggle",
                    name = "Guild Groups Only",
                    desc = "Only track loot and attendance when at least half the group are guildmates. Prevents tracking PUG runs.",
                    width = "full",
                    get = function() return WGS.db.profile.guildGroupsOnly end,
                    set = function(_, val) WGS.db.profile.guildGroupsOnly = val end,
                },
                headerFeatures = {
                    order = 20,
                    type = "header",
                    name = "Features",
                },
                showLootDistHelper = {
                    order = 21,
                    type = "toggle",
                    name = "Loot Distribution Helper",
                    desc = "Show a popup when wishlisted loot drops, with options to announce to raid or assign.",
                    width = "full",
                    get = function() return WGS.db.profile.showLootDistHelper end,
                    set = function(_, val) WGS.db.profile.showLootDistHelper = val end,
                },
                showReadinessCheck = {
                    order = 22,
                    type = "toggle",
                    name = "Raid Readiness Check",
                    desc = "Show a warning when entering a raid if players have missing enchants or gems. Can also be triggered with /gh readiness.",
                    width = "full",
                    get = function() return WGS.db.profile.showReadinessCheck end,
                    set = function(_, val) WGS.db.profile.showReadinessCheck = val end,
                },
                showBossNotes = {
                    order = 23,
                    type = "toggle",
                    name = "Auto-Show Boss Notes",
                    desc = "Automatically display imported boss notes when a boss encounter starts.",
                    width = "full",
                    get = function() return WGS.db.profile.showBossNotes end,
                    set = function(_, val) WGS.db.profile.showBossNotes = val end,
                },
                showWebMOTD = {
                    order = 24,
                    type = "toggle",
                    name = "Show Web MOTD on Login",
                    desc = "Display the guild's web platform message of the day in chat when you log in.",
                    width = "full",
                    get = function() return WGS.db.profile.showWebMOTD end,
                    set = function(_, val) WGS.db.profile.showWebMOTD = val end,
                },
                headerMinimap = {
                    order = 30,
                    type = "header",
                    name = "Minimap",
                },
                minimapIcon = {
                    order = 31,
                    type = "toggle",
                    name = "Show Minimap Icon",
                    desc = "Toggle the minimap icon.",
                    get = function() return not WGS.db.profile.minimap.hide end,
                    set = function(_, val)
                        WGS.db.profile.minimap.hide = not val
                        if val then
                            LibStub("LibDBIcon-1.0"):Show("GuildHall")
                        else
                            LibStub("LibDBIcon-1.0"):Hide("GuildHall")
                        end
                    end,
                },
            },
        },
        info = {
            order = 2,
            type = "group",
            name = "About",
            inline = true,
            args = {
                website = {
                    order = 1,
                    type = "description",
                    name = "|cffffd100Web App:|r  guildhall.run\n\n"
                        .. "|cffffd100Feedback & Issues:|r  Visit guildhall.run or whisper an officer in-game.\n\n"
                        .. "|cff888888GuildHall is a free guild management platform for raid teams, loot tracking, attendance, and more. This addon is its in-game companion.|r",
                    fontSize = "medium",
                },
            },
        },
        data = {
            order = 3,
            type = "group",
            name = "Data Management",
            inline = true,
            args = {
                clearLoot = {
                    order = 2,
                    type = "execute",
                    name = "Clear Loot Data",
                    desc = "Clear all stored loot records.",
                    confirm = true,
                    confirmText = "Are you sure you want to clear all loot data?",
                    func = function()
                        WGS.db.global.loot = {}
                        WGS:Print("Loot data cleared.")
                    end,
                },
                clearAttendance = {
                    order = 3,
                    type = "execute",
                    name = "Clear Attendance Data",
                    desc = "Clear all stored attendance records.",
                    confirm = true,
                    confirmText = "Are you sure you want to clear all attendance data?",
                    func = function()
                        WGS.db.global.attendance = {}
                        WGS:Print("Attendance data cleared.")
                    end,
                },
                clearImported = {
                    order = 5,
                    type = "execute",
                    name = "Clear Imported Data",
                    desc = "Clear all data imported from the web app (teams, wishlists, boss notes, raid comps, events, gear audit, MOTD).",
                    confirm = true,
                    confirmText = "Clear all imported web data? You'll need to re-import from the web app.",
                    func = function()
                        WGS.db.global.teams = {}
                        WGS.db.global.wishlists = {}
                        WGS.db.global.bossNotes = {}
                        WGS.db.global.raidComps = {}
                        WGS.db.global.events = {}
                        WGS.db.global.gearAudit = {}
                        WGS.db.global.characters = {}
                        WGS.db.global.characterLookup = {}
                        WGS.db.global.webMOTD = ""
                        WGS.db.global.targetIlvl = 0
                        WGS:Print("Imported web data cleared.")
                    end,
                },
                clearAll = {
                    order = 10,
                    type = "execute",
                    name = "Clear ALL Data",
                    desc = "Clear all captured and imported data.",
                    confirm = true,
                    confirmText = "Are you sure you want to clear ALL data? This cannot be undone.",
                    func = function()
                        WGS.db.global.attendance = {}
                        WGS.db.global.loot = {}
                        WGS.db.global.encounters = {}
                        WGS.db.global.raidCompResults = {}
                        WGS.db.global.guildBankMoneyChanges = {}
                        WGS.db.global.guildBankTransactions = {}
                        WGS.db.global.lastKnownGold = nil
                        WGS.db.global.teams = {}
                        WGS.db.global.wishlists = {}
                        WGS.db.global.bossNotes = {}
                        WGS.db.global.raidComps = {}
                        WGS.db.global.events = {}
                        WGS.db.global.gearAudit = {}
                        WGS.db.global.characters = {}
                        WGS.db.global.characterLookup = {}
                        WGS.db.global.webMOTD = ""
                        WGS.db.global.targetIlvl = 0
                        WGS:Print("All data cleared.")
                    end,
                },
            },
        },
    },
}

function WGS:SetupConfig()
    LibStub("AceConfigRegistry-3.0"):RegisterOptionsTable("GuildHall", options)
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions("GuildHall", "GuildHall")
end

function WGS:OpenConfig()
    LibStub("AceConfigDialog-3.0"):Open("GuildHall")
end

-- SetupConfig is called from Core.lua OnInitialize
