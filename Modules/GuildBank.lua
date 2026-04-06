---@type WoWGuildSync
local WGS = WoWGuildSync
local L = WoWGuildSync_L

---@class WGSGuildBankModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("GuildBank", "AceEvent-3.0")

local pendingMoneyUpdate = nil
-- Fingerprints of already-captured transactions to prevent duplicates
local capturedFingerprints = {}

function module:OnEnable()
    self:RegisterEvent("GUILDBANK_UPDATE_MONEY", "OnMoneyUpdate")
end

function module:OnMoneyUpdate()
    -- Debounce: multiple events can fire rapidly (e.g. mass repairs)
    if pendingMoneyUpdate then pendingMoneyUpdate:Cancel() end
    pendingMoneyUpdate = C_Timer.NewTimer(0.5, function()
        pendingMoneyUpdate = nil
        WGS:OnGoldChanged()
    end)
end

local function formatGold(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100
    return string.format("%dg %ds %dc", gold, silver, cop)
end

-- Fingerprint a transaction for dedup (player + type + amount)
local function txFingerprint(player, txType, amount)
    return (player or "") .. "|" .. (txType or "") .. "|" .. tostring(amount or 0)
end

-- Called when guild bank gold changes (debounced)
function WGS:OnGoldChanged()
    local guildMoney = GetGuildBankMoney and GetGuildBankMoney() or 0
    if guildMoney == 0 then return end

    local db = self.db.global
    local previousMoney = db.lastKnownGold

    -- Update the known gold balance
    db.lastKnownGold = guildMoney

    -- Record the gold snapshot diff
    if previousMoney and previousMoney ~= guildMoney then
        db.guildBankMoneyChanges = db.guildBankMoneyChanges or {}
        local diff = guildMoney - previousMoney
        local sign = diff >= 0 and "+" or "-"
        table.insert(db.guildBankMoneyChanges, {
            timestamp = self:GetTimestamp(),
            recordedBy = self:GetPlayerKey(),
            money = guildMoney,
            moneyFormatted = formatGold(guildMoney),
            diff = diff,
            diffFormatted = sign .. formatGold(math.abs(diff)),
            previousMoney = previousMoney,
        })
    end

    -- Auto-capture new transactions from the log
    self:CaptureNewTransactions()
end

-- Scan the transaction log and capture only entries we haven't seen yet
function WGS:CaptureNewTransactions()
    if not GetNumGuildBankMoneyTransactions then return end

    local numTx = GetNumGuildBankMoneyTransactions()
    if numTx == 0 then return end

    local db = self.db.global
    db.guildBankTransactions = db.guildBankTransactions or {}

    local now = time()
    local added = 0

    -- Rebuild fingerprint set from stored transactions (on first call)
    if next(capturedFingerprints) == nil and #db.guildBankTransactions > 0 then
        for _, tx in ipairs(db.guildBankTransactions) do
            local fp = txFingerprint(tx.player, tx.type, tx.amount)
            capturedFingerprints[fp] = (capturedFingerprints[fp] or 0) + 1
        end
    end

    -- Withdrawal type lookup (hoisted out of loop)
    local withdrawTypes = { withdraw = true, withdrawForTab = true, repair = true, buyTab = true }
    local function isWithdrawal(tt)
        if type(tt) == "string" then return withdrawTypes[tt] or false end
        return tt and tt > 0
    end

    -- First pass: count fingerprint occurrences in the current WoW transaction log (O(n))
    local logFpCounts = {}
    local logEntries = {}
    for i = 1, numTx do
        local txType, name, amount, years, months, days, hours = GetGuildBankMoneyTransaction(i)
        if amount and amount > 0 then
            local mappedType = isWithdrawal(txType) and "withdrawal" or "deposit"
            local fp = txFingerprint(name, mappedType, amount)
            logFpCounts[fp] = (logFpCounts[fp] or 0) + 1

            local secondsAgo = (years or 0) * 31536000
                             + (months or 0) * 2592000
                             + (days or 0) * 86400
                             + (hours or 0) * 3600

            logEntries[i] = {
                fp = fp,
                name = name,
                amount = amount,
                mappedType = mappedType,
                rawType = txType,
                timestamp = now - secondsAgo,
                fpOccurrence = logFpCounts[fp], -- which occurrence of this fp in the log
            }
        end
    end

    -- Second pass: compare log occurrences against captured fingerprints (O(n))
    local consecutiveKnown = 0
    for i = 1, numTx do
        local entry = logEntries[i]
        if entry then
            local seenCount = capturedFingerprints[entry.fp] or 0

            if entry.fpOccurrence > seenCount then
                table.insert(db.guildBankTransactions, {
                    timestamp = entry.timestamp,
                    player = entry.name or "Unknown",
                    amount = entry.amount,
                    amountFormatted = formatGold(entry.amount),
                    type = entry.mappedType,
                    rawType = entry.rawType or "",
                })
                capturedFingerprints[entry.fp] = seenCount + 1
                added = added + 1
                consecutiveKnown = 0
            else
                consecutiveKnown = consecutiveKnown + 1
                if consecutiveKnown >= 3 then
                    break
                end
            end
        end
    end

    if added > 0 then
        self:Print(added .. " new bank transaction(s) captured.")
    end
end

-- Manual full scan (button in MainFrame) — captures everything not yet known
function WGS:ScanBankTransactions()
    if not IsInGuild() then
        self:Print("You are not in a guild.")
        return false
    end

    if not GetNumGuildBankMoneyTransactions then
        self:Print("Guild bank transaction API not available.")
        return false
    end

    local numTx = GetNumGuildBankMoneyTransactions()
    if numTx == 0 then
        self:Print("No guild bank transactions found. Open the guild bank first.")
        return false
    end

    self:CaptureNewTransactions()
    local txCount = self.db.global.guildBankTransactions and #self.db.global.guildBankTransactions or 0
    self:Print("Bank transactions total: " .. txCount .. " (WoW keeps last " .. numTx .. " entries)")
    return true
end

-- Manual gold capture (button in MainFrame)
function WGS:CaptureGold()
    if not IsInGuild() then
        self:Print("You are not in a guild.")
        return false
    end

    local guildMoney = GetGuildBankMoney and GetGuildBankMoney() or 0
    if guildMoney == 0 then
        self:Print("Guild bank gold is 0 — open the guild bank once to load the value.")
        return false
    end

    local db = self.db.global
    local previousMoney = db.lastKnownGold

    if previousMoney and previousMoney == guildMoney then
        self:Print("Bank gold unchanged: " .. formatGold(guildMoney))
        return true
    end

    db.lastKnownGold = guildMoney
    db.guildBankMoneyChanges = db.guildBankMoneyChanges or {}

    local diff = previousMoney and (guildMoney - previousMoney) or 0
    local sign = diff >= 0 and "+" or "-"

    table.insert(db.guildBankMoneyChanges, {
        timestamp = self:GetTimestamp(),
        recordedBy = self:GetPlayerKey(),
        money = guildMoney,
        moneyFormatted = formatGold(guildMoney),
        diff = diff,
        diffFormatted = sign .. formatGold(math.abs(diff)),
        previousMoney = previousMoney,
    })

    if previousMoney then
        self:Print("Bank gold captured: " .. formatGold(guildMoney) .. " (" .. sign .. formatGold(math.abs(diff)) .. ")")
    else
        self:Print("Bank gold captured: " .. formatGold(guildMoney))
    end

    return true
end

function WGS:GetGuildGoldFormatted()
    local money = self.db.global.lastKnownGold
    if money and money > 0 then
        return formatGold(money)
    end
    return nil
end
