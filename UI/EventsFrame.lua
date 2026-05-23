---@type GuildHall
local WGS = GuildHall

-- Events tab: sortable table of imported events. Mirrors the
-- table pattern from UI/Tabs/Teams.lua so the two surfaces feel
-- consistent. Replaces the old prose-y row layout that wrote out
-- date/time/title/type/description as stacked text — the new shape
-- adds a Signups count (joined from db.global.signups) and a status
-- pill (TODAY / SOON / UPCOMING / PAST) which were the actual
-- decisions raid leaders make on this page.
--
-- Columns:
--   Date · Time | Title | Type | Team | Signups | Status
--
-- Click any column header to sort by it. Click again to flip
-- direction. Default sort = date asc (next event first).

local CONTENT_W = 660
local HEADER_H  = 22
local ROW_H     = 22

local COL = {
    DATE    = { x = 10,  w = 130, label = "Date · Time" },
    TITLE   = { x = 140, w = 200, label = "Title"       },
    TYPE    = { x = 340, w = 70,  label = "Type"        },
    TEAM    = { x = 410, w = 90,  label = "Team"        },
    SIGNUPS = { x = 500, w = 70,  label = "Signups"     },
    STATUS  = { x = 570, w = 90,  label = "Status"      },
}

local SORT_ARROW_TEX = "Interface\\Buttons\\UI-SortArrow"

