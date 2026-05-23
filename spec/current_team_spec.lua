local helpers = require("spec.helpers")

-- Global current-team picker. Pure db.profile state + a change event;
-- the title-bar widget in UI/MainFrame.lua subscribes to the event so
-- slash-command sets stay in sync with the chrome. Specs exercise the
-- state + event, not the widget.

describe("current-team picker", function()
    local WGS

    before_each(function()
        WGS = helpers.setup()
    end)

    it("defaults to nil ('All Teams')", function()
        assert.is_nil(WGS:GetCurrentTeamId())
    end)

    it("Set/Get round-trips a valid team id", function()
        WGS.db.global.teams = {
            { id = 11, name = "Mythic Raiders" },
            { id = 22, name = "Heroic Crew"   },
        }
        WGS:SetCurrentTeamId(11)
        assert.are.equal(11, WGS:GetCurrentTeamId())
        WGS:SetCurrentTeamId(22)
        assert.are.equal(22, WGS:GetCurrentTeamId())
    end)

    it("Set nil clears the filter", function()
        WGS.db.global.teams = { { id = 11, name = "Mythic Raiders" } }
        WGS:SetCurrentTeamId(11)
        WGS:SetCurrentTeamId(nil)
        assert.is_nil(WGS:GetCurrentTeamId())
    end)

    it("coerces an orphan team id to nil on Get", function()
        -- Set a team that exists, then nuke the teams list (simulating a
        -- re-import that dropped the team). Get should return nil rather
        -- than the stale id — otherwise every team-scoped filter would
        -- silently hide all rows.
        WGS.db.global.teams = { { id = 11, name = "Mythic Raiders" } }
        WGS:SetCurrentTeamId(11)
        WGS.db.global.teams = {}
        assert.is_nil(WGS:GetCurrentTeamId())
    end)

    it("fires WGS_CURRENT_TEAM_CHANGED when the value changes", function()
        WGS.db.global.teams = {
            { id = 11, name = "Mythic Raiders" },
            { id = 22, name = "Heroic Crew" },
        }
        WGS:SetCurrentTeamId(11)
        local fired = nil
        for _, e in ipairs(WGS._fired) do
            if e.event == "WGS_CURRENT_TEAM_CHANGED" then fired = e end
        end
        assert.is_not_nil(fired, "expected WGS_CURRENT_TEAM_CHANGED to fire")
        assert.is_table(fired.args[1])
        assert.are.equal(11, fired.args[1].teamId)
    end)

    it("does not fire when set to the same value twice", function()
        WGS.db.global.teams = { { id = 11, name = "M" } }
        WGS:SetCurrentTeamId(11)
        local before = 0
        for _, e in ipairs(WGS._fired) do
            if e.event == "WGS_CURRENT_TEAM_CHANGED" then before = before + 1 end
        end
        WGS:SetCurrentTeamId(11)
        local after = 0
        for _, e in ipairs(WGS._fired) do
            if e.event == "WGS_CURRENT_TEAM_CHANGED" then after = after + 1 end
        end
        assert.are.equal(before, after)
    end)
end)
