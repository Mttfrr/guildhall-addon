local helpers = require("spec.helpers")

-- ui.BuildPlayerMenuItems + ui.OpenPlayerContextMenu in UI/UIHelpers.lua
-- are the shared right-click surface for every player name in the
-- addon (Logs → Loot rows, Logs → Attendance member grid, Events
-- Roster, Teams Roster). Coverage gap: nothing was locking down what
-- the menu produces, so a regression in the items list (missing
-- callback, wrong order, item that doesn't fire) would only surface
-- as a user report mid-raid.

local function setup()
    local WGS = helpers.setup()
    helpers.loadUIShims()
    _G._capturedMenus = {}
    return WGS
end

describe("ui.BuildPlayerMenuItems", function()
    local WGS, ui
    before_each(function()
        WGS = setup()
        ui = WGS._ui
    end)

    it("returns the canonical 3 items when no characterIds lookup hits", function()
        WGS.db.global.characterIds = nil
        local items = ui.BuildPlayerMenuItems("Foo-Realm", "WARRIOR")
        assert.are.equal(3, #items)
        assert.are.equal("Whisper",   items[1].text)
        assert.are.equal("Invite",    items[2].text)
        assert.are.equal("Copy name", items[3].text)
    end)

    it("appends 'Copy profile link' when characterIds[short] resolves", function()
        WGS.db.global.characterIds = { Foo = 12345 }
        local items = ui.BuildPlayerMenuItems("Foo-Realm", "WARRIOR")
        assert.are.equal(4, #items)
        assert.are.equal("Copy profile link", items[4].text)
    end)

    it("each item exposes a callable func", function()
        WGS.db.global.characterIds = { Foo = 42 }
        local items = ui.BuildPlayerMenuItems("Foo-Realm", "WARRIOR")
        for _, item in ipairs(items) do
            assert.is_function(item.func, item.text .. " must carry a func callback")
        end
    end)

    it("Invite calls InviteUnit with the short name", function()
        local invitedWith
        _G.InviteUnit = function(name) invitedWith = name end
        local items = ui.BuildPlayerMenuItems("Foo-Realm", "WARRIOR")
        items[2].func()   -- Invite
        assert.are.equal("Foo", invitedWith,
            "Invite should pass the short name (Blizzard's API takes either form but UI uses short)")
        _G.InviteUnit = nil
    end)

    it("Whisper calls ChatFrame_SendTell with the short name", function()
        local sentTo
        _G.ChatFrame_SendTell = function(name) sentTo = name end
        local items = ui.BuildPlayerMenuItems("Foo-Realm", "WARRIOR")
        items[1].func()   -- Whisper
        assert.are.equal("Foo", sentTo)
        _G.ChatFrame_SendTell = nil
    end)

    -- Copy name and Copy profile link both call ShowCopyPopup. The
    -- text is set via C_Timer.After(0, …) — synchronous SetText (from
    -- OnShow or post-return) gets clobbered by Blizzard's deferred
    -- editBox config on retail 11.0+. These specs mock C_Timer.After
    -- to fire the callback immediately so the deferred SetText is
    -- observable synchronously.
    local function mockPopup()
        local capturedText
        local fakeEditBox = {
            SetText       = function(_, t) capturedText = t end,
            HighlightText = function() end,
            SetFocus      = function() end,
        }
        local popup = { editBox = fakeEditBox, IsShown = function() return true end }
        _G.StaticPopup_Show = function() return popup end
        _G.C_Timer = { After = function(_, fn) fn() end }
        return function() return capturedText end
    end

    it("Copy name sets the short name on the popup's editBox", function()
        local capturedText = mockPopup()
        local items = ui.BuildPlayerMenuItems("Foo-Realm", "WARRIOR")
        items[3].func()   -- Copy name
        assert.are.equal("Foo", capturedText())
        _G.StaticPopup_Show = function() return nil end
        _G.C_Timer = nil
    end)

    it("Copy profile link sets the platform URL on the popup's editBox", function()
        WGS.db.global.characterIds = { Foo = 999 }
        local capturedText = mockPopup()
        local items = ui.BuildPlayerMenuItems("Foo-Realm", "WARRIOR")
        items[4].func()   -- Copy profile link
        assert.are.equal("https://guildhall.run/character/999", capturedText())
        _G.StaticPopup_Show = function() return nil end
        _G.C_Timer = nil
    end)

    it("Copy popup no-ops gracefully when StaticPopup_Show returns nil (defensive)", function()
        _G.StaticPopup_Show = function() return nil end
        _G.C_Timer = { After = function(_, fn) fn() end }
        local items = ui.BuildPlayerMenuItems("Foo-Realm", "WARRIOR")
        assert.has_no.errors(function() items[3].func() end)
        _G.C_Timer = nil
    end)

    it("returns empty list when name is nil or empty", function()
        assert.are.same({}, ui.BuildPlayerMenuItems(nil, "WARRIOR"))
        assert.are.same({}, ui.BuildPlayerMenuItems("",  "WARRIOR"))
    end)
end)

describe("ui.OpenPlayerContextMenu", function()
    local WGS, ui
    before_each(function()
        WGS = setup()
        ui = WGS._ui
    end)

    it("builds a menu with the short name as title + every action below", function()
        WGS.db.global.characterIds = nil
        ui.OpenPlayerContextMenu("Foo-Realm", "WARRIOR")
        local root = _G._capturedMenus[1]
        assert.is_not_nil(root, "MenuUtil.CreateContextMenu must have been called")

        -- 1 title + 3 player actions = 4 children at the root.
        assert.are.equal(4, #root._children,
            "menu must render 1 title + 3 action buttons (Whisper/Invite/Copy name)")
        assert.are.equal("title", root._children[1].kind)
        assert.are.equal("Foo",   root._children[1].text)
        for i = 2, 4 do
            assert.are.equal("button", root._children[i].kind,
                "child " .. i .. " must be a button (action item)")
        end
    end)

    it("button callbacks fire when invoked through the captured menu", function()
        local invitedWith
        _G.InviteUnit = function(name) invitedWith = name end
        WGS.db.global.characterIds = nil
        ui.OpenPlayerContextMenu("Foo-Realm", "WARRIOR")
        local root = _G._capturedMenus[1]
        -- root._children[3] is "Invite" (1=title, 2=Whisper, 3=Invite)
        assert.are.equal("Invite", root._children[3].label)
        root._children[3].func()
        assert.are.equal("Foo", invitedWith,
            "the captured button.func must be the one that calls InviteUnit")
        _G.InviteUnit = nil
    end)

    it("no-op when name is nil — must not call MenuUtil with an empty menu", function()
        ui.OpenPlayerContextMenu(nil)
        assert.are.equal(0, #_G._capturedMenus)
    end)
end)
