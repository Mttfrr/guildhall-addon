---@type GuildHall
local WGS = GuildHall

-- Cross-addon presence detection. Used by the MRT/NSRT bridge modules
-- (Modules/MRTNotes.lua, future MRT attendance + loot bridges) to
-- short-circuit when the other addon isn't loaded — so GuildHall stays
-- a zero-cost dependency for guilds that don't run MRT.
--
-- The cache is per-session: addons loaded after PLAYER_LOGIN through
-- LoadAddOn() are rare enough that we don't bother invalidating; if a
-- bug report says "I /reload after enabling MRT and the bridge doesn't
-- light up", drop the cache and add a SPELLS_CHANGED-equivalent hook.

local presenceCache = {}

--- Is the named addon loaded right now?
---
--- Wraps C_AddOns.IsAddOnLoaded (modern API) with a fallback to the
--- legacy global IsAddOnLoaded for older clients. Result is cached per
--- session to avoid the per-call cost when MRT-bridge hot paths poll
--- repeatedly (e.g. inside ENCOUNTER_END handlers).
function WGS:HasAddon(name)
    if not name then return false end
    local cached = presenceCache[name]
    if cached ~= nil then return cached end

    local loaded = false
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        loaded = C_AddOns.IsAddOnLoaded(name) and true or false
    elseif _G.IsAddOnLoaded then
        loaded = _G.IsAddOnLoaded(name) and true or false
    end

    presenceCache[name] = loaded
    return loaded
end

-- RCLootCouncil probe result. nil = not probed yet, false = probed and
-- absent, otherwise the addon object itself. Same per-session caching
-- rationale as presenceCache.
local rclcProbe

--- Test-only: drop the presence cache. Production code should not need
--- this — addon presence is fixed for the session. Exposed so busted
--- specs can flip _G.IsAddOnLoaded between cases without leaking state.
function WGS:_ResetAddonCache()
    presenceCache = {}
    rclcProbe = nil
end

--- The RCLootCouncil addon object, or nil when it isn't available.
---
--- Probes the AceAddon registry directly (silent) rather than trusting
--- the folder name — a renamed install still registers as
--- "RCLootCouncil". The result is only accepted when it exposes the
--- surface the bridge consumes (`Require`, RCLC's class-system entry
--- point), so a foreign addon squatting the name degrades to "absent"
--- instead of a crash inside Modules/RCLC.lua.
function WGS:GetRCLC()
    if rclcProbe ~= nil then return rclcProbe or nil end
    local found
    local ok, aceAddon = pcall(LibStub, "AceAddon-3.0", true)
    if ok and type(aceAddon) == "table" and type(aceAddon.GetAddon) == "function" then
        local ok2, addon = pcall(aceAddon.GetAddon, aceAddon, "RCLootCouncil", true)
        if ok2 then found = addon end
    end
    if type(found) ~= "table" or type(found.Require) ~= "function" then
        found = nil
    end
    rclcProbe = found or false
    return found
end

--- Is RCLootCouncil available right now?
function WGS:HasRCLC()
    return self:GetRCLC() ~= nil
end

--- True if any addon that exposes the VMRT global is available — covers
--- classic MRT, NSRT (Method's modern fork which keeps VMRT for
--- backwards compat), and any future addon writing to the same shared
--- structures. The MRT bridge sites in Modules/Attendance.lua and
--- Modules/Loot.lua use this in place of `HasAddon("MRT")` so NSRT
--- users get the same integration without us having to enumerate every
--- fork — we ultimately only care that VMRT.Attendance / VMRT.LootHistory
--- are populated by *someone*.
---
--- The `_G.VMRT` check is the actual signal; HasAddon checks are kept
--- as a cheap early-out so bridge sites in hot paths (e.g. inside
--- ENCOUNTER_END handlers) don't do a table lookup when no compatible
--- addon is loaded at all.
function WGS:HasMRTData()
    if self:HasAddon("MRT") or self:HasAddon("NSRT") then return true end
    return type(_G.VMRT) == "table"
end

