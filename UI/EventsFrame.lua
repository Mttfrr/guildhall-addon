---@type GuildHall
local WGS = GuildHall

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

local RAIL_ROW_H = 38
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

-- Signup status → display group. The web platform's status codes:
--   P  Present (committed)        L  Late (committed)
--   LT Late tentative (committed) B  Bench (committed but benched)
--   T  Tentative                  A  Absent
local COMMITTED_STATUSES = { P = true, L = true, LT = true, B = true }
local STATUS_LABELS = {
    P = "Going", L = "Late", LT = "Late?", B = "Bench",
    T = "Tentative", A = "Absent",
}
local STATUS_LABEL_COLORS = {
    P = "ff00ff00", L = "ffffd100", LT = "ffffaa00", B = "ff888888",
    T = "ffaaaaaa", A = "ffff5555",
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
    if delta < -3 * 3600 then return "PAST", STATUS_COLORS.PAST end
    if delta < 86400 and ev.date == date("%Y-%m-%d", now) then
        return "TODAY", STATUS_COLORS.TODAY
    end
    if delta < 7 * 86400 then return "SOON", STATUS_COLORS.SOON end
    return "UPCOMING", STATUS_COLORS.UPCOMING
end

---------------------------------------------------------------------------
-- Rail rendering
---------------------------------------------------------------------------

-- One row in the left rail: date · title on the top line, status pill +
-- signup count on the bottom. Clicking selects the event and re-renders
-- the detail panel.
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

    -- Top line: date · time + title (truncated)
    local topLine = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    topLine:SetPoint("TOPLEFT", btn, "TOPLEFT", 6, -4)
    topLine:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -6, -4)
    topLine:SetJustifyH("LEFT")
    topLine:SetWordWrap(false)
    local dateStr = ev.date or "?"
    if ev.time then dateStr = dateStr .. " |cffaaaaaa" .. ev.time .. "|r" end
    topLine:SetText(dateStr)

    local titleLine = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    titleLine:SetPoint("TOPLEFT", topLine, "BOTTOMLEFT", 0, -2)
    titleLine:SetPoint("TOPRIGHT", topLine, "BOTTOMRIGHT", 0, -2)
    titleLine:SetJustifyH("LEFT")
    titleLine:SetWordWrap(false)
    titleLine:SetText("|cffffffff" .. (ev.title or "Untitled") .. "|r")

    -- Bottom line: status pill + signup count
    local statusText, statusColor = EventStatus(ev, time())
    local bottomLine = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bottomLine:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 6, 4)
    bottomLine:SetText("|c" .. statusColor .. statusText .. "|r")

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
-- so officers see "Foo-Realm — Going · 632 · 2 enchants missing" on
-- one line. This is the per-event replacement for the standalone
-- Readiness sub-view which walked the live raid instead.
local function BuildEventRoster(eventId)
    local out = { committedCount = 0, tentativeCount = 0, gearGapCount = 0, rows = {} }
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
            if COMMITTED_STATUSES[s.status] then
                out.committedCount = out.committedCount + 1
            elseif s.status == "T" then
                out.tentativeCount = out.tentativeCount + 1
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

