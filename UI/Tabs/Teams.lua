---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Teams tab (was "Roster"): three sub-views, all per-player data.
--   Teams         — flat listing of imported teams with main/alt rollup
--                   PLUS a gear-issues column sourced from gearAudit
--                   (missing enchants/gems, ilvl-vs-target).
--   Roster Check  — for today's event, compares the team's expected
--                   roster against who's actually in the raid (or last
--                   session), surfacing Present/Missing/Extra plus an
--                   "Announce" + "Invite" action row.
--   Wishlists     — boss-filtered view of which characters wishlisted
--                   which items, sorted by wisher count. Moved here
--                   from the old standalone Loot tab — wishlists are
--                   per-player data, fits with the roster.

local TAB_INDEX            = ui.TAB_TEAMS
local TEAMS_SUB_TEAMS      = ui.TEAMS_SUB_TEAMS
local TEAMS_SUB_CHECK      = ui.TEAMS_SUB_CHECK
local TEAMS_SUB_WISHLISTS  = ui.TEAMS_SUB_WISHLISTS
local TEAMS_SUB_COUNT      = ui.TEAMS_SUB_COUNT
local TEAMS_SUB_NAMES      = ui.TEAMS_SUB_NAMES
local ClearContainer       = ui.ClearContainer
local CreateScrollContent  = ui.CreateScrollContent
local SelectSubView        = ui.SelectSubView
local BuildSubNav          = ui.BuildSubNav

-- Forward declarations: BuildRosterCheckSubView + PopulateRosterCheck
-- are referenced by BuildTeamsTab's sub-nav callback before they're
-- defined further down. Without the local-first declaration, those
-- closures would capture nil globals.
local BuildRosterCheckSubView
local PopulateRosterCheck
local BuildWishlistsSubView
local PopulateWishlists

---------------------------------------------------------------------------
-- Class icon helper
--
-- WoW ships a 64×64 sprite sheet of all class icons at
-- Interface\Glues\CharacterCreate\UI-CharacterCreate-Classes, indexed
-- via the CLASS_ICON_TCOORDS global. Falls back to a class-coloured
-- square if the class is unknown (defensive — adding a new class
-- mid-expansion would otherwise show a broken texture).
---------------------------------------------------------------------------

local CLASS_ICON_PATH = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"

local function ApplyClassIcon(texture, classFile, color)
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

---------------------------------------------------------------------------
-- Character / gear-info helpers
---------------------------------------------------------------------------

-- Resolves the canonical class for a character, falling back through:
--   characterDetails (most authoritative — server-supplied)
--   GetGuildRosterInfo lookup
--   nil (caller renders without a class color)
--
-- Always returns the file-constant form ("DEATHKNIGHT", "DEMONHUNTER")
-- so downstream CLASS_COLORS / CLASS_ICON_TCOORDS lookups work
-- regardless of source: characterDetails carries localized display
-- names like "Death Knight"; roster carries the file constant already.
local function ResolveClass(charName, roster)
    local details = WGS.db.global.characterDetails
    local key = charName:match("^([^%-]+)") or charName
    local d = details and details[key]
    if d and d.class and d.class ~= "" then return WGS:NormalizeClassFile(d.class) end
    local gi = roster[key]
    if gi and gi.class then return WGS:NormalizeClassFile(gi.class) end
    return nil
end

-- Returns the imported per-character details (or nil if unknown).
local function GetCharacterDetails(charName)
    local details = WGS.db.global.characterDetails
    if not details then return nil end
    local key = charName:match("^([^%-]+)") or charName
    return details[key]
end