-- A column-header button. Mirrors UI/Tabs/Teams.lua's BuildHeaderCell;
-- duplicated rather than shared because the two tabs have slightly
-- different column geometries and the helper is only ~25 lines.
local function BuildHeaderCell(parent, col, key, sortKey, sortDir, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(col.w, HEADER_H)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", col.x, 0)
    btn:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    local hl = btn:GetHighlightTexture()
    if hl then hl:SetAlpha(0.3) end

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", btn, "LEFT", 6, 0)
    label:SetText(col.label)
    if sortKey == key then
        label:SetTextColor(1.00, 0.82, 0.00)
    else
        label:SetTextColor(0.85, 0.85, 0.85)
    end

    if sortKey == key then
        local arrow = btn:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(10, 10)
        arrow:SetPoint("LEFT", label, "RIGHT", 4, 0)
        arrow:SetTexture(SORT_ARROW_TEX)
        if sortDir == "asc" then
            arrow:SetTexCoord(0, 1, 1, 0)   -- flip default-desc to point up
        end
    end

    btn:SetScript("OnClick", function() onClick(key) end)
    return btn
end

-- Count signups per event, bucketed by status. Returns
-- { [eventId] = { committed = N, tentative = N } }
-- where committed = P/L/LT/B (people who are coming or warming a bench)
-- and tentative = T (interested but not promised).
--
-- Walks db.global.signups once per render — cheap enough at typical
-- guild sizes (a few hundred rows at most).
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

-- Resolve a team_id to its display name via db.global.teams. Returns
-- nil if not found (unaffiliated event); callers render an em-dash.
local function TeamNameById(teamId)
    if not teamId then return nil end
    local teams = WGS.db.global.teams
    if type(teams) ~= "table" then return nil end
    for _, t in ipairs(teams) do
        if t.id == teamId then return t.name end
    end
    return nil
end

-- Parse an event's "date" (yyyy-mm-dd) and optional "time" (HH:MM) into
-- a unix timestamp for status comparison. Uses os.date to assemble the
-- table; if the strings don't match the expected shape, returns 0 so
-- the row sorts to the top and the status reads as PAST.
local function EventStartTs(ev)
    local y, mo, d = (ev.date or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return 0 end
    local h, mi = (ev.time or "00:00"):match("^(%d%d):(%d%d)$")
    return time({
        year  = tonumber(y),
        month = tonumber(mo),
        day   = tonumber(d),
        hour  = tonumber(h or 0),
        min   = tonumber(mi or 0),
        sec   = 0,
    })
end

-- Status pill text + colour. The three meaningful states for a raid
-- leader skimming the page are "tonight", "soon" (this week), and
-- "later" — past events come along if /reload happened after the
-- night ran but before the next import.
local function EventStatus(ev, now)
    local startTs = EventStartTs(ev)
    if startTs == 0 then return "?", "ff888888" end
    local delta = startTs - now
    if delta < -3 * 3600 then return "PAST", "ff666666" end
    if delta < 86400 and ev.date == date("%Y-%m-%d", now) then
        return "TODAY", "ff00ff00"
    end
    if delta < 7 * 86400 then return "SOON", "ffffd100" end
    return "UPCOMING", "ff80c0ff"
end

-- Sort comparators keyed by column. Each returns true if `a` should
-- come before `b`. asc/desc is applied by swapping args at the call
-- site; here we just define "ascending = natural" for each column.
local function CompareEvents(key)
    if key == "date" then
        return function(a, b) return (a._startTs or 0) < (b._startTs or 0) end
    elseif key == "title" then
        return function(a, b) return (a.title or "") < (b.title or "") end
    elseif key == "type" then
        return function(a, b) return (a.type or "") < (b.type or "") end
    elseif key == "team" then
        return function(a, b) return (a._teamName or "") < (b._teamName or "") end
    elseif key == "signups" then
        return function(a, b)
            local ac = (a._counts and a._counts.committed) or 0
            local bc = (b._counts and b._counts.committed) or 0
            return ac < bc
        end
    elseif key == "status" then
        -- Surface upcoming first by ordering on start time again
        return function(a, b) return (a._startTs or 0) < (b._startTs or 0) end
    end
    return function() return false end
end

local function PopulateEvents(frame)
    -- Tear down anything from a prior render. Same pattern as Teams.lua —
    -- we don't pool widgets; recreating them on each refresh is fast
    -- enough at typical event counts (≤20 from the platform query).
    local children = { frame.content:GetChildren() }
    for _, child in ipairs(children) do child:Hide() end
    local regions = { frame.content:GetRegions() }
    for _, region in ipairs(regions) do region:Hide() end

    local events = WGS.db.global.events
    if not events or #events == 0 then
        local noData = frame.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 5, -10)
        noData:SetText("No events imported. Import from the web app first.")
        noData:Show()
        frame.content:SetHeight(40)
        return
    end

    -- Decorate each event with derived fields so the sort comparators
    -- don't have to look them up per-comparison (n log n calls would
    -- otherwise spam the signup-count walk).
    local counts = BuildSignupCounts()
    local now    = time()
    local rows = {}
    for _, ev in ipairs(events) do
        rows[#rows + 1] = setmetatable({
            _startTs   = EventStartTs(ev),
            _teamName  = TeamNameById(ev.team_id),
            _counts    = counts[ev.id] or { committed = 0, tentative = 0 },
        }, { __index = ev })
    end

    -- Per-tab sort state. Default: date asc (next event first).
    local sortKey = frame._sortKey or "date"
    local sortDir = frame._sortDir or "asc"
    local function setSort(key)
        if frame._sortKey == key then
            frame._sortDir = (frame._sortDir == "asc") and "desc" or "asc"
        else
            frame._sortKey = key
            -- Non-date columns default to desc (highest first) since
            -- e.g. "sort by signups" almost always means "most signups".
            frame._sortDir = (key == "date" or key == "title" or key == "team" or key == "type") and "asc" or "desc"
        end
        PopulateEvents(frame)
    end

    local cmp = CompareEvents(sortKey)
    table.sort(rows, function(a, b)
        if sortDir == "asc" then return cmp(a, b) else return cmp(b, a) end
    end)

    -- Headers
    local header = CreateFrame("Frame", nil, frame.content)
    header:SetSize(CONTENT_W, HEADER_H)
    header:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, 0)
    BuildHeaderCell(header, COL.DATE,    "date",    sortKey, sortDir, setSort)
    BuildHeaderCell(header, COL.TITLE,   "title",   sortKey, sortDir, setSort)
    BuildHeaderCell(header, COL.TYPE,    "type",    sortKey, sortDir, setSort)
    BuildHeaderCell(header, COL.TEAM,    "team",    sortKey, sortDir, setSort)
    BuildHeaderCell(header, COL.SIGNUPS, "signups", sortKey, sortDir, setSort)
    BuildHeaderCell(header, COL.STATUS,  "status",  sortKey, sortDir, setSort)

    local yOff = -HEADER_H - 2
    for idx, row in ipairs(rows) do
        local r = CreateFrame("Frame", nil, frame.content)
        r:SetSize(CONTENT_W, ROW_H)
        r:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, yOff)

        -- Zebra stripe for readability
        if idx % 2 == 0 then
            local bg = r:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(r)
            bg:SetColorTexture(1, 1, 1, 0.025)
        end

        -- Date · Time
        local dateFs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        dateFs:SetPoint("LEFT", r, "LEFT", COL.DATE.x, 0)
        local dateStr = row.date or "?"
        if row.time then
            dateStr = dateStr .. " |cffaaaaaa" .. row.time .. "|r"
        end
        dateFs:SetText(dateStr)

        -- Title
        local titleFs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        titleFs:SetPoint("LEFT", r, "LEFT", COL.TITLE.x, 0)
        titleFs:SetWidth(COL.TITLE.w - 8)
        titleFs:SetJustifyH("LEFT")
        titleFs:SetWordWrap(false)
        titleFs:SetText(row.title or "Untitled")

        -- Type
        local typeFs = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        typeFs:SetPoint("LEFT", r, "LEFT", COL.TYPE.x, 0)
        typeFs:SetText("|cff888888" .. (row.type or "—") .. "|r")

        -- Team
        local teamFs = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        teamFs:SetPoint("LEFT", r, "LEFT", COL.TEAM.x, 0)
        teamFs:SetText(row._teamName and ("|cffffd100" .. row._teamName .. "|r") or "|cff555555—|r")

        -- Signups: "18 ✓ / 4 ?" with the committed count coloured by
        -- a 20-raider rule of thumb (green ≥20, orange ≥14, red below).
        local committed = row._counts.committed
        local tentative = row._counts.tentative
        local cColor
        if committed >= 20 then       cColor = "ff00ff00"
        elseif committed >= 14 then   cColor = "ffffaa00"
        else                          cColor = "ffff5555" end
        local signupFs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        signupFs:SetPoint("LEFT", r, "LEFT", COL.SIGNUPS.x, 0)
        local txt = "|c" .. cColor .. committed .. "|r"
        if tentative > 0 then
            txt = txt .. " |cff888888/ " .. tentative .. " ?|r"
        end
        signupFs:SetText(txt)

        -- Status pill (TODAY / SOON / UPCOMING / PAST). Plain text in
        -- the appropriate colour rather than a real pill texture — the
        -- in-game default font handles this fine and keeps the cell
        -- compact.
        local label, color = EventStatus(row, now)
        local statusFs = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        statusFs:SetPoint("LEFT", r, "LEFT", COL.STATUS.x, 0)
        statusFs:SetText("|c" .. color .. label .. "|r")

        -- Tooltip on hover: description + signups breakdown. Hover the
        -- whole row, anchored RIGHT so it doesn't fight the scroll bar.
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(self)
            if not (row.description and row.description ~= "")
               and (committed + tentative) == 0 then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("|cffffd100" .. (row.title or "Untitled") .. "|r")
            if row.description and row.description ~= "" then
                GameTooltip:AddLine(row.description, 1, 1, 1, true)
            end
            if (committed + tentative) > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(string.format("Signups: %d committed, %d tentative",
                    committed, tentative))
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)

        yOff = yOff - ROW_H - 2
    end

    frame.content:SetHeight(math.abs(yOff) + 10)
end

function WGS:ToggleEventsFrame()
    self:SelectMainFrameTab(self._ui.TAB_EVENTS)
end

function WGS:PopulateEvents(container)
    PopulateEvents(container)
end
