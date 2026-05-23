---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

local ApplyClassIcon  = ui.ApplyClassIcon
local BuildNumericCell = ui.BuildNumericCell

-- Events tab render: master-detail. The rail (left, narrow) lists every
-- imported event sorted by start time; clicking a row loads that event
-- in the detail panel (right). The detail panel is the new home for
-- per-event Raid Comp, Roster + gear gaps, Boss Notes, and the share
-- action buttons — replacing the standalone Raids → Raid Comp and
-- Raids → Readiness sub-views.
--
-- Phase 1 of the restructure: rail rendering + detail-header only. The
-- detail sections (Roster, Raid Comp, Boss Notes, Actions) land in
-- later commits.

local RAIL_ROW_H = 50
local STATUS_COLORS = {
    TODAY    = "ff00ff00",
    SOON     = "ffffd100",
    UPCOMING = "ff80c0ff",
    PAST     = "ff666666",
}

local ROLE_ORDER  = { "TANK", "HEALER", "DPS" }
local ROLE_LABELS = {
    TANK   = "|cff5599ffTanks|r",
    HEALER = "|cff00ff00Healers|r",
    DPS    = "|cffff4444DPS|r",
}

-- Signup status → display group. The full set is mirrored from the
-- platform's ATTENDANCE_STATUSES (client/src/utils.js); label strings
-- are kept verbatim so chat-announce + UI rows read the same here as
-- they do on the website + in the Discord embed.
--
--   P   Present (committed)            L   Late (committed)
--   LT  Late (officer) (committed)     B   Bench (committed)
--   T   Tentative                      A   Absent
--   LE  Left early (tier-2; addon-                RM  Replaced mid-raid (tier-2)
--       rarely produces this, but we surface it if it lands)
local COMMITTED_STATUSES = { P = true, L = true, LT = true, B = true }
local STATUS_LABELS = {
    P  = "Present",
    L  = "Late",
    LT = "Late (officer)",
    B  = "Bench",
    T  = "Tentative",
    A  = "Absent",
    LE = "Left early",
    RM = "Replaced mid-raid",
}
local STATUS_LABEL_COLORS = {
    P  = "ff00ff00", L  = "ffffd100", LT = "ffffaa00", B = "ff888888",
    T  = "ffaaaaaa", A  = "ffff5555",
    LE = "ffff8800", RM = "ff66ccff",
}

-- Local copies of the small helpers from the old table renderer.
-- BuildSignupCounts walks db.global.signups once per refresh; cheap
-- enough at typical guild sizes (a few hundred rows).
local function BuildSignupCounts()
    local out = {}
    local signups = WGS.db.global.signups
    if type(signups) ~= "table" then return out end
    for _, s in ipairs(signups) do
        local id = s.eventId
        if id then
            local b = out[id]
            if not b then b = { committed = 0, tentative = 0 }; out[id] = b end
            local st = s.status
            if st == "T" then
                b.tentative = b.tentative + 1
            elseif st == "P" or st == "L" or st == "LT" or st == "B" then
                b.committed = b.committed + 1
            end
        end
    end
    return out
end

local function TeamNameById(teamId)
    if not teamId then return nil end
    local teams = WGS.db.global.teams
    if type(teams) ~= "table" then return nil end
    for _, t in ipairs(teams) do
        if t.id == teamId then return t.name end
    end
    return nil
end

local function EventStartTs(ev)
    local y, mo, d = (ev.date or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return 0 end
    local h, mi = (ev.time or "00:00"):match("^(%d%d):(%d%d)$")
    return time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h or 0), min = tonumber(mi or 0), sec = 0,
    })
end

local function EventStatus(ev, now)
    local startTs = EventStartTs(ev)
    if startTs == 0 then return "?", "ff888888" end
    local delta = startTs - now
    -- Mixed-case strings to match the platform's section/tab labels
    -- ("Upcoming", "Past"). The all-caps form was addon-only invention
    -- and read as shoutier than the rest of the UI.
    if delta < -3 * 3600 then return "Past", STATUS_COLORS.PAST end
    if delta < 86400 and ev.date == date("%Y-%m-%d", now) then
        return "Today", STATUS_COLORS.TODAY
    end
    if delta < 7 * 86400 then return "Soon", STATUS_COLORS.SOON end
    return "Upcoming", STATUS_COLORS.UPCOMING
