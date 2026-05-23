---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Bank tab: guild bank ledger. Single view — current balance up top
-- plus the transaction log (deposit/withdrawal rows) chronologically
-- below. Loot history used to live here as a second sub-view but was
-- moved to Raids (it's raid-flow data, not bank-ledger data).

local TAB_INDEX           = ui.TAB_BANK
local ClearContainer      = ui.ClearContainer

local function BuildBankTab(parent)
    -- Current balance, prominent at the top
    parent.balance = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    parent.balance:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -4)

    parent.balanceSub = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    parent.balanceSub:SetPoint("TOPLEFT", parent.balance, "BOTTOMLEFT", 0, -2)

    -- Transaction log below
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -48)
    sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(660)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    parent.scrollFrame = sf
    parent.content = content
end

local function RefreshBank(tab)
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

ui.tabs[TAB_INDEX] = { build = BuildBankTab, refresh = RefreshBank }
