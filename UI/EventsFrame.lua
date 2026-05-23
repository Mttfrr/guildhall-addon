---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Events tab entry point + rail rendering. The detail panel (Roster /
-- Raid Comp / Boss Notes / Actions footer) lives in UI/EventsDetail.lua
-- and registers itself on `ui.events.PopulateDetail`; the orchestrator
-- below calls into it once per render.
--
-- Small helpers (EventStartTs, EventStatus, FormatEventTime) are stashed
-- on `ui.events` so the detail panel can reuse them for the subline.

ui.events = ui.events or {}

local RAIL_ROW_H = 50

-- Event time-bucket pill colors (rail row + detail subline). Unrelated
-- to signup status — these describe how soon the event is.
local STATUS_COLORS = {
    TODAY    = "ff00ff00",
    SOON     = "ffffd100",
    UPCOMING = "ff80c0ff",
    PAST     = "ff666666",
}

---------------------------------------------------------------------------
-- Small helpers used by both the rail and the detail panel
---------------------------------------------------------------------------

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

-- Format an event's time range. Returns "20:00" if only start is known,
-- "20:00–23:00" (en-dash) when end_time exists.
local function FormatEventTime(ev)
    if not ev.time or ev.time == "" then return nil end
    if ev.end_time and ev.end_time ~= "" then
        return ev.time .. "\226\128\147" .. ev.end_time
    end
    return ev.time
end

-- Stash the two formatters the detail panel needs so the cross-file
-- call site can resolve them at runtime.
ui.events.EventStatus     = EventStatus
ui.events.FormatEventTime = FormatEventTime

---------------------------------------------------------------------------
-- Rail rendering
---------------------------------------------------------------------------

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

    -- Top-right: status pill. Created before the date text so the date
    -- can anchor its right edge to the pill's left edge and avoid
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
-- Entry point — orchestrates rail + detail panel rendering
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

    -- Sort: date asc (next event on top). Rich sort/filter belongs on
    -- the platform; the rail is a fixed chronological list.
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
    if ui.events.PopulateDetail then
        ui.events.PopulateDetail(frame, selected)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function WGS:ToggleEventsFrame()
    self:SelectMainFrameTab(self._ui.TAB_EVENTS)
end

function WGS:PopulateEvents(container)
    PopulateEvents(container)
end
