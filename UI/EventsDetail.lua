---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Events detail panel: right-hand side of the master-detail Events tab.
-- Renders the per-event surface — title + subline, Roster section, Raid
-- Comp section, Boss Notes section, and the sticky action-button footer
-- below the scroll area.
--
-- The rail (left side) + the small event helpers (EventStartTs, Event-
-- Status, FormatEventTime, …) live in UI/EventsFrame.lua and stash
-- themselves on `ui.events` so the cross-file calls down below resolve
-- regardless of script load order.

ui.events = ui.events or {}

local ApplyClassIcon   = ui.ApplyClassIcon
local BuildNumericCell = ui.BuildNumericCell

-- Signup-status tables come from Util/SignupStatus.lua; raid-comp role
-- labels stay local to this file since the detail panel is their only
-- consumer (chat-share role labels come from WGS:NormalizeRole).
local STATUS_LABELS       = WGS.SIGNUP_STATUS_LABELS
local STATUS_LABEL_COLORS = WGS.SIGNUP_STATUS_COLORS
local COMMITTED_STATUSES  = WGS.SIGNUP_STATUS_COMMITTED
local ROSTER_GROUP_ORDER  = WGS.SIGNUP_STATUS_ORDER

-- ROLE_ORDER is still used by the "Share Comp" chat output path which
-- groups by role (tanks/healers/dps) for raid-chat readability. The
-- main raid-comp UI now groups by raid group (1-8) since that matches
-- the platform's Raid Comp builder.
local ROLE_ORDER  = { "TANK", "HEALER", "DPS" }

---------------------------------------------------------------------------
-- Data builders (small helpers used only by the detail panel)
---------------------------------------------------------------------------

-- Build the per-signup row list for an event. Each row pairs the
-- signup status with the character's gear summary from characterDetails
-- so officers see "Foo-Realm — Present · 632 · 2 enchants missing" on
-- one line.
--
-- Returned fields:
--   rows          { ... } per-signup rows (see body)
--   byStatus      { P=N, L=N, LT=N, B=N, T=N, A=N, LE=N, RM=N }
--   gearGapCount  signups with at least one missing enchant or gem
local function BuildEventRoster(eventId)
    local out = {
        byStatus = { P = 0, L = 0, LT = 0, B = 0, T = 0, A = 0, LE = 0, RM = 0 },
        gearGapCount = 0,
        rows = {},
    }
    local signups = WGS.db.global.signups
    if type(signups) ~= "table" or not eventId then return out end
    local details = WGS.db.global.characterDetails or {}

    for _, s in ipairs(signups) do
        if s.eventId == eventId and s.characterName then
            local short = s.characterName:match("^([^%-]+)") or s.characterName
            local d = details[short] or {}
            local row = {
                short            = short,
                fullName         = s.characterName,
                status           = s.status,
                class            = d.class or s.class,
                spec             = d.spec,
                ilvl             = d.ilvl or 0,
                missingEnchants  = d.missingEnchants or 0,
                missingGems      = d.missingGems or 0,
            }
            if (row.missingEnchants + row.missingGems) > 0 then
                out.gearGapCount = out.gearGapCount + 1
            end
            if out.byStatus[s.status] ~= nil then
                out.byStatus[s.status] = out.byStatus[s.status] + 1
            end
            out.rows[#out.rows + 1] = row
        end
    end
    return out
end

-- Pulls the raid comp for `eventId` from db.global.raidComps. The comp
-- shape is normalised on import to { eventId, name, assignments } (see
-- Modules/Import.lua). Returns nil if no comp exists for this event.
local function FindRaidCompForEvent(eventId)
    if not eventId then return nil end
    local comps = WGS.db.global.raidComps
    if type(comps) ~= "table" then return nil end
    for _, c in ipairs(comps) do
        if c.eventId == eventId then return c end
    end
    return nil
end

-- A horizontal divider with a section label. Used to separate the
-- detail panel's stacked sections without leaning on heavy frames.
local function BuildSectionHeader(parent, anchor, label, width)
    local divider = parent:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT",  anchor, "BOTTOMLEFT",  0, -8)
    divider:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -8)
    divider:SetHeight(1)
    divider:SetColorTexture(0.3, 0.3, 0.3, 0.6)

    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 4, -4)
    fs:SetText("|cffffd100" .. label .. "|r")
    fs._sectionWidth = width    -- caller uses this for child sizing
    return fs
end

---------------------------------------------------------------------------
-- Roster section
--
-- Layout, top to bottom:
--   Section title + "N gear gaps" summary on the same line
--   Column headers (iLvl / Enchants / Gems) right-aligned, dimmed
--   For each non-empty status group:
--     Status group header in the status color ("Present (18)")
--     Indented data rows: [class icon] Name … iLvl Ench Gems
--
-- The per-row status column was dropped — it just repeated the same
-- word ("Present") 15-20 times per row, where the Discord embed has
-- one group header per status. Numeric columns right-anchor so they
-- reach the right edge of the section instead of dangling in the middle.
---------------------------------------------------------------------------

