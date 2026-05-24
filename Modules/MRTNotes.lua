---@type GuildHall
local WGS = GuildHall

-- Read-through bridge for MRT's shared raid note (`VMRT.Note.Text1`).
-- MRT is what most progression raids actually look at mid-pull; this
-- module surfaces that text in GuildHall's BossNotesFrame so officers
-- don't have to alt-tab. Read-only — write-back (officer edits notes
-- on the web → push to MRT's sync channel) is deferred.
--
-- Pure data accessor; no events, no frames, no chat. The UI side
-- (UI/BossNotesFrame.lua) calls WGS:GetMRTNote() when populating the
-- notes panel. If MRT isn't loaded the call returns nil and the panel
-- skips the "MRT Note" section silently.
--
-- Contract reference: docs/INTEROP.md (verified 2026-05-23 against
-- akbyrd/method-raid-tools snapshot of ykiigor's upstream).

---@type WGSModuleBase
local module = WGS:NewModule("MRTNotes")

function module:OnEnable() end

--- Return MRT's current shared-note text, or nil if unavailable.
---
--- Prefers MRT's public API (MRT.F.GetNote / GMRT.F:GetNote) so we get
--- the same formatted string MRT displays — color codes stripped, extra
--- whitespace collapsed — instead of the raw saved-variable. Falls back
--- to a direct read of VMRT.Note.Text1 if neither namespace exposes the
--- accessor (older MRT versions, partial loads).
---
--- @param raw boolean? — if true, return the raw saved-variable text
---   without going through MRT's formatter. Useful if a caller wants to
---   preserve in-note color codes for verbatim rendering.
function WGS:GetMRTNote(raw)
    if not self:HasMRTData() then return nil end

    if not raw then
        local mrt = _G.MRT
        if mrt and mrt.F and type(mrt.F.GetNote) == "function" then
            local ok, text = pcall(mrt.F.GetNote, true, true) -- (removeColors, removeExtraSpaces)
            if ok and type(text) == "string" and text ~= "" then
                return text
            elseif not ok then
                self:FireEvent("WGS_INTERNAL_ERROR", { source = "MRTNotes.MRT.F.GetNote", error = text })
            end
        end
        local gmrt = _G.GMRT
        if gmrt and gmrt.F and type(gmrt.F.GetNote) == "function" then
            local ok, text = pcall(gmrt.F.GetNote, gmrt.F, true, true)
            if ok and type(text) == "string" and text ~= "" then
                return text
            elseif not ok then
                self:FireEvent("WGS_INTERNAL_ERROR", { source = "MRTNotes.GMRT.F.GetNote", error = text })
            end
        end
    end

    local vmrt = _G.VMRT
    if vmrt and vmrt.Note and type(vmrt.Note.Text1) == "string" and vmrt.Note.Text1 ~= "" then
        return vmrt.Note.Text1
    end

    return nil
end
