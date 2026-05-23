---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Roster tab: two sub-views.
--   Teams       — flat listing of imported teams with main/alt rollup
--                 and per-character online status from the guild roster.
--   Roster Check — for today's event, compares the team's expected
--                 roster against who's actually in the raid (or last
--                 session), surfacing Present/Missing/Extra plus an
--                 "Announce" + "Invite" action row.

local TAB_INDEX            = ui.TAB_ROSTER
local ROSTER_SUB_TEAMS     = ui.ROSTER_SUB_TEAMS
local ROSTER_SUB_CHECK     = ui.ROSTER_SUB_CHECK
local ROSTER_SUB_COUNT     = ui.ROSTER_SUB_COUNT
local ROSTER_SUB_NAMES     = ui.ROSTER_SUB_NAMES
local ClearContainer       = ui.ClearContainer
local CreateScrollContent  = ui.CreateScrollContent
local SelectSubView        = ui.SelectSubView
local BuildSubNav          = ui.BuildSubNav

-- Forward declarations: BuildRosterCheckSubView + PopulateRosterCheck
-- are referenced by BuildRosterTab before they're defined further down
-- in this file. Without the local-first declaration, the closures
-- would capture nil globals.
local BuildRosterCheckSubView
local PopulateRosterCheck

---------------------------------------------------------------------------
-- Teams sub-view
---------------------------------------------------------------------------

local function BuildTeamsSubView(sv)
    local sf, content = CreateScrollContent(sv)
    sf:ClearAllPoints()
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    sv.scrollFrame = sf
    sv.content = content
end