local function PopulateRosterSection(content, anchor, roster, width, frame)
    local header = BuildSectionHeader(content, anchor, "Roster", width)

    -- Inline summary on the section-title row: gear-gap total only.
    -- Per-status counts moved into the group headers below.
    local summary = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("LEFT", header, "RIGHT", 12, 0)
    if roster.gearGapCount > 0 then
        summary:SetText(string.format("|cffff5555%d gear gaps|r", roster.gearGapCount))
    else
        summary:SetText("")
    end

    if #roster.rows == 0 then
        local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        empty:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
        empty:SetText("No signups yet for this event.")
        return empty
    end

    -- Search filter. Frame-scoped persistence (frame._rosterFilter)
    -- survives the per-render rebuild — PopulateDetail clears content
    -- but `frame` stays. After OnTextChanged → PopulateEvents rebuild,
    -- the new EditBox restores text + focus + cursor so typing feels
    -- uninterrupted. Filter matches case-insensitively against the
    -- short character name (post-realm-strip).
    local currentFilter = (frame and frame._rosterFilter) or ""
    local searchBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    searchBox:SetSize(160, 20)
    searchBox:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 12, -6)
    searchBox:SetAutoFocus(false)
    searchBox:SetText(currentFilter)
    searchBox:SetCursorPosition(#currentFilter)
    if currentFilter ~= "" then searchBox:SetFocus() end
    searchBox:SetScript("OnTextChanged", function(self)
        local txt = (self:GetText() or ""):lower()
        if not frame then return end
        if (frame._rosterFilter or "") == txt then return end   -- no-op guard
        frame._rosterFilter = txt
        if WGS.PopulateEvents then WGS:PopulateEvents(frame) end
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")   -- triggers OnTextChanged → re-renders empty
        self:ClearFocus()
    end)
    local searchHint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchHint:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
    searchHint:SetText("|cff666666filter by name|r")

    -- Bucket rows by status code; sort within each by short name.
    -- Filter is applied here so empty buckets fall out of the render
    -- entirely (no group headers for groups with zero matches).
    local needle = currentFilter ~= "" and currentFilter or nil
    local byStatus = {}
    for _, code in ipairs(ROSTER_GROUP_ORDER) do byStatus[code] = {} end
    for _, row in ipairs(roster.rows) do
        local bucket = byStatus[row.status]
        if bucket then
            if not needle or ((row.short or ""):lower():find(needle, 1, true)) then
                bucket[#bucket + 1] = row
            end
        end
    end
    for _, code in ipairs(ROSTER_GROUP_ORDER) do
        table.sort(byStatus[code], function(a, b)
            return (a.short or "") < (b.short or "")
        end)
    end

    -- Column geometry. Numeric cells right-anchor to the row's RIGHT
    -- edge so they always reach the right edge of the section, no
    -- matter how wide the panel is. Name fills the remaining space
    -- between the class icon and the iLvl column.
    local ROW_H        = 18
    local HEADER_H     = 14
    local GROUP_HDR_H  = 18
    local INDENT       = 8           -- left-indent for rows under a group header
    local NUM_W        = 50          -- each numeric column
    local NUM_GAP      = 10
    local COL_GEMS_X   = width - 4  - NUM_W                       -- right-most
    local COL_ENCH_X   = COL_GEMS_X  - NUM_GAP - NUM_W
    local COL_ILVL_X   = COL_ENCH_X  - NUM_GAP - NUM_W
    local NAME_RIGHT_LIMIT = COL_ILVL_X - 4
    local ICON_X       = INDENT
    local NAME_X       = ICON_X + 20

    -- Column-header row above the data. Dimmed so it reads as a label
    -- not a value. Single row at the top of the section; not repeated
    -- per group.
    local columnHdr = CreateFrame("Frame", nil, content)
    columnHdr:SetSize(width, HEADER_H)
    -- columnHdr anchors below the search box so the filter input
    -- doesn't collide with the iLvl / Enchants / Gems labels.
    columnHdr:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -12, -6)
    columnHdr:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -6)

    local function colLabel(x, text)
        local fs = columnHdr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("LEFT", columnHdr, "LEFT", x, 0)
        fs:SetWidth(NUM_W)
        fs:SetJustifyH("RIGHT")
        fs:SetText(text)
        return fs
    end
    colLabel(COL_ILVL_X, "iLvl")
    colLabel(COL_ENCH_X, "Enchants")
    colLabel(COL_GEMS_X, "Gems")

    local last = columnHdr

    for _, code in ipairs(ROSTER_GROUP_ORDER) do
        local rows = byStatus[code]
        if #rows > 0 then
            -- Group header: "Present (18)" in the status color.
            local groupHdr = CreateFrame("Frame", nil, content)
            groupHdr:SetSize(width, GROUP_HDR_H)
            groupHdr:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -4)
            groupHdr:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -4)

            local fs = groupHdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetPoint("LEFT", groupHdr, "LEFT", 2, 0)
            fs:SetText(string.format("|c%s%s (%d)|r",
                STATUS_LABEL_COLORS[code] or "ffffffff",
                STATUS_LABELS[code] or code, #rows))
            last = groupHdr

            for _, row in ipairs(rows) do
                -- Button (not Frame) so the row can receive right-click
                -- for the shared player context menu. Left-click is a
                -- no-op today; the row chrome doesn't have its own
                -- click behaviour to preserve.
                local r = CreateFrame("Button", nil, content)
                r:SetSize(width, ROW_H)
                r:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -1)
                r:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -1)

                -- Class icon + class-coloured name. Indented under the
                -- group header so the visual grouping reads at a glance.
                local classFile = WGS:NormalizeClassFile(row.class or "")
                local colorHex  = WGS.CLASS_COLORS[classFile] or "ffffffff"

                local icon = r:CreateTexture(nil, "ARTWORK")
                icon:SetSize(16, 16)
                icon:SetPoint("LEFT", r, "LEFT", ICON_X, 0)
                ApplyClassIcon(icon, classFile, colorHex)

                local nameFs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                nameFs:SetPoint("LEFT", r, "LEFT", NAME_X, 0)
                nameFs:SetWidth(NAME_RIGHT_LIMIT - NAME_X)
                nameFs:SetJustifyH("LEFT")
                nameFs:SetWordWrap(false)
                nameFs:SetText("|c" .. colorHex .. row.short .. "|r")

                -- Roster row right-click: prepend a "Mark status ▸"
                -- submenu to the shared player-action items so the
                -- officer can re-tag this signup (Late / Tentative /
                -- Absent / etc.) without leaving WoW. The mutation
                -- lands in db.global.signups + queues for export via
                -- WGS:UpdateSignupStatus. Non-officers see the menu
                -- but the mutation rejects with a clear print.
                local capturedEventId = frame and frame._selectedEventId
                local capturedFullName = row.fullName
                r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                r:SetScript("OnClick", function(_, mouseBtn)
                    if mouseBtn ~= "RightButton" then return end

                    local statusMenu = {}
                    for _, statusCode in ipairs(WGS.SIGNUP_STATUS_ORDER or {}) do
                        statusMenu[#statusMenu + 1] = {
                            text = (WGS.SIGNUP_STATUS_LABELS or {})[statusCode] or statusCode,
                            notCheckable = true,
                            func = function()
                                WGS:UpdateSignupStatus(
                                    capturedEventId,
                                    capturedFullName,
                                    statusCode)
                            end,
                        }
                    end

                    local menu = {
                        { text = row.short, isTitle = true, notCheckable = true },
                        {
                            text = "Mark status",
                            notCheckable = true,
                            hasArrow = true,
                            menuList = statusMenu,
                        },
                        { text = "", isTitle = true, notCheckable = true },
                    }
                    -- Pass fullName (not short) so the menu's Invite
                    -- item gets the Name-Realm form for cross-realm
                    -- invites — see UIHelpers.lua's BuildPlayerMenuItems.
                    for _, item in ipairs(ui.BuildPlayerMenuItems(row.fullName or row.short, classFile)) do
                        menu[#menu + 1] = item
                    end
                    ui.OpenContextMenu(menu)
                end)

                BuildNumericCell(r, COL_ILVL_X, 0, NUM_W, ROW_H, row.ilvl, false)
                BuildNumericCell(r, COL_ENCH_X, 0, NUM_W, ROW_H, row.missingEnchants, true)
                BuildNumericCell(r, COL_GEMS_X, 0, NUM_W, ROW_H, row.missingGems, true)

                last = r
            end
        end
    end

    return last
end

---------------------------------------------------------------------------
-- Raid Comp section
---------------------------------------------------------------------------

-- Classes that bring a combat rez to the raid. Hits any of these and
-- we have at least one B-rez slot covered. (Druid, DK, Hunter, Warlock.)
local BATTLE_REZ_CLASSES = {
    DEATHKNIGHT = true, DRUID = true, HUNTER = true, WARLOCK = true,
}

-- Classes that bring Bloodlust/Heroism/Time Warp/Primal Rage/Fury of
-- the Aspects. At least one of these guarantees lust coverage.
local LUST_CLASSES = {
    SHAMAN = true, MAGE = true, HUNTER = true, EVOKER = true,
}

-- Evaluate a planned raid comp's class/role mix and return a list of
-- short warning strings ("No combat rez", "Only 1 healer"). Empty
-- result = comp looks balanced under our heuristics; that's the
-- happy path — we don't render anything in that case.
--
-- Counts (tank/healer) are only warned about when the comp is
-- close-to-mythic-sized (≥18). Smaller groups (HC/Normal/flex M+)
-- legitimately use fewer healers/tanks so a fixed threshold would
-- spam false positives.
local function evaluateRaidCompBalance(assignments)
    local warnings = {}
    local total, tanks, healers = 0, 0, 0
    local classCount = {}
    local hasBR, hasLust = false, false

    for _, m in ipairs(assignments) do
        total = total + 1
        local role = WGS:NormalizeRole(m.role)
        if role == "TANK" then tanks = tanks + 1
        elseif role == "HEALER" then healers = healers + 1
        end
        local cls = WGS:NormalizeClassFile(m.class or m.classFile or "")
        if cls and cls ~= "" then
            classCount[cls] = (classCount[cls] or 0) + 1
            if BATTLE_REZ_CLASSES[cls] then hasBR = true end
            if LUST_CLASSES[cls] then hasLust = true end
        end
    end

    if total >= 18 then
        if tanks < 2 then
            warnings[#warnings + 1] = string.format(
                "Only %d tank%s (mythic expects 2)",
                tanks, tanks == 1 and "" or "s")
        end
        if healers < 4 then
            warnings[#warnings + 1] = string.format(
                "Only %d healer%s (mythic expects 4-5)",
                healers, healers == 1 and "" or "s")
        end
    end
    if total > 0 and not hasBR then
        warnings[#warnings + 1] = "No combat rez (DK / Druid / Hunter / Warlock)"
    end
    if total > 0 and not hasLust then
        warnings[#warnings + 1] = "No Bloodlust (Shaman / Mage / Hunter / Evoker)"
    end
    -- 4+ of the same class signals stacking that's usually a balance
    -- mistake — surface it so the officer notices on the planning
    -- pass instead of mid-pull.
    for cls, n in pairs(classCount) do
        if n >= 4 then
            warnings[#warnings + 1] = string.format(
                "%dx %s stacking",
                n, cls:lower():gsub("^%l", string.upper))
        end
    end

    return warnings
end
WGS._EvaluateRaidCompBalance = evaluateRaidCompBalance   -- exposed for tests

-- Compare the planned raid-comp slots against the in-flight session's
-- captured members. Returns { planned, actual, present, missing,
-- extras } where:
--   planned   = number of planned slots
--   actual    = number of session members
--   present   = number of planned slots whose name is also in the
--               session (the people who actually showed)
--   missing   = array of { name, class, role, group } for planned
--               slots whose name is NOT in the session
--   extras    = array of { name, class, role } for session members
--               whose name is NOT in the planned comp (subs / pugs)
--
-- Matching is short-name (post-realm-strip) and case-insensitive so
-- "Foo-EU" in the comp and "Foo-Realm" in-session resolve as the
-- same character. Drives the diff strip below the Raid Comp section.
local function buildCompDiff(assignments, sessionMembers)
    local plannedByShort = {}
    for _, slot_ in ipairs(assignments) do
        local short = ((slot_.name or ""):match("^([^%-]+)") or slot_.name or ""):lower()
        if short ~= "" then plannedByShort[short] = slot_ end
    end

    local actualByShort = {}
    for _, m in ipairs(sessionMembers) do
        local short = ((m.name or ""):match("^([^%-]+)") or m.name or ""):lower()
        if short ~= "" then actualByShort[short] = m end
    end

    local present, missing, extras = 0, {}, {}
    for short, slot_ in pairs(plannedByShort) do
        if actualByShort[short] then
            present = present + 1
        else
            missing[#missing + 1] = {
                name  = slot_.name or short,
                class = slot_.class or slot_.classFile,
                role  = slot_.role,
                group = slot_.group,
            }
        end
    end
    for short, m in pairs(actualByShort) do
        if not plannedByShort[short] then
            extras[#extras + 1] = {
                name  = m.name or short,
                class = m.class,
                role  = m.role,
            }
        end
    end

    -- Sort missing by group asc (then by name) so the strip reads
    -- "Group 1: …, Group 2: …" cleanly.
    table.sort(missing, function(a, b)
        local ga, gb = tonumber(a.group) or 99, tonumber(b.group) or 99
        if ga ~= gb then return ga < gb end
        return (a.name or "") < (b.name or "")
    end)
    table.sort(extras, function(a, b) return (a.name or "") < (b.name or "") end)

    local actual = 0
    for _ in pairs(actualByShort) do actual = actual + 1 end
    local planned = 0
    for _ in pairs(plannedByShort) do planned = planned + 1 end
    return { planned = planned, actual = actual, present = present,
             missing = missing, extras = extras }
end
WGS._BuildCompDiff = buildCompDiff   -- exposed for tests

local function PopulateRaidCompSection(content, anchor, comp, width)
    local header = BuildSectionHeader(content, anchor, "Raid Comp", width)

    if not comp then
        local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        empty:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
        empty:SetText("No comp planned for this event.")
        return empty
    end

    -- Group assignments by raid group (1-8), with a fallback bucket
    -- for slots that don't have a group assignment yet. This mirrors
    -- the platform's Raid Comp builder, which is group-centric — the
    -- earlier role-grouped rendering (Tanks / Healers / DPS) didn't
    -- match what officers were planning on guildhall.run.
    --
    -- WGS:AutoInvite → invites fire → SortRaidGroups runs 5s later
    -- to move accepted raiders into their assigned group. So this
    -- view both PLANS the groups and is what officers see during the
    -- raid as the in-game subgroups fill in.
    local assignments = comp.assignments or comp.members or {}
    local byGroup = {}
    local unassigned = {}
    for _, m in ipairs(assignments) do
        local g = tonumber(m.group)
        if g and g >= 1 and g <= 8 then
            byGroup[g] = byGroup[g] or {}
            byGroup[g][#byGroup[g] + 1] = m
        else
            unassigned[#unassigned + 1] = m
        end
    end

    -- Within each group, sort by role (tanks first, then healers, then
    -- dps) so the column reads at a glance.
    local roleOrder = { TANK = 1, HEALER = 2, DPS = 3 }
    local function sortGroup(g)
        table.sort(g, function(a, b)
            local ra = roleOrder[WGS:NormalizeRole(a.role)] or 4
            local rb = roleOrder[WGS:NormalizeRole(b.role)] or 4
            if ra ~= rb then return ra < rb end
            return ((a.name or "")) < ((b.name or ""))
        end)
    end
    for g = 1, 8 do
        if byGroup[g] then sortGroup(byGroup[g]) end
    end
    sortGroup(unassigned)

    -- Split anchors: TOP-of-previous for vertical stacking, LEFT-of-
    -- header for a stable x column. Without the split, each row's
    -- TOPLEFT anchored to the previous row's BOTTOMLEFT at x = +12
    -- accumulates the offset down the list. The LEFT anchor pins
    -- every group heading to header.x and every member to
    -- header.x + 12, regardless of what came before.
    local last = header

    -- Class-balance warnings strip. Rendered above the group list
    -- when the comp has heuristic issues (no B-rez, no lust,
    -- low tank/healer count at mythic size, class stacking ≥4).
    -- Officer catches these at planning time instead of at the pull.
    local warnings = evaluateRaidCompBalance(assignments)
    if #warnings > 0 then
        local warnFs = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        warnFs:SetPoint("TOP", last, "BOTTOM", 0, -4)
        warnFs:SetPoint("LEFT", header, "LEFT", 0, 0)
        warnFs:SetPoint("RIGHT", content, "RIGHT", -4, 0)
        warnFs:SetJustifyH("LEFT")
        warnFs:SetWordWrap(true)
        warnFs:SetText("|cffffaa00\226\154\160 " ..
            table.concat(warnings, "  \194\183  ") .. "|r")
        last = warnFs
    end

    local function renderBucket(label, color, members)
        if #members == 0 then return end
        local groupFs = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        groupFs:SetPoint("TOP", last, "BOTTOM", 0, last == header and -6 or -4)
        groupFs:SetPoint("LEFT", header, "LEFT", 0, 0)
        groupFs:SetText(string.format("|c%s%s|r |cff888888(%d)|r",
            color, label, #members))
        last = groupFs

        for _, m in ipairs(members) do
            local nameStr   = m.name or m.playerName or m.characterName or "Unknown"
            local classFile = WGS:NormalizeClassFile(m.class or m.classFile or "")
            local colorHex  = WGS.CLASS_COLORS[classFile]

            local row = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row:SetPoint("TOP", last, "BOTTOM", 0, -2)
            row:SetPoint("LEFT", header, "LEFT", 12, 0)
            row:SetWidth(width - 12)
            row:SetJustifyH("LEFT")
            local text = colorHex and ("|c" .. colorHex .. nameStr .. "|r") or nameStr
            -- Role badge in front of the name so officers can scan
            -- "where are the healers" without re-reading each spec.
            local roleNorm = WGS:NormalizeRole(m.role)
            if roleNorm == "TANK" then
                text = "|cff5599ffT|r " .. text
            elseif roleNorm == "HEALER" then
                text = "|cff00ff00H|r " .. text
            elseif roleNorm == "DPS" then
                text = "|cffff4444D|r " .. text
            end
            if m.spec and m.spec ~= "" then
                text = text .. "  |cff888888" .. m.spec .. "|r"
            elseif m.note and m.note ~= "" then
                text = text .. "  |cff888888" .. m.note .. "|r"
            end
            row:SetText(text)
            last = row
        end
    end

    -- Group 1-8 in order, then any unassigned slots at the bottom.
    -- Group colors are subtle on purpose — the platform's comp
    -- builder doesn't colour groups, and a too-loud palette here
    -- would compete with class colours.
    for g = 1, 8 do
        if byGroup[g] and #byGroup[g] > 0 then
            renderBucket("Group " .. g, "ffffd100", byGroup[g])
        end
    end
    if #unassigned > 0 then
        renderBucket("Unassigned", "ff888888", unassigned)
    end

    -- Planned vs actual diff strip. Renders only when there's an
    -- in-flight session for the same event we're viewing — i.e. the
    -- officer is mid-raid AND opened the planned comp panel. The
    -- counts ("Planned 25 · In raid 22") and the gap names ("Missing:
    -- Alice (Group 1, Warlock); Subbed: Charlie") help the officer
    -- spot who hasn't joined yet OR who got swapped in without the
    -- platform-side comp being updated.
    local sessionMembers = WGS.GetCurrentSessionMembers and WGS:GetCurrentSessionMembers() or nil
    local ctx = WGS.GetCurrentAttendanceContext and WGS:GetCurrentAttendanceContext() or nil
    if sessionMembers and ctx and comp and ctx.eventId == (comp.eventId or comp.event_id) then
        local diff = buildCompDiff(assignments, sessionMembers)
        local summary = string.format(
            "|cffaaaaaaPlanned %d \194\183 In raid %d \194\183 Present %d|r",
            diff.planned, diff.actual, diff.present)
        local sumFs = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sumFs:SetPoint("TOP", last, "BOTTOM", 0, -6)
        sumFs:SetPoint("LEFT", header, "LEFT", 0, 0)
        sumFs:SetText(summary)
        last = sumFs

        if #diff.missing > 0 then
            local labels = {}
            for _, m in ipairs(diff.missing) do
                local short = (m.name or ""):match("^([^%-]+)") or m.name or "?"
                local classFile = WGS:NormalizeClassFile(m.class or "")
                local colorHex = WGS.CLASS_COLORS[classFile] or "ffffffff"
                labels[#labels + 1] = "|c" .. colorHex .. short .. "|r"
                    .. (m.group and (" |cff888888(G" .. m.group .. ")|r") or "")
            end
            local missFs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            missFs:SetPoint("TOP", last, "BOTTOM", 0, -2)
            missFs:SetPoint("LEFT", header, "LEFT", 12, 0)
            missFs:SetPoint("RIGHT", content, "RIGHT", -4, 0)
            missFs:SetJustifyH("LEFT")
            missFs:SetWordWrap(true)
            missFs:SetText("|cffff8888Missing:|r  " .. table.concat(labels, ", "))
            last = missFs
        end

        if #diff.extras > 0 then
            local labels = {}
            for _, m in ipairs(diff.extras) do
                local short = (m.name or ""):match("^([^%-]+)") or m.name or "?"
                local classFile = WGS:NormalizeClassFile(m.class or "")
                local colorHex = WGS.CLASS_COLORS[classFile] or "ffffffff"
                labels[#labels + 1] = "|c" .. colorHex .. short .. "|r"
            end
            local subFs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            subFs:SetPoint("TOP", last, "BOTTOM", 0, -2)
            subFs:SetPoint("LEFT", header, "LEFT", 12, 0)
            subFs:SetPoint("RIGHT", content, "RIGHT", -4, 0)
            subFs:SetJustifyH("LEFT")
            subFs:SetWordWrap(true)
            subFs:SetText("|cff88ff88Subbed in:|r  " .. table.concat(labels, ", "))
            last = subFs
        end
    end

    return last
end

---------------------------------------------------------------------------
-- Boss Notes section
--
-- Boss notes aren't linked to events in the data model (the platform
-- sends a flat list per guild), so the section surfaces the full list
-- as a wrapping row of clickable text buttons + a body font-string that
-- shows the selected note's strategy / assignments / MRT text. If the
-- user landed here via `/gh bossnotes <name>`, the requested name is
-- pre-selected via the frame's _selectedBoss field.
---------------------------------------------------------------------------

local function PopulateBossNotesSection(content, anchor, frame, width)
    local header = BuildSectionHeader(content, anchor, "Boss Notes", width)

    local list = WGS:GetBossNotesList()
    if #list == 0 then
        local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        empty:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
        empty:SetText("No boss notes imported.")
        return empty
    end

    -- Boss name picker: wrapping row of clickable text buttons. More
    -- compact than the standalone view's dropdown — the detail panel
    -- has limited vertical room and we don't want a click + open-popup
    -- before the body is visible.
    local pickerBar = CreateFrame("Frame", nil, content)
    pickerBar:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -6)
    pickerBar:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
    pickerBar:SetHeight(20)

    local selected = frame._selectedBoss
    if not selected or not list[1] then selected = list[1] end
    -- Ensure the chosen name actually exists in the current list
    -- (could be stale after a re-import).
    local present
    for _, n in ipairs(list) do if n == selected then present = true; break end end
    if not present then selected = list[1] end
    frame._selectedBoss = selected

    local xOff = 0
    for _, name in ipairs(list) do
        local btn = CreateFrame("Button", nil, pickerBar)
        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", btn, "LEFT", 4, 0)
        label:SetText(name)
        btn:SetSize(label:GetStringWidth() + 12, 18)
        btn:SetPoint("TOPLEFT", pickerBar, "TOPLEFT", xOff, 0)
        btn:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
        local hl = btn:GetHighlightTexture()
        if hl then hl:SetAlpha(0.3) end
        if name == selected then
            label:SetTextColor(1.00, 0.82, 0.00)
            local underline = btn:CreateTexture(nil, "ARTWORK")
            underline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 4, 0)
            underline:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -4, 0)
            underline:SetHeight(1)
            underline:SetColorTexture(1.00, 0.82, 0.00)
        else
            label:SetTextColor(0.75, 0.75, 0.75)
        end
        btn:SetScript("OnClick", function()
            frame._selectedBoss = name
            WGS:PopulateEvents(frame)
        end)
        xOff = xOff + btn:GetWidth() + 4
        if xOff > width - 80 then xOff = 0 end   -- crude wrap; rare case
    end

    -- Note body. Assembled inline (rather than reusing the standalone
    -- BossNotesFrame helper) so the detail panel doesn't resize itself
    -- to fit the note's height — the scroll frame handles overflow.
    local notes = WGS:GetBossNotes(selected)
    local mrt   = WGS.GetMRTNote and WGS:GetMRTNote() or nil
    local sections = {}
    if notes then
        if notes.strategy    then sections[#sections + 1] = "|cffffd100Strategy:|r\n"    .. notes.strategy end
        if notes.assignments then sections[#sections + 1] = "|cffffd100Assignments:|r\n" .. notes.assignments end
        if notes.notes       then sections[#sections + 1] = "|cffffd100Notes:|r\n"       .. notes.notes end
        if notes.videoUrl    then sections[#sections + 1] = "|cffffd100Video:|r "        .. notes.videoUrl end
    end
    if mrt then sections[#sections + 1] = "|cff66ccffMRT Note:|r\n" .. mrt end

    local body = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetPoint("TOPLEFT",  pickerBar, "BOTTOMLEFT",  4, -6)
    body:SetPoint("TOPRIGHT", pickerBar, "BOTTOMRIGHT", 0, -6)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetWordWrap(true)
    if #sections > 0 then
        body:SetText(table.concat(sections, "\n\n"))
    else
        body:SetText("|cff888888No notes for: " .. selected .. "|r")
    end

    return body
end

---------------------------------------------------------------------------
-- Sticky action-button footer
--
-- The footer Frame is built once in UI/Tabs/Events.lua's BuildEventsTab
-- and lives OUTSIDE the scroll area, so the four Invite/Share buttons
-- stay reachable regardless of how far down the user has scrolled.
-- Each render re-binds the OnClick closures to the currently-selected
-- event's roster + comp.
---------------------------------------------------------------------------

local function PopulateActionsFooter(footer, ev, roster, comp)
    if not footer then return end
    -- Wipe whatever was here for the previous selection.
    for _, child in ipairs({ footer:GetChildren() }) do child:Hide() end
    for _, region in ipairs({ footer:GetRegions() }) do region:Hide() end

    -- Buttons sit inside the detail half of the footer; the rail half
    -- (left of _buttonInsetLeft) stays empty so the buttons line up
    -- under the detail content rather than under the rail.
    local insetLeft = footer._buttonInsetLeft or 0
    local function actionBtn(label, x, w, onClick)
        local btn = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
        btn:SetSize(w, 24)
        btn:SetPoint("LEFT", footer, "LEFT", insetLeft + x, 0)
        btn:SetText(label)
        btn:SetScript("OnClick", onClick)
        return btn
    end

    -- Split-button Invite. Primary action (left chunk, 56px wide)
    -- runs AutoInvite excluding bench — semantic match for B = "available
    -- if needed, not actively going." A narrow arrow chunk (14px) on the
    -- right opens a MenuUtil dropdown with two overrides:
    --   - Invite signups + bench  → includeBench = true
    --   - Invite team roster      → sourceOverride = "roster"
    -- Total width stays 70px so the Share Roster button anchored at x=78
    -- doesn't have to move.
    local inviteMain = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
    inviteMain:SetSize(56, 24)
    inviteMain:SetPoint("LEFT", footer, "LEFT", insetLeft + 4, 0)
    inviteMain:SetText("Invite")
    inviteMain:SetScript("OnClick", function()
        if WGS.AutoInvite then WGS:AutoInvite(ev) end
    end)

    local inviteArrow = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
    inviteArrow:SetSize(14, 24)
    inviteArrow:SetPoint("LEFT", inviteMain, "RIGHT", 0, 0)
    inviteArrow:SetText("\194\187")   -- "»" rendered small
    inviteArrow:SetScript("OnClick", function()
        local menu = {
            { text = "More invite options",
              isTitle = true, notCheckable = true },
            { text = "Invite signups + bench",
              notCheckable = true,
              func = function()
                  if WGS.AutoInvite then WGS:AutoInvite(ev, { includeBench = true }) end
              end },
            { text = "Invite team roster",
              notCheckable = true,
              func = function()
                  if WGS.AutoInvite then WGS:AutoInvite(ev, { sourceOverride = "roster" }) end
              end },
        }
        ui.OpenContextMenu(menu)
    end)

    -- Track / Stop attendance. Scoped to the currently-selected event:
    -- starting via this button explicitly binds the session to `ev`,
    -- bypassing the FindActiveScheduledEvent auto-resolution (which is
    -- still what RAID_INSTANCE_WELCOME uses). Disabled when viewing a
    -- past event so officers can't accidentally start a session for a
    -- raid that already happened.
    local isTracking = WGS:IsTrackingAttendance()
    local statusText = ui.events.EventStatus and ui.events.EventStatus(ev, time()) or ""
    local isPast = (statusText == "Past")
    local trackBtn = actionBtn(isTracking and "Stop" or "Track", 410, 60, function()
        if WGS:IsTrackingAttendance() then
            WGS:StopAttendance()
        else
            local teamName = ev.team_id and WGS:GetTeamName(ev.team_id) or nil
            WGS:StartAttendanceForTeam(ev.team_id, teamName, ev)
        end
        -- Re-render the detail panel so the button label flips and
        -- the rest of the footer picks up the new state.
        if WGS.PopulateEvents then WGS:PopulateEvents(footer:GetParent()) end
    end)
    -- Disable on past events when (a) no session is in flight AND
    -- (b) we're not currently in a raid. The first guard stops officers
    -- accidentally creating a session for last week's raid from town;
    -- the IsInRaid() carve-out keeps the button usable mid-raid when
    -- EventStatus has already flipped to "Past" (raid started >3h ago,
    -- which is normal — 3.5-4h sessions are common) but the user
    -- legitimately needs to manually attach the session to this event.
    if isPast and not isTracking and not (IsInRaid and IsInRaid()) then
        trackBtn:Disable()
    end

    actionBtn("Share Roster", 78, 100, function()
        local channel = WGS:GetGroupChannel()
        if not channel then WGS:Print("Not in a group."); return end
        -- Group by status to match the platform's Discord embed
        -- layout — one labelled chunk per non-empty status.
        local byStatus = { P = {}, L = {}, T = {}, B = {} }
        for _, r in ipairs(roster.rows) do
            if byStatus[r.status] then
                byStatus[r.status][#byStatus[r.status] + 1] = r.short
            end
        end
        local SHARE_STATUS_ORDER = { "P", "L", "T", "B" }
        local anyShared = false
        for _, code in ipairs(SHARE_STATUS_ORDER) do
            if #byStatus[code] > 0 then
                if not anyShared then
                    WGS:SendChatLine("Roster for " .. (ev.title or "event") .. ":", channel)
                    anyShared = true
                end
                WGS:SendChatLine(string.format("%s (%d):",
                    STATUS_LABELS[code], #byStatus[code]), channel)
                WGS:SendChatChunked(WGS:PackChatTokens(byStatus[code]), channel)
            end
        end
        if not anyShared then
            WGS:Print("No signups to share yet.")
        end
    end)

    actionBtn("Share Gaps", 182, 100, function()
        local channel = WGS:GetGroupChannel()
        if not channel then WGS:Print("Not in a group."); return end
        local lines = {}
        for _, r in ipairs(roster.rows) do
            if (r.missingEnchants + r.missingGems) > 0 and COMMITTED_STATUSES[r.status] then
                local issues = {}
                if r.missingEnchants > 0 then issues[#issues + 1] = r.missingEnchants .. " enchant(s)" end
                if r.missingGems     > 0 then issues[#issues + 1] = r.missingGems     .. " gem(s)"     end
                lines[#lines + 1] = r.short .. ": missing " .. table.concat(issues, ", ")
            end
        end
        if #lines == 0 then
            WGS:Print("No gear gaps to announce — all committed players are ready.")
            return
        end
        WGS:SendChatLine("Pre-pull gear check for " .. (ev.title or "event") .. ":", channel)
        WGS:SendChatChunked(lines, channel)
    end)

    actionBtn("Share Comp", 286, 100, function()
        local channel = WGS:GetGroupChannel()
        if not channel then WGS:Print("Not in a group."); return end
        if not comp then
            WGS:Print("No comp planned for this event.")
            return
        end
        local assignments = comp.assignments or comp.members or {}
        local byRole = { TANK = {}, HEALER = {}, DPS = {} }
        for _, m in ipairs(assignments) do
            local role = WGS:NormalizeRole(m.role)
            byRole[role][#byRole[role] + 1] = m.name or m.playerName or "?"
        end
        WGS:SendChatLine("Raid Comp for " .. (ev.title or "event") .. ":", channel)
        for _, role in ipairs(ROLE_ORDER) do
            local names = byRole[role]
            if #names > 0 then
                WGS:SendChatLine(role .. " (" .. #names .. "):", channel)
                WGS:SendChatChunked(WGS:PackChatTokens(names), channel)
            end
        end
    end)
end

---------------------------------------------------------------------------
-- Detail panel orchestrator
--
-- Wired into the entry point in UI/EventsFrame.lua via
-- `ui.events.PopulateDetail`. Called once per render with the selected
-- event (or nil if nothing's selected) and the parent frame whose
-- detailContent / detailFooter fields it should populate.
---------------------------------------------------------------------------

local function PopulateDetail(frame, ev)
    local content = frame.detailContent
    for _, child in ipairs({ content:GetChildren() }) do child:Hide() end
    for _, region in ipairs({ content:GetRegions() }) do region:Hide() end

    if not ev then
        local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        empty:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -10)
        empty:SetText("Select an event from the list.")
        content:SetHeight(40)
        -- Clear any sticky-footer buttons from the previous selection
        -- so the user can't click stale Invite/Share when nothing is
        -- actually selected.
        if frame.detailFooter then
            for _, child in ipairs({ frame.detailFooter:GetChildren() }) do child:Hide() end
            for _, region in ipairs({ frame.detailFooter:GetRegions() }) do region:Hide() end
        end
        return
    end

    local sectionW = content:GetWidth() - 8

    -- Title (large)
    local title = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -4)
    title:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, -4)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetText(ev.title or "Untitled")

    -- Subline: date · time-range · team · status pill. EventStatus +
    -- FormatEventTime are stashed on ui.events by EventsFrame.lua so
    -- the rail row and this subline share the same formatting.
    local subline = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subline:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subline:SetPoint("TOPRIGHT", title, "BOTTOMRIGHT", 0, -4)
    subline:SetJustifyH("LEFT")
    subline:SetWordWrap(false)
    local statusText, statusColor = ui.events.EventStatus(ev, time())
    local parts = {}
    parts[#parts + 1] = "|cffffd100" .. (ev.date or "?") .. "|r"
    local timeStr = ui.events.FormatEventTime(ev)
    if timeStr then parts[#parts + 1] = "|cffaaaaaa" .. timeStr .. "|r" end
    if ev._teamName then parts[#parts + 1] = "|cffffd100" .. ev._teamName .. "|r" end
    parts[#parts + 1] = "|c" .. statusColor .. statusText .. "|r"
    subline:SetText(table.concat(parts, "  ·  "))

    local lastAnchor = subline

    -- Description, if any.
    if ev.description and ev.description ~= "" then
        local desc = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        desc:SetPoint("TOPLEFT", subline, "BOTTOMLEFT", 0, -6)
        desc:SetPoint("TOPRIGHT", subline, "BOTTOMRIGHT", 0, -6)
        desc:SetJustifyH("LEFT")
        desc:SetWordWrap(true)
        desc:SetText("|cffcccccc" .. ev.description .. "|r")
        lastAnchor = desc
    end

    local roster = BuildEventRoster(ev.id)
    lastAnchor = PopulateRosterSection(content, lastAnchor, roster, sectionW, frame)

    local comp = FindRaidCompForEvent(ev.id)
    lastAnchor = PopulateRaidCompSection(content, lastAnchor, comp, sectionW)

    -- Boss Notes is the last scrolling section — Actions used to be
    -- here too but moved to the sticky footer, so we don't keep the
    -- lastAnchor chain past this point.
    PopulateBossNotesSection(content, lastAnchor, frame, sectionW)

    PopulateActionsFooter(frame.detailFooter, ev, roster, comp)

    -- Grow the scroll content so the bottom of the last section is
    -- reachable. The action row lives in the sticky footer outside
    -- this scroll area so it's not part of the height budget.
    local approxHeight = 60
        + (#roster.rows * 19)
        + (comp and (40 + #(comp.assignments or comp.members or {}) * 18) or 30)
    content:SetHeight(approxHeight)
end

-- Expose to the entry point in UI/EventsFrame.lua. Load order doesn't
-- matter since this only resolves when PopulateEvents is called at
-- runtime (both scripts loaded by then).
ui.events.PopulateDetail = PopulateDetail
