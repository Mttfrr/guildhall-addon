---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Raids tab: loot capture-log only. The other former sub-views —
-- Raid Comp, Readiness, Boss Notes — were per-event surfaces, so
-- they moved into the Events tab's detail panel (master-detail
-- rework). Loot History stays here because the loot log is global
-- across events, not per-event.

local TAB_INDEX            = ui.TAB_RAIDS
local ClearContainer       = ui.ClearContainer

local ITEM_QUALITY_COLORS = {
    [2] = "ff1eff00",
    [3] = "ff0070dd",
    [4] = "ffa335ee",
    [5] = "ffff8000",
    [6] = "ffe6cc80",
    [7] = "ff00ccff",
}

---------------------------------------------------------------------------
-- Loot History (the only thing this tab still hosts)
---------------------------------------------------------------------------

local function BuildLootHistorySubView(sv)
    local searchLbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    searchLbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -2)
    searchLbl:SetText("Filter:")

    local searchBox = CreateFrame("EditBox", nil, sv, "InputBoxTemplate")
    searchBox:SetSize(250, 22)
    searchBox:SetPoint("LEFT", searchLbl, "RIGHT", 10, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnTextChanged", function(self)
        sv.filterText = (self:GetText() or ""):lower()
        if sv._refreshFn then sv._refreshFn() end
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    sv.searchBox = searchBox

    local countText = sv:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countText:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)
    sv.countText = countText

    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -28)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
    sv.filterText = ""
end

local function PopulateLootHistory(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local loot = WGS.db.global.loot or {}
    local filter = tab.filterText or ""
    local roster = WGS:GetGuildRosterLookup()

    local sorted = {}
    for i = #loot, 1, -1 do sorted[#sorted + 1] = loot[i] end

    local yOff = 0
    local shown = 0
    local MAX_ROWS = 200

    for _, entry in ipairs(sorted) do
        if shown >= MAX_ROWS then break end

        local matches = filter == ""
        if not matches then
            local itemName = (entry.itemName or ""):lower()
            local player = (entry.player or ""):lower()
            local boss = (entry.boss or ""):lower()
            if itemName:find(filter, 1, true) or player:find(filter, 1, true) or boss:find(filter, 1, true) then
                matches = true
            end
        end

        if matches then
            local row = CreateFrame("Frame", nil, tab.content)
            row:SetSize(660, 18)
            row:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

            local qColor = ITEM_QUALITY_COLORS[entry.itemQuality or 4] or "ffa335ee"
            local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            itemText:SetPoint("LEFT", row, "LEFT", 5, 0)
            itemText:SetWidth(220)
            itemText:SetJustifyH("LEFT")
            itemText:SetText("|c" .. qColor .. (entry.itemName or "Unknown") .. "|r")

            local short = (entry.player or ""):match("^([^%-]+)") or entry.player or "?"
            local gi = roster[short]
            local pColor = gi and WGS.CLASS_COLORS[gi.class] or "ffffffff"
            local playerText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            playerText:SetPoint("LEFT", itemText, "RIGHT", 4, 0)
            playerText:SetWidth(120)
            playerText:SetJustifyH("LEFT")
            playerText:SetText("|c" .. pColor .. short .. "|r")

            local bossText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            bossText:SetPoint("LEFT", playerText, "RIGHT", 4, 0)
            bossText:SetWidth(140)
            bossText:SetJustifyH("LEFT")
            local bossStr = entry.boss and entry.boss ~= "" and entry.boss or "\226\128\148"
            bossText:SetText("|cff888888" .. bossStr .. "|r")

            local dateText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            dateText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            dateText:SetWidth(120)
            dateText:SetJustifyH("RIGHT")
            dateText:SetText("|cff555555" .. date("%m/%d %H:%M", entry.timestamp or 0) .. "|r")

            yOff = yOff - 18
            shown = shown + 1
        end
    end

    if shown == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText(filter == "" and "No loot recorded yet." or "No loot matching filter.")
        tab.content:SetHeight(30)
    else
        tab.content:SetHeight(math.abs(yOff) + 10)
    end

    tab.countText:SetText(string.format("|cff888888Showing %d of %d|r", shown, #loot))
end

-- The tab no longer has a sub-nav — Loot History is the only surface
-- so it builds directly into `parent`. Keeping the build/refresh
-- registry contract unchanged so MainFrame.lua's dispatch loop doesn't
-- need to special-case Raids.
local function BuildRaidsTab(parent)
    BuildLootHistorySubView(parent)
    parent._refreshFn = function() PopulateLootHistory(parent) end
end

local function RefreshRaidsTab(tab)
    if not tab or not tab:IsVisible() then return end
    PopulateLootHistory(tab)
end

ui.tabs[TAB_INDEX] = { build = BuildRaidsTab, refresh = RefreshRaidsTab }