local function PopulateTeams(tab)
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

    local roster = WGS:GetGuildRosterLookup()
    local characters = WGS.db.global.characters or {}
    local yOff = 0
    local cw = 660

    for _, team in ipairs(teams) do
        local row = CreateFrame("Frame", nil, tab.content)
        row:SetSize(cw, 20)
        row:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)
        local tn = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tn:SetPoint("LEFT", row, "LEFT", 5, 0)
        local mc = team.playerMembers and #team.playerMembers or (team.members and #team.members or 0)
        tn:SetText("|cffffd100" .. (team.name or "?") .. "|r  |cff888888("
            .. (team.type or "Team") .. " \226\128\148 " .. mc .. " members)|r")
        yOff = yOff - 22

        if team.playerMembers and #team.playerMembers > 0 then
            for _, pm in ipairs(team.playerMembers) do
                local pi = characters[pm.playerId]
                local mainName = pm.main or (pi and pi.main) or "Unknown"
                local short = mainName:match("^([^%-]+)") or mainName
                local gi = roster[short]

                local anyOnline = gi and gi.online
                if not anyOnline and pi and pi.alts then
                    for _, alt in ipairs(pi.alts) do
                        local ag = roster[alt:match("^([^%-]+)")]
                        if ag and ag.online then anyOnline = true; break end
                    end
                end

                local mr = CreateFrame("Frame", nil, tab.content)
                mr:SetSize(cw, 16)
                mr:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

                local dot = mr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                dot:SetPoint("LEFT", mr, "LEFT", 12, 0)
                dot:SetText(gi and (anyOnline and "|cff00ff00\194\183|r" or "|cff555555\194\183|r") or "|cffff4444\194\183|r")

                local nt = mr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                nt:SetPoint("LEFT", dot, "RIGHT", 4, 0)
                if gi then
                    nt:SetText("|c" .. (WGS.CLASS_COLORS[gi.class] or "ffffffff") .. short .. "|r")
                else
                    nt:SetText("|cff666666" .. short .. "|r")
                end

                local nAlts = pi and pi.alts and #pi.alts or 0
                if nAlts > 0 then
                    local ab = mr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    ab:SetPoint("LEFT", nt, "RIGHT", 6, 0)
                    ab:SetText("|cff888888+" .. nAlts .. " alt" .. (nAlts > 1 and "s" or "") .. "|r")
                end
                if gi then
                    local it = mr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    it:SetPoint("RIGHT", mr, "RIGHT", -4, 0)
                    it:SetText("|cff555555Lv" .. gi.level .. " " .. gi.rank .. "|r")
                end

                if nAlts > 0 then
                    mr:EnableMouse(true)
                    mr._alts = pi.alts
                    mr._main = mainName
                    mr._short = short
                    mr:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:AddLine(self._short .. "'s Characters")
                        GameTooltip:AddLine("Main: " .. self._main, 1, 1, 1)
                        for _, alt in ipairs(self._alts) do
                            local as = alt:match("^([^%-]+)")
                            local ag = roster[as]
                            if ag then
                                GameTooltip:AddLine("|c" .. (WGS.CLASS_COLORS[ag.class] or "ffffffff") .. as .. "|r  "
                                    .. (ag.online and "|cff00ff00online|r" or "|cff555555offline|r"))
                            else
                                GameTooltip:AddLine("|cff666666" .. as .. "|r  (not in guild)")
                            end
                        end
                        GameTooltip:Show()
                    end)
                    mr:SetScript("OnLeave", function() GameTooltip:Hide() end)
                end
                yOff = yOff - 16
            end
        elseif team.members and #team.members > 0 then
            for _, mn in ipairs(team.members) do
                local short = mn:match("^([^%-]+)")
                local gi = roster[short]
                local mr = CreateFrame("Frame", nil, tab.content)
                mr:SetSize(cw, 16)
                mr:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)
                local dot = mr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                dot:SetPoint("LEFT", mr, "LEFT", 12, 0)
                dot:SetText(gi and (gi.online and "|cff00ff00\194\183|r" or "|cff555555\194\183|r") or "|cffff4444\194\183|r")
                local nt = mr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                nt:SetPoint("LEFT", dot, "RIGHT", 4, 0)
                if gi then
                    nt:SetText("|c" .. (WGS.CLASS_COLORS[gi.class] or "ffffffff") .. short .. "|r")
                else
                    nt:SetText("|cff666666" .. short .. "|r")
                end
                if gi then
                    local it = mr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    it:SetPoint("LEFT", nt, "RIGHT", 6, 0)
                    it:SetText("|cff555555Lv" .. gi.level .. " " .. gi.rank .. "|r")
                end
                yOff = yOff - 16
            end
        else
            local noM = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            noM:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 16, yOff)
            noM:SetText("(no members)")
            yOff = yOff - 16
        end
        yOff = yOff - 6
    end
    tab.content:SetHeight(math.abs(yOff) + 10)
end

---------------------------------------------------------------------------
-- Roster Check sub-view
---------------------------------------------------------------------------

function BuildRosterCheckSubView(sv)
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

