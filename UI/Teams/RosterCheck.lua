---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Roster Check sub-view: for today's event, compares the team's expected
-- roster against who's actually in the raid (or last attendance session)
-- and surfaces Present / Missing / Extra plus action buttons (Announce
-- Missing, Invite Missing, Refresh).

ui.teams = ui.teams or {}

local ClearContainer = ui.ClearContainer

---------------------------------------------------------------------------
-- Data — pulls today's event, expected roster (mains + linked alts),
-- and the actual present-set (live raid if grouped, otherwise the last
-- captured attendance session).
---------------------------------------------------------------------------

local function BuildRosterCheckData()
    local currentTeamId = WGS.GetCurrentTeamId and WGS:GetCurrentTeamId() or nil
    local event = WGS.FindTodayEventForTeam and WGS:FindTodayEventForTeam(currentTeamId) or nil
    if not event then
        if currentTeamId then
            return nil, "No event for the picked team today."
        end
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
    -- (the canonical full list).
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

---------------------------------------------------------------------------
-- Sub-view build + populate (registered on ui.teams.rosterCheck)
---------------------------------------------------------------------------

local function BuildSubView(sv)
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

local function Populate(tab)
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
                -- Pack short character names into the minimum number of
                -- comma-joined chat lines that fit under the 200-byte
                -- chat-message cap. Centralised in Util/Announce.lua so
                -- it can't drift from other announce paths.
                local channel = WGS:GetGroupChannel() or "PARTY"
                local shorts = {}
                for _, m in ipairs(missing) do
                    shorts[#shorts + 1] = m:match("^([^%-]+)") or m
                end
                WGS:SendChatLine("Missing for " .. (data.event.title or "event") .. ":", channel)
                WGS:SendChatChunked(WGS:PackChatTokens(shorts), channel)
            end)
        else
            tab.announceBtn:Hide()
        end
    else
        tab.announceBtn:Hide()
        tab.inviteBtn:Hide()
    end
end

ui.teams.rosterCheck = { build = BuildSubView, populate = Populate }