-- Render the Roster section: one row per signup with class colour,
-- status badge, ilvl, missing-enchant + missing-gem counts. Sorted by
-- status group then name so committed players bubble to the top.
local function PopulateRosterSection(content, anchor, roster, width)
    local header = BuildSectionHeader(content, anchor, "Roster", width)

    -- Header summary line: "12 committed · 4 tentative · 3 with gear gaps".
    local summary = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("LEFT", header, "RIGHT", 12, 0)
    summary:SetText(string.format(
        "|cff00ff00%d|r committed · |cffaaaaaa%d|r tentative · |cffff5555%d|r gear gaps",
        roster.committedCount, roster.tentativeCount, roster.gearGapCount))

    if #roster.rows == 0 then
        local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        empty:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
        empty:SetText("No signups yet for this event.")
        return empty
    end

    -- Sort: committed first, then tentative, then absent; within each
    -- group, alphabetic by short name. Officers reading top-down see
    -- "who's in" first.
    local function statusBucket(s)
        if COMMITTED_STATUSES[s] then return 1 end
        if s == "T" then return 2 end
        return 3
    end
    table.sort(roster.rows, function(a, b)
        local ba, bb = statusBucket(a.status), statusBucket(b.status)
        if ba ~= bb then return ba < bb end
        return (a.short or "") < (b.short or "")
    end)

    local last = header
    for _, row in ipairs(roster.rows) do
        local r = CreateFrame("Frame", nil, content)
        r:SetSize(width, 16)
        r:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -3)
        r:SetPoint("TOPRIGHT", last == header and header or last, "BOTTOMRIGHT", 0, -3)

        -- Name (class-coloured)
        local classFile = WGS:NormalizeClassFile(row.class or "")
        local colorHex  = WGS.CLASS_COLORS[classFile] or "ffffffff"
        local nameFs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameFs:SetPoint("LEFT", r, "LEFT", 4, 0)
        nameFs:SetWidth(140)
        nameFs:SetJustifyH("LEFT")
        nameFs:SetText("|c" .. colorHex .. row.short .. "|r")

        -- Status badge
        local statusFs = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        statusFs:SetPoint("LEFT", nameFs, "RIGHT", 4, 0)
        statusFs:SetWidth(60)
        statusFs:SetText(string.format("|c%s%s|r",
            STATUS_LABEL_COLORS[row.status] or "ffaaaaaa",
            STATUS_LABELS[row.status] or row.status or "?"))

        -- iLvl
        local ilvlFs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        ilvlFs:SetPoint("LEFT", statusFs, "RIGHT", 4, 0)
        ilvlFs:SetWidth(36)
        ilvlFs:SetJustifyH("RIGHT")
        ilvlFs:SetText(row.ilvl > 0 and tostring(row.ilvl) or "|cff555555—|r")

        -- Gear-gap badges. Plain numbers (per the Teams tab convention)
        -- coloured red when non-zero so a glance shows which signups
        -- have something to fix before pull.
        local gapText = ""
        if row.missingEnchants > 0 then
            gapText = gapText .. "|cffff5555E" .. row.missingEnchants .. "|r "
        end
        if row.missingGems > 0 then
            gapText = gapText .. "|cffff5555G" .. row.missingGems .. "|r"
        end
        if gapText == "" then gapText = "|cff00ff00✓|r" end
        local gapFs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        gapFs:SetPoint("LEFT", ilvlFs, "RIGHT", 8, 0)
        gapFs:SetText(gapText)

        last = r
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
        local role = (m.role or "DPS"):upper()
        if not byRole[role] then role = "DPS" end
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

-- Build the four "Share" / "Invite" action buttons in a row below the
-- last section. Each button reuses an existing helper — Invite goes
-- through AutoInvite (already scoped to the next event), the three
-- share buttons funnel through WGS:SendChatLine + SendChatChunked so
-- the chat formatting stays consistent across the addon.
local function PopulateActionsRow(content, anchor, ev, roster, comp, width)
    local header = BuildSectionHeader(content, anchor, "Actions", width)

    local row = CreateFrame("Frame", nil, content)
    row:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -6)
    row:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
    row:SetHeight(26)

    local function actionBtn(label, x, w, onClick)
        local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        btn:SetSize(w, 24)
        btn:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
        btn:SetText(label)
        btn:SetScript("OnClick", onClick)
        return btn
    end

    actionBtn("Invite", 0, 70, function()
        if WGS.AutoInvite then WGS:AutoInvite() end
    end)

    actionBtn("Share Roster", 74, 100, function()
        local channel = WGS:GetGroupChannel()
        if not channel then WGS:Print("Not in a group."); return end
        local shorts = {}
        for _, r in ipairs(roster.rows) do
            if COMMITTED_STATUSES[r.status] then shorts[#shorts + 1] = r.short end
        end
        WGS:SendChatLine("Roster for " .. (ev.title or "event") .. " ("
            .. roster.committedCount .. " committed):", channel)
        WGS:SendChatChunked(WGS:PackChatTokens(shorts), channel)
    end)

    actionBtn("Share Gear Gaps", 178, 120, function()
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

    actionBtn("Share Comp", 302, 100, function()
        local channel = WGS:GetGroupChannel()
        if not channel then WGS:Print("Not in a group."); return end
        if not comp then
            WGS:Print("No comp planned for this event.")
            return
        end
        local assignments = comp.assignments or comp.members or {}
        local byRole = { TANK = {}, HEALER = {}, DPS = {} }
        for _, m in ipairs(assignments) do
            local role = (m.role or "DPS"):upper()
            if not byRole[role] then role = "DPS" end
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

    return row
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
    if ev.time then parts[#parts + 1] = "|cffaaaaaa" .. ev.time .. "|r" end
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

    -- Boss Notes section
    lastAnchor = PopulateBossNotesSection(content, lastAnchor, frame, sectionW)

    -- Actions row (Invite + three Share buttons)
    PopulateActionsRow(content, lastAnchor, ev, roster, comp, sectionW)

    -- Grow the scroll content so the bottom of the last section is
    -- reachable. We can't introspect every child's offset cleanly, so
    -- a generous fixed allowance (roster row × signups + comp rows)
    -- is fine — the scrollbar handles overflow either way.
    local approxHeight = 100
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