-- Returns { expected, actual } lists for today's event
local function BuildRosterCheckData()
    local event = WGS.FindTodayEventForTeam and WGS:FindTodayEventForTeam(nil) or nil
    if not event then
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

    -- Expected: set of character names (main + alts for each player)
    local expected = {}       -- [charName-realm] = { playerId, isMain, mainName }
    local expectedOrder = {}  -- ordered list of main names

    if team.playerMembers then
        local chars = WGS.db.global.characters or {}
        for _, pm in ipairs(team.playerMembers) do
            local info = chars[pm.playerId]
            local main = pm.main or (info and info.main) or nil
            if main then
                expected[main] = { playerId = pm.playerId, isMain = true, mainName = main }
                expectedOrder[#expectedOrder + 1] = main
                if info and info.alts then
                    for _, alt in ipairs(info.alts) do
                        expected[alt] = { playerId = pm.playerId, isMain = false, mainName = main }
                    end
                end
            end
        end
    elseif team.members then
        for _, m in ipairs(team.members) do
            expected[m] = { isMain = true, mainName = m }
            expectedOrder[#expectedOrder + 1] = m
        end
    end

    -- Actual: characters in current raid (or last session)
    local actual = {}  -- [charName-realm] = true
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

function PopulateRosterCheck(tab)
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

    -- Classify each expected player: present (any of their chars in actual) or missing
    local present = {}
    local missing = {}
    local presentChars = {}  -- track which actual characters matched (for extra detection)

    for _, main in ipairs(data.expectedOrder) do
        local playerId = data.expected[main].playerId
        local matched = nil
        -- Check main first
        if data.actual[main] then
            matched = main
            presentChars[main] = true
        else
            -- Check alts by playerId (reverse-resolve through expected map)
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

    -- Extra: actual raid members not in expected (pugs, alts of team members annotated)
    local extra = {}
    for actualName in pairs(data.actual) do
        if not presentChars[actualName] and not data.expected[actualName] then
            -- Maybe an alt of someone on the team (resolve via character map)
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

    -- Show/hide action buttons based on whether there's anything missing
    if #missing > 0 then
        tab.inviteBtn:Show()
        if WGS:IsInAnyGroup() then
            tab.announceBtn:Show()
            tab.announceBtn:SetScript("OnClick", function()
                local channel = WGS:GetGroupChannel() or "PARTY"
                C_ChatInfo.SendChatMessage("[GuildHall] Missing for " .. (data.event.title or "event") .. ":", channel)
                local names = {}
                for _, m in ipairs(missing) do
                    names[#names + 1] = m:match("^([^%-]+)") or m
                end
                -- Batch names into chunks to avoid message length limit
                local chunk = ""
                for _, n in ipairs(names) do
                    if #chunk + #n + 2 > 200 then
                        C_ChatInfo.SendChatMessage("  " .. chunk, channel)
                        chunk = n
                    else
                        chunk = chunk == "" and n or (chunk .. ", " .. n)
                    end
                end
                if chunk ~= "" then
                    C_ChatInfo.SendChatMessage("  " .. chunk, channel)
                end
            end)
        else
            tab.announceBtn:Hide()
        end
    else
        tab.announceBtn:Hide()
        tab.inviteBtn:Hide()
    end
end

---------------------------------------------------------------------------
-- Tab wiring
---------------------------------------------------------------------------

local function BuildRosterTab(parent)
    BuildSubNav(parent, ROSTER_SUB_NAMES, function(p, i)
        SelectSubView(p, i, ROSTER_SUB_COUNT)
        if i == ROSTER_SUB_TEAMS then
            PopulateTeams(p.subViews[i])
        elseif i == ROSTER_SUB_CHECK then
            PopulateRosterCheck(p.subViews[i])
        end
    end)
    BuildTeamsSubView(parent.subViews[ROSTER_SUB_TEAMS])
    BuildRosterCheckSubView(parent.subViews[ROSTER_SUB_CHECK])
    -- Back-pointer used by the Refresh button inside BuildRosterCheckSubView.
    -- Used to live in MainFrame's CreateMainFrame; moved here so the tab
    -- owns its own wiring.
    parent.subViews[ROSTER_SUB_CHECK]._refreshFn = function()
        PopulateRosterCheck(parent.subViews[ROSTER_SUB_CHECK])
    end
    SelectSubView(parent, ROSTER_SUB_TEAMS, ROSTER_SUB_COUNT)
end

local function RefreshRosterSubView(tab)
    if not tab or not tab:IsVisible() then return end
    local sub = tab.selectedSub or ROSTER_SUB_TEAMS
    if sub == ROSTER_SUB_TEAMS then
        PopulateTeams(tab.subViews[sub])
    elseif sub == ROSTER_SUB_CHECK then
        PopulateRosterCheck(tab.subViews[sub])
    end
end

ui.tabs[TAB_INDEX] = { build = BuildRosterTab, refresh = RefreshRosterSubView }
