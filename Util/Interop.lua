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

--- Test-only: drop the presence cache. Production code should not need
--- this — addon presence is fixed for the session. Exposed so busted
--- specs can flip _G.IsAddOnLoaded between cases without leaking state.
function WGS:_ResetAddonCache()
    presenceCache = {}
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

    -- Count loot rows that came from the MRT gap-fill path (Modules/
    -- Loot.lua tags them with source = "mrt"). Lifetime count, not
    -- "since reload" — gives the user a sense of whether the gap-fill
    -- has ever fired.
    local loot = self.db and self.db.global and self.db.global.loot or {}
    local mrtLootCount, mrtLootLast = 0, nil
    for _, row in ipairs(loot) do
        if row.source == "mrt" then
            mrtLootCount = mrtLootCount + 1
            local ts = tonumber(row.timestamp) or 0
            if not mrtLootLast or ts > mrtLootLast then mrtLootLast = ts end
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
    }
end

-- Pretty-print the InteropStatus snapshot to chat. Called from
-- /gh interop. Stays in Util/ because the slash dispatcher is in Core
-- and the formatting is interop-specific.
function WGS:PrintInteropStatus()
    local s = self:InteropStatus()
    local function ago(ts)
        if not ts or ts == 0 then return "never" end
        local d = (tonumber(time and time()) or 0) - ts
        if d < 60   then return d .. "s ago" end
        if d < 3600 then return math.floor(d / 60)   .. "m ago" end
        if d < 86400 then return math.floor(d / 3600) .. "h ago" end
        return math.floor(d / 86400) .. "d ago"
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
end
