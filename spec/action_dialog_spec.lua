local helpers = require("spec.helpers")

-- The end-of-raid "Export Now" reminder and the raid-start "Start
-- tracking?" prompt must share ONE panel style. Both route through the
-- reusable WGS:ShowActionDialog builder (UI/UIHelpers.lua); these specs
-- lock that wiring so a future edit can't quietly fork one popup back
-- into a bespoke frame or a plain StaticPopup.
--
-- We load the real locale + the two thin UI hand-off files (which only
-- define functions at file scope — no CreateFrame until shown) and stub
-- ShowActionDialog as a recorder, so we assert on the contract without a
-- full frame mock.
describe("shared action dialog wiring", function()
    local WGS
    local calls

    before_each(function()
        WGS = helpers.setup()
        dofile("Locales/enUS.lua")           -- real strings so body text is meaningful
        dofile("UI/AttendanceFrame.lua")
        dofile("UI/RaidTrackingPrompt.lua")

        calls = {}
        WGS.ShowActionDialog = function(_, opts) table.insert(calls, opts) end
    end)

    it("export reminder routes through the shared dialog", function()
        WGS.db.global.loot = { { item = "Thunderfury" } }   -- something to export
        WGS:ShowExportReminder()

        assert.are.equal(1, #calls)
        assert.are.equal("export", calls[1].key)
        assert.are.equal("Export Now", calls[1].acceptText)
        assert.are.equal("Later", calls[1].declineText)
        assert.is_truthy(calls[1].title:find("Raid Over"))
        assert.is_function(calls[1].onAccept)
    end)

    it("export reminder stays silent when there's nothing to export", function()
        -- helpers seeds every export table empty → no popup.
        WGS:ShowExportReminder()
        assert.are.equal(0, #calls)
    end)

    it("raid-tracking prompt routes through the same shared dialog", function()
        WGS:ShowRaidTrackingPrompt({ title = "Tuesday Pulls" })

        assert.are.equal(1, #calls)
        assert.are.equal("raidtrack", calls[1].key)
        assert.are.equal("Start Tracking", calls[1].acceptText)
        assert.are.equal("Not Now", calls[1].declineText)
        assert.is_truthy(calls[1].body:find("Tuesday Pulls"),
            "the scheduled event's title must appear in the prompt body")
        assert.is_function(calls[1].onAccept)
    end)

    it("raid-tracking prompt falls back to a generic title with no event name", function()
        WGS:ShowRaidTrackingPrompt({})
        assert.are.equal(1, #calls)
        assert.is_truthy(calls[1].body:find("your scheduled raid"))
    end)
end)
