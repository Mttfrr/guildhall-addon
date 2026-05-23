local helpers = require("spec.helpers")

-- ProcessImport gets a big payload and applies it across 13 importers.
-- In live WoW it streams one importer per frame via C_Timer.After so
-- the paste doesn't visibly hitch; in tests the C_Timer-less fallback
-- drives synchronously so assertions see the post-state immediately.
-- These specs lock both contracts in.

describe("WGS:ProcessImport streaming", function()
    local WGS
    before_each(function() WGS = helpers.setup() end)

    -- The legacy synchronous contract: with no C_Timer in the
    -- environment (the default test stub), ProcessImport finishes
    -- before returning. db state and the WGS_IMPORT_APPLIED event are
    -- both observable inline. Existing call sites depend on this.
    it("runs synchronously when C_Timer is unavailable", function()
        _G.C_Timer = nil

        local applied
        GuildHall.RegisterCallback({}, "WGS_IMPORT_APPLIED", function(_, p) applied = p end)

        WGS:ProcessImport({
            events = { { id = 1, title = "Heroic" } },
            signups = { { eventId = 1, characterName = "X", status = "P" } },
        })

        assert.is_table(applied)
        assert.is_true(applied.count >= 2)
        assert.are.equal(1, #WGS.db.global.events)
        assert.are.equal(1, #WGS.db.global.signups)
    end)

    -- With C_Timer present, importers are scheduled one per frame. The
    -- WGS_IMPORT_APPLIED event must fire only after the last importer
    -- has actually run — never mid-stream — so subscribers see a
    -- fully-consistent db.
    it("defers importers across frames via C_Timer.After", function()
        local queue = {}
        _G.C_Timer = {
            After = function(_, fn) table.insert(queue, fn) end,
        }

        local applied = false
        GuildHall.RegisterCallback({}, "WGS_IMPORT_APPLIED", function() applied = true end)

        WGS:ProcessImport({
            events  = { { id = 1, title = "Heroic" } },
            signups = { { eventId = 1, characterName = "X", status = "P" } },
        })

        -- First importer ran inline; the rest were scheduled. The
        -- applied event must NOT have fired yet — the db is still
        -- being filled in by the deferred steps.
        assert.is_false(applied, "applied fired before deferred importers ran")
        assert.is_true(#queue >= 1, "expected importers to be deferred via C_Timer.After")

        -- Drain the scheduled callbacks until everything settles. Each
        -- step may schedule the next one, so we have to re-poll the
        -- queue rather than iterate it once.
        local guard = 0
        while #queue > 0 and guard < 100 do
            local fn = table.remove(queue, 1)
            fn()
            guard = guard + 1
        end

        assert.is_true(applied, "applied never fired after draining the queue")
        assert.are.equal(1, #WGS.db.global.events)
        assert.are.equal(1, #WGS.db.global.signups)

        _G.C_Timer = nil
    end)

    -- A throwing importer must not abort the whole import. The pcall
    -- catches it, fires WGS_INTERNAL_ERROR for ops visibility, and
    -- the rest of the importers continue against db.global.
    it("survives a throwing importer and still applies the rest", function()
        _G.C_Timer = nil
        _G.C_Item  = { RequestLoadItemDataByID = function() end }

        -- importWishlists eventually calls ipairs(entry.items); handing
        -- it a non-table for entry.items forces a throw inside the
        -- importer. The pcall in ProcessImport should swallow it.
        WGS:ProcessImport({
            wishlists = { { playerName = "X", items = "not-a-table" } },
            events    = { { id = 1 } },
        })

        _G.C_Item = nil

        local sawErr
        for _, f in ipairs(WGS._fired) do
            if f.event == "WGS_INTERNAL_ERROR" and f.args[1]
               and tostring(f.args[1].source):find("^Import%.step%.") then
                sawErr = true
            end
        end
        -- The events importer ran regardless of the wishlists failure.
        assert.are.equal(1, #WGS.db.global.events)
        assert.is_true(sawErr, "expected WGS_INTERNAL_ERROR from the throwing importer")
    end)
end)

describe("WGS:ProcessImport wishlist preload batching", function()
    local WGS
    before_each(function() WGS = helpers.setup() end)

    -- 500 itemIDs in a single guild's wishlists is realistic for a
    -- 25-raider roster; firing 500 C_Item requests in one frame is what
    -- drives the visible hitch on paste. The importer now drains them in
    -- batches across frames.
    it("batches C_Item.RequestLoadItemDataByID across frames", function()
        local queue = {}
        _G.C_Timer = { After = function(_, fn) table.insert(queue, fn) end }

        local requested = {}
        _G.C_Item = {
            RequestLoadItemDataByID = function(id) requested[#requested + 1] = id end,
        }

        -- 125 items across 5 wishlists → ceil(125/50) = 3 batches.
        local wl = {}
        for w = 1, 5 do
            local items = {}
            for i = 1, 25 do items[i] = { itemID = w * 1000 + i } end
            wl[w] = { playerName = "P" .. w, items = items }
        end

        WGS:ProcessImport({ wishlists = wl })

        -- Drain the scheduled queue (both per-importer steps AND the
        -- per-50-item preload batches end up on it). Importantly,
        -- assert that no single drain step exceeds the batch size —
        -- otherwise we'd still hitch on paste.
        local maxDelta = 0
        local guard = 0
        while #queue > 0 and guard < 200 do
            local before = #requested
            local fn = table.remove(queue, 1)
            fn()
            local delta = #requested - before
            if delta > maxDelta then maxDelta = delta end
            guard = guard + 1
        end

        assert.are.equal(125, #requested, "every wishlist item should be preloaded")
        assert.is_true(maxDelta <= 50, "a single drained step issued more than 50 requests: " .. maxDelta)

        _G.C_Timer = nil
        _G.C_Item = nil
    end)
end)
