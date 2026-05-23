---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Bank tab: captured-ledger data.
--   Ledger       — current guild bank balance plus the transaction log
--                  (deposits/withdrawals). One row per transaction,
--                  newest first.
--   Loot History — chronological list of captured loot drops, with a
--                  search box. Moved here from the deleted Loot tab;
--                  loot is the same shape of "captured-ledger" data
--                  as bank transactions.

local TAB_INDEX           = ui.TAB_BANK
local BANK_SUB_LEDGER     = ui.BANK_SUB_LEDGER
local BANK_SUB_LOOT       = ui.BANK_SUB_LOOT
local BANK_SUB_COUNT      = ui.BANK_SUB_COUNT
local BANK_SUB_NAMES      = ui.BANK_SUB_NAMES
local ClearContainer      = ui.ClearContainer
local SelectSubView       = ui.SelectSubView
local BuildSubNav         = ui.BuildSubNav

local ITEM_QUALITY_COLORS = {
    [2] = "ff1eff00",
    [3] = "ff0070dd",
    [4] = "ffa335ee",
    [5] = "ffff8000",
    [6] = "ffe6cc80",
    [7] = "ff00ccff",
}

---------------------------------------------------------------------------
-- Ledger sub-view
---------------------------------------------------------------------------

local function BuildLedgerSubView(sv)
    -- Current balance, large + bold at the top
    sv.balance = sv:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    sv.balance:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -4)

    sv.balanceSub = sv:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sv.balanceSub:SetPoint("TOPLEFT", sv.balance, "BOTTOMLEFT", 0, -2)

    -- Transaction log below
    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -48)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
end

local function PopulateLedger(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local db = WGS.db.global
    local gold = WGS:GetGuildGoldFormatted()
    if gold then
        tab.balance:SetText("|cffffd100" .. gold .. "|r")
    else
        tab.balance:SetText("|cff888888No bank data yet|r")
    end

    local changes = db.guildBankMoneyChanges or {}
    local txs = db.guildBankTransactions or {}
    tab.balanceSub:SetText(string.format(
        "|cff555555%d gold snapshots, %d transactions captured|r",
        #changes, #txs))

    if #txs == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText("No transactions yet. Open the guild bank to capture some.")
        tab.content:SetHeight(30)
        return
    end

    -- Sort newest first
    local sorted = {}
    for i = #txs, 1, -1 do sorted[#sorted + 1] = txs[i] end

    local yOff = 0
    local cw = 660
    local MAX_ROWS = 300
    local shown = 0
    for _, tx in ipairs(sorted) do
        if shown >= MAX_ROWS then break end
        local row = CreateFrame("Frame", nil, tab.content)
        row:SetSize(cw, 18)
        row:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 0, yOff)

        local typeColor = tx.type == "withdrawal" and "ffff8800" or "ff00ff00"
        local sign      = tx.type == "withdrawal" and "-"        or "+"
        local typeText  = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        typeText:SetPoint("LEFT", row, "LEFT", 5, 0)
        typeText:SetWidth(90)
        typeText:SetJustifyH("LEFT")
        typeText:SetText("|c" .. typeColor .. (tx.type or "?") .. "|r")

        local playerText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        playerText:SetPoint("LEFT", typeText, "RIGHT", 4, 0)
        playerText:SetWidth(180)
        playerText:SetJustifyH("LEFT")
        playerText:SetText(tx.player or "Unknown")

        local amountText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        amountText:SetPoint("LEFT", playerText, "RIGHT", 4, 0)
        amountText:SetWidth(180)
        amountText:SetJustifyH("LEFT")
        amountText:SetText("|c" .. typeColor .. sign .. (tx.amountFormatted or WGS:FormatGold(tx.amount or 0)) .. "|r")

        local dateText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        dateText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        dateText:SetWidth(120)
        dateText:SetJustifyH("RIGHT")
        dateText:SetText("|cff555555" .. date("%m/%d %H:%M", tx.timestamp or 0) .. "|r")

        yOff = yOff - 18
        shown = shown + 1
    end

    tab.content:SetHeight(math.abs(yOff) + 10)
end

---------------------------------------------------------------------------
-- Loot History sub-view (moved here from the deleted Loot tab)
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

---------------------------------------------------------------------------
-- Tab wiring
---------------------------------------------------------------------------

local function BuildBankTab(parent)
    BuildSubNav(parent, BANK_SUB_NAMES, function(p, i)
        SelectSubView(p, i, BANK_SUB_COUNT)
        if i == BANK_SUB_LEDGER then
            PopulateLedger(p.subViews[i])
        elseif i == BANK_SUB_LOOT then
            PopulateLootHistory(p.subViews[i])
        end
    end)
    BuildLedgerSubView(parent.subViews[BANK_SUB_LEDGER])
    BuildLootHistorySubView(parent.subViews[BANK_SUB_LOOT])

    parent.subViews[BANK_SUB_LOOT]._refreshFn = function()
        PopulateLootHistory(parent.subViews[BANK_SUB_LOOT])
    end

    SelectSubView(parent, BANK_SUB_LEDGER, BANK_SUB_COUNT)
end

local function RefreshBankSubView(tab)
    if not tab or not tab:IsVisible() then return end
    local sub = tab.selectedSub or BANK_SUB_LEDGER
    if sub == BANK_SUB_LEDGER then
        PopulateLedger(tab.subViews[sub])
    elseif sub == BANK_SUB_LOOT then
        PopulateLootHistory(tab.subViews[sub])
    end
end

ui.tabs[TAB_INDEX] = { build = BuildBankTab, refresh = RefreshBankSubView }
