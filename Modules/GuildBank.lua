---@type GuildHall
local WGS = GuildHall

---@class WGSGuildBankModule: AceModule, AceEvent-3.0
local module = WGS:NewModule("GuildBank", "AceEvent-3.0")

local pendingMoneyUpdate = nil
local pendingBankOpen = nil
-- Fingerprints of already-captured transactions to prevent duplicates
local capturedFingerprints = {}

function module:OnEnable()
    -- GUILDBANK_UPDATE_MONEY: fires when the gold balance changes
    -- (deposits, withdrawals, repairs). Drives the gold-snapshot diff
    -- recording. Does NOT fire when the money-log query response
    -- arrives — that's a separate event, GUILDBANKLOG_UPDATE.
    self:RegisterEvent("GUILDBANK_UPDATE_MONEY", "OnMoneyUpdate")
    -- GUILDBANKLOG_UPDATE: fires when the server responds to a
    -- QueryGuildBankLog call with money- or item-log data. Without
    -- this subscription, the addon would issue the query on bank open
    -- (or the user would click Money Log themselves) and the response
    -- would arrive into a void — GetNumGuildBankMoneyTransactions()
    -- would suddenly return non-zero but nothing would read it.
    -- Routed through the same debounce as OnMoneyUpdate so a flurry
    -- of log updates (mass-repair sessions trigger several) collapses
    -- to one capture.
    self:RegisterEvent("GUILDBANKLOG_UPDATE", "OnLogUpdate")
    -- GUILDBANKFRAME_OPENED is the historical event; in modern retail
    -- some bank-replacement addons swallow GuildBankFrame's OnShow and
    -- the event never fires. PLAYER_INTERACTION_MANAGER_FRAME_SHOW is
    -- the engine-level "an NPC interaction frame opened" event,
    -- filtered to the guild-banker type — fires regardless of which
    -- frame implementation actually renders. We subscribe to both and
    -- let _HandleBankOpened be idempotent against double-fire (the
    -- pendingBankOpen timer cancels its predecessor).
    self:RegisterEvent("GUILDBANKFRAME_OPENED", "OnBankOpened")
    self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "OnInteractionFrameShow")
end

function module:OnMoneyUpdate()
    -- Debounce: multiple events can fire rapidly (e.g. mass repairs)
    if pendingMoneyUpdate then pendingMoneyUpdate:Cancel() end
    pendingMoneyUpdate = C_Timer.NewTimer(0.5, function()
        pendingMoneyUpdate = nil
        WGS:OnGoldChanged()
    end)
end

-- PLAYER_INTERACTION_MANAGER_FRAME_SHOW carries an interaction-type
-- enum as its first arg. We only want the guild-banker type; the same
-- event fires for vendors, mailboxes, void storage, etc., and
-- triggering bank capture on every NPC frame would be obviously wrong.
-- Enum.PlayerInteractionType.GuildBanker = 10 in retail TWW; if the
-- enum table isn't available (older client flavors), fall back to the
-- numeric constant so the subscription doesn't no-op.
function module:OnInteractionFrameShow(_, interactionType)
    local guildBankerType = (Enum and Enum.PlayerInteractionType
                                  and Enum.PlayerInteractionType.GuildBanker) or 10
    if interactionType ~= guildBankerType then return end
    WGS:_HandleBankOpened()
end

function module:OnLogUpdate()
    -- Log updates skip the OnGoldChanged guard (which bails if
    -- GetGuildBankMoney returns 0 — useful for cold-load races on
    -- money events, useless and harmful here since the log can
    -- legitimately arrive before the gold balance does). Go straight
    -- to CaptureNewTransactions, but reuse the same debounce so a
    -- burst of log updates collapses to one capture.
    if pendingMoneyUpdate then pendingMoneyUpdate:Cancel() end
    pendingMoneyUpdate = C_Timer.NewTimer(0.5, function()
        pendingMoneyUpdate = nil
        WGS:CaptureGold()                  -- best-effort; no-op if 0
        WGS:CaptureNewTransactions()       -- the actual point of the event
    end)
end

