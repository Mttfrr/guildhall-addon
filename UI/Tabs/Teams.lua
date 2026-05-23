---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Teams tab (was "Roster"): three sub-views, all per-player data.
--   Teams         — flat listing of imported teams with main/alt rollup
--                   PLUS a gear-issues column sourced from gearAudit
--                   (missing enchants/gems, ilvl-vs-target).
--   Roster Check  — for today's event, compares the team's expected
--                   roster against who's actually in the raid (or last
--                   session), surfacing Present/Missing/Extra plus an
--                   "Announce" + "Invite" action row.
--   Wishlists     — boss-filtered view of which characters wishlisted
--                   which items, sorted by wisher count. Moved here
--                   from the old standalone Loot tab — wishlists are
--                   per-player data, fits with the roster.

local TAB_INDEX            = ui.TAB_TEAMS
local TEAMS_SUB_TEAMS      = ui.TEAMS_SUB_TEAMS
local TEAMS_SUB_CHECK      = ui.TEAMS_SUB_CHECK
local TEAMS_SUB_WISHLISTS  = ui.TEAMS_SUB_WISHLISTS
local TEAMS_SUB_COUNT      = ui.TEAMS_SUB_COUNT
local TEAMS_SUB_NAMES      = ui.TEAMS_SUB_NAMES
local ClearContainer       = ui.ClearContainer
local CreateScrollContent  = ui.CreateScrollContent
local SelectSubView        = ui.SelectSubView
local BuildSubNav          = ui.BuildSubNav

-- Forward declarations: BuildRosterCheckSubView + PopulateRosterCheck
-- are referenced by BuildTeamsTab's sub-nav callback before they're
-- defined further down. Without the local-first declaration, those
-- closures would capture nil globals.
local BuildRosterCheckSubView
local PopulateRosterCheck
local BuildWishlistsSubView
local PopulateWishlists

---------------------------------------------------------------------------
-- Gear-issue lookup (for the Teams sub-view per-member row)
---------------------------------------------------------------------------

