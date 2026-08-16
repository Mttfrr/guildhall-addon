local helpers = require("spec.helpers")

-- Modules/RCLC.lua — the RCLootCouncil bridge. Award capture rides
-- RCLC's own "history" / "delete_history" comms (every GuildHall user
-- in the raid receives them, not just the ML); wishlist injection puts
-- the platform's imported wishes into RCLC's voting/roll frames.
--
-- Tests cover:
--   * history comm → new loot row (award fields, source="rclc",
--     timestamp from the id's epoch prefix, instance last-hyphen split)
--   * rclcId idempotency (same award twice → one row)
--   * upgrade path (existing chat row gets award fields + rev bump,
--     no new row, WGS_LOOT_EDITED kind="award")
--   * delete_history → tombstone via the existing DeleteLootRow path
--   * RCHistory_ResponseEdit → response fields updated by entry id
--   * backfill (GetHistoryDB walk, idempotent re-run)
--   * quality gate (cached sub-Epic quality skipped on fresh insert)
--   * RCLC-absent → every entry point is a no-op
--   * voting column install (official Column API args) + cell contract
--   * gh_wish overlay freshness (peer share wins only when newer)

local FAKE_ID = "1754078130-3"

local function makeHistoryEntry(t)
    t = t or {}
    local entry = {
        lootWon      = t.lootWon or "|cffa335ee|Hitem:212425::::::::80|h[Sword]|h|r",
        date         = t.date or "2026/08/01",
        time         = t.time or "20:15:30",
        instance     = t.instance or "Manaforge Omega-Mythic",
        boss         = t.boss or "Dimensius",
        votes        = t.votes,
        response     = t.response or "Mainspec",
        responseID   = t.responseID or 1,
        isAwardReason = t.isAwardReason,
        difficultyID = t.difficultyID or 16,
        mapID        = 2810,
        groupSize    = 20,
        class        = t.class or "WARRIOR",
        id           = t.id or FAKE_ID,
    }
    if t.noId then entry.id = nil end
    return entry
end

-- Minimal RCLC stand-in exposing exactly the surface the bridge
-- consumes: PREFIXES, Require("Services.Comms") (BulkSubscribe capture
-- + GetSender), GetHistoryDB, GetActiveModule, GetLootTable.
local function makeFakeRCLC(opts)
    opts = opts or {}
    local comms = { subs = {}, sent = {} }
    function comms:BulkSubscribe(prefix, map)
        self.subs[prefix] = self.subs[prefix] or {}
        local handles = {}
        for command, fn in pairs(map) do
            self.subs[prefix][command] = fn
            handles[#handles + 1] = { unsubscribe = function() end }
        end
        return handles
    end
    function comms:GetSender(prefix)
        return function(target, command, ...)
            comms.sent[#comms.sent + 1] = {
                prefix = prefix, target = target, command = command, args = { ... },
            }
        end
    end
    local rc = {
        PREFIXES = { MAIN = "RCLC" },
        _comms   = comms,
        Require  = function(name)
            if name == "Services.Comms" then return comms end
        end,
    }
    function rc:GetHistoryDB() return opts.historyDB or {} end
    function rc:GetActiveModule(name) return opts.modules and opts.modules[name] end
    function rc:GetLootTable() return opts.lootTable end
    return rc
end

describe("Modules/RCLC.lua", function()
    local WGS, rc

    local origGetNormalizedRealmName, origC_Item

    -- Point the AceAddon stub's GetAddon at the fake (or nil) and drop
    -- the probe cache so WGS:GetRCLC re-resolves.
    local function installFakeRCLC(fake)
        LibStub("AceAddon-3.0").GetAddon = function(_, name, _silent)
            if name == "RCLootCouncil" then return fake end
        end
        WGS:_ResetAddonCache()
    end

    local function lastFired(event)
        local hit
        for _, f in ipairs(GuildHall._fired) do
            if f.event == event then hit = f.args[1] end
        end
        return hit
    end

    before_each(function()
        WGS = helpers.setup()
        -- Loot.lua carries the DeleteLootRow machinery the delete path
        -- reuses; neither file is in helpers.setup()'s dofile list.
        dofile("Modules/Loot.lua")
        dofile("Modules/RCLC.lua")

        origGetNormalizedRealmName = _G.GetNormalizedRealmName
        origC_Item                 = _G.C_Item
        _G.GetNormalizedRealmName  = function() return "TestRealm" end

        function WGS:GetTimestamp() return 1754078130 end
        function WGS:GetPlayerKey() return "Recorder-TestRealm" end

        WGS.db.global.loot = {}
        WGS:_RCLC_ResetState()
        rc = makeFakeRCLC()
        installFakeRCLC(rc)
    end)

    after_each(function()
        _G.GetNormalizedRealmName = origGetNormalizedRealmName
        _G.C_Item                 = origC_Item
        WGS:_ResetAddonCache()
    end)

    ------------------------------------------------------------------
    -- Detection
    ------------------------------------------------------------------

    it("detects RCLC only when the registry hands back its real surface", function()
        assert.is_true(WGS:HasRCLC())
        -- A table without .Require (e.g. the permissive Ace stub's {})
        -- must read as absent, not crash later on rc.Require(...).
        installFakeRCLC({})
        assert.is_false(WGS:HasRCLC())
        installFakeRCLC(nil)
        assert.is_false(WGS:HasRCLC())
    end)

    it("is a no-op on every entry point when RCLC is absent", function()
        installFakeRCLC(nil)
        assert.is_false(WGS:_RCLC_InstallAwardComms())
        assert.is_false(WGS:_RCLC_InstallWishComms())
        assert.is_false(WGS:_RCLC_InstallVotingColumn())
        assert.is_false(WGS:_RCLC_HookLootFrame())
        assert.are.equal(0, WGS:ImportRCLCHistory())
        assert.are.equal(0, #WGS.db.global.loot)
    end)

    ------------------------------------------------------------------
    -- Award capture via the "history" comm
    ------------------------------------------------------------------

    it("records a history comm as a loot row with award fields + source='rclc'", function()
        assert.is_true(WGS:_RCLC_InstallAwardComms(rc))
        rc._comms.subs["RCLC"].history({ "Winner-TestRealm", makeHistoryEntry{ votes = 2 } })

        assert.are.equal(1, #WGS.db.global.loot)
        local row = WGS.db.global.loot[1]
        assert.are.equal("rclc",               row.source)
        assert.are.equal("Winner-TestRealm",   row.player)
        assert.are.equal(212425,               row.itemID)
        assert.are.equal(1754078130,           row.timestamp,
            "timestamp must come from the id's epoch prefix")
        assert.are.equal("Manaforge Omega",    row.instance,
            "instance splits 'InstanceName-DifficultyName' on the last hyphen")
        assert.are.equal(16,                   row.difficulty)
        assert.are.equal("Dimensius",          row.boss)
        assert.are.equal("Mainspec",           row.awardResponse)
        assert.are.equal(1,                    row.awardResponseId)
        assert.are.equal(2,                    row.awardVotes)
        assert.is_nil(row.awardIsReason)
        assert.are.equal("Winner-TestRealm@" .. FAKE_ID, row.rclcId)
        assert.are.equal("Recorder-TestRealm", row.recordedBy)

        local fired = lastFired("WGS_LOOT_RECORDED")
        assert.is_table(fired)
        assert.are.equal("rclc", fired.source)
    end)

    it("normalises a bare winner name with the local realm suffix", function()
        WGS:RecordRCLCAward("ShortName", makeHistoryEntry{})
        assert.are.equal("ShortName-TestRealm", WGS.db.global.loot[1].player)
        -- rclcId keeps the raw winner: delete_history matches by id
        -- suffix, and re-deliveries carry the same raw form.
        assert.are.equal("ShortName@" .. FAKE_ID, WGS.db.global.loot[1].rclcId)
    end)

    it("keeps awardIsReason for award-reason entries", function()
        WGS:RecordRCLCAward("Winner-TestRealm",
            makeHistoryEntry{ response = "Disenchant", responseID = 1, isAwardReason = true })
        assert.is_true(WGS.db.global.loot[1].awardIsReason)
    end)

    it("is idempotent on the same award (rclcId exact match)", function()
        assert.are.equal("added",
            WGS:RecordRCLCAward("Winner-TestRealm", makeHistoryEntry{}))
        assert.are.equal("skipped",
            WGS:RecordRCLCAward("Winner-TestRealm", makeHistoryEntry{}))
        assert.are.equal(1, #WGS.db.global.loot)
    end)

    ------------------------------------------------------------------
    -- Upgrade path (chat/MRT row already captured the drop)
    ------------------------------------------------------------------

    it("upgrades an existing chat row in place instead of inserting", function()
        table.insert(WGS.db.global.loot, {
            timestamp = 1754078130 - 300,   -- council lag: award lands minutes later
            player    = "Winner-TestRealm",
            itemID    = 212425,
            itemLink  = "|cffa335ee|Hitem:212425|h[Sword]|h|r",
        })

        local action = WGS:RecordRCLCAward("Winner-TestRealm", makeHistoryEntry{ votes = 3 })
        assert.are.equal("updated", action)
        assert.are.equal(1, #WGS.db.global.loot, "no second row for the same drop")

        local row = WGS.db.global.loot[1]
        assert.are.equal("Mainspec", row.awardResponse)
        assert.are.equal(3,          row.awardVotes)
        assert.are.equal("Winner-TestRealm@" .. FAKE_ID, row.rclcId)
        assert.is_nil(row.source, "the captured row's source stays as-is")
        assert.are.equal(1, row.rev, "upgrade bumps rev so the edit wins LWW on peers")

        local fired = lastFired("WGS_LOOT_EDITED")
        assert.is_table(fired)
        assert.are.equal("award", fired.kind)
        assert.are.equal("Mainspec", fired.row.awardResponse)
        assert.is_not.equal(row, fired.row,
            "the event payload is a snapshot copy, not the live row")
    end)

    it("matches upgrades on short player name across realm-suffix drift", function()
        table.insert(WGS.db.global.loot, {
            timestamp = 1754078130 - 60,
            player    = "Winner-OtherRealm",
            itemID    = 212425,
        })
        assert.are.equal("updated",
            WGS:RecordRCLCAward("Winner-TestRealm", makeHistoryEntry{}))
        assert.are.equal(1, #WGS.db.global.loot)
    end)

    it("does not upgrade a row outside the 15-minute award window", function()
        table.insert(WGS.db.global.loot, {
            timestamp = 1754078130 - 1000,   -- > AWARD_MATCH_WINDOW
            player    = "Winner-TestRealm",
            itemID    = 212425,
        })
        assert.are.equal("added",
            WGS:RecordRCLCAward("Winner-TestRealm", makeHistoryEntry{}))
        assert.are.equal(2, #WGS.db.global.loot)
    end)

    ------------------------------------------------------------------
    -- delete_history
    ------------------------------------------------------------------

    it("delete_history removes the row through the DeleteLootRow tombstone path", function()
        assert.is_true(WGS:_RCLC_InstallAwardComms(rc))
        rc._comms.subs["RCLC"].history({ "Winner-TestRealm", makeHistoryEntry{} })
        assert.are.equal(1, #WGS.db.global.loot)

        rc._comms.subs["RCLC"].delete_history({ FAKE_ID })
        assert.are.equal(0, #WGS.db.global.loot)

        local fired = lastFired("WGS_LOOT_EDITED")
        assert.is_table(fired)
        assert.are.equal("delete", fired.kind)
        assert.is_true(fired.row._deleted, "peers get the standard tombstone")
        assert.are.equal(212425, fired.row.itemID)
    end)

    it("delete_history with an unknown id is a no-op", function()
        WGS:RecordRCLCAward("Winner-TestRealm", makeHistoryEntry{})
        assert.is_false(WGS:HandleRCLCDeleteHistory("9999999999-42"))
        assert.are.equal(1, #WGS.db.global.loot)
    end)

    ------------------------------------------------------------------
    -- RCHistory_ResponseEdit
    ------------------------------------------------------------------

    it("applies a history response edit to the matching row by entry id", function()
        WGS:RecordRCLCAward("Winner-TestRealm", makeHistoryEntry{})
        local edited = WGS:HandleRCLCResponseEdit({
            name = "Winner-TestRealm",
            cols = {
                [3] = { args = { id = FAKE_ID } },
                [6] = { args = { response = "Minor Upgrade", responseID = 3 } },
            },
        })
        assert.is_true(edited)
        local row = WGS.db.global.loot[1]
        assert.are.equal("Minor Upgrade", row.awardResponse)
        assert.are.equal(3,               row.awardResponseId)
        assert.are.equal(1,               row.rev)
        assert.are.equal("award", lastFired("WGS_LOOT_EDITED").kind)
    end)

    it("ignores response edits without an identifiable entry id", function()
        WGS:RecordRCLCAward("Winner-TestRealm", makeHistoryEntry{})
        assert.is_false(WGS:HandleRCLCResponseEdit({ cols = {} }))
        assert.is_false(WGS:HandleRCLCResponseEdit(nil))
        assert.is_nil(WGS.db.global.loot[1].rev)
    end)

    ------------------------------------------------------------------
    -- Backfill (/gh rclc import)
    ------------------------------------------------------------------

    it("imports GetHistoryDB in bulk and stays idempotent on re-run", function()
        rc = makeFakeRCLC({ historyDB = {
            ["Alpha-TestRealm"] = {
                makeHistoryEntry{ id = "1754000000-1",
                    lootWon = "|cffa335ee|Hitem:1001|h[A]|h|r" },
                makeHistoryEntry{ id = "1754000100-2",
                    lootWon = "|cffa335ee|Hitem:1002|h[B]|h|r" },
            },
            ["Beta-TestRealm"] = {
                makeHistoryEntry{ id = "1754000200-3",
                    lootWon = "|cffa335ee|Hitem:1003|h[C]|h|r" },
            },
        } })
        installFakeRCLC(rc)

        assert.are.equal(3, WGS:ImportRCLCHistory())
        assert.are.equal(3, #WGS.db.global.loot)
        assert.are.equal(0, WGS:ImportRCLCHistory(), "re-run adds nothing")
        assert.are.equal(3, #WGS.db.global.loot)
        for _, row in ipairs(WGS.db.global.loot) do
            assert.are.equal("rclc", row.source)
            assert.is_nil(row.eventId, "backfill carries no live event stamp")
        end
    end)

    it("backfills id-less legacy entries idempotently via a synthesized id", function()
        rc = makeFakeRCLC({ historyDB = {
            ["Alpha-TestRealm"] = { makeHistoryEntry{ noId = true } },
        } })
        installFakeRCLC(rc)
        assert.are.equal(1, WGS:ImportRCLCHistory())
        assert.are.equal(0, WGS:ImportRCLCHistory())
        assert.are.equal(1, #WGS.db.global.loot)
    end)

    ------------------------------------------------------------------
    -- Quality gate
    ------------------------------------------------------------------

    it("skips fresh inserts below Epic when quality is cached", function()
        _G.C_Item = { GetItemInfo = function() return "Blue Thing", nil, 3, 480 end }
        assert.are.equal("skipped",
            WGS:RecordRCLCAward("Winner-TestRealm", makeHistoryEntry{}))
        assert.are.equal(0, #WGS.db.global.loot)
    end)

    it("tolerates uncached quality (0) like the MRT gap-fill does", function()
        _G.C_Item = nil
        assert.are.equal("added",
            WGS:RecordRCLCAward("Winner-TestRealm", makeHistoryEntry{}))
        assert.are.equal(0, WGS.db.global.loot[1].itemQuality)
    end)

    ------------------------------------------------------------------
    -- Voting-frame column
    ------------------------------------------------------------------

    describe("voting column", function()
        local captured, vf

        before_each(function()
            captured = nil
            vf = {
                scrollCols = {},
                GetColumnIndex = function() return nil end,
                AddColumn = function(_, spec, target, position)
                    captured = { spec = spec, target = target, position = position }
                end,
            }
            rc = makeFakeRCLC({
                modules   = { votingframe = vf },
                lootTable = { { itemID = 212425 } },
            })
            vf.GetCurrentSession = function() return 1 end
            installFakeRCLC(rc)
            WGS.db.global.wishlists = {
                { playerName = "Wisher", items = {
                    { itemID = 212425, itemName = "Sword", priority = "BiS", note = "" },
                } },
            }
        end)

        it("installs after 'response' via the official Column API", function()
            assert.is_true(WGS:_RCLC_InstallVotingColumn(rc))
            assert.is_table(captured)
            assert.are.equal("guildhall_wish", captured.spec.colName)
            assert.are.equal("GuildHall",      captured.spec.name)
            assert.are.equal("response",       captured.target)
            assert.are.equal("after",          captured.position)
            assert.is_function(captured.spec.DoCellUpdate)
            assert.is_function(captured.spec.comparesort)
        end)

        it("cell shows the candidate's priority and always sets the sortable value", function()
            WGS:_RCLC_InstallVotingColumn(rc)
            local frame = { text = { SetText = function(self, t) self.last = t end } }
            local data = { { name = "Wisher-TestRealm", cols = { [6] = {} } } }
            captured.spec.DoCellUpdate(nil, frame, data, nil, 1, 1, 6, true)
            assert.is_truthy(frame.text.last:find("BiS"))
            assert.are.equal(4, data[1].cols[6].value, "BiS weighs 4")

            local data2 = { { name = "NoWish-TestRealm", cols = { [6] = {} } } }
            captured.spec.DoCellUpdate(nil, frame, data2, nil, 1, 1, 6, true)
            assert.are.equal("-", frame.text.last)
            assert.are.equal(0, data2[1].cols[6].value,
                "value MUST be written even when there is no wish")
        end)
    end)

    ------------------------------------------------------------------
    -- gh_wish freshness share
    ------------------------------------------------------------------

    describe("wish share", function()
        before_each(function()
            WGS.db.global.wishlists = {
                { playerName = "Wisher", items = {
                    { itemID = 212425, itemName = "Sword", priority = "High", note = "" },
                } },
            }
            WGS.db.global.wishlistImportedAt = 100
        end)

        it("wires the GHall prefix with the sender registered before the subscribe", function()
            assert.is_true(WGS:_RCLC_InstallWishComms(rc))
            assert.is_function(rc._comms.subs["GHall"].gh_wish)
        end)

        it("broadcasts an item's wishes with the import stamp on RCMLAddItem", function()
            WGS:_RCLC_InstallWishComms(rc)
            WGS:_RCLC_ShareWishesForItem("|cffa335ee|Hitem:212425|h[Sword]|h|r")
            assert.are.equal(1, #rc._comms.sent)
            local msg = rc._comms.sent[1]
            assert.are.equal("GHall",   msg.prefix)
            assert.are.equal("group",   msg.target)
            assert.are.equal("gh_wish", msg.command)
            assert.are.equal(212425,    msg.args[1])
            assert.are.equal("Wisher",  msg.args[2][1].playerName)
            assert.are.equal(100,       msg.args[3])
        end)

        it("prefers a peer overlay only when strictly newer than the local import", function()
            -- Older share → local data stands.
            WGS:_RCLC_NoteSharedWishes(212425,
                { { playerName = "Wisher", priority = "Low" } }, 50)
            assert.are.equal("High", WGS:_RCLC_WishForPlayer(212425, "Wisher-TestRealm").priority)
            -- Newer share → overlay wins.
            WGS:_RCLC_NoteSharedWishes(212425,
                { { playerName = "Wisher", priority = "Low" } }, 200)
            assert.are.equal("Low", WGS:_RCLC_WishForPlayer(212425, "Wisher-TestRealm").priority)
            -- Stale share after a fresh one is ignored.
            WGS:_RCLC_NoteSharedWishes(212425,
                { { playerName = "Wisher", priority = "Medium" } }, 150)
            assert.are.equal("Low", WGS:_RCLC_WishForPlayer(212425, "Wisher").priority)
        end)
    end)

    ------------------------------------------------------------------
    -- Import stamp + interop status
    ------------------------------------------------------------------

    it("importWishlists stamps db.global.wishlistImportedAt", function()
        WGS.db.global.wishlistImportedAt = 0
        WGS:ProcessImport({ wishlists = {
            { playerName = "Wisher", items = { { itemID = 1, priority = "BiS" } } },
        } })
        assert.are.equal(1754078130, WGS.db.global.wishlistImportedAt)
    end)

    it("surfaces RCLC state in the interop snapshot", function()
        WGS.db.global.loot = {
            { itemID = 1, player = "X", timestamp = 1000, source = "rclc" },
            { itemID = 2, player = "Y", timestamp = 2000, source = "mrt" },
            { itemID = 3, player = "Z", timestamp = 3000, source = "rclc" },
        }
        local s = WGS:InteropStatus()
        assert.is_true(s.rclcLoaded)
        assert.is_true(s.rclcCaptureOn)
        assert.are.equal(2,    s.rclcLootCount)
        assert.are.equal(3000, s.rclcLootLast)

        installFakeRCLC(nil)
        assert.is_false(WGS:InteropStatus().rclcLoaded)
    end)
end)
