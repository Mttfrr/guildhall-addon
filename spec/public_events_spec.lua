local helpers = require("spec.helpers")

-- docs/EVENTS.md is GuildHall's public-API contract for the in-process
-- callback bus. Other addons (and our own future bridge modules) rely
-- on the listed event names + payload shapes — breaking changes are
-- the kind of regression that ripples invisibly through the ecosystem.
--
-- These specs subscribe to each documented event, trigger the
-- producing path, and assert the fired payload carries the fields
-- the docs promise (with the documented types). Drift between the
-- code and the docs becomes a CI failure, not a user-report failure.
--
-- Not every documented event is exercised here — WGS_ENCOUNTER_RECORDED
-- needs an ENCOUNTER_END trigger, WGS_INTERNAL_ERROR fires from many
-- internal failure paths and is unit-tested at each site, and
-- WGS_PEER_SYNC_APPLIED is covered in spec/peer_sync_spec.lua. What
-- lives here is the "would have caught silent drift" set.

local function setup()
    local WGS = helpers.setup()
    WGS._captured = {}
    return WGS
end

-- Subscribe to one event; return a table that records every payload
-- the bus fires for that event. Reads naturally in specs:
--     local capture = subscribe(WGS, "WGS_SESSION_STARTED")
--     trigger()
--     assert.are.equal(1, #capture)
--     assert.is_table(capture[1])
local function subscribe(WGS, eventName)
    local capture = {}
    GuildHall.RegisterCallback({}, eventName, function(_, payload)
        capture[#capture + 1] = payload
    end)
    return capture
end

describe("public event contract — docs/EVENTS.md", function()
    describe("WGS_SESSION_STARTED + WGS_SESSION_ENDED", function()
        local WGS
        before_each(function()
            WGS = setup()
            _G.IsInRaid = function() return true end
            _G.IsInGroup = function() return true end
            _G.GetInstanceInfo = function() return "TestRaid", nil, 16, "Mythic" end
            WGS.GetTimestamp = function() return 1700000000 end
        end)

        it("fires on StartAttendanceForTeam with the documented session fields", function()
            local capture = subscribe(WGS, "WGS_SESSION_STARTED")
            WGS:StartAttendanceForTeam(42, "Mythic Raiders",
                { id = 7, title = "Tuesday Pulls" })

            assert.are.equal(1, #capture, "exactly one WGS_SESSION_STARTED")
            local session = capture[1]
            -- Required fields per docs/EVENTS.md WGS_SESSION_STARTED.
            assert.is_number(session.startedAt)
            assert.is_string(session.startedBy)
            assert.is_string(session.instanceName)
            assert.is_number(session.difficultyID)
            assert.are.equal(42, session.teamId)
            assert.are.equal("Mythic Raiders", session.teamName)
            assert.are.equal(7, session.eventId)
            assert.are.equal("Tuesday Pulls", session.eventTitle)
        end)

        it("fires WGS_SESSION_ENDED on StopAttendance with endedAt + memberList", function()
            -- StopAttendance schedules a deferred export reminder via
            -- C_Timer.After; tests don't install C_Timer by default
            -- so stub it before triggering. The reminder fn never
            -- runs in tests (we don't drain timers), only the deferred
            -- API needs to exist.
            _G.C_Timer = _G.C_Timer or { After = function() end }
            WGS:StartAttendanceForTeam(42, "Mythic Raiders", { id = 7 })
            local capture = subscribe(WGS, "WGS_SESSION_ENDED")
            WGS:StopAttendance()

            assert.are.equal(1, #capture)
            local session = capture[1]
            assert.is_number(session.startedAt)
            assert.is_number(session.endedAt, "endedAt is the docs-required addition vs SESSION_STARTED")
            assert.is_table(session.memberList, "memberList is the frozen array form")
        end)
    end)

    describe("WGS_IMPORT_APPLIED", function()
        local WGS
        before_each(function()
            WGS = setup()
            -- ProcessImport streams importers across frames via
            -- C_Timer when present. Tests need timers to drain so
            -- the tail-fire of WGS_IMPORT_APPLIED actually happens.
            -- Inline-executing After keeps the chain synchronous so
            -- spec assertions stay observable.
            _G.C_Timer = { After = function(_, fn) fn() end }
        end)

        it("fires once at the tail of ProcessImport with { count, importedAt }", function()
            local capture = subscribe(WGS, "WGS_IMPORT_APPLIED")
            WGS:ProcessImport({
                teams = {},
                events = {},
                characters = {},
            })
            assert.are.equal(1, #capture,
                "WGS_IMPORT_APPLIED must fire exactly once at the tail of the import chain")
            assert.is_number(capture[1].count)
            assert.is_number(capture[1].importedAt)
        end)
    end)

    describe("WGS_CURRENT_TEAM_CHANGED", function()
        local WGS
        before_each(function()
            WGS = setup()
            WGS.db.global.teams = {
                { id = 5, name = "Team Alpha" },
                { id = 9, name = "Team Beta" },
            }
        end)

        it("fires on SetCurrentTeamId with { teamId } payload", function()
            local capture = subscribe(WGS, "WGS_CURRENT_TEAM_CHANGED")
            WGS:SetCurrentTeamId(5)
            assert.are.equal(1, #capture)
            assert.is_table(capture[1])
            assert.are.equal(5, capture[1].teamId)
        end)

        it("does NOT fire when the value didn't change (no-op set)", function()
            WGS:SetCurrentTeamId(5)
            local capture = subscribe(WGS, "WGS_CURRENT_TEAM_CHANGED")
            WGS:SetCurrentTeamId(5)   -- same value
            assert.are.equal(0, #capture,
                "documented invariant: no fire when the team didn't actually change")
        end)

        it("fires with nil teamId when clearing the filter", function()
            WGS:SetCurrentTeamId(5)
            local capture = subscribe(WGS, "WGS_CURRENT_TEAM_CHANGED")
            WGS:SetCurrentTeamId(nil)
            assert.are.equal(1, #capture)
            assert.is_nil(capture[1].teamId)
        end)
    end)

    describe("WGS_LOOT_EDITED + WGS_ATTENDANCE_EDITED (correction mutators)", function()
        -- Spot-checks the contract — full coverage is in
        -- loot_corrections_spec.lua and attendance_corrections_spec.lua.
        -- This pass asserts the docs-required `kind` discriminator
        -- and `index` are present, which downstream UI subscribers
        -- (e.g. the in-place refresh in UI/Tabs/Logs.lua) depend on.
        local WGS
        before_each(function()
            WGS = helpers.setup()
            dofile("Modules/Loot.lua")
            WGS._printed = {}
            function WGS:Print(s) self._printed[#self._printed + 1] = s end
            WGS.db.global.loot = { { itemID = 1, timestamp = 1, player = "X-R" } }
            WGS.db.global.attendance = { { startedAt = 100, memberList = {} } }
        end)

        it("WGS_LOOT_EDITED carries { index, row, kind }", function()
            local capture = subscribe(WGS, "WGS_LOOT_EDITED")
            WGS:RetagLootRow(1, 99, 42)
            assert.are.equal(1, #capture)
            assert.are.equal(1, capture[1].index)
            assert.is_table(capture[1].row)
            assert.are.equal("retag", capture[1].kind)
        end)

        it("WGS_ATTENDANCE_EDITED carries { index, session, kind }", function()
            local capture = subscribe(WGS, "WGS_ATTENDANCE_EDITED")
            WGS:RebindAttendanceSession(1, 99, "New")
            assert.are.equal(1, #capture)
            assert.are.equal(1, capture[1].index)
            assert.is_table(capture[1].session)
            assert.are.equal("rebind", capture[1].kind)
        end)
    end)
    describe("fired-event completeness pin", function()
        -- The drift the audit found: events were being fired in source
        -- that docs/EVENTS.md never mentioned, and the spec only pinned
        -- the documented subset — so the gap was invisible to CI. This
        -- block closes the loop in both directions: every FireEvent
        -- literal in shipping source must be documented, and every
        -- documented event must still have a fire site.

        local function readFile(path)
            local f = assert(io.open(path, "r"), "cannot open " .. path)
            local s = f:read("*a")
            f:close()
            return s
        end

        local function documentedEvents()
            local out = {}
            for name in readFile("docs/EVENTS.md"):gmatch("### `(WGS_[%u_]+)`") do
                out[name] = true
            end
            return out
        end

        local function firedEvents()
            -- Shipping source only — Libs/ is vendored, spec/ is tests
            -- (WGS_UNIT_TEST_EVENT lives there and is intentionally
            -- not part of the public contract).
            local p = assert(io.popen(
                [[grep -rho 'FireEvent("WGS_[A-Z_]*"' --include='*.lua' ]] ..
                [[Core.lua Config.lua Modules Sync UI Util 2>/dev/null]]),
                "io.popen unavailable")
            local out = {}
            for line in p:lines() do
                local name = line:match('(WGS_[%u_]+)')
                if name then out[name] = true end
            end
            p:close()
            return out
        end

        it("every event fired in source is documented in docs/EVENTS.md", function()
            local documented = documentedEvents()
            local missing = {}
            for name in pairs(firedEvents()) do
                if not documented[name] then missing[#missing + 1] = name end
            end
            table.sort(missing)
            assert.same({}, missing,
                "fired but undocumented — add these to docs/EVENTS.md: "
                .. table.concat(missing, ", "))
        end)

        it("every documented event still has a fire site in source", function()
            local fired = firedEvents()
            local stale = {}
            for name in pairs(documentedEvents()) do
                if not fired[name] then stale[#stale + 1] = name end
            end
            table.sort(stale)
            assert.same({}, stale,
                "documented but never fired — remove from docs/EVENTS.md or restore the fire site: "
                .. table.concat(stale, ", "))
        end)

        it("sanity: the doc scrape actually found the core events", function()
            local documented = documentedEvents()
            assert.is_true(documented["WGS_SESSION_STARTED"])
            assert.is_true(documented["WGS_IMPORT_APPLIED"])
        end)
    end)
end)
