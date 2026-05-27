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

local ROLE_ORDER  = { "TANK", "HEALER", "DPS" }
local ROLE_LABELS = {
    TANK   = "|cff5599ffTanks|r",
    HEALER = "|cff00ff00Healers|r",
    DPS    = "|cffff4444DPS|r",
}

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

                ui.AttachPlayerContextMenu(r,
                    function() return row.short end,
                    function() return classFile end)

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

    -- Split anchors: TOP-of-previous for vertical stacking, LEFT-of-
    -- header for a stable x column. Without the split, each row's
    -- TOPLEFT anchored to the previous row's BOTTOMLEFT at x = +12
    -- accumulates the offset down the list — Teraiz at header+12,
    -- Healers at Teraiz+0, Deconaga at Healers+12 = header+24,
    -- and so on until DPS members render four indents deep. The
    -- LEFT anchor pins every role heading to header.x and every
    -- member to header.x + 12, regardless of what came before.
    local last = header
    for _, role in ipairs(ROLE_ORDER) do
        local members = byRole[role]
        if #members > 0 then
            local roleFs = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            roleFs:SetPoint("TOP", last, "BOTTOM", 0, last == header and -6 or -4)
            roleFs:SetPoint("LEFT", header, "LEFT", 0, 0)
            roleFs:SetText((ROLE_LABELS[role] or role) .. " (" .. #members .. ")")
            last = roleFs

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

    actionBtn("Invite", 4, 70, function()
        if WGS.AutoInvite then WGS:AutoInvite() end
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