-- Diagnostic snapshot of cross-addon interop state. Returned as a
-- structured table so the slash command can print it AND specs can
-- assert against it. Anything that depends on per-row data
-- (loot/attendance lifetime counts) reads db.global at call time —
-- no caching, called rarely (manual /gh interop only).
function WGS:InteropStatus()
    local mrtLoaded  = self:HasAddon("MRT")
    local nsrtLoaded = self:HasAddon("NSRT") or self:HasAddon("NorthernSkyRaidTools")
    local vmrt       = _G.VMRT
    local nsrt       = _G.NSRT

    -- Count loot rows per bridge source (Modules/Loot.lua tags MRT
    -- gap-fill rows source = "mrt"; Modules/RCLC.lua tags award rows
    -- source = "rclc"). Lifetime counts, not "since reload" — gives the
    -- user a sense of whether each bridge has ever fired.
    local loot = self.db and self.db.global and self.db.global.loot or {}
    local mrtLootCount, mrtLootLast = 0, nil
    local rclcLootCount, rclcLootLast = 0, nil
    for _, row in ipairs(loot) do
        if row.source == "mrt" then
            mrtLootCount = mrtLootCount + 1
            local ts = tonumber(row.timestamp) or 0
            if not mrtLootLast or ts > mrtLootLast then mrtLootLast = ts end
        elseif row.source == "rclc" then
            rclcLootCount = rclcLootCount + 1
            local ts = tonumber(row.timestamp) or 0
            if not rclcLootLast or ts > rclcLootLast then rclcLootLast = ts end
        end
    end

    -- Count attendance sessions that have a bossAttendance field
    -- attached (set by BuildBossAttendanceFromMRT at session end).
    -- A populated bossAttendance is the only signal that MRT
    -- attendance gap-fill did something useful for that session.
    local attendance = self.db and self.db.global and self.db.global.attendance or {}
    local mrtAttCount, mrtAttLast = 0, nil
    for _, sess in ipairs(attendance) do
        if type(sess.bossAttendance) == "table" and #sess.bossAttendance > 0 then
            mrtAttCount = mrtAttCount + 1
            local ts = tonumber(sess.endedAt) or tonumber(sess.startedAt) or 0
            if not mrtAttLast or ts > mrtAttLast then mrtAttLast = ts end
        end
    end

    -- Sub-table inventory of the VMRT global — gives a single signal
    -- for "is the addon actually populating its global, or is it just
    -- loaded with an empty table?"
    local vmrtSubTables = 0
    if type(vmrt) == "table" then
        for _ in pairs(vmrt) do vmrtSubTables = vmrtSubTables + 1 end
    end

    -- RCLC version drift: docs/INTEROP.md's bridge contract was
    -- verified against RCLootCouncil 3.23.x. A newer RCLC still mostly
    -- degrades to pcall'd no-ops if its internals moved, but the
    -- officer should KNOW the bridge is running against an unverified
    -- surface instead of debugging silently-missing award rows.
    local rclcVersion, rclcVersionDrifted = nil, false
    do
        local rc = self:GetRCLC()
        if rc and type(rc.version) == "string" and rc.version ~= "" then
            rclcVersion = rc.version
            rclcVersionDrifted = self:CompareVersions(rclcVersion, "3.24.0") >= 0
        end
    end

    -- MRT note text size: GMRT.F:GetNote() or MRT.F.GetNote() if the
    -- public API is available, otherwise VMRT.Note.Text1 fallback.
    local noteText, noteAPIUsed = nil, nil
    if _G.MRT and _G.MRT.F and type(_G.MRT.F.GetNote) == "function" then
        local ok, txt = pcall(_G.MRT.F.GetNote, true, true)
        if ok then noteText, noteAPIUsed = txt, "MRT.F.GetNote" end
    elseif _G.GMRT and _G.GMRT.F and type(_G.GMRT.F.GetNote) == "function" then
        local ok, txt = pcall(_G.GMRT.F.GetNote, _G.GMRT.F)
        if ok then noteText, noteAPIUsed = txt, "GMRT.F:GetNote" end
    elseif type(vmrt) == "table" and vmrt.Note then
        noteText, noteAPIUsed = vmrt.Note.Text1, "VMRT.Note.Text1 (raw)"
    end

    return {
        mrtLoaded       = mrtLoaded,
        nsrtLoaded      = nsrtLoaded,
        vmrtPresent     = type(vmrt) == "table",
        vmrtSubTables   = vmrtSubTables,
        nsrtPresent     = type(nsrt) == "table",
        hasMRTData      = self:HasMRTData(),
        mrtLootCount    = mrtLootCount,
        mrtLootTotal    = #loot,
        mrtLootLast     = mrtLootLast,
        mrtAttCount     = mrtAttCount,
        mrtAttTotal     = #attendance,
        mrtAttLast      = mrtAttLast,
        noteText        = noteText,
        noteSize        = noteText and #noteText or 0,
        noteAPIUsed     = noteAPIUsed,
        rclcLoaded      = self:HasRCLC(),
        -- ~= false so a fresh test db (no AceDB defaults) reads the
        -- same as the runtime default (on).
        rclcCaptureOn   = (self.db and self.db.profile and self.db.profile.rclcCapture) ~= false,
        rclcLootCount   = rclcLootCount,
        rclcLootLast    = rclcLootLast,
        rclcVersion     = rclcVersion,
        rclcVersionDrifted = rclcVersionDrifted,
    }
