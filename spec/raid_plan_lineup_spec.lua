-- Tonight's boss lineup, each boss with its own comp.
--
-- The platform exports `raidPlans` — the night default comp plus each
-- lineup boss's comp, in order. The addon follows the raid through it:
-- Organize Groups sorts for the boss the raid is on, a kill moves the raid
-- to the next boss and prints the swaps, and a raider a boss's comp has on
-- standby goes to the groups after the playing ones.

local helpers = require("spec.helpers")

local function slot(name, group, extra)
    local s = { character_name = name, slot_group = group and ("group" .. group) or "bench", slot_index = 0 }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

local DEFAULT = {
    slot("Tank", 1), slot("Heal", 2), slot("Alpha", 3), slot("Bravo", 3), slot("Sitter"),
}

local function planPayload()
    return {
        raidComps = { { eventId = 7, slots = DEFAULT } },
        raidPlans = { {
            eventId = 7, teamId = 3, defaultComp = DEFAULT,
            bosses = {
                -- Out of order on purpose: the importer sorts by `order`.
                { name = "Second Boss", order = 1, encounterID = 202, inherits = true, slots = {} },
                { name = "First Boss", order = 0, encounterID = 201, inherits = false, slots = {
                    slot("Tank", 1), slot("Heal", 2), slot("Alpha", 3), slot("Sitter", 3), slot("Bravo"),
                } },
                { name = "Third Boss", order = 2, encounterID = 203, inherits = false, slots = {
                    slot("Tank", 1), slot("Heal", 2), slot("Bravo", 4), slot("Sitter", 3), slot("Alpha"),
                    slot("Pug", 3, { placeholder = true }),
                } },
            },
        } },
    }
end

