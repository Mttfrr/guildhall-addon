local helpers = require("spec.helpers")

-- Modules/GuildBank.lua — bank capture flow. The historical bug this
-- spec exists to lock down: GetNumGuildBankMoneyTransactions() returns
-- 0 until the client explicitly queries the server's money log via
-- QueryGuildBankLog(MAX_GUILDBANK_TABS + 1). Without that query, the
-- addon's auto-capture on bank-open scanned an empty log and silently
-- recorded nothing — the user-visible "Bank scan: no data yet"
-- message was the only signal, and most users assumed it was a
-- timing issue rather than a missing API call.

local function setup()
    local WGS = helpers.setup()

    -- Bank API stubs. The real surface is much larger; tests only need
    -- the calls actually invoked by _HandleBankOpened + the gold/tx
    -- capture functions it chains to.
    _G.QueryGuildBankLog       = function(tab) WGS._lastBankQuery = tab end
    _G.MAX_GUILDBANK_TABS      = 6
    _G.GetGuildBankMoney       = function() return 0 end
    _G.GetNumGuildBankMoneyTransactions = function() return 0 end
    _G.IsInGuild               = function() return true end

    -- C_Timer.NewTimer is what the bank module uses to schedule the
    -- post-query capture. We stub it as a recording struct so the test
    -- can fire the deferred work synchronously without sleeping.
    _G.C_Timer = _G.C_Timer or {}
    function _G.C_Timer.NewTimer(_delay, fn)
        WGS._lastTimerFn = fn
        return { Cancel = function() end }
    end

    -- WGS:Print captures output for the assertion side; default in
    -- helpers prints to stdout which we don't need here.
    WGS._printed = {}
    function WGS:Print(s) self._printed[#self._printed + 1] = s end

    return WGS
end

describe("WGS:_HandleBankOpened", function()
    -- The fix: opening the bank must trigger a money-log query to the
    -- server. Without it, the deferred CaptureNewTransactions sees a
    -- zero-length log and the user sees "no data yet" forever.
    it("calls QueryGuildBankLog(MAX_GUILDBANK_TABS + 1) on bank open", function()
        local WGS = setup()
        WGS:_HandleBankOpened()
        assert.are.equal(7, WGS._lastBankQuery,
            "expected QueryGuildBankLog to be called with the money-log tab index")
    end)

    -- Defensive: if the API is somehow missing (e.g. an unsupported
    -- client flavor), the handler must not crash — it should still
    -- schedule the capture so gold-only flows keep working.
    it("does not crash when QueryGuildBankLog is unavailable", function()
        local WGS = setup()
        _G.QueryGuildBankLog = nil
        assert.has_no.errors(function() WGS:_HandleBankOpened() end)
        assert.is_function(WGS._lastTimerFn)
    end)

    -- The deferred capture runs through the existing CaptureGold +
    -- CaptureNewTransactions path. With money == 0 (default stub) the
    -- gold capture bails and we surface the "no data yet" diagnostic
    -- rather than a misleading "Bank captured: 0g 0s 0c" line.
    it("prints the diagnostic when the deferred capture finds no data", function()
        local WGS = setup()
        WGS:_HandleBankOpened()
        assert.is_function(WGS._lastTimerFn)
        WGS._lastTimerFn()
        local sawDiag = false
        for _, line in ipairs(WGS._printed) do
            if line:find("no data yet") then sawDiag = true end
        end
        assert.is_true(sawDiag)
    end)

    -- Happy path: server-side log populated. The deferred capture
    -- records the gold balance and reports the transaction count.
    it("prints the summary line when gold + transactions are available", function()
        local WGS = setup()
        _G.GetGuildBankMoney = function() return 12345600 end   -- 1234g 56s 0c
        _G.GetNumGuildBankMoneyTransactions = function() return 1 end
        _G.GetGuildBankMoneyTransaction = function(_)
            return "deposit", "Tester-Realm", 100, 0, 0, 0, 1
        end
        WGS:_HandleBankOpened()
        WGS._lastTimerFn()
        local sawSummary = false
        for _, line in ipairs(WGS._printed) do
            if line:find("Bank captured") and line:find("1 new transaction") then
                sawSummary = true
            end
        end
        assert.is_true(sawSummary, "expected 'Bank captured: ..., 1 new transaction(s).'")
        assert.are.equal(1, #WGS.db.global.guildBankTransactions)
    end)
end)