end

-- Pretty-print the InteropStatus snapshot to chat. Called from
-- /gh interop. Stays in Util/ because the slash dispatcher is in Core
-- and the formatting is interop-specific.
function WGS:PrintInteropStatus()
    local s = self:InteropStatus()
    -- Shared relative-time formatter (Util/Time.lua).
    local function ago(ts)
        return self:FormatRelativeTime(ts)
    end
    local function yesno(b)
        return b and "|cff00ff00yes|r" or "|cff888888no|r"
    end

    self:Print("|cffffd100GuildHall interop status|r")
    self:Print(string.format("  MRT loaded:        %s", yesno(s.mrtLoaded)))
    self:Print(string.format("  NSRT loaded:       %s", yesno(s.nsrtLoaded)))
    self:Print(string.format("  VMRT global:       %s (%d sub-tables)",
        yesno(s.vmrtPresent), s.vmrtSubTables))
    self:Print(string.format("  NSRT global:       %s", yesno(s.nsrtPresent)))

    if s.hasMRTData then
        self:Print("|cffffd100  Loot gap-fill|r")
        self:Print(string.format("    rows tagged source=mrt: %d / %d total  (last: %s)",
            s.mrtLootCount, s.mrtLootTotal, ago(s.mrtLootLast)))
        self:Print("|cffffd100  Boss attendance|r")
        self:Print(string.format("    sessions with bossAttendance: %d / %d total  (last: %s)",
            s.mrtAttCount, s.mrtAttTotal, ago(s.mrtAttLast)))
        if s.noteAPIUsed then
            self:Print(string.format("|cffffd100  MRT note|r: %d bytes via %s",
                s.noteSize, s.noteAPIUsed))
        end
    else
        self:Print(
            "|cff888888  No MRT/NSRT data available — bridge code stays dormant.|r")
    end

    self:Print(string.format("  RCLC loaded:       %s%s", yesno(s.rclcLoaded),
        s.rclcVersion and ("  (v" .. s.rclcVersion .. ")") or ""))
    if s.rclcVersionDrifted then
        self:Print(string.format(
            "  |cffffaa00RCLC v%s is newer than the verified 3.23.x — the bridge " ..
            "degrades to no-ops where RCLC's internals moved. Check for a GuildHall update.|r",
            s.rclcVersion))
    end
    if s.rclcLoaded then
        self:Print("|cffffd100  RCLC award capture|r")
        self:Print(string.format("    capture: %s   rows tagged source=rclc: %d / %d total  (last: %s)",
            s.rclcCaptureOn and "|cff00ff00on|r" or "|cff888888off|r",
            s.rclcLootCount, s.mrtLootTotal, ago(s.rclcLootLast)))
        self:Print("    |cff888888/gh rclc import pulls RCLC's saved history into the loot log|r")
    end
end
