---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Teams sub-view: flat listing of imported teams with main/alt rollup
-- and a gear-issues column (missing enchants/gems, ilvl-vs-target).
-- Each team is its own section; rows are sortable by clicking any
-- column header.
--
-- The Roster Check and Wishlists sub-views live in their own files
-- (UI/Teams/RosterCheck.lua, UI/Teams/Wishlists.lua) and share the
-- top-level Teams tab via the ui.teams namespace.

ui.teams = ui.teams or {}

local ClearContainer      = ui.ClearContainer
local CreateScrollContent = ui.CreateScrollContent
local ApplyClassIcon      = ui.ApplyClassIcon

---------------------------------------------------------------------------
-- Character / gear-info helpers (used by this sub-view only — Roster
-- Check pulls class from the guild-roster lookup directly).
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

-- Multi-line tooltip body for an alt: class/spec + online state + ilvl
-- + missing-enchant/gem counts. Each line is "|cAARRGGBBtext|r" ready
-- to feed into GameTooltip:AddLine.
local function BuildAltTooltipLines(charName, roster)
    local info = GetCharacterDetails(charName)
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
-- Table layout
--
-- One row per team member (mains only). Columns:
--   Character  iLvl  Enchants  Gems  Alts
-- Click a column header to sort by it. Hover the Alts cell to see the
-- alt list with per-alt gear breakdown in a tooltip.
--
-- Numeric cells render as plain numbers coloured by severity rather
-- than glyphs — the in-game default font misses a lot of Unicode and
-- we'd rather use what's guaranteed to render.
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

-- Thin wrapper around ui.BuildNumericCell that adapts the col-record
-- API to the helper's positional args. Kept here so the per-row builds
-- below read cleanly.
local function BuildNumericCell(parent, col, x, value, isProblemWhenAbove0, yOff)
    return ui.BuildNumericCell(parent, x, yOff, col.w, ROW_H, value, isProblemWhenAbove0)
end

local function BuildDataRow(parent, member, roster, yOff, evenStripe)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(CONTENT_W, ROW_H)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOff)

    if evenStripe then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(row)
        bg:SetColorTexture(1, 1, 1, 0.025)
    end

    -- Character cell: online dot + class icon + class-coloured name.
    local short    = member.short
    local classFile = ResolveClass(member.name, roster) or ""
    local colorHex = WGS.CLASS_COLORS[classFile] or "ffffffff"
    local gi       = roster[short]

    -- Button (not Frame) so right-click can open the shared player
    -- context menu (Whisper / Invite / Copy name / Copy profile link).
    -- AttachPlayerContextMenu sets RegisterForClicks + OnClick; the row
    -- has no left-click behaviour of its own to preserve.
    local nameCell = CreateFrame("Button", nil, row)
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

    ui.AttachPlayerContextMenu(nameCell, member.name, classFile)

    -- Numeric cells
    BuildNumericCell(row, COL.ILVL, COL.ILVL.x, member.ilvl,             false, 0)
    BuildNumericCell(row, COL.ENCH, COL.ENCH.x, member.missingEnchants,  true,  0)
    BuildNumericCell(row, COL.GEMS, COL.GEMS.x, member.missingGems,      true,  0)

    -- Alts cell: count + hover-tooltip with per-alt breakdown.
    -- Created as a Button (not a Frame) because SetHighlightTexture
    -- only exists on Button — Frame has no such method and calling it
    -- crashes the row render.
    local altsCell = CreateFrame("Button", nil, row)
    altsCell:SetSize(COL.ALTS.w, ROW_H)
    altsCell:SetPoint("TOPLEFT", row, "TOPLEFT", COL.ALTS.x, 0)

    local altsText = altsCell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    altsText:SetPoint("RIGHT", altsCell, "RIGHT", -10, 0)
    if member.altCount > 0 then
        altsText:SetText("|cffffd100" .. member.altCount .. "|r")
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
    name     = function(a, b) return a.short:lower() < b.short:lower() end,
    ilvl     = function(a, b) return (a.ilvl or 0) < (b.ilvl or 0) end,
    enchants = function(a, b) return (a.missingEnchants or 0) < (b.missingEnchants or 0) end,
    gems     = function(a, b) return (a.missingGems or 0) < (b.missingGems or 0) end,
    alts     = function(a, b) return (a.altCount or 0) < (b.altCount or 0) end,
}

---------------------------------------------------------------------------
-- Sub-view build + populate (registered on ui.teams.roster)
---------------------------------------------------------------------------

local function BuildSubView(sv)
    local sf, content = CreateScrollContent(sv)
    sf:ClearAllPoints()
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    sv.scrollFrame = sf
    sv.content = content
end

local function Populate(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local teams = WGS.db.global.teams
    if not teams or #teams == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText("No teams imported yet. Use the Sync tab to import data.")
        tab.content:SetHeight(30)
        return
    end

    -- Apply the global current-team filter: when set, render only the
    -- matching team. nil = "All Teams" (show all, current behaviour).
    local currentTeamId = WGS.GetCurrentTeamId and WGS:GetCurrentTeamId() or nil
    if currentTeamId then
        local filtered = {}
        for _, t in ipairs(teams) do
            if t.id == currentTeamId then filtered[#filtered + 1] = t end
        end
        teams = filtered
        if #teams == 0 then
            local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
            noData:SetText("Picked team is no longer present in the imported teams list.")
            tab.content:SetHeight(30)
            return
        end
    end

    local roster     = WGS:GetGuildRosterLookup()
    local characters = WGS.db.global.characters or {}
    local details    = WGS.db.global.characterDetails or {}

    -- Sort state lives on the tab so it survives a re-render.
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
        Populate(tab)
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

            -- Build per-member rows. Iterates team.members (the canonical
            -- full list) and decorates from playerMembers when a link
            -- exists — fixes the bug where a team mixing linked +
            -- unlinked members would silently drop the unlinked ones.
            local linkInfo = {}
            for _, pm in ipairs(team.playerMembers or {}) do
                local shortMain = (pm.main or ""):match("^([^%-]+)") or pm.main or ""
                if shortMain ~= "" then linkInfo[shortMain:lower()] = pm end
            end

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

    -- Re-assert the scroll child geometry. SetHeight alone doesn't
    -- always wake the UIPanelScrollFrameTemplate scrollbar — without
    -- UpdateScrollChildRect() the bar stays hidden and only the
    -- top 1-2 rows render visibly. SetSize re-asserts both dimensions.
    tab.content:SetSize(CONTENT_W, math.abs(yOff) + 10)
    if tab.scrollFrame and tab.scrollFrame.UpdateScrollChildRect then
        tab.scrollFrame:UpdateScrollChildRect()
    end
end

ui.teams.roster = { build = BuildSubView, populate = Populate }