-- Returns a compact gear-issue label for a character, or nil if the
-- gearAudit data has nothing for them. Format:
--   "|cff00ff00clean|r"                       — no issues, green
--   "|cffff8800 2E 1G  i612/620|r"           — yellow: some issues
--   "|cffff4444 4E 3G|r"                      — red: many issues
-- Caller decorates with class color on the name; this is a side-pill.
local function GearIssueLabel(shortName)
    local audit = WGS.db.global.gearAudit
    if not audit or #audit == 0 then return nil end

    local lowerShort = shortName:lower()
    local match = nil
    for _, entry in ipairs(audit) do
        local n = entry.characterName or entry.playerName or ""
        if n:lower():match("^([^%-]+)") == lowerShort then
            match = entry
            break
        end
    end
    if not match then return nil end

    local me = match.missingEnchants or 0
    local mg = match.missingGems or 0
    local ilvl = match.ilvl or 0
    local target = WGS.db.global.targetIlvl or 0
    local belowTarget = target > 0 and ilvl > 0 and ilvl < target

    if me == 0 and mg == 0 and not belowTarget then
        return "|cff00ff00clean|r"
    end

    local parts = {}
    if me > 0 then parts[#parts + 1] = me .. "E" end
    if mg > 0 then parts[#parts + 1] = mg .. "G" end
    if belowTarget then parts[#parts + 1] = string.format("i%d/%d", ilvl, target) end
    local total = me + mg + (belowTarget and 1 or 0)
    local color = total >= 4 and "ffff4444" or "ffff8800"
    return "|c" .. color .. table.concat(parts, " ") .. "|r"
end

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
        noData:SetText("No teams imported yet. Use the Import/Export tab to import data.")
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
                local altsText
                if nAlts > 0 then
                    altsText = mr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    altsText:SetPoint("LEFT", nt, "RIGHT", 6, 0)
                    altsText:SetText("|cff888888+" .. nAlts .. " alt" .. (nAlts > 1 and "s" or "") .. "|r")
                end

                -- Gear-issues badge: sits left of the level/rank tag.
                -- Compact "2E 1G i612/620" with severity coloring; absent
                -- entirely if we have no gearAudit data for this player.
                local gearLabel = GearIssueLabel(short)
                if gearLabel then
                    local gt = mr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    gt:SetPoint("RIGHT", mr, "RIGHT", -110, 0)
                    gt:SetText(gearLabel)
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

                local gearLabel = GearIssueLabel(short or mn)
                if gearLabel then
                    local gt = mr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    gt:SetPoint("RIGHT", mr, "RIGHT", -110, 0)
                    gt:SetText(gearLabel)
                end

                if gi then
                    local it = mr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    it:SetPoint("RIGHT", mr, "RIGHT", -4, 0)
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

    local expected = {}
    local expectedOrder = {}

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
                local channel = WGS:GetGroupChannel() or "PARTY"
                C_ChatInfo.SendChatMessage("[GuildHall] Missing for " .. (data.event.title or "event") .. ":", channel)
                local names = {}
                for _, m in ipairs(missing) do
                    names[#names + 1] = m:match("^([^%-]+)") or m
                end
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
-- Wishlists sub-view (moved here from the deleted Loot tab — per-player
-- data fits with the rest of Teams).
---------------------------------------------------------------------------

local PRIORITY_ORDER = { BiS = 1, High = 2, Medium = 3, Low = 4 }
local PRIORITY_COLORS = {
    BiS    = "ffff8000",
    High   = "ffa335ee",
    Medium = "ff0070dd",
    Low    = "ff1eff00",
}

function BuildWishlistsSubView(sv)
    local lbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -2)
    lbl:SetText("Boss:")

    sv.dropBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.dropBtn:SetSize(280, 22)
    sv.dropBtn:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    sv.dropBtn:SetText("(All items)")
    sv.selectedBoss = nil

    sv.dropMenu = CreateFrame("Frame", nil, sv, "BackdropTemplate")
    sv.dropMenu:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    sv.dropMenu:SetBackdropColor(0, 0, 0, 0.95)
    sv.dropMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    sv.dropMenu:Hide()
    sv.dropMenuButtons = {}

    sv.dropBtn:SetScript("OnClick", function()
        if sv.dropMenu:IsShown() then sv.dropMenu:Hide(); return end
        for _, btn in ipairs(sv.dropMenuButtons) do btn:Hide() end

        local bossSet = {}
        for _, entry in ipairs(WGS.db.global.loot or {}) do
            if entry.boss and entry.boss ~= "" then bossSet[entry.boss] = true end
        end
        local bosses = { "(All items)" }
        for name in pairs(bossSet) do bosses[#bosses + 1] = name end
        table.sort(bosses, function(a, b)
            if a == "(All items)" then return true end
            if b == "(All items)" then return false end
            return a < b
        end)

        local bh = 22
        sv.dropMenu:SetSize(280, #bosses * bh + 8)
        sv.dropMenu:ClearAllPoints()
        sv.dropMenu:SetPoint("TOPLEFT", sv.dropBtn, "BOTTOMLEFT", 0, -2)

        for i, name in ipairs(bosses) do
            local btn = sv.dropMenuButtons[i]
            if not btn then
                btn = CreateFrame("Button", nil, sv.dropMenu)
                btn:SetSize(272, bh)
                btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                btn.text:SetAllPoints()
                btn.text:SetJustifyH("LEFT")
                sv.dropMenuButtons[i] = btn
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", sv.dropMenu, "TOPLEFT", 4, -(i - 1) * bh - 4)
            btn.text:SetText("  " .. name)
            btn:SetScript("OnClick", function()
                sv.selectedBoss = (name == "(All items)") and nil or name
                sv.dropBtn:SetText(name)
                sv.dropMenu:Hide()
                if sv._refreshFn then sv._refreshFn() end
            end)
            btn:Show()
        end
        sv.dropMenu:Show()
    end)

    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -28)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
end

function PopulateWishlists(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local wishlists = WGS.db.global.wishlists or {}
    if #wishlists == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText("No wishlists imported. Import from web app first.")
        tab.content:SetHeight(30)
        return
    end

    local itemWishers = {}
    local itemNames = {}
    for _, entry in ipairs(wishlists) do
        if entry.items then
            for _, item in ipairs(entry.items) do
                if item.itemID then
                    itemWishers[item.itemID] = itemWishers[item.itemID] or {}
                    table.insert(itemWishers[item.itemID], {
                        playerName = entry.playerName,
                        priority = item.priority,
                        note = item.note,
                    })
                end
            end
        end
    end

    for _, lootEntry in ipairs(WGS.db.global.loot or {}) do
        if lootEntry.itemID and lootEntry.itemName and not itemNames[lootEntry.itemID] then
            itemNames[lootEntry.itemID] = lootEntry.itemName
        end
    end
    for itemID in pairs(itemWishers) do
        if not itemNames[itemID] then
            local name = C_Item.GetItemInfo(itemID)
            if name then itemNames[itemID] = name end
        end
    end

    local allowedIds = nil
    if tab.selectedBoss then
        allowedIds = {}
        for _, lootEntry in ipairs(WGS.db.global.loot or {}) do
            if lootEntry.boss == tab.selectedBoss and lootEntry.itemID then
                allowedIds[lootEntry.itemID] = true
            end
        end
    end

    local itemsToShow = {}
    for itemID, wishers in pairs(itemWishers) do
        if not allowedIds or allowedIds[itemID] then
            itemsToShow[#itemsToShow + 1] = { itemID = itemID, wishers = wishers }
        end
    end
    table.sort(itemsToShow, function(a, b)
        if #a.wishers ~= #b.wishers then return #a.wishers > #b.wishers end
        return a.itemID < b.itemID
    end)

    if #itemsToShow == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        if tab.selectedBoss then
            noData:SetText("No wishlisted items from " .. tab.selectedBoss .. " in loot history yet.")
        else
            noData:SetText("No wishlisted items found.")
        end
        tab.content:SetHeight(30)
        return
    end

    local roster = WGS:GetGuildRosterLookup()
    local yOff = 0

    for _, item in ipairs(itemsToShow) do
        local header = CreateFrame("Frame", nil, tab.content)
        header:SetSize(660, 20)
        header:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

        local headerText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        headerText:SetPoint("LEFT", header, "LEFT", 5, 0)
        local name = itemNames[item.itemID] or ("Item " .. item.itemID)
        headerText:SetText(string.format("|cffa335ee%s|r  |cff888888(%d wisher%s)|r",
            name, #item.wishers, #item.wishers == 1 and "" or "s"))
        yOff = yOff - 20

        table.sort(item.wishers, function(a, b)
            return (PRIORITY_ORDER[a.priority] or 99) < (PRIORITY_ORDER[b.priority] or 99)
        end)

        for _, w in ipairs(item.wishers) do
            local row = CreateFrame("Frame", nil, tab.content)
            row:SetSize(660, 16)
            row:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

            local short = (w.playerName or ""):match("^([^%-]+)") or w.playerName or "?"
            local gi = roster[short]
            local pColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local pText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            pText:SetPoint("LEFT", row, "LEFT", 25, 0)
            pText:SetText("|c" .. pColor .. short .. "|r")

            local prColor = PRIORITY_COLORS[w.priority] or "ffffffff"
            local prText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            prText:SetPoint("LEFT", pText, "RIGHT", 10, 0)
            prText:SetText("|c" .. prColor .. (w.priority or "?") .. "|r")

            if w.note and w.note ~= "" then
                local nText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                nText:SetPoint("LEFT", prText, "RIGHT", 8, 0)
                nText:SetText("|cff888888(" .. w.note .. ")|r")
            end

            yOff = yOff - 16
        end

        yOff = yOff - 4
    end

    tab.content:SetHeight(math.abs(yOff) + 10)
end

---------------------------------------------------------------------------
-- Tab wiring
---------------------------------------------------------------------------

local function BuildTeamsTab(parent)
    BuildSubNav(parent, TEAMS_SUB_NAMES, function(p, i)
        SelectSubView(p, i, TEAMS_SUB_COUNT)
        if i == TEAMS_SUB_TEAMS then
            PopulateTeams(p.subViews[i])
        elseif i == TEAMS_SUB_CHECK then
            PopulateRosterCheck(p.subViews[i])
        elseif i == TEAMS_SUB_WISHLISTS then
            PopulateWishlists(p.subViews[i])
        end
    end)
    BuildTeamsSubView(parent.subViews[TEAMS_SUB_TEAMS])
    BuildRosterCheckSubView(parent.subViews[TEAMS_SUB_CHECK])
    BuildWishlistsSubView(parent.subViews[TEAMS_SUB_WISHLISTS])

    -- Back-pointer used by the Refresh button inside RosterCheck and
    -- the boss-dropdown inside Wishlists. Sub-view-owned re-renders.
    parent.subViews[TEAMS_SUB_CHECK]._refreshFn = function()
        PopulateRosterCheck(parent.subViews[TEAMS_SUB_CHECK])
    end
    parent.subViews[TEAMS_SUB_WISHLISTS]._refreshFn = function()
        PopulateWishlists(parent.subViews[TEAMS_SUB_WISHLISTS])
    end

    SelectSubView(parent, TEAMS_SUB_TEAMS, TEAMS_SUB_COUNT)
end

local function RefreshTeamsSubView(tab)
    if not tab or not tab:IsVisible() then return end
    local sub = tab.selectedSub or TEAMS_SUB_TEAMS
    if sub == TEAMS_SUB_TEAMS then
        PopulateTeams(tab.subViews[sub])
    elseif sub == TEAMS_SUB_CHECK then
        PopulateRosterCheck(tab.subViews[sub])
    elseif sub == TEAMS_SUB_WISHLISTS then
        PopulateWishlists(tab.subViews[sub])
    end
end

ui.tabs[TAB_INDEX] = { build = BuildTeamsTab, refresh = RefreshTeamsSubView }