-- Build a (segmented, colour-coded) detail line for the main row.
-- Multi-line tooltip body for an alt: class/spec + ilvl + missing counts.
-- Each line is "|cAARRGGBBtext|r" ready to feed into GameTooltip:AddLine.
local function BuildAltTooltipLines(charName, roster)
    local info = GetCharacterDetails(charName)
    -- ResolveClass already returns the file-constant form.
    local class = ResolveClass(charName, roster) or ""
    local colorHex = WGS.CLASS_COLORS[class] or "ffffffff"
    local short = charName:match("^([^%-]+)") or charName

    local lines = {}
    -- Header: "AltName (Class, Spec)"
    local header = "|c" .. colorHex .. short .. "|r"
    if info and (info.spec ~= "" or info.class ~= "") then
        local subtitle
        if info.spec and info.spec ~= "" then
            subtitle = info.spec .. " " .. (info.class or "")
        else
            subtitle = info.class or ""
        end
        header = header .. "  |cff888888(" .. subtitle:match("^(.-)%s*$") .. ")|r"
    end
    lines[#lines + 1] = header

    -- Online status
    local gi = roster[short]
    if gi then
        lines[#lines + 1] = gi.online
            and "|cff00ff00online|r"
            or  "|cff555555offline|r"
    else
        lines[#lines + 1] = "|cff666666not in guild roster|r"
    end

    -- Gear info — only emit lines that have actual data
    if info then
        if info.ilvl and info.ilvl > 0 then
            lines[#lines + 1] = "|cffffd100Item level:|r " .. info.ilvl
        end
        local me, mg = info.missingEnchants or 0, info.missingGems or 0
        if me > 0 then
            lines[#lines + 1] = "|cffff8800Missing enchants:|r " .. me
        else
            lines[#lines + 1] = "|cff00ff00Enchants:|r all good"
        end
        if mg > 0 then
            lines[#lines + 1] = "|cffff8800Missing gems:|r " .. mg
        else
            lines[#lines + 1] = "|cff00ff00Gems:|r all socketed"
        end
    else
        lines[#lines + 1] = "|cff666666(no gear data — sync from web)|r"
    end

    return lines
end

---------------------------------------------------------------------------
-- Teams sub-view
---------------------------------------------------------------------------

local function BuildTeamsSubView(sv)
    local sf, content = CreateScrollContent(sv)
    sf:ClearAllPoints()
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    sv.scrollFrame = sf
    sv.content = content
end

---------------------------------------------------------------------------
-- Table layout
--
-- One row per team member (mains only). Columns:
--   Character  iLvl  Enchants  Gems  Alts
-- Click a column header to sort by it. Hover the Alts cell to see the
-- alt list with per-alt gear breakdown in a tooltip.
--
-- Numeric cells render as plain numbers (e.g. "0", "2") coloured by
-- severity rather than ✓ / ✗ glyphs — the in-game default font misses
-- a lot of Unicode and we'd rather use what's guaranteed to render.
---------------------------------------------------------------------------

local CONTENT_W   = 660
local HEADER_H    = 22
local ROW_H       = 20
local TEAM_GAP    = 12

-- Column geometry. Each cell anchors LEFT at COL_X[k]; numeric cells
-- right-align their text against COL_X[k+1] - 8 so the digits line up.
local COL = {
    NAME = { x = 10,  w = 240, label = "Character" },
    ILVL = { x = 250, w = 70,  label = "iLvl"      },
    ENCH = { x = 320, w = 100, label = "Enchants"  },
    GEMS = { x = 420, w = 100, label = "Gems"      },
    ALTS = { x = 520, w = 120, label = "Alts"      },
}

-- Default sort = name asc. Stored per-tab on `tab._sortKey` / `_sortDir`.
local DEFAULT_SORT_KEY = "name"
local DEFAULT_SORT_DIR = "asc"

local SORT_ARROW_TEX = "Interface\\Buttons\\UI-SortArrow"

-- One sortable column header. clickFn(key) is called when the button
-- is clicked. The arrow indicator is added/oriented externally based
-- on the tab's current sort state.
local function BuildHeaderCell(parent, col, key, x, sortKey, sortDir, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(col.w, HEADER_H)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, 0)

    -- Highlight on hover so the column reads as clickable.
    btn:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    local hl = btn:GetHighlightTexture()
    if hl then hl:SetAlpha(0.3) end

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", btn, "LEFT", 6, 0)
    label:SetText(col.label)
    if sortKey == key then
        label:SetTextColor(1.00, 0.82, 0.00)  -- gold when active
    else
        label:SetTextColor(0.85, 0.85, 0.85)
    end

    if sortKey == key then
        local arrow = btn:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(10, 10)
        arrow:SetPoint("LEFT", label, "RIGHT", 4, 0)
        arrow:SetTexture(SORT_ARROW_TEX)
        if sortDir == "asc" then
            -- Default texcoords point down (desc). Flip for asc.
            arrow:SetTexCoord(0, 1, 1, 0)
        end
    end

    btn:SetScript("OnClick", function() onClick(key) end)
    return btn
end

-- Numeric cell: right-aligned text with severity colour.
--   0 → green, 1-3 → orange, 4+ → red. Below-target ilvl follows the
--   same scale (0 issues; ilvl < target counts as 1).
local function BuildNumericCell(parent, col, x, value, isProblemWhenAbove0, yOff)
    local cell = CreateFrame("Frame", nil, parent)
    cell:SetSize(col.w, ROW_H)
    cell:SetPoint("TOPLEFT", parent, "TOPLEFT", x, yOff)

    local text = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("RIGHT", cell, "RIGHT", -10, 0)

    if isProblemWhenAbove0 then
        local n = value or 0
        local color
        if n == 0       then color = "ff00ff00"
        elseif n >= 4   then color = "ffff4444"
        else                 color = "ffff8800" end
        text:SetText("|c" .. color .. n .. "|r")
    else
        -- ilvl-style: green at-target, orange below-target.
        local target = WGS.db.global.targetIlvl or 0
        if not value or value == 0 then
            text:SetText("|cff666666\226\128\148|r")  -- em dash
        elseif target > 0 and value < target then
            text:SetText("|cffff8800" .. value .. "|r")
        else
            text:SetText("|cff00ff00" .. value .. "|r")
        end
    end
    return cell
end

-- Build one data row.
local function BuildDataRow(parent, member, roster, yOff, evenStripe)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(CONTENT_W, ROW_H)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOff)

    -- Optional zebra-stripe background to make the columns scan easier.
    if evenStripe then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(row)
        bg:SetColorTexture(1, 1, 1, 0.025)
    end

    -- Character cell: online dot + class icon + class-coloured name.
    -- ResolveClass already normalises to the file-constant form so the
    -- two lookups below don't have to.
    local short    = member.short
    local classFile = ResolveClass(member.name, roster) or ""
    local colorHex = WGS.CLASS_COLORS[classFile] or "ffffffff"
    local gi       = roster[short]

    local nameCell = CreateFrame("Frame", nil, row)
    nameCell:SetSize(COL.NAME.w, ROW_H)
    nameCell:SetPoint("TOPLEFT", row, "TOPLEFT", COL.NAME.x, 0)

    local dot = nameCell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dot:SetPoint("LEFT", nameCell, "LEFT", 0, 0)
    if gi then
        dot:SetText(gi.online and "|cff00ff00\194\183|r" or "|cff555555\194\183|r")
    else
        dot:SetText("|cffff4444\194\183|r")
    end

    local icon = nameCell:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", dot, "RIGHT", 4, 0)
    ApplyClassIcon(icon, classFile, colorHex)

    local nameText = nameCell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    nameText:SetText("|c" .. colorHex .. short .. "|r")

    -- Numeric cells
    BuildNumericCell(row, COL.ILVL, COL.ILVL.x, member.ilvl, false, 0)
    BuildNumericCell(row, COL.ENCH, COL.ENCH.x, member.missingEnchants, true, 0)
    BuildNumericCell(row, COL.GEMS, COL.GEMS.x, member.missingGems, true, 0)

    -- Alts cell: count + hover-tooltip with per-alt breakdown.
    -- Created as a Button (not a Frame) because SetHighlightTexture
    -- only exists on Button — Frame has no such method and calling it
    -- crashes the row render. The cell still doesn't behave like a
    -- typical clickable button; we just want the highlight texture
    -- for the hover affordance.
    local altsCell = CreateFrame("Button", nil, row)
    altsCell:SetSize(COL.ALTS.w, ROW_H)
    altsCell:SetPoint("TOPLEFT", row, "TOPLEFT", COL.ALTS.x, 0)

    local altsText = altsCell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    altsText:SetPoint("RIGHT", altsCell, "RIGHT", -10, 0)
    if member.altCount > 0 then
        altsText:SetText("|cffffd100" .. member.altCount .. "|r")
        -- Highlight + tooltip on hover
        altsCell:EnableMouse(true)
        altsCell:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
        local hl = altsCell:GetHighlightTexture()
        if hl then hl:SetAlpha(0.3) end
        altsCell:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("|cffffd100" .. short .. "'s alts|r")
            for _, alt in ipairs(member.alts) do
                local lines = BuildAltTooltipLines(alt, roster)
                for _, line in ipairs(lines) do GameTooltip:AddLine(line) end
                GameTooltip:AddLine(" ")  -- blank separator between alts
            end
            GameTooltip:Show()
        end)
        altsCell:SetScript("OnLeave", function() GameTooltip:Hide() end)
    else
        altsText:SetText("|cff555555\226\128\148|r")  -- em dash
    end
end

-- Sort comparators per key. Each returns true if `a` should come
-- before `b`. asc/desc is applied by swapping arguments at the call.
local SORT_COMPARATORS = {
    name    = function(a, b) return a.short:lower() < b.short:lower() end,
    ilvl    = function(a, b) return (a.ilvl or 0) < (b.ilvl or 0) end,
    enchants = function(a, b) return (a.missingEnchants or 0) < (b.missingEnchants or 0) end,
    gems    = function(a, b) return (a.missingGems or 0) < (b.missingGems or 0) end,
    alts    = function(a, b) return (a.altCount or 0) < (b.altCount or 0) end,
}

local function PopulateTeams(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local teams = WGS.db.global.teams
    if not teams or #teams == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText("No teams imported yet. Use the Import/Export tab to import data.")
        tab.content:SetHeight(30)
        return
    end

    local roster     = WGS:GetGuildRosterLookup()
    local characters = WGS.db.global.characters or {}
    local details    = WGS.db.global.characterDetails or {}

    -- Sort state lives on the tab so it survives a re-render. Click
    -- a header → SetSort(key) → PopulateTeams(tab) re-runs.
    local sortKey = tab._sortKey or DEFAULT_SORT_KEY
    local sortDir = tab._sortDir or DEFAULT_SORT_DIR

    local function setSort(key)
        if tab._sortKey == key then
            tab._sortDir = (tab._sortDir == "asc") and "desc" or "asc"
        else
            tab._sortKey = key
            -- Default for non-name columns is desc (highest first) since
            -- "who has the most missing enchants" is the usual question.
            tab._sortDir = (key == "name") and "asc" or "desc"
        end
        PopulateTeams(tab)
    end

    local yOff = 0

    for _, team in ipairs(teams) do
        -- Team header
        local header = CreateFrame("Frame", nil, tab.content)
        header:SetSize(CONTENT_W, 20)
        header:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)
        local tn = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tn:SetPoint("LEFT", header, "LEFT", 5, 0)
        local memberNames = team.members or {}
        tn:SetText("|cffffd100" .. (team.name or "?") .. "|r  |cff888888("
            .. (team.type or "Team") .. " \226\128\148 " .. #memberNames .. " members)|r")
        yOff = yOff - 24

        if #memberNames == 0 then
            local noM = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            noM:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 16, yOff)
            noM:SetText("(no members)")
            yOff = yOff - 16
        else
            -- Column headers (sortable, gold + arrow on the active column)
            local hdrRow = CreateFrame("Frame", nil, tab.content)
            hdrRow:SetSize(CONTENT_W, HEADER_H)
            hdrRow:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)
            BuildHeaderCell(hdrRow, COL.NAME, "name",     COL.NAME.x, sortKey, sortDir, setSort)
            BuildHeaderCell(hdrRow, COL.ILVL, "ilvl",     COL.ILVL.x, sortKey, sortDir, setSort)
            BuildHeaderCell(hdrRow, COL.ENCH, "enchants", COL.ENCH.x, sortKey, sortDir, setSort)
            BuildHeaderCell(hdrRow, COL.GEMS, "gems",     COL.GEMS.x, sortKey, sortDir, setSort)
            BuildHeaderCell(hdrRow, COL.ALTS, "alts",     COL.ALTS.x, sortKey, sortDir, setSort)

            -- Thin separator under the header
            local sep = tab.content:CreateTexture(nil, "ARTWORK")
            sep:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff - HEADER_H + 1)
            sep:SetPoint("TOPRIGHT", tab.content, "TOPRIGHT", 0, yOff - HEADER_H + 1)
            sep:SetHeight(1)
            sep:SetColorTexture(0.3, 0.3, 0.3, 0.6)

            yOff = yOff - HEADER_H

            -- Build per-member rows. Fixes the linked-vs-unlinked
            -- mutual-exclusion bug by iterating team.members (the
            -- canonical full list) and decorating from playerMembers
            -- when a link exists.
            local linkInfo = {}
            for _, pm in ipairs(team.playerMembers or {}) do
                local shortMain = (pm.main or ""):match("^([^%-]+)") or pm.main or ""
                if shortMain ~= "" then linkInfo[shortMain:lower()] = pm end
            end

            -- Collect rows first so we can sort, then render.
            local rows = {}
            for _, memberName in ipairs(memberNames) do
                local short = memberName:match("^([^%-]+)") or memberName
                local pm = linkInfo[short:lower()]
                local altList = pm and characters[pm.playerId] and characters[pm.playerId].alts
                local info = details[short] or {}
                rows[#rows + 1] = {
                    name             = memberName,
                    short            = short,
                    ilvl             = info.ilvl or 0,
                    missingEnchants  = info.missingEnchants or 0,
                    missingGems      = info.missingGems or 0,
                    altCount         = altList and #altList or 0,
                    alts             = altList or {},
                }
            end

            local cmp = SORT_COMPARATORS[sortKey] or SORT_COMPARATORS.name
            table.sort(rows, function(a, b)
                if sortDir == "asc" then return cmp(a, b) else return cmp(b, a) end
            end)

            for i, member in ipairs(rows) do
                BuildDataRow(tab.content, member, roster, yOff, i % 2 == 0)
                yOff = yOff - ROW_H
            end
        end
        yOff = yOff - TEAM_GAP
    end
    -- Refresh the scroll child geometry. SetHeight alone doesn't
    -- always wake the UIPanelScrollFrameTemplate scrollbar — without
    -- UpdateScrollChildRect() the bar stays hidden and only the
    -- top 1-2 rows (whatever fits in the unscrolled viewport)
    -- render visibly. SetSize re-asserts both dimensions defensively.
    tab.content:SetSize(CONTENT_W, math.abs(yOff) + 10)
    if tab.scrollFrame and tab.scrollFrame.UpdateScrollChildRect then
        tab.scrollFrame:UpdateScrollChildRect()
    end
end

---------------------------------------------------------------------------
-- Roster Check sub-view
---------------------------------------------------------------------------

function BuildRosterCheckSubView(sv)
    sv.header = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sv.header:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -2)
    sv.header:SetWidth(660)
    sv.header:SetJustifyH("LEFT")

    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -22)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 30)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content

    sv.announceBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.announceBtn:SetSize(180, 26)
    sv.announceBtn:SetPoint("BOTTOMLEFT", sv, "BOTTOMLEFT", 5, 0)
    sv.announceBtn:SetText("Announce Missing")
    sv.announceBtn:Hide()

    sv.inviteBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.inviteBtn:SetSize(140, 26)
    sv.inviteBtn:SetPoint("LEFT", sv.announceBtn, "RIGHT", 8, 0)
    sv.inviteBtn:SetText("Invite Missing")
    sv.inviteBtn:SetScript("OnClick", function() WGS:AutoInvite() end)
    sv.inviteBtn:Hide()

    sv.refreshBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.refreshBtn:SetSize(100, 26)
    sv.refreshBtn:SetPoint("LEFT", sv.inviteBtn, "RIGHT", 8, 0)
    sv.refreshBtn:SetText("Refresh")
    sv.refreshBtn:SetScript("OnClick", function()
        if sv._refreshFn then sv._refreshFn() end
    end)
end

-- Returns { expected, actual } lists for today's event
local function BuildRosterCheckData()
    local event = WGS.FindTodayEventForTeam and WGS:FindTodayEventForTeam(nil) or nil
    if not event then
        return nil, "No event scheduled for today."
    end

    local teamId = event.team_id or event.teamId
    local team = nil
    if teamId then
        for _, t in ipairs(WGS.db.global.teams or {}) do
            if t.id == teamId then team = t; break end
        end
    end

    if not team then
        return nil, "Today's event has no linked team."
    end

    local expected = {}
    local expectedOrder = {}

    -- Build a name → playerMember lookup so we can decorate linked
    -- members with their alts, while still iterating team.members
    -- (the canonical full list) — same bug pattern as PopulateTeams:
    -- if a team mixes linked + unlinked members, an `elseif` branch
    -- silently drops the unlinked ones.
    local linkByMain = {}
    for _, pm in ipairs(team.playerMembers or {}) do
        if pm.main then linkByMain[pm.main] = pm end
    end

    local chars = WGS.db.global.characters or {}
    for _, memberName in ipairs(team.members or {}) do
        local pm = linkByMain[memberName]
        local main = memberName
        expected[main] = {
            playerId = pm and pm.playerId or nil,
            isMain = true,
            mainName = main,
        }
        expectedOrder[#expectedOrder + 1] = main
        -- Linked? Pull in alts too so "matched on alt: X" can fire.
        if pm and chars[pm.playerId] and chars[pm.playerId].alts then
            for _, alt in ipairs(chars[pm.playerId].alts) do
                expected[alt] = { playerId = pm.playerId, isMain = false, mainName = main }
            end
        end
    end

    local actual = {}
    local actualSource = nil
    if WGS:IsInAnyGroup() then
        local members = WGS:GetRaidMembers()
        for name in pairs(members) do actual[name] = true end
        actualSource = "current raid"
    else
        local attendance = WGS.db.global.attendance or {}
        if #attendance > 0 then
            local last = attendance[#attendance]
            if last.memberList then
                for _, m in ipairs(last.memberList) do
                    if m.name then actual[m.name] = true end
                end
                actualSource = "last session"
            end
        end
    end

    if not actualSource then
        return nil, "Not in a raid and no attendance history."
    end

    return {
        event = event,
        team = team,
        expected = expected,
        expectedOrder = expectedOrder,
        actual = actual,
        actualSource = actualSource,
    }
end

function PopulateRosterCheck(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local data, err = BuildRosterCheckData()
    if not data then
        tab.header:SetText("|cff888888" .. (err or "No data") .. "|r")
        tab.announceBtn:Hide()
        tab.inviteBtn:Hide()
        tab.content:SetHeight(10)
        return
    end

    tab.header:SetText(string.format("|cffffd100%s|r  |cff888888(%s, vs %s)|r",
        data.event.title or "Event", data.team.name or "?", data.actualSource))

    local roster = WGS:GetGuildRosterLookup()
    local yOff = 0
    local cw = 660

    local present = {}
    local missing = {}
    local presentChars = {}

    for _, main in ipairs(data.expectedOrder) do
        local playerId = data.expected[main].playerId
        local matched = nil
        if data.actual[main] then
            matched = main
            presentChars[main] = true
        else
            for altName, info in pairs(data.expected) do
                if info.playerId == playerId and not info.isMain and data.actual[altName] then
                    matched = altName
                    presentChars[altName] = true
                    break
                end
            end
        end
        if matched then
            present[#present + 1] = { main = main, matched = matched }
        else
            missing[#missing + 1] = main
        end
    end

    local extra = {}
    for actualName in pairs(data.actual) do
        if not presentChars[actualName] and not data.expected[actualName] then
            local pid = WGS:ResolvePlayerForCharacter(actualName)
            local altOfMain = nil
            if pid then
                for _, info in pairs(data.expected) do
                    if info.playerId == pid then
                        altOfMain = info.mainName
                        break
                    end
                end
            end
            extra[#extra + 1] = { name = actualName, altOfMain = altOfMain }
        end
    end

    local function addSectionHeader(text)
        local h = tab.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, yOff)
        h:SetText(text)
        yOff = yOff - 20
    end

    local function addRow(text)
        local r = CreateFrame("Frame", nil, tab.content)
        r:SetSize(cw, 16)
        r:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)
        local t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t:SetPoint("LEFT", r, "LEFT", 15, 0)
        t:SetText(text)
        yOff = yOff - 16
    end

    addSectionHeader("|cff00ff00Present (" .. #present .. ")|r")
    if #present == 0 then
        addRow("|cff666666(none)|r")
    else
        for _, p in ipairs(present) do
            local short = p.main:match("^([^%-]+)") or p.main
            local gi = roster[short]
            local cColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local label = "|c" .. cColor .. short .. "|r"
            if p.matched ~= p.main then
                local altShort = p.matched:match("^([^%-]+)") or p.matched
                label = label .. " |cff888888(on alt: " .. altShort .. ")|r"
            end
            addRow(label)
        end
    end
    yOff = yOff - 6

    addSectionHeader("|cffff4444Missing (" .. #missing .. ")|r")
    if #missing == 0 then
        addRow("|cff666666(none)|r")
    else
        for _, m in ipairs(missing) do
            local short = m:match("^([^%-]+)") or m
            local gi = roster[short]
            local cColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local status = gi and (gi.online and "|cff00ff00online|r" or "|cff555555offline|r") or "|cffff4444not in guild|r"
            addRow("|c" .. cColor .. short .. "|r  " .. status)
        end
    end
    yOff = yOff - 6

    addSectionHeader("|cffffcc00Extra (" .. #extra .. ")|r")
    if #extra == 0 then
        addRow("|cff666666(none)|r")
    else
        for _, e in ipairs(extra) do
            local short = e.name:match("^([^%-]+)") or e.name
            local gi = roster[short]
            local cColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local label = "|c" .. cColor .. short .. "|r"
            if e.altOfMain then
                local mainShort = e.altOfMain:match("^([^%-]+)") or e.altOfMain
                label = label .. " |cff888888(alt of " .. mainShort .. ")|r"
            else
                label = label .. " |cff888888(pug)|r"
            end
            addRow(label)
        end
    end

    tab.content:SetHeight(math.abs(yOff) + 10)

    if #missing > 0 then
        tab.inviteBtn:Show()
        if WGS:IsInAnyGroup() then
            tab.announceBtn:Show()
            tab.announceBtn:SetScript("OnClick", function()
                local channel = WGS:GetGroupChannel() or "PARTY"
                C_ChatInfo.SendChatMessage("[GuildHall] Missing for " .. (data.event.title or "event") .. ":", channel)
                local names = {}
                for _, m in ipairs(missing) do
                    names[#names + 1] = m:match("^([^%-]+)") or m
                end
                local chunk = ""
                for _, n in ipairs(names) do
                    if #chunk + #n + 2 > 200 then
                        C_ChatInfo.SendChatMessage("  " .. chunk, channel)
                        chunk = n
                    else
                        chunk = chunk == "" and n or (chunk .. ", " .. n)
                    end
                end
                if chunk ~= "" then
                    C_ChatInfo.SendChatMessage("  " .. chunk, channel)
                end
            end)
        else
            tab.announceBtn:Hide()
        end
    else
        tab.announceBtn:Hide()
        tab.inviteBtn:Hide()
    end
end

---------------------------------------------------------------------------
-- Wishlists sub-view (moved here from the deleted Loot tab — per-player
-- data fits with the rest of Teams).
---------------------------------------------------------------------------

local PRIORITY_ORDER = { BiS = 1, High = 2, Medium = 3, Low = 4 }
local PRIORITY_COLORS = {
    BiS    = "ffff8000",
    High   = "ffa335ee",
    Medium = "ff0070dd",
    Low    = "ff1eff00",
}

function BuildWishlistsSubView(sv)
    local lbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -2)
    lbl:SetText("Boss:")

    sv.dropBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.dropBtn:SetSize(280, 22)
    sv.dropBtn:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    sv.dropBtn:SetText("(All items)")
    sv.selectedBoss = nil

    sv.dropMenu = CreateFrame("Frame", nil, sv, "BackdropTemplate")
    sv.dropMenu:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    sv.dropMenu:SetBackdropColor(0, 0, 0, 0.95)
    sv.dropMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    sv.dropMenu:Hide()
    sv.dropMenuButtons = {}

    sv.dropBtn:SetScript("OnClick", function()
        if sv.dropMenu:IsShown() then sv.dropMenu:Hide(); return end
        for _, btn in ipairs(sv.dropMenuButtons) do btn:Hide() end

        local bossSet = {}
        for _, entry in ipairs(WGS.db.global.loot or {}) do
            if entry.boss and entry.boss ~= "" then bossSet[entry.boss] = true end
        end
        local bosses = { "(All items)" }
        for name in pairs(bossSet) do bosses[#bosses + 1] = name end
        table.sort(bosses, function(a, b)
            if a == "(All items)" then return true end
            if b == "(All items)" then return false end
            return a < b
        end)

        local bh = 22
        sv.dropMenu:SetSize(280, #bosses * bh + 8)
        sv.dropMenu:ClearAllPoints()
        sv.dropMenu:SetPoint("TOPLEFT", sv.dropBtn, "BOTTOMLEFT", 0, -2)

        for i, name in ipairs(bosses) do
            local btn = sv.dropMenuButtons[i]
            if not btn then
                btn = CreateFrame("Button", nil, sv.dropMenu)
                btn:SetSize(272, bh)
                btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                btn.text:SetAllPoints()
                btn.text:SetJustifyH("LEFT")
                sv.dropMenuButtons[i] = btn
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", sv.dropMenu, "TOPLEFT", 4, -(i - 1) * bh - 4)
            btn.text:SetText("  " .. name)
            btn:SetScript("OnClick", function()
                sv.selectedBoss = (name == "(All items)") and nil or name
                sv.dropBtn:SetText(name)
                sv.dropMenu:Hide()
                if sv._refreshFn then sv._refreshFn() end
            end)
            btn:Show()
        end
        sv.dropMenu:Show()
    end)

    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -28)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
end

function PopulateWishlists(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local wishlists = WGS.db.global.wishlists or {}
    if #wishlists == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText("No wishlists imported. Import from web app first.")
        tab.content:SetHeight(30)
        return
    end

    local itemWishers = {}
    local itemNames = {}
    for _, entry in ipairs(wishlists) do
        if entry.items then
            for _, item in ipairs(entry.items) do
                if item.itemID then
                    itemWishers[item.itemID] = itemWishers[item.itemID] or {}
                    table.insert(itemWishers[item.itemID], {
                        playerName = entry.playerName,
                        priority = item.priority,
                        note = item.note,
                    })
                end
            end
        end
    end

    for _, lootEntry in ipairs(WGS.db.global.loot or {}) do
        if lootEntry.itemID and lootEntry.itemName and not itemNames[lootEntry.itemID] then
            itemNames[lootEntry.itemID] = lootEntry.itemName
        end
    end
    for itemID in pairs(itemWishers) do
        if not itemNames[itemID] then
            local name = C_Item.GetItemInfo(itemID)
            if name then itemNames[itemID] = name end
        end
    end

    local allowedIds = nil
    if tab.selectedBoss then
        allowedIds = {}
        for _, lootEntry in ipairs(WGS.db.global.loot or {}) do
            if lootEntry.boss == tab.selectedBoss and lootEntry.itemID then
                allowedIds[lootEntry.itemID] = true
            end
        end
    end

    local itemsToShow = {}
    for itemID, wishers in pairs(itemWishers) do
        if not allowedIds or allowedIds[itemID] then
            itemsToShow[#itemsToShow + 1] = { itemID = itemID, wishers = wishers }
        end
    end
    table.sort(itemsToShow, function(a, b)
        if #a.wishers ~= #b.wishers then return #a.wishers > #b.wishers end
        return a.itemID < b.itemID
    end)

    if #itemsToShow == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        if tab.selectedBoss then
            noData:SetText("No wishlisted items from " .. tab.selectedBoss .. " in loot history yet.")
        else
            noData:SetText("No wishlisted items found.")
        end
        tab.content:SetHeight(30)
        return
    end

    local roster = WGS:GetGuildRosterLookup()
    local yOff = 0

    for _, item in ipairs(itemsToShow) do
        local header = CreateFrame("Frame", nil, tab.content)
        header:SetSize(660, 20)
        header:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

        local headerText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        headerText:SetPoint("LEFT", header, "LEFT", 5, 0)
        local name = itemNames[item.itemID] or ("Item " .. item.itemID)
        headerText:SetText(string.format("|cffa335ee%s|r  |cff888888(%d wisher%s)|r",
            name, #item.wishers, #item.wishers == 1 and "" or "s"))
        yOff = yOff - 20

        table.sort(item.wishers, function(a, b)
            return (PRIORITY_ORDER[a.priority] or 99) < (PRIORITY_ORDER[b.priority] or 99)
        end)

        for _, w in ipairs(item.wishers) do
            local row = CreateFrame("Frame", nil, tab.content)
            row:SetSize(660, 16)
            row:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

            local short = (w.playerName or ""):match("^([^%-]+)") or w.playerName or "?"
            local gi = roster[short]
            local pColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local pText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            pText:SetPoint("LEFT", row, "LEFT", 25, 0)
            pText:SetText("|c" .. pColor .. short .. "|r")

            local prColor = PRIORITY_COLORS[w.priority] or "ffffffff"
            local prText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            prText:SetPoint("LEFT", pText, "RIGHT", 10, 0)
            prText:SetText("|c" .. prColor .. (w.priority or "?") .. "|r")

            if w.note and w.note ~= "" then
                local nText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                nText:SetPoint("LEFT", prText, "RIGHT", 8, 0)
                nText:SetText("|cff888888(" .. w.note .. ")|r")
            end

            yOff = yOff - 16
        end

        yOff = yOff - 4
    end

    tab.content:SetHeight(math.abs(yOff) + 10)
end

---------------------------------------------------------------------------
-- Tab wiring
---------------------------------------------------------------------------

local function BuildTeamsTab(parent)
    BuildSubNav(parent, TEAMS_SUB_NAMES, function(p, i)
        SelectSubView(p, i, TEAMS_SUB_COUNT)
        if i == TEAMS_SUB_TEAMS then
            PopulateTeams(p.subViews[i])
        elseif i == TEAMS_SUB_CHECK then
            PopulateRosterCheck(p.subViews[i])
        elseif i == TEAMS_SUB_WISHLISTS then
            PopulateWishlists(p.subViews[i])
        end
    end)
    BuildTeamsSubView(parent.subViews[TEAMS_SUB_TEAMS])
    BuildRosterCheckSubView(parent.subViews[TEAMS_SUB_CHECK])
    BuildWishlistsSubView(parent.subViews[TEAMS_SUB_WISHLISTS])

    -- Back-pointer used by the Refresh button inside RosterCheck and
    -- the boss-dropdown inside Wishlists. Sub-view-owned re-renders.
    parent.subViews[TEAMS_SUB_CHECK]._refreshFn = function()
        PopulateRosterCheck(parent.subViews[TEAMS_SUB_CHECK])
    end
    parent.subViews[TEAMS_SUB_WISHLISTS]._refreshFn = function()
        PopulateWishlists(parent.subViews[TEAMS_SUB_WISHLISTS])
    end

    SelectSubView(parent, TEAMS_SUB_TEAMS, TEAMS_SUB_COUNT)
end

local function RefreshTeamsSubView(tab)
    if not tab or not tab:IsVisible() then return end
    local sub = tab.selectedSub or TEAMS_SUB_TEAMS
    if sub == TEAMS_SUB_TEAMS then
        PopulateTeams(tab.subViews[sub])
    elseif sub == TEAMS_SUB_CHECK then
        PopulateRosterCheck(tab.subViews[sub])
    elseif sub == TEAMS_SUB_WISHLISTS then
        PopulateWishlists(tab.subViews[sub])
    end
end

ui.tabs[TAB_INDEX] = { build = BuildTeamsTab, refresh = RefreshTeamsSubView }
