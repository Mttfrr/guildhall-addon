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
-- Detail panel rendering
---------------------------------------------------------------------------

-- Phase 1 detail: header only (title, date, team, status pill, signup
-- summary). The Roster / Raid Comp / Boss Notes / Actions sections
-- land in later commits and slot in below the header.
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

    -- Signup summary (one line; the Roster section in a later commit
    -- will show the per-player list).
    local committed = ev._counts and ev._counts.committed or 0
    local tentative = ev._counts and ev._counts.tentative or 0
    local summary = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("TOPLEFT", subline, "BOTTOMLEFT", 0, -8)
    summary:SetText(string.format(
        "|cff00ff00%d|r committed   |cffaaaaaa%d|r tentative", committed, tentative))

    -- Description, if any. Truncated tooltips are gone — we now have
    -- room to show the full text in the detail panel.
    if ev.description and ev.description ~= "" then
        local desc = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        desc:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -10)
        desc:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, -52)
        desc:SetJustifyH("LEFT")
        desc:SetWordWrap(true)
        desc:SetText("|cffcccccc" .. ev.description .. "|r")
        content:SetHeight(120)
    else
        content:SetHeight(80)
    end
end

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

local function PopulateEvents(frame)
    -- Sanity: if the tab hasn't been built yet (old build entry was
    -- used), the rail/detail fields won't exist. Bail rather than
    -- error out.
    if not frame.railContent or not frame.detailContent then return end

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
