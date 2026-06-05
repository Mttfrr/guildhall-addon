local helpers = require("spec.helpers")

-- ui.OpenContextMenu in UI/UIHelpers.lua is the compatibility helper
-- that takes the addon's existing EasyMenu-style menu tables and
-- dispatches via MenuUtil.CreateContextMenu (EasyMenu was removed at
-- the 11.0 interface and broke every right-click menu in the addon
-- before this layer landed — see the v0.7.3 fix).
--
-- These specs lock the dispatcher's translation against drift: title /
-- divider / button / submenu / disabled / func-callback all need to
-- land on the right MenuUtil node API. Without this coverage, "menu
-- builds but renders subtly wrong" regressions slip through every
-- time (no user immediately notices that "Re-tag event" lost its
-- submenu, for example).

local function setup()
    local WGS = helpers.setup()
    helpers.loadUIShims()
    -- Each test starts with a clean menu-capture buffer so we can
    -- assert on exactly the menu the current spec produced.
    _G._capturedMenus = {}
    return WGS
end

describe("ui.OpenContextMenu", function()
    local WGS, ui
    before_each(function()
        WGS = setup()
        ui = WGS._ui
    end)

    it("dispatches the menu through MenuUtil.CreateContextMenu", function()
        ui.OpenContextMenu({
            { text = "Hello", func = function() end },
        })
        assert.are.equal(1, #_G._capturedMenus,
            "OpenContextMenu must invoke MenuUtil.CreateContextMenu exactly once")
    end)

    it("renders a top-level item with text + callback as :CreateButton(text, fn)", function()
        local called = false
        ui.OpenContextMenu({
            { text = "Click me", func = function() called = true end },
        })
        local root = _G._capturedMenus[1]
        assert.are.equal(1, #root._children)
        local btn = root._children[1]
        assert.are.equal("button", btn.kind)
        assert.are.equal("Click me", btn.label)
        -- Invoke the recorded callback — the menu doesn't auto-fire,
        -- but the func should be the one we passed.
        btn.func()
        assert.is_true(called)
    end)

    it("converts { isTitle = true, text = 'Foo' } to :CreateTitle('Foo')", function()
        ui.OpenContextMenu({
            { text = "Header", isTitle = true, notCheckable = true },
            { text = "Item",   func = function() end },
        })
        local root = _G._capturedMenus[1]
        assert.are.equal(2, #root._children)
        assert.are.equal("title",  root._children[1].kind)
        assert.are.equal("Header", root._children[1].text)
        assert.are.equal("button", root._children[2].kind)
    end)

    it("converts { isTitle = true, text = '' } to :CreateDivider", function()
        -- EasyMenu-era convention: empty-text title item was used as
        -- a visual separator. ui.OpenContextMenu translates these to
        -- MenuUtil's :CreateDivider so existing menu tables keep
        -- their visual rhythm without per-callsite changes.
        ui.OpenContextMenu({
            { text = "Top", func = function() end },
            { text = "", isTitle = true, notCheckable = true },
            { text = "Bottom", func = function() end },
        })
        local root = _G._capturedMenus[1]
        assert.are.equal(3, #root._children)
        assert.are.equal("divider", root._children[2].kind)
    end)

    it("nests menuList into a submenu (recursive walk)", function()
        ui.OpenContextMenu({
            {
                text = "Re-tag event",
                hasArrow = true,
                menuList = {
                    { text = "Today's raid", func = function() end },
                    { text = "Yesterday's raid", func = function() end },
                    { text = "", isTitle = true, notCheckable = true },
                    { text = "Untag", func = function() end },
                },
            },
            { text = "Delete row", func = function() end },
        })
        local root = _G._capturedMenus[1]
        assert.are.equal(2, #root._children)

        local submenu = root._children[1]
        assert.are.equal("button", submenu.kind)
        assert.are.equal("Re-tag event", submenu.label)
        assert.are.equal(4, #submenu._children,
            "submenu must contain all 4 entries (2 picks + divider + Untag)")
        assert.are.equal("button",  submenu._children[1].kind)
        assert.are.equal("divider", submenu._children[3].kind)
        assert.are.equal("Untag",   submenu._children[4].label)
    end)

    it("disabled items render as buttons with :SetEnabled(false)", function()
        ui.OpenContextMenu({
            { text = "Greyed out", disabled = true, notCheckable = true },
            { text = "Clickable",  func = function() end },
        })
        local root = _G._capturedMenus[1]
        assert.is_false(root._children[1]._enabled, "disabled item must be SetEnabled(false)")
        assert.is_true(root._children[2]._enabled,  "normal item stays enabled")
    end)

    -- Regression for the 0.7.4-beta bug: Events Roster right-click menu
    -- opened on live retail but clicking action items (Invite, Whisper,
    -- Copy profile link) did nothing. Root cause: live MenuUtil's
    -- responder swallows the click unless the callback returns an
    -- explicit MenuResponse. buildContextItem now wraps every action
    -- callback with `pcall(fn); return MenuResponse.CloseAll`.
    it("button callbacks return MenuResponse.CloseAll so live MenuUtil fires them", function()
        _G.MenuResponse = { CloseAll = "CLOSE", Refresh = "REFRESH", Open = "OPEN" }
        ui.OpenContextMenu({
            { text = "Invite", func = function() end },
        })
        local btn = _G._capturedMenus[1]._children[1]
        local result = btn.func()
        assert.are.equal("CLOSE", result,
            "wrapper must return MenuResponse.CloseAll so the menu acts on the click")
        _G.MenuResponse = nil
    end)

    it("wrapped callback invokes the user's func before returning", function()
        _G.MenuResponse = { CloseAll = "CLOSE" }
        local called = false
        ui.OpenContextMenu({
            { text = "Invite", func = function() called = true end },
        })
        _G._capturedMenus[1]._children[1].func()
        assert.is_true(called)
        _G.MenuResponse = nil
    end)

    it("a runtime error inside the user's func is swallowed by pcall, menu still closes", function()
        _G.MenuResponse = { CloseAll = "CLOSE" }
        ui.OpenContextMenu({
            { text = "Boom", func = function() error("kaboom") end },
        })
        local ok, result = pcall(function()
            return _G._capturedMenus[1]._children[1].func()
        end)
        assert.is_true(ok, "pcall inside wrapper must prevent the error from escaping")
        assert.are.equal("CLOSE", result,
            "menu must still close even when the action func errors")
        _G.MenuResponse = nil
    end)

    it("silently no-ops when MenuUtil is unavailable (pre-11.0 fallback)", function()
        local saved = _G.MenuUtil
        _G.MenuUtil = nil
        local ok = pcall(ui.OpenContextMenu, {
            { text = "Item", func = function() end },
        })
        _G.MenuUtil = saved
        assert.is_true(ok, "missing MenuUtil must not throw — defensive nil-check")
    end)
end)
