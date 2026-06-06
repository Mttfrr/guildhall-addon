---@type GuildHall
local WGS = GuildHall

-- Private UI namespace shared across UI/MainFrame.lua and the per-tab
-- builders in UI/Tabs/*. Anything that more than one tab needs lives
-- here. Keep it small — public API on WGS:* should stay public.
WGS._ui = WGS._ui or {}
local ui = WGS._ui

---------------------------------------------------------------------------
-- Tab + sub-view constants
---------------------------------------------------------------------------

-- Tab order is officer-flow-first: Events (today's raid) → Teams
-- (rosters / readiness) → Logs (capture-log surfaces: loot · bank ·
-- attendance) → Sync (paste in/out). Dashboard tab was removed (its
-- summary tiles weren't pulling their weight). Bank and Raids were
-- collapsed into Logs as sub-views since both are capture-log data of
-- the same shape and didn't pull their weight as top-level tabs.
ui.TAB_EVENTS = 1
ui.TAB_TEAMS  = 2
ui.TAB_LOGS   = 3
ui.TAB_SYNC   = 4
ui.TAB_COUNT  = 4
ui.TAB_NAMES  = { "Events", "Teams", "Logs", "Sync" }

ui.TEAMS_SUB_TEAMS     = 1
ui.TEAMS_SUB_CHECK     = 2
ui.TEAMS_SUB_WISHLISTS = 3
ui.TEAMS_SUB_COUNT     = 3
ui.TEAMS_SUB_NAMES     = { "Teams", "Roster Check", "Wishlists" }

ui.LOGS_SUB_LOOT       = 1
ui.LOGS_SUB_BANK       = 2
ui.LOGS_SUB_ATTENDANCE = 3
ui.LOGS_SUB_COUNT      = 3
ui.LOGS_SUB_NAMES      = { "Loot", "Bank", "Attendance" }

---------------------------------------------------------------------------
-- Shared frame helpers
---------------------------------------------------------------------------

-- Hide every child + region of a container so the next populate-pass
-- starts with a blank slate. Used by Roster/Loot/etc. before
-- repopulating after a refresh.
function ui.ClearContainer(container)
    for _, child in ipairs({ container:GetChildren() }) do child:Hide() end
    for _, region in ipairs({ container:GetRegions() }) do region:Hide() end
end

-- Create a scrolling region pinned to the parent's edges (leaving
-- room for the scrollbar). Returns (scrollFrame, content) — the
-- caller attaches widgets to `content`.
function ui.CreateScrollContent(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    return sf, content
end

-- Sub-nav visual states. The active tab gets a gold underline + bright
-- label; inactives are dimmed; hover splits the difference. Kept here
-- so the colors are tweakable in one place and read alongside the
-- tab construction.
local TAB_COLOR_ACTIVE   = { 1.00, 0.82, 0.00, 1.00 }  -- gold
local TAB_COLOR_INACTIVE = { 0.65, 0.65, 0.65, 1.00 }  -- dim grey
local TAB_COLOR_HOVER    = { 1.00, 1.00, 1.00, 1.00 }  -- white

local function paintTab(btn, active)
    if not btn or not btn.label then return end
    local c = active and TAB_COLOR_ACTIVE or TAB_COLOR_INACTIVE
    btn.label:SetTextColor(c[1], c[2], c[3], c[4])
    if btn.underline then
        if active then btn.underline:Show() else btn.underline:Hide() end
    end
end

-- Generic sub-view selector. Hides all sub-views, shows the selected
-- one, and updates the sub-nav highlight to indicate selection.
function ui.SelectSubView(tab, index, count)
    for i = 1, count do
        tab.subViews[i]:Hide()
        paintTab(tab.subButtons[i], false)
    end
    tab.subViews[index]:Show()
    paintTab(tab.subButtons[index], true)
    tab.selectedSub = index
end

-- Build a sub-navigation row across the top of a tab plus N sub-view
-- frames. onSelect(tab, index) is called when a sub-button is clicked.
--
-- Visual style: text-only tabs with a gold underline indicator on the
-- active one. UIPanelButtonTemplate (the chunky red Blizzard buttons)
-- is reserved for CTAs — Invite, Announce, Export, etc. — so the
-- distinction between "switch views" and "do an action" reads
-- cleanly at a glance.
function ui.BuildSubNav(parent, names, onSelect)
    parent.subButtons = {}
    parent.subViews = {}
    parent.selectedSub = 1
    local count = #names
    local btnW = math.floor(660 / count) - 4
    local btnX = 0
    local btnH = 24

    for i = 1, count do
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(btnW, btnH)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", btnX, 0)

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER", btn, "CENTER", 0, 1)
        label:SetText(names[i])
        btn.label = label

        local underline = btn:CreateTexture(nil, "ARTWORK")
        underline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 6, 0)
        underline:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -6, 0)
        underline:SetHeight(2)
        underline:SetColorTexture(TAB_COLOR_ACTIVE[1], TAB_COLOR_ACTIVE[2], TAB_COLOR_ACTIVE[3], 1)
        underline:Hide()
        btn.underline = underline

        btn:SetScript("OnEnter", function(self)
            -- Hover lift only on non-active tabs; the active one stays gold.
            if parent.selectedSub ~= i then
                self.label:SetTextColor(TAB_COLOR_HOVER[1], TAB_COLOR_HOVER[2], TAB_COLOR_HOVER[3], 1)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            paintTab(self, parent.selectedSub == i)
        end)
        btn:SetScript("OnClick", function() onSelect(parent, i) end)

        paintTab(btn, false)  -- start inactive; SelectSubView paints the chosen one
        parent.subButtons[i] = btn
        btnX = btnX + btnW + 4
    end

    -- Thin separator line under the whole nav row.
    local sep = parent:CreateTexture(nil, "ARTWORK")
    sep:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -btnH)
    sep:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -btnH)
    sep:SetHeight(1)
    sep:SetColorTexture(0.3, 0.3, 0.3, 0.6)

    for i = 1, count do
        local sv = CreateFrame("Frame", nil, parent)
        sv:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(btnH + 4))
        sv:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
        sv:Hide()
        parent.subViews[i] = sv
    end
end

---------------------------------------------------------------------------
-- Per-tab builder registry
--
-- Each tab file (UI/Tabs/*.lua) registers itself via
--   ui.tabs[ui.TAB_X] = { build = fn(parent), refresh = fn(tab) }
-- MainFrame.lua walks this table in CreateMainFrame / RefreshCurrentTab
-- so adding a tab is a one-file change (define + register) instead of
-- editing a giant switch.
---------------------------------------------------------------------------

ui.tabs = ui.tabs or {}

---------------------------------------------------------------------------
-- Shared row chrome — class icon + numeric cell
--
-- Both the Teams sub-view (UI/Tabs/Teams.lua) and the Events detail
-- panel's Roster section (UI/EventsFrame.lua) render rows of
-- "[class icon] Name … iLvl … Enchants … Gems …". Keeping the helpers
-- here means the two surfaces can't drift on icon path, severity
-- thresholds, or em-dash for missing data.
---------------------------------------------------------------------------

local CLASS_ICON_PATH = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"

-- WoW ships a 64×64 sprite sheet of all class icons indexed via the
-- CLASS_ICON_TCOORDS global. Falls back to a class-coloured square if
-- the class is unknown (defensive — adding a new class mid-expansion
-- would otherwise show a broken texture).
function ui.ApplyClassIcon(texture, classFile, color)
    classFile = (classFile or ""):upper()
    local tc = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
    if tc then
        texture:SetTexture(CLASS_ICON_PATH)
        texture:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
        texture:SetVertexColor(1, 1, 1, 1)
    elseif color then
        -- Class color extracted from "AABBGGRR" hex; class-coloured tile.
        local r = tonumber(color:sub(3, 4), 16) / 255
        local g = tonumber(color:sub(5, 6), 16) / 255
        local b = tonumber(color:sub(7, 8), 16) / 255
        texture:SetColorTexture(r, g, b, 1)
    else
        texture:SetColorTexture(0.4, 0.4, 0.4, 1)
    end
end

-- Right-aligned numeric cell with severity colouring.
--   isProblemWhenAbove0 = true   → 0 green · 1-3 orange · 4+ red
--   isProblemWhenAbove0 = false  → ilvl-style: at/above target green,
--                                  below target orange, missing em-dash
-- Returns the frame so the caller can anchor a tooltip / hit area.
function ui.BuildNumericCell(parent, x, yOff, width, height, value, isProblemWhenAbove0)
    local cell = CreateFrame("Frame", nil, parent)
    cell:SetSize(width, height)
    cell:SetPoint("TOPLEFT", parent, "TOPLEFT", x, yOff)

    local text = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("RIGHT", cell, "RIGHT", -8, 0)

    if isProblemWhenAbove0 then
        local n = value or 0
        local color
        if n == 0       then color = "ff00ff00"
        elseif n >= 4   then color = "ffff4444"
        else                 color = "ffff8800" end
        text:SetText("|c" .. color .. n .. "|r")
    else
        local target = WGS.db and WGS.db.global and WGS.db.global.targetIlvl or 0
        if not value or value == 0 then
            text:SetText("|cff666666\226\128\148|r")  -- em dash
        elseif target > 0 and value < target then
            text:SetText("|cffff8800" .. value .. "|r")
        else
            text:SetText("|cff00ff00" .. value .. "|r")
        end
    end
    cell.text = text
    return cell
end

---------------------------------------------------------------------------
-- Player context menu
--
-- Shared right-click handler used everywhere a player name appears
-- (Logs → Loot rows, Logs → Attendance member grid, Events Roster
-- section, Events Raid Comp slots, Teams Roster, Teams Wishlists).
-- One implementation, one menu shape — clicking right on any player
-- name surfaces the same actions, in the same order, with the same
-- styling.
--
-- Actions:
--   - Whisper   → opens the chat target ChatFrame_SendTell
--   - Invite    → InviteUnit; greys out if we can't invite right now
--   - Copy name → static popup with EditBox prefilled + auto-selected
--                 (Ctrl+C in one keystroke; matches the "copy event
--                 link" pattern shipped for the kebab popover)
--   - Copy profile link → builds https://<PLATFORM_URL>/character/<id>
--                 from db.global.characterIds[name]. Hides entirely
--                 when the lookup misses (older imports, characters
--                 not yet synced from the platform) so the user
--                 doesn't see a broken item.
---------------------------------------------------------------------------

-- Hardcoded platform base URL. Single platform, no per-guild override.
-- Bake into constants so changing it is one-line; if the platform ever
-- moves we can plumb it through the addon-sync export instead.
local PLATFORM_URL = "https://guildhall.run"

-- Strip "Foo-Realm" → "Foo" since Blizzard's chat / invite APIs take
-- either form but the short form is what users see in addon UI.
local function ShortName(name)
    if not name or name == "" then return name end
    return name:match("^([^%-]+)") or name
end

-- Resolve a StaticPopup dialog's EditBox child. Tries the modern
-- direct field first, then the legacy global-name pattern. Both have
-- been observed across retail patches; on some clients .editBox is
-- nil while _G[parent:GetName() .. "EditBox"] resolves, and vice
-- versa. Returns nil only when neither path works.
local function GetPopupEditBox(popup)
    if not popup then return nil end
    if popup.editBox then return popup.editBox end
    if popup.GetName then
        local n = popup:GetName()
        if n then
            local eb = _G[n .. "EditBox"]
            if eb then return eb end
        end
    end
    return nil
end

-- StaticPopup for the copy-to-clipboard flow. Registered once at file
-- scope (addon is single-instance per character; re-register is a
-- no-op). Belt-and-braces population: OnShow sets the text from data,
-- ShowCopyPopup also sets it post-return, AND a C_Timer.After(0)
-- retry catches the case where Blizzard's setup re-clears the editBox
-- after OnShow on some retail builds. At least one of the three paths
-- has to stick.
StaticPopupDialogs["GUILDHALL_COPY_STRING"] = {
    text         = "%s",  -- replaced by the format arg below
    button1      = "Close",
    hasEditBox   = 1,     -- Blizzard convention; truthy is what gets checked
    editBoxWidth = 350,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    EnterClicksFirstButton = true,
    OnShow = function(self, data)
        if not data or not data.value then return end
        local eb = GetPopupEditBox(self)
        if eb then
            eb:SetText(data.value)
            eb:HighlightText()
            eb:SetFocus()
        end
    end,
    EditBoxOnEnterPressed  = function(self) self:GetParent():Hide() end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

local function ShowCopyPopup(prompt, value)
    local popup = StaticPopup_Show("GUILDHALL_COPY_STRING", prompt, nil, { value = value })
    if not popup then return end

    -- Path 2: post-return SetText. Runs after OnShow synchronously
    -- completes, so it stomps any cleanup that happened during setup.
    local eb = GetPopupEditBox(popup)
    if eb then
        eb:SetText(value or "")
        eb:HighlightText()
        eb:SetFocus()
    end

    -- Path 3: next-frame retry. Some retail builds defer editBox
    -- configuration past the current synchronous frame, so even the
    -- post-return SetText above can be wiped. C_Timer.After(0, ...)
    -- queues to the very next frame tick, which is after all that.
    if C_Timer and C_Timer.After and value then
        C_Timer.After(0, function()
            if popup.IsShown and popup:IsShown() then
                local eb2 = GetPopupEditBox(popup)
                if eb2 then
                    eb2:SetText(value)
                    eb2:HighlightText()
                    eb2:SetFocus()
                end
            end
        end)
    end
end

---------------------------------------------------------------------------
-- Context-menu compatibility helper
---------------------------------------------------------------------------
--
-- Convert EasyMenu-style menu tables into MenuUtil.CreateContextMenu
-- calls. EasyMenu was removed from retail in the 11.0 interface (TOC
-- 110000+); the addon's right-click affordances (loot row menu,
-- session event picker, player context menu, minimap menu, event row
-- kebab) all targeted EasyMenu and now fail with "attempt to call a
-- nil value" on current retail.
--
-- The conversion preserves the existing menu-table format so each
-- callsite only changes its dispatch line, not the menu construction:
--   text         (string)
--   isTitle      → :CreateTitle (or :CreateDivider when text is empty —
--                  the EasyMenu code used { isTitle = true, text = "" }
--                  as a separator)
--   disabled     → button with :SetEnabled(false)
--   menuList     → nested submenu, walked recursively
--   func         → click handler (called by MenuUtil on activation)
--   notCheckable → ignored (EasyMenu required it; MenuUtil doesn't
--                  render checkboxes by default so this field becomes
--                  a no-op marker)
-- Wrap a click callback so the menu always receives an explicit
-- MenuResponse. Live retail MenuUtil (observed on the Events Roster
-- right-click in 0.7.3-beta) silently drops the click when the
-- responder returns nil — the documented default is CloseAll but in
-- practice the action callback never fires unless we say so. The
-- wrapper also pcalls the user's func so a runtime error inside
-- (e.g. InviteUnit throwing) doesn't leave the menu wedged open.
local function wrapMenuCallback(fn)
    if type(fn) ~= "function" then return nil end
    return function()
        pcall(fn)
        if _G.MenuResponse and _G.MenuResponse.CloseAll then
            return _G.MenuResponse.CloseAll
        end
    end
end

local function buildContextItem(parent, item)
    if not item then return end
    if item.isTitle then
        if item.text and item.text ~= "" then
            parent:CreateTitle(item.text)
        else
            parent:CreateDivider()
        end
        return
    end
    if type(item.menuList) == "table" then
        local sub = parent:CreateButton(item.text or "")
        for _, child in ipairs(item.menuList) do
            buildContextItem(sub, child)
        end
        return
    end
    local btn = parent:CreateButton(item.text or "", wrapMenuCallback(item.func))
    if item.disabled and btn and btn.SetEnabled then
        btn:SetEnabled(false)
    end
end

function ui.OpenContextMenu(menu)
    if type(MenuUtil) ~= "table" or type(MenuUtil.CreateContextMenu) ~= "function" then
        return   -- pre-11.0 client without MenuUtil; defensive only
    end
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        for _, item in ipairs(menu) do buildContextItem(root, item) end
    end)
end
-- Exposed so the kebab popover (and any future copy-to-clipboard surface)
-- can reuse the same EditBox-preselected popup without re-declaring the
-- StaticPopupDialogs entry.
ui.ShowCopyPopup = ShowCopyPopup

-- Platform base URL, also exposed so event/character link surfaces
-- elsewhere can build URLs without re-hardcoding the host.
ui.PLATFORM_URL = PLATFORM_URL

-- Build the standard player-action items (Whisper / Invite / Inspect /
-- Copy name / Copy profile link) as an array. No title or separators —
-- callers compose their own menu structure around this. Same items
-- everywhere a player name shows up, with the same ordering and
-- conditional profile-link visibility.
function ui.BuildPlayerMenuItems(name, class)
    if type(name) ~= "string" or name == "" then return {} end
    local short = ShortName(name)
    local _ = class   -- reserved for future class-themed items

    local items = {
        {
            text = "Whisper",
            notCheckable = true,
            func = function()
                if ChatFrame_SendTell then
                    ChatFrame_SendTell(short,
                        ChatEdit_ChooseBoxForSend and ChatEdit_ChooseBoxForSend() or nil)
                end
            end,
        },
        {
            text = "Invite",
            notCheckable = true,
            func = function() if InviteUnit then InviteUnit(short) end end,
        },
        {
            text = "Copy name",
            notCheckable = true,
            func = function() ShowCopyPopup("Character name:", short) end,
        },
    }

    -- Profile link conditionally appears when the platform-supplied
    -- characterIds map knows this character's memberId. Older imports
    -- miss the lookup and the item silently hides.
    local memberIdMap = WGS.db and WGS.db.global and WGS.db.global.characterIds
    local memberId = memberIdMap and memberIdMap[short]
    if memberId then
        items[#items + 1] = {
            text = "Copy profile link",
            notCheckable = true,
            func = function()
                ShowCopyPopup("Profile link:",
                    PLATFORM_URL .. "/character/" .. tostring(memberId))
            end,
        }
    end
    return items
end

function ui.OpenPlayerContextMenu(name, class)
    if type(name) ~= "string" or name == "" then return end
    local menu = { { text = ShortName(name), isTitle = true, notCheckable = true } }
    for _, item in ipairs(ui.BuildPlayerMenuItems(name, class)) do
        menu[#menu + 1] = item
    end
    ui.OpenContextMenu(menu)
end

-- Helper to attach right-click → OpenPlayerContextMenu on an existing
-- frame (typically the FontString's parent row). Caller is responsible
-- for: (a) making the target a Button so it can RegisterForClicks,
-- (b) adding any hover highlight texture to match local UX, (c) not
-- swallowing left-click behaviour that the row already provides.
function ui.AttachPlayerContextMenu(button, getName, getClass)
    if not button then return end
    if button.RegisterForClicks then
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end
    local prevOnClick = button:GetScript("OnClick")
    button:SetScript("OnClick", function(self, mouseBtn, ...)
        if mouseBtn == "RightButton" then
            local n = type(getName) == "function" and getName() or getName
            local c = type(getClass) == "function" and getClass() or getClass
            ui.OpenPlayerContextMenu(n, c)
            return
        end
        if prevOnClick then prevOnClick(self, mouseBtn, ...) end
    end)
end