end

---------------------------------------------------------------------------
-- Rail rendering
---------------------------------------------------------------------------

-- Format an event's time range. Returns "20:00" if only start is known,
-- "20:00–23:00" (en-dash) when end_time exists.
local function FormatEventTime(ev)
    if not ev.time or ev.time == "" then return nil end
    if ev.end_time and ev.end_time ~= "" then
        return ev.time .. "\226\128\147" .. ev.end_time
    end
    return ev.time
end

-- One row in the left rail. Vertical layout:
--   row 1 (top):    date + time-range (left)   ·   status pill (right)
--   row 2 (middle): title (full width, truncated)
--   row 3 (bottom): signup count (right)
-- Status moved off the bottom line so it doesn't crowd the title; the
-- title gets dedicated breathing room between the two metadata rows.
-- Clicking selects the event and re-renders the detail panel.
local function BuildRailRow(parent, ev, yOff, isSelected, onSelect)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(parent:GetWidth(), RAIL_ROW_H)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOff)

    -- Selection background. Same hue as the active sub-nav underline
    -- (gold) so the selected row reads as "this is what the panel is
    -- showing right now".
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(btn)
    if isSelected then
        bg:SetColorTexture(1.00, 0.82, 0.00, 0.12)
    else
        bg:SetColorTexture(1, 1, 1, 0.025)
    end

    btn:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    local hl = btn:GetHighlightTexture()
    if hl then hl:SetAlpha(0.25) end

    -- Top-right: status pill (was crowding the title on the bottom row
    -- with only 2 px of vertical separation — moved up here to give the
    -- title its own clean line). Created before the date text so the
    -- date can anchor its right edge to the pill's left edge and avoid
    -- overlapping when end_time is included (e.g. "15:00–18:00" eats
    -- most of the row, the pill used to overwrite it).
    local statusText, statusColor = EventStatus(ev, time())
    local statusPill = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusPill:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -6, -4)
    statusPill:SetText("|c" .. statusColor .. statusText .. "|r")

    -- Top-left: date + time range. Clamped left of the status pill so
    -- they can't overlap on long time-ranges.
    local dateText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dateText:SetPoint("TOPLEFT",  btn, "TOPLEFT",  6, -4)
    dateText:SetPoint("TOPRIGHT", statusPill, "TOPLEFT", -6, 0)
    dateText:SetJustifyH("LEFT")
    dateText:SetWordWrap(false)
    local dateStr = ev.date or "?"
    local timeStr = FormatEventTime(ev)
    if timeStr then dateStr = dateStr .. " |cffaaaaaa" .. timeStr .. "|r" end
    dateText:SetText(dateStr)

    -- Middle: title (with breathing room above and below)
    local titleLine = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    titleLine:SetPoint("TOPLEFT", dateText, "BOTTOMLEFT", 0, -6)
    titleLine:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -6, -6 - dateText:GetStringHeight())
    titleLine:SetJustifyH("LEFT")
    titleLine:SetWordWrap(false)
    titleLine:SetText("|cffffffff" .. (ev.title or "Untitled") .. "|r")

    -- Bottom-right: signup count (status moved off this row).
    if ev._counts and (ev._counts.committed + ev._counts.tentative) > 0 then
        local signupText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        signupText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -6, 4)
        signupText:SetText("|cffaaaaaa" .. ev._counts.committed
            .. (ev._counts.tentative > 0 and (" / " .. ev._counts.tentative .. "?") or "")
            .. "|r")
    end

    btn:SetScript("OnClick", function() onSelect(ev) end)
    return btn
end

local function PopulateRail(frame, decoratedEvents, selectedId)
    local content = frame.railContent
    for _, child in ipairs({ content:GetChildren() }) do child:Hide() end
    for _, region in ipairs({ content:GetRegions() }) do region:Hide() end

    if #decoratedEvents == 0 then
        local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        empty:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -10)
        empty:SetText("No events imported.")
        content:SetHeight(40)
        return
    end

    local yOff = 0
    for _, ev in ipairs(decoratedEvents) do
        BuildRailRow(content, ev, yOff, ev.id == selectedId, function(picked)
            frame._selectedEventId = picked.id
            WGS:PopulateEvents(frame)
        end)
        yOff = yOff - RAIL_ROW_H - 2
    end
    content:SetHeight(math.abs(yOff) + 10)