-- Body of the bank-opened handler, extracted to a WGS method so tests
-- can invoke it without going through the AceModule. The AceModule
-- wrapper below is a one-line trampoline.
function WGS:_HandleBankOpened()
    -- Immediate "the event fired" feedback. Without this, opening the
    -- bank looks like a no-op while the debounce runs, and on
    -- cold-open WoW hasn't populated GetGuildBankMoney yet so the
    -- post-debounce summary may also print nothing useful. This line
    -- confirms the addon noticed.
    self:Print("Scanning guild bank…")

    -- Ask the server for the money log. Without this, the client never
    -- populates the money-transaction log on its own —
    -- GetNumGuildBankMoneyTransactions() returns 0 until either we
    -- query, or the user manually clicks the Money Log tab in
    -- Blizzard's built-in bank UI. The money log is the special tab
    -- index MAX_GUILDBANK_TABS + 1 (Blizzard's FrameXML uses the same
    -- magic number in GuildBankFrame.lua). The server responds
    -- asynchronously by firing GUILDBANK_UPDATE_MONEY again, which our
    -- OnMoneyUpdate handler picks up and routes through
    -- CaptureNewTransactions. The 2s delay below covers the
    -- round-trip; users on bad connections may need to reopen to
    -- catch transactions that didn't land in time.
    if QueryGuildBankLog and MAX_GUILDBANK_TABS then
        QueryGuildBankLog(MAX_GUILDBANK_TABS + 1)
    end

    if pendingBankOpen then pendingBankOpen:Cancel() end
    pendingBankOpen = C_Timer.NewTimer(2, function()
        pendingBankOpen = nil
        local goldOk = WGS:CaptureGold()
        local txAdded = WGS:CaptureNewTransactions() or 0
        if goldOk then
            local gold = WGS:GetGuildGoldFormatted() or "?"
            if txAdded > 0 then
                WGS:Print(string.format("Bank captured: %s, %d new transaction(s).", gold, txAdded))
            else
                WGS:Print(string.format("Bank captured: %s.", gold))
            end
        else
            -- Gold capture bailed (no guild / API not loaded / 0 balance).
            -- Most common cause: balance hasn't loaded yet; another
            -- GUILDBANK_UPDATE_MONEY will fire once it has and the
            -- captures will run silently then. Still, the user deserves
            -- a clear "we tried" message.
            WGS:Print("Bank scan: no data yet — try reopening the bank in a moment.")
        end
    end)
end

function module:OnBankOpened()
    WGS:_HandleBankOpened()
end

--- Format a copper amount as "Ng Ms Pc". Exposed on the WGS namespace
--- because other modules (UI tiles, sync diagnostics) need the same
--- shape — keeping it local here meant every caller re-implemented it.
function WGS:FormatGold(copper)
    copper = copper or 0
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
            moneyFormatted = WGS:FormatGold(guildMoney),
            diff = diff,
            diffFormatted = sign .. WGS:FormatGold(math.abs(diff)),
            previousMoney = previousMoney,
        })
    end

    -- Auto-capture new transactions from the log
    self:CaptureNewTransactions()
end

-- Scan the transaction log and capture only entries we haven't seen yet
function WGS:CaptureNewTransactions()
    if not GetNumGuildBankMoneyTransactions then return 0 end

    local numTx = GetNumGuildBankMoneyTransactions()
    -- numTx == 0 happens before the user clicks the Money Log tab.
    -- Bail out quietly — clicking the tab will fire another
    -- GUILDBANK_UPDATE_MONEY that runs this again.
    if numTx == 0 then return 0 end

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
                    amountFormatted = WGS:FormatGold(entry.amount),
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

    -- Returns the count of rows added so OnBankOpened can surface a
    -- single summary line. Per-transaction chatter during a raid is
    -- noise; the summary is the only user-visible signal.
    --
    -- Fire WGS_BANK_CAPTURED so any open Bank sub-view can re-populate
    -- without the user having to switch tabs. Only fire when something
    -- actually changed — avoids storming the UI with re-renders during
    -- a no-op repeat scan.
    if added > 0 then
        self:FireEvent("WGS_BANK_CAPTURED", { added = added, total = #db.guildBankTransactions })
    end
    return added
end

-- Silent gold snapshot. Called on GUILDBANK_UPDATE_MONEY (debounced) and
-- on GUILDBANKFRAME_OPENED. Returns true if it captured something useful,
-- false if it bailed out (no guild / API missing / zero).
function WGS:CaptureGold()
    if not IsInGuild() then return false end

    local guildMoney = GetGuildBankMoney and GetGuildBankMoney() or 0
    if guildMoney == 0 then return false end

    local db = self.db.global
    local previousMoney = db.lastKnownGold

    if previousMoney and previousMoney == guildMoney then
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
        moneyFormatted = WGS:FormatGold(guildMoney),
        diff = diff,
        diffFormatted = sign .. WGS:FormatGold(math.abs(diff)),
        previousMoney = previousMoney,
    })

    -- Notify UI subscribers so the Bank sub-view balance updates
    -- without the user having to switch tabs.
    self:FireEvent("WGS_BANK_CAPTURED", { goldChanged = true, money = guildMoney })
    return true
end

function WGS:GetGuildGoldFormatted()
    local money = self.db.global.lastKnownGold
    if money and money > 0 then
        return WGS:FormatGold(money)
    end
    return nil
end
