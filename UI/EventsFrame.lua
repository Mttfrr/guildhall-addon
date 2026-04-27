---@type GuildHall
local WGS = GuildHall

local function PopulateEvents(frame)
    -- Hide previous children
    local children = { frame.content:GetChildren() }
    for _, child in ipairs(children) do
        child:Hide()
    end
    local regions = { frame.content:GetRegions() }
    for _, region in ipairs(regions) do
        region:Hide()
    end

    local events = WGS.db.global.events
    if not events or #events == 0 then
        local noData = frame.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 5, -10)
        noData:SetWidth(frame.scrollFrame:GetWidth() - 10)
        noData:SetJustifyH("LEFT")
        noData:SetWordWrap(true)
        noData:SetText("No events imported. Import from web app first.")
        noData:Show()
        frame.content:SetHeight(40)
        return
    end

    -- Sort events by date/time
    local sorted = {}
    for _, ev in ipairs(events) do
        table.insert(sorted, ev)
    end
    table.sort(sorted, function(a, b)
        local da = (a.date or "") .. (a.time or "")
        local db = (b.date or "") .. (b.time or "")
        return da < db
    end)

    local today = date("%Y-%m-%d")
    local contentWidth = frame.scrollFrame:GetWidth() - 10
    local yOffset = 0

    for _, ev in ipairs(sorted) do
        local eventRow = CreateFrame("Frame", nil, frame.content)
        eventRow:SetSize(contentWidth, 44)
        eventRow:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, yOffset)

        -- Date and time
        local isToday = ev.date == today
        local dateColor = isToday and "|cff00ff00" or "|cffffd100"
        local dateStr = dateColor .. (ev.date or "?") .. "|r"
        local timeStr = ""
        if ev.time then
            timeStr = " |cffaaaaaa" .. ev.time
            if ev.end_time then
                timeStr = timeStr .. " - " .. ev.end_time
            end
            timeStr = timeStr .. "|r"
        end

        local dateLine = eventRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dateLine:SetPoint("TOPLEFT", eventRow, "TOPLEFT", 5, -2)
        dateLine:SetText(dateStr .. timeStr .. (isToday and " |cff00ff00(TODAY)|r" or ""))

        -- Title and type
        local titleLine = eventRow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        titleLine:SetPoint("TOPLEFT", eventRow, "TOPLEFT", 5, -16)
        titleLine:SetText((ev.title or "Untitled") .. "  |cff888888" .. (ev.type or "") .. "|r")

        -- Description (truncated)
        if ev.description and ev.description ~= "" then
            local descLine = eventRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            descLine:SetPoint("TOPLEFT", eventRow, "TOPLEFT", 5, -30)
            descLine:SetWidth(contentWidth - 10)
            descLine:SetJustifyH("LEFT")
            local desc = ev.description
            if #desc > 80 then desc = desc:sub(1, 80) .. "..." end
            descLine:SetText(desc)
            yOffset = yOffset - 48
        else
            yOffset = yOffset - 36
        end

        -- Separator
        yOffset = yOffset - 4
    end

    frame.content:SetHeight(math.abs(yOffset) + 10)
end

function WGS:ToggleEventsFrame()
    self:SelectMainFrameTab(3, 3)
end

--- Populate events into any container with .content and .scrollFrame fields.
function WGS:PopulateEvents(container)
    PopulateEvents(container)
end