end

---------------------------------------------------------------------------
-- Detail panel sections
---------------------------------------------------------------------------

-- Build the per-signup row list for an event. Each row pairs the
-- signup status with the character's gear summary from characterDetails
-- so officers see "Foo-Realm — Present · 632 · 2 enchants missing" on
-- one line. This is the per-event replacement for the standalone
-- Readiness sub-view which walked the live raid instead.
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

-- Pulls the raid comp for `eventId` from db.global.raidComps. The
-- comp shape is normalised on import to { eventId, name, assignments }
-- (see Modules/Import.lua). Returns nil if no comp exists for this
-- event, in which case the section just renders "No comp planned".
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

-- Order in which the per-status groups render. Mirrors the Discord
-- embed's field order so the addon and the web embed read in the same
-- sequence (Present → Late → Late(officer) → Bench → Tentative →
-- Absent → tier-2 codes). Empty groups are skipped at render time.
local ROSTER_GROUP_ORDER = { "P", "L", "LT", "B", "T", "A", "LE", "RM" }

-- Render the Roster section. Layout, top to bottom:
--   Section title + "N gear gaps" summary on the same line
--   Column headers (iLvl / Enchants / Gems) right-aligned, dimmed
--   For each non-empty status group:
--     Status group header in the status color ("Present (18)")
--     Indented data rows: [class icon] Name … iLvl Ench Gems
--
-- The per-row status column was dropped — it just repeated the same
-- word ("Present") 15-20 times per row, where the Discord embed has
-- one group header per status. Numeric columns now right-anchor so
-- they reach the right edge of the section instead of dangling in the
-- middle.
local function PopulateRosterSection(content, anchor, roster, width)
    local header = BuildSectionHeader(content, anchor, "Roster", width)

    -- Inline summary on the section-title row: gear-gap total only.
    -- Per-status counts moved into the group headers below to remove
    -- the duplication.
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

    -- Bucket rows by status code; sort within each by short name.
    local byStatus = {}
    for _, code in ipairs(ROSTER_GROUP_ORDER) do byStatus[code] = {} end
    for _, row in ipairs(roster.rows) do
        local bucket = byStatus[row.status]
        if bucket then bucket[#bucket + 1] = row end
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
    columnHdr:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    columnHdr:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -4)

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
                local r = CreateFrame("Frame", nil, content)
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

                BuildNumericCell(r, COL_ILVL_X, 0, NUM_W, ROW_H, row.ilvl, false)
                BuildNumericCell(r, COL_ENCH_X, 0, NUM_W, ROW_H, row.missingEnchants, true)
                BuildNumericCell(r, COL_GEMS_X, 0, NUM_W, ROW_H, row.missingGems, true)

                last = r
            end
        end
    end

    return last
end

-- Render the Raid Comp section: assignments grouped by role, mirroring
-- the old standalone Raid Comp sub-view. Returns the bottom widget so
-- the next section anchors to it.
local function PopulateRaidCompSection(content, anchor, comp, width)
    local header = BuildSectionHeader(content, anchor, "Raid Comp", width)

    if not comp then
        local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        empty:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
        empty:SetText("No comp planned for this event.")
        return empty
    end

    -- Group assignments by role.
    local assignments = comp.assignments or comp.members or {}
    local byRole = { TANK = {}, HEALER = {}, DPS = {} }
    for _, m in ipairs(assignments) do
        local role = WGS:NormalizeRole(m.role)
        byRole[role][#byRole[role] + 1] = m
    end

    local last = header
    for _, role in ipairs(ROLE_ORDER) do
        local members = byRole[role]
        if #members > 0 then
            local roleFs = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            roleFs:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, last == header and -6 or -4)
            roleFs:SetText((ROLE_LABELS[role] or role) .. " (" .. #members .. ")")
            last = roleFs

            for _, m in ipairs(members) do
                local nameStr   = m.name or m.playerName or m.characterName or "Unknown"
                local classFile = WGS:NormalizeClassFile(m.class or m.classFile or "")
                local colorHex  = WGS.CLASS_COLORS[classFile]

                local row = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 12, -2)
                row:SetWidth(width - 12)
                row:SetJustifyH("LEFT")
                local text = colorHex and ("|c" .. colorHex .. nameStr .. "|r") or nameStr
                if m.spec and m.spec ~= "" then
                    text = text .. "  |cff888888" .. m.spec .. "|r"
                elseif m.note and m.note ~= "" then
                    text = text .. "  |cff888888" .. m.note .. "|r"
                end
                row:SetText(text)
                last = row
            end
        end
    end

    return last
