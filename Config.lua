---@type GuildHall
local WGS = GuildHall

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
                promptRaidTracking = {
                    order = 11.5,
                    type = "toggle",
                    name = "Prompt to Track Scheduled Raids",
                    desc = "When you join a raid group around a scheduled event's start time, pop a window asking whether to start attendance tracking. Only appears when a scheduled event matches.",
                    width = "full",
                    get = function() return WGS.db.profile.promptRaidTracking end,
                    set = function(_, val) WGS.db.profile.promptRaidTracking = val end,
                },
                autoSortGroups = {
                    order = 11.7,
                    type = "toggle",
                    name = "Auto-Sort Into Comp Groups",
                    desc = "As raiders accept and join a tracked raid, automatically move each newcomer into the subgroup your platform raid comp assigns them. Only touches fresh joiners (never reshuffles people you've moved by hand), and does nothing when the event has no comp with group assignments. The Events tab's \"Organize Groups\" button is the manual, sort-everyone version.",
                    width = "full",
                    get = function() return WGS.db.profile.autoSortGroups end,
                    set = function(_, val) WGS.db.profile.autoSortGroups = val end,
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
                    desc = "Only track loot and attendance when at least 80% of the group are guildmates. Prevents tracking PUG runs.",
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
                showBossNotes = {
                    order = 23,
                    type = "toggle",
                    name = "Auto-Show Boss Notes",
                    desc = "Automatically display imported boss notes when a boss encounter starts.",
                    width = "full",
                    get = function() return WGS.db.profile.showBossNotes end,
                    set = function(_, val) WGS.db.profile.showBossNotes = val end,
                },
                headerRCLC = {
                    order = 24,
                    type = "header",
                    name = "RCLootCouncil",
                },
                rclcCapture = {
                    order = 25,
                    type = "toggle",
                    name = "Capture RCLC Awards",
                    desc = "Record RCLootCouncil award decisions (winner, response, votes) into the loot log — upgrading the chat-captured row for the same drop when one exists. Works for every raider running both addons, not just the loot master. Does nothing when RCLootCouncil isn't loaded. Takes effect on next /reload.",
                    width = "full",
                    get = function() return WGS.db.profile.rclcCapture end,
                    set = function(_, val) WGS.db.profile.rclcCapture = val end,
                },
                rclcWishlistColumn = {
                    order = 26,
                    type = "toggle",
                    name = "Wishlists in RCLC Frames",
                    desc = "Add a GuildHall column to RCLootCouncil's voting frame showing each candidate's imported wishlist priority for the item, and append your own wish to the roll window. Does nothing when RCLootCouncil isn't loaded. Takes effect on next /reload.",
                    width = "full",
                    get = function() return WGS.db.profile.rclcWishlistColumn end,
                    set = function(_, val) WGS.db.profile.rclcWishlistColumn = val end,
                },
                headerPeerSync = {
                    order = 28,
                    type = "header",
                    name = "Officer Sync",
                },
                peerSyncEnabled = {
                    order = 29,
                    type = "toggle",
                    name = "Enable Officer-to-Officer Sync",
                    desc = "Broadcast loot drops, attendance sessions, encounter kills, and raid-comp snapshots to other officers in your raid/guild so everyone's addon stays in sync without copy-pasting. Officer rank required on both sides; reads from the guild roster. Default: on for officers, off for everyone else. Takes effect on next /reload.",
                    width = "full",
                    get = function()
                        local v = WGS.db.profile.peerSyncEnabled
                        if v == nil then return WGS:IsGuildOfficer() end
                        return v
                    end,
                    set = function(_, val) WGS.db.profile.peerSyncEnabled = val end,
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
                        -- Silent LibStub lookup: a broken/partial Libs
                        -- install shouldn't error out the settings panel.
                        local icon = LibStub("LibDBIcon-1.0", true)
                        if not icon then return end
                        if val then
                            icon:Show("GuildHall")
                        else
                            icon:Hide("GuildHall")
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
                        WGS:ClearImportedData()
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
                        WGS:ClearExportedData()
                        WGS:ClearImportedData()
                        WGS.db.global.lastKnownGold = nil
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