describe("raidPlans import", function()
    local WGS
    before_each(function()
        WGS = helpers.setup()
        WGS:ProcessImport(planPayload())
    end)

    it("stores the lineup in order, inheriting bosses without a comp of their own", function()
        local plan = WGS:GetRaidPlan(7)
        assert.are.equal(3, #plan.bosses)
        assert.are.equal("First Boss", plan.bosses[1].name)
        assert.are.equal("Second Boss", plan.bosses[2].name)
        assert.is_true(plan.bosses[2].inherits)
        assert.is_nil(plan.bosses[2].comp)
        assert.are.equal(5, #plan.bosses[1].comp.assignments)
    end)

    it("an import without raidPlans (older server) clears last week's lineup", function()
        WGS:ProcessImport({ raidComps = { { eventId = 7, slots = DEFAULT } } })
        assert.is_nil(WGS:GetRaidPlan(7))
        assert.is_not_nil(WGS:GetRaidComp(7))
    end)

    it("keeps the pug flag so a placeholder never matches a raider", function()
        local comp = WGS:GetRaidComp(7, "Third Boss")
        local pug
        for _, a in ipairs(comp.assignments) do if a.name == "Pug" then pug = a end end
        assert.is_true(pug.placeholder)
    end)
end)

describe("GetRaidComp per boss", function()
    local WGS
    before_each(function()
        WGS = helpers.setup()
        WGS:ProcessImport(planPayload())
    end)

    local function groupOf(comp, name)
        for _, a in ipairs(comp.assignments) do if a.name == name then return a.group end end
    end

    it("returns the boss's own comp, by name or encounter id", function()
        assert.are.equal(3, groupOf(WGS:GetRaidComp(7, "First Boss"), "Sitter"))
        assert.are.equal(3, groupOf(WGS:GetRaidComp(7, 201), "Sitter"))
        assert.are.equal(3, groupOf(WGS:GetRaidComp(7, "first boss"), "Sitter"))
    end)

    it("falls back to the night default for an inheriting or unknown boss", function()
        assert.is_nil(groupOf(WGS:GetRaidComp(7, "Second Boss"), "Sitter"))
        assert.is_nil(groupOf(WGS:GetRaidComp(7, "Nobody"), "Sitter"))
        assert.is_nil(groupOf(WGS:GetRaidComp(7), "Sitter"))
    end)

    it("the current comp boss persists, and a boss gone from the lineup reads as the default", function()
        WGS:SetCompBoss(7, "Third Boss")
        assert.are.equal("Third Boss", WGS:GetCompBoss(7))
        WGS.db.global.raidPlans[1].bosses[3] = nil
        assert.is_nil(WGS:GetCompBoss(7))
    end)
end)

describe("CompSwaps", function()
    local WGS
    before_each(function()
        WGS = helpers.setup()
        WGS:ProcessImport(planPayload())
    end)

    it("names who comes in and who goes to standby", function()
        local s = WGS:CompSwaps(WGS:GetRaidComp(7), WGS:GetRaidComp(7, "First Boss"))
        assert.are.same({ "Sitter" }, s.incoming)
        assert.are.same({ "Bravo" }, s.standby)
    end)

    it("flags a regroup when the same players change groups", function()
        local s = WGS:CompSwaps(WGS:GetRaidComp(7), WGS:GetRaidComp(7))
        assert.are.same({}, s.incoming)
        assert.are.same({}, s.standby)
        assert.is_false(s.regroup)
    end)
end)

describe("PlanGroupMoves", function()
    local WGS
    before_each(function() WGS = helpers.setup() end)

    -- Apply a plan to a model of the raid and return short → group.
    local function apply(roster, ops)
        local g, count = {}, {}
        for i = 1, 8 do count[i] = 0 end
        for _, r in ipairs(roster) do g[r.index] = r.subgroup; count[r.subgroup] = count[r.subgroup] + 1 end
        for _, o in ipairs(ops) do
            if o.op == "set" then
                -- The real API does nothing into a full group; fail loudly here.
                assert(count[o.group] < 5, "set into a full group " .. o.group)
                count[g[o.index]] = count[g[o.index]] - 1
                count[o.group] = count[o.group] + 1
                g[o.index] = o.group
            else
                g[o.a], g[o.b] = g[o.b], g[o.a]
            end
        end
        local out = {}
        for _, r in ipairs(roster) do out[r.short] = g[r.index] end
        return out, count
    end

    local function roster(list)
        local r = {}
        for i, e in ipairs(list) do r[i] = { index = i, short = e[1], subgroup = e[2] } end
        return r
    end

    it("moves a planned raider into a group with room", function()
        local r = roster({ { "A", 1 }, { "B", 1 } })
        local placed = apply(r, WGS:PlanGroupMoves(r, { a = 2 }, {}, {}))
        assert.are.equal(2, placed.A)
        assert.are.equal(1, placed.B)
    end)

    it("swaps into a FULL group instead of silently failing", function()
        -- Group 1 is full of raiders who belong in group 2, and vice versa.
        local list = {}
        for i = 1, 5 do list[#list + 1] = { "x" .. i, 1 } end
        for i = 1, 5 do list[#list + 1] = { "y" .. i, 2 } end
        local target = {}
        for i = 1, 5 do target["x" .. i] = 2; target["y" .. i] = 1 end
        local r = roster(list)
        local placed = apply(r, WGS:PlanGroupMoves(r, target, {}, {}))
        for i = 1, 5 do
            assert.are.equal(2, placed["x" .. i])
            assert.are.equal(1, placed["y" .. i])
        end
    end)

    it("moves standby raiders behind the playing groups", function()
        local r = roster({ { "Play", 2 }, { "Sit", 1 } })
        local placed = apply(r, WGS:PlanGroupMoves(r, { play = 1 }, { sit = true }, { standbyToBack = true }))
        assert.are.equal(1, placed.Play)
        assert.are.equal(5, placed.Sit)
    end)

    it("leaves standby raiders alone with the toggle off", function()
        local r = roster({ { "Sit", 1 } })
        local placed = apply(r, WGS:PlanGroupMoves(r, {}, { sit = true }, { standbyToBack = false }))
        assert.are.equal(1, placed.Sit)
    end)

    it("never chases a raider the comp doesn't mention", function()
        local r = roster({ { "Stranger", 2 } })
        assert.are.same({}, WGS:PlanGroupMoves(r, { other = 1 }, {}, { standbyToBack = true }))
    end)

    it("a 20-man with 4 standby fills groups 1-4 and parks standby in 5", function()
        local list, target, standby = {}, {}, {}
        for i = 1, 20 do
            list[#list + 1] = { "p" .. i, ((i - 1) % 5) + 1 }   -- spread over 1-5
            target["p" .. i] = math.floor((i - 1) / 5) + 1        -- planned 1-4
        end
        for i = 1, 4 do list[#list + 1] = { "s" .. i, 1 + (i % 2) }; standby["s" .. i] = true end
        local r = roster(list)
        local placed, count = apply(r, WGS:PlanGroupMoves(r, target, standby, { standbyToBack = true }))
        for i = 1, 20 do assert.are.equal(target["p" .. i], placed["p" .. i], "p" .. i) end
        for i = 1, 4 do assert.is_true(placed["s" .. i] >= 5, "s" .. i) end
        for g = 1, 4 do assert.are.equal(5, count[g]) end
    end)
end)

describe("following the lineup through the night", function()
    local WGS, moves, printed, members

    before_each(function()
        WGS = helpers.setup()
        -- Real strings, so the chat lines can be read: the stub locale
        -- returns keys, and modules captured that table at load.
        -- (_G explicitly: busted sandboxes the spec's own globals.)
        local stub = _G.GuildHall_L
        dofile("Locales/enUS.lua")
        for k, v in pairs(_G.GuildHall_L) do rawset(stub, k, v) end
        _G.GuildHall_L = stub
        WGS:ProcessImport(planPayload())
        moves, printed = {}, {}
        members = { { "Tank", 1 }, { "Heal", 2 }, { "Alpha", 3 }, { "Bravo", 3 }, { "Sitter", 6 } }
        _G.IsInRaid = function() return true end
        _G.GetNumGroupMembers = function() return #members end
        _G.GetRaidRosterInfo = function(i)
            local m = members[i]
            if m then return m[1], nil, m[2] end
        end
        _G.SetRaidSubgroup = function(i, g)
            moves[#moves + 1] = { i = i, g = g }
            members[i][2] = g
        end
        _G.SwapRaidSubgroup = function(a, b)
            members[a][2], members[b][2] = members[b][2], members[a][2]
        end
        _G.InCombatLockdown = function() return false end
        _G.IsEncounterInProgress = function() return false end
        WGS.HasGroupLeadOrAssist = function() return true end
        WGS.GetCurrentAttendanceContext = function() return { eventId = 7 } end
        WGS.db.profile.autoSortGroups = true
        WGS.Print = function(_, msg) printed[#printed + 1] = msg end
    end)

    local function groupOf(name)
        for _, m in ipairs(members) do if m[1] == name then return m[2] end end
    end

    it("Organize Groups sorts for the boss the raid is on", function()
        WGS:SetCompBoss(7, "First Boss")
        WGS:SortRaidGroups({ id = 7 })
        assert.are.equal(3, groupOf("Sitter"))
        assert.are.equal(5, groupOf("Bravo"))   -- standby → the back
    end)

    it("a kill moves to the next boss, prints the swaps and sorts", function()
        WGS:SetCompBoss(7, "First Boss")
        WGS:SortRaidGroups({ id = 7 })
        printed = {}
        local nextBoss = WGS:OnLineupBossKilled(201, "First Boss")
        assert.are.equal("Second Boss", nextBoss.name)
        assert.are.equal("Second Boss", WGS:GetCompBoss(7))
        local line = table.concat(printed, "\n")
        assert.truthy(line:find("Second Boss", 1, true))
        assert.truthy(line:find("in: Bravo", 1, true))
        assert.truthy(line:find("standby: Sitter", 1, true))
        -- Second Boss inherits the default: Bravo back in 3, Sitter to the back.
        assert.are.equal(3, groupOf("Bravo"))
        assert.are.equal(5, groupOf("Sitter"))
    end)

    it("waits for combat to end before sorting", function()
        members[5][2] = 3   -- arranged for First Boss: Sitter plays,
        members[4][2] = 5   -- Bravo on standby
        _G.InCombatLockdown = function() return true end
        WGS:OnLineupBossKilled(201, "First Boss")
        assert.are.equal(0, #moves)
        _G.InCombatLockdown = function() return false end
        assert.is_true(WGS:RunPendingSort())
        assert.is_true(#moves > 0)
    end)

    it("does not sort with auto-sort off — it only says what changes", function()
        WGS.db.profile.autoSortGroups = false
        WGS:OnLineupBossKilled(201, "First Boss")
        assert.are.equal(0, #moves)
        assert.truthy(table.concat(printed, "\n"):find("Next: Second Boss", 1, true))
    end)

    it("a kill that isn't on the lineup changes nothing", function()
        WGS:SetCompBoss(7, "First Boss")
        assert.is_nil(WGS:OnLineupBossKilled(999, "Some Other Boss"))
        assert.are.equal("First Boss", WGS:GetCompBoss(7))
    end)

    it("the last boss says the lineup is done", function()
        WGS:OnLineupBossKilled(203, "Third Boss")
        assert.truthy(table.concat(printed, "\n"):find("Lineup done", 1, true))
    end)

    it("pulling a lineup boss puts the raid on its comp", function()
        WGS:OnLineupBossPulled(203, "Third Boss")
        assert.are.equal("Third Boss", WGS:GetCompBoss(7))
    end)

    it("a pug placeholder never moves a real raider", function()
        members[#members + 1] = { "Pug", 1 }
        WGS:SortRaidGroups({ id = 7 }, "Third Boss")
        assert.are.equal(1, groupOf("Pug"))
    end)

    it("a fresh joiner the boss has on standby is placed in a back group", function()
        WGS:SetCompBoss(7, "First Boss")
        members[5][2] = 3   -- Sitter plays First Boss
        members[4][2] = 1   -- Bravo (standby) just joined into group 1
        assert.is_true(WGS:PlaceRaiderInCompGroup("Bravo", 7))
        assert.are.equal(5, groupOf("Bravo"))
    end)
end)
