---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Wishlists sub-view: boss-filtered view of which characters wishlisted
-- which items, sorted by wisher count. Lifted here from the deleted
-- standalone Loot tab — wishlists are per-player data so they fit with
-- the rest of Teams.

ui.teams = ui.teams or {}

local ClearContainer = ui.ClearContainer

local PRIORITY_ORDER = { BiS = 1, High = 2, Medium = 3, Low = 4 }
local PRIORITY_COLORS = {
    BiS    = "ffff8000",
    High   = "ffa335ee",
    Medium = "ff0070dd",
    Low    = "ff1eff00",
}

---------------------------------------------------------------------------
-- Sub-view build + populate (registered on ui.teams.wishlists)
---------------------------------------------------------------------------

local function BuildSubView(sv)
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

local function Populate(tab)
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

    -- Build the set of allowed player names if the team picker is set.
    -- We accept both full ("Foo-Realm") and short ("Foo") forms since
    -- wishlist.playerName drift between the two depending on the
    -- import path.
    local allowedPlayers = nil
    local currentTeamId = WGS.GetCurrentTeamId and WGS:GetCurrentTeamId() or nil
    if currentTeamId then
        allowedPlayers = {}
        for _, t in ipairs(WGS.db.global.teams or {}) do
            if t.id == currentTeamId then
                for _, memberName in ipairs(t.members or {}) do
                    allowedPlayers[memberName] = true
                    local short = memberName:match("^([^%-]+)") or memberName
                    allowedPlayers[short] = true
                end
                -- Also accept linked-character alts so a wishlist on an
                -- alt of a team main still shows up under the team filter.
                local chars = WGS.db.global.characters or {}
                for _, pm in ipairs(t.playerMembers or {}) do
                    local info = chars[pm.playerId]
                    if info and info.alts then
                        for _, alt in ipairs(info.alts) do
                            allowedPlayers[alt] = true
                            local altShort = alt:match("^([^%-]+)") or alt
                            allowedPlayers[altShort] = true
                        end
                    end
                end
                break
            end
        end
    end

    local function inScope(playerName)
        if not allowedPlayers then return true end
        if not playerName then return false end
        if allowedPlayers[playerName] then return true end
        local short = playerName:match("^([^%-]+)") or playerName
        return allowedPlayers[short] == true
    end

    local itemWishers = {}
    local itemNames = {}
    for _, entry in ipairs(wishlists) do
        if entry.items and inScope(entry.playerName) then
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

ui.teams.wishlists = { build = BuildSubView, populate = Populate }
