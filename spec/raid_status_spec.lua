local helpers = require("spec.helpers")

-- Live raid-status snapshot + group organizing. Covers:
--   * WGS:BuildInviteSnapshot — classifies each expected raider as
--     in-raid / invited(pending) / not-invited / offline.
--   * WGS:SortRaidGroups(eventOverride) — the "Organize Groups" button
--     sorts against the viewed event, not FindTodayEventForTeam.
--   * WGS:PlaceRaiderInCompGroup — auto-place a single fresh joiner.

describe("WGS:BuildInviteSnapshot", function()
    local WGS

    local EVENT = { id = 1, title = "Raid" }

    before_each(function()
        WGS = helpers.setup()

        -- Stubs for the AutoInvite pass that seeds the invited-set.
        _G.IsInGuild = function() return true end
        _G.IsInRaid  = function() return false end
        _G.IsInGroup = function() return false end
        _G.C_PartyInfo = { InviteUnit = function() end }
        WGS.IsGuildOfficer = function() return true end
        WGS.HasGroupLeadOrAssist = function() return true, nil end
        WGS.GetPlayerKey = function() return "Me-Realm" end
        WGS.GetRaidComp = function() return nil end
        WGS.GetEventInviteList = function()
            return { "Alpha", "Bravo", "Charlie", "Delta", "Echo" }, "signups"
        end
    end)

    it("classifies each raider as in-raid / invited / not-invited / offline", function()
        -- First invite pass: Delta + Echo are offline so they aren't
        -- invited; Alpha/Bravo/Charlie are online and get invites.
        WGS.GetGuildRosterLookup = function()
            return {
                Alpha   = { online = true,  fullName = "Alpha-Realm",   class = "WARRIOR" },
                Bravo   = { online = true,  fullName = "Bravo-Realm",   class = "MAGE" },
                Charlie = { online = true,  fullName = "Charlie-Realm", class = "PRIEST" },
                Delta   = { online = false, fullName = "Delta-Realm",   class = "ROGUE" },
                Echo    = { online = false, fullName = "Echo-Realm",    class = "DRUID" },
            }
        end
        WGS:AutoInvite(EVENT)

        -- Now: Alpha accepted (in the group), Delta reconnected (online
        -- but never invited), Echo still offline.
        WGS.GetGuildRosterLookup = function()
            return {
                Alpha   = { online = true,  fullName = "Alpha-Realm",   class = "WARRIOR" },
                Bravo   = { online = true,  fullName = "Bravo-Realm",   class = "MAGE" },
                Charlie = { online = true,  fullName = "Charlie-Realm", class = "PRIEST" },
                Delta   = { online = true,  fullName = "Delta-Realm",   class = "ROGUE" },
                Echo    = { online = false, fullName = "Echo-Realm",    class = "DRUID" },
            }
        end
        WGS.GetCurrentGroupShortNames = function() return { Alpha = true } end

        local snap = WGS:BuildInviteSnapshot(EVENT)

        local live = {}
        for _, r in ipairs(snap.rows) do live[r.short] = r.live end
        assert.are.equal("in-raid",     live.Alpha)
        assert.are.equal("invited",     live.Bravo)
        assert.are.equal("invited",     live.Charlie)
        assert.are.equal("not-invited", live.Delta)
        assert.are.equal("offline",     live.Echo)

        assert.are.equal(1, snap.counts.inRaid)
        assert.are.equal(2, snap.counts.invited)
        assert.are.equal(1, snap.counts.notInvited)
        assert.are.equal(1, snap.counts.offline)
        assert.are.equal(5, snap.counts.total)
    end)

    it("counts the local player as in-raid even if the group set misses them", function()
        WGS.GetGuildRosterLookup = function()
            return { Me = { online = true, fullName = "Me-Realm", class = "WARRIOR" } }
        end
        WGS.GetEventInviteList = function() return { "Me" }, "signups" end
        WGS.GetCurrentGroupShortNames = function() return {} end
        local snap = WGS:BuildInviteSnapshot(EVENT)
        assert.are.equal("in-raid", snap.rows[1].live)
    end)

    it("dedupes repeated characters and returns empty for a nil event", function()
        WGS.GetGuildRosterLookup = function()
            return { Alpha = { online = true, fullName = "Alpha-Realm" } }
        end
        WGS.GetEventInviteList = function() return { "Alpha", "Alpha-Realm" } end
        WGS.GetCurrentGroupShortNames = function() return {} end
        local snap = WGS:BuildInviteSnapshot(EVENT)
        assert.are.equal(1, #snap.rows)

        assert.are.equal(0, WGS:BuildInviteSnapshot(nil).counts.total)
    end)
end)

describe("WGS:SortRaidGroups event override", function()
    local WGS
    local moves

    before_each(function()
        WGS = helpers.setup()
        moves = {}
        _G.IsInRaid = function() return true end
        _G.GetNumGroupMembers = function() return 2 end
        _G.GetRaidRosterInfo = function(i)
            -- Both currently in group 1; comp wants Foo→2, Bar→3.
            if i == 1 then return "Foo", nil, 1 end
            if i == 2 then return "Bar", nil, 1 end
        end
        _G.SetRaidSubgroup = function(i, g) moves[#moves + 1] = { i = i, g = g } end
        WGS.HasGroupLeadOrAssist = function() return true, nil end
        WGS.GetRaidComp = function(_, id)
            if id == 99 then
                return { assignments = {
                    { name = "Foo", group = 2 },
                    { name = "Bar", group = 3 },
                } }
            end
            return nil
        end
    end)

    it("sorts against the passed-in event, not today's resolution", function()
        WGS.FindTodayEventForTeam = function() return nil end   -- no 'today' event
        WGS:SortRaidGroups({ id = 99 })
        assert.are.equal(2, #moves)
    end)

    it("bails with no event when neither override nor today resolves one", function()
        WGS.FindTodayEventForTeam = function() return nil end
        WGS:SortRaidGroups()          -- no override
        assert.are.equal(0, #moves)
    end)
end)

describe("WGS:PlaceRaiderInCompGroup (auto-place on accept)", function()
    local WGS
    local moves

    before_each(function()
        WGS = helpers.setup()
        moves = {}
        _G.IsInRaid = function() return true end
        _G.GetNumGroupMembers = function() return 1 end
        _G.SetRaidSubgroup = function(i, g) moves[#moves + 1] = { i = i, g = g } end
        WGS.HasGroupLeadOrAssist = function() return true, nil end
        WGS.GetRaidComp = function()
            return { assignments = { { name = "Foo-Realm", group = 4 } } }
        end
    end)

    it("moves a raider who isn't yet in their comp group", function()
        _G.GetRaidRosterInfo = function(i)
            if i == 1 then return "Foo", nil, 1 end   -- currently group 1, wants 4
        end
        local moved = WGS:PlaceRaiderInCompGroup("Foo", 7)
        assert.is_true(moved)
        assert.are.equal(4, moves[1].g)
    end)

    it("is a no-op when the raider is already in the right group", function()
        _G.GetRaidRosterInfo = function(i)
            if i == 1 then return "Foo", nil, 4 end   -- already group 4
        end
        assert.is_false(WGS:PlaceRaiderInCompGroup("Foo", 7))
        assert.are.equal(0, #moves)
    end)

    it("is a no-op when the comp doesn't assign the raider a group", function()
        _G.GetRaidRosterInfo = function(i)
            if i == 1 then return "Foo", nil, 1 end
        end
        assert.is_false(WGS:PlaceRaiderInCompGroup("Nobody", 7))
        assert.are.equal(0, #moves)
    end)
end)