end

-- Render the Boss Notes section. Boss notes aren't linked to events in
-- the data model (the platform sends a flat list per guild), so the
-- section surfaces the full list as a button row + a body font-string
-- that shows the selected note's strategy/assignments/MRT text. If
-- the user landed here via `/gh bossnotes <name>`, the requested name
-- is pre-selected via the frame's _selectedBoss field.
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
    -- already has limited vertical room and we don't want a click +
    -- open-popup before the body is visible.
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
        -- Wrap at the section width
        if xOff > width - 80 then xOff = 0 end   -- crude wrap; rare case
    end

    -- Note body. Replicates PopulateBossNotes's section assembly (we
    -- don't reuse the helper directly because it expects a container
    -- with .content and .noteText fields, which would force the whole
    -- detail panel to resize to the note's height).
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

-- Populate the sticky footer at the bottom of the detail panel with the
-- four "Share" / "Invite" action buttons scoped to `ev`. The footer
-- frame lives outside the scroll area (built once in UI/Tabs/Events.lua's
-- BuildEventsTab) so the buttons stay reachable no matter how far down
-- the user has scrolled.
--
-- Invite goes through AutoInvite (already scoped to the next event);
-- the three share buttons funnel through WGS:SendChatLine +
-- SendChatChunked so the chat formatting stays consistent across the
-- addon.
local function PopulateActionsFooter(footer, ev, roster, comp)
    if not footer then return end
    -- Wipe whatever was here for the previous selection.
    for _, child in ipairs({ footer:GetChildren() }) do child:Hide() end
    for _, region in ipairs({ footer:GetRegions() }) do region:Hide() end

    -- Buttons sit inside the detail half of the footer; the rail half
    -- (left of _buttonInsetLeft) stays empty so the buttons line up
    -- under the detail content rather than under the rail. Falls back
    -- to 0 if the inset wasn't stashed (defensive, shouldn't happen).
    local insetLeft = footer._buttonInsetLeft or 0
    local function actionBtn(label, x, w, onClick)
        local btn = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
        btn:SetSize(w, 24)
        btn:SetPoint("LEFT", footer, "LEFT", insetLeft + x, 0)
        btn:SetText(label)
        btn:SetScript("OnClick", onClick)
        return btn
    end

    actionBtn("Invite", 4, 70, function()
        if WGS.AutoInvite then WGS:AutoInvite() end
    end)

    actionBtn("Share Roster", 78, 100, function()
        local channel = WGS:GetGroupChannel()
        if not channel then WGS:Print("Not in a group."); return end
        -- Group by status to match the platform's Discord embed
        -- layout — one line per non-empty status (Present / Late /
        -- Tentative / Bench) so raiders can see who's in what bucket
        -- at a glance, instead of one flat "N committed" header.
        local byStatus = { P = {}, L = {}, T = {}, B = {} }
        for _, r in ipairs(roster.rows) do
            if byStatus[r.status] then
                byStatus[r.status][#byStatus[r.status] + 1] = r.short
            end
        end
        local ROSTER_STATUS_ORDER = { "P", "L", "T", "B" }
        local anyShared = false
        for _, code in ipairs(ROSTER_STATUS_ORDER) do
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

    actionBtn("Share Gear Gaps", 182, 120, function()
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

    actionBtn("Share Comp", 306, 100, function()
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
-- Detail panel rendering
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
        -- so the user can't click stale Invite/Share when nothing's
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

    -- Subline: date · time · team · status pill
    local subline = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subline:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subline:SetPoint("TOPRIGHT", title, "BOTTOMRIGHT", 0, -4)
    subline:SetJustifyH("LEFT")
    subline:SetWordWrap(false)
    local statusText, statusColor = EventStatus(ev, time())
    local parts = {}
    parts[#parts + 1] = "|cffffd100" .. (ev.date or "?") .. "|r"
    local timeStr = FormatEventTime(ev)
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

    -- Roster section
    local roster = BuildEventRoster(ev.id)
    lastAnchor = PopulateRosterSection(content, lastAnchor, roster, sectionW)

    -- Raid Comp section
    local comp = FindRaidCompForEvent(ev.id)
    lastAnchor = PopulateRaidCompSection(content, lastAnchor, comp, sectionW)

    -- Boss Notes section. Last scrolling section — Actions used to be
    -- here too but moved to the sticky footer, so we don't need to keep
    -- the lastAnchor chain past this point.
    PopulateBossNotesSection(content, lastAnchor, frame, sectionW)

    -- Actions row (Invite + three Share buttons) renders into the
    -- persistent footer outside the scroll frame, so it stays visible
    -- regardless of how far down the user has scrolled.
    PopulateActionsFooter(frame.detailFooter, ev, roster, comp)

    -- Grow the scroll content so the bottom of the last section is
    -- reachable. We can't introspect every child's offset cleanly, so
    -- a generous fixed allowance (roster row × signups + comp rows)
    -- is fine — the scrollbar handles overflow either way. The action
    -- row's height is no longer accounted for here since it lives in
    -- the sticky footer outside this scroll area.
    local approxHeight = 60
        + (#roster.rows * 19)
        + (comp and (40 + #(comp.assignments or comp.members or {}) * 18) or 30)
    content:SetHeight(approxHeight)
end

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

local function PopulateEvents(frame)
    -- Sanity: if the tab hasn't been built yet (old build entry was
    -- used), the rail/detail fields won't exist. Bail rather than
    -- error out.
    if not frame.railContent or not frame.detailContent then return end

    -- Cross-module hand-off: /gh bossnotes <name> stashes the boss
    -- name on WGS before switching to this tab. Adopt it once on
    -- render and clear so subsequent refreshes don't keep re-applying
    -- a stale selection.
    if WGS._pendingBossNoteSelection then
        frame._selectedBoss = WGS._pendingBossNoteSelection
        WGS._pendingBossNoteSelection = nil
    end

    local events = WGS.db.global.events or {}

    -- Apply the global current-team filter (if set). nil = "All Teams".
    -- We filter the source list before decoration so the counts/sort
    -- arrays don't carry rows we won't render anyway.
    local currentTeamId = WGS.GetCurrentTeamId and WGS:GetCurrentTeamId() or nil
    if currentTeamId then
        local filtered = {}
        for _, ev in ipairs(events) do
            if ev.team_id == currentTeamId then
                filtered[#filtered + 1] = ev
            end
        end
        events = filtered
    end

    -- Decorate each event with derived fields so the rail + detail
    -- don't have to compute them twice.
    local counts = BuildSignupCounts()
    local decorated = {}
    for _, ev in ipairs(events) do
        decorated[#decorated + 1] = setmetatable({
            _startTs  = EventStartTs(ev),
            _teamName = TeamNameById(ev.team_id),
            _counts   = counts[ev.id] or { committed = 0, tentative = 0 },
        }, { __index = ev })
    end

    -- Sort: date asc (next event on top). The full sortable-table UX
    -- the previous renderer offered is dropped — the rail is a fixed
    -- chronological list, and rich sort/filter belongs on the platform.
    table.sort(decorated, function(a, b) return (a._startTs or 0) < (b._startTs or 0) end)

    -- Pick a default selection on first render: the first non-past
    -- event, or the first event if everything's in the past.
    local now = time()
    if not frame._selectedEventId and #decorated > 0 then
        for _, ev in ipairs(decorated) do
            if (ev._startTs or 0) >= now - 3 * 3600 then
                frame._selectedEventId = ev.id
                break
            end
        end
        if not frame._selectedEventId then
            frame._selectedEventId = decorated[1].id
        end
    end

    -- Resolve the selected event (if it's been removed from import,
    -- fall back to the first one).
    local selected
    for _, ev in ipairs(decorated) do
        if ev.id == frame._selectedEventId then selected = ev; break end
    end
    if not selected and #decorated > 0 then
        selected = decorated[1]
        frame._selectedEventId = selected.id
    end

    PopulateRail(frame, decorated, frame._selectedEventId)
    PopulateDetail(frame, selected)
end

function WGS:ToggleEventsFrame()
    self:SelectMainFrameTab(self._ui.TAB_EVENTS)
end

function WGS:PopulateEvents(container)
    PopulateEvents(container)
end
