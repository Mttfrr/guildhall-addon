---@type GuildHall
local WGS = GuildHall

-- Signup status — single source of truth.
--
-- Mirrors the platform's ATTENDANCE_STATUSES (client/src/utils.js) so
-- the addon never invents its own wording for a status the website
-- already named. When a new code or label lands on the platform side,
-- this is the only file in the addon that needs updating.
--
-- Codes:
--   P   Present (committed)        L   Late (committed)
--   LT  Late (officer) (committed) B   Bench (committed)
--   T   Tentative                  A   Absent
--   LE  Left early (tier-2)        RM  Replaced mid-raid (tier-2)
--
-- "Committed" = a signup the officer can count on showing up in some
-- form (Present, Late, Late-officer, Bench). Tentative and Absent
-- aren't committed; tier-2 codes (LE / RM) are after-the-fact.

WGS.SIGNUP_STATUS_LABELS = {
    P  = "Present",
    L  = "Late",
    LT = "Late (officer)",
    B  = "Bench",
    T  = "Tentative",
    A  = "Absent",
    LE = "Left early",
    RM = "Replaced mid-raid",
}

WGS.SIGNUP_STATUS_COLORS = {
    P  = "ff00ff00", L  = "ffffd100", LT = "ffffaa00", B = "ff888888",
    T  = "ffaaaaaa", A  = "ffff5555",
    LE = "ffff8800", RM = "ff66ccff",
}

WGS.SIGNUP_STATUS_COMMITTED = { P = true, L = true, LT = true, B = true }

-- Display order matching the platform's Discord embed grouping
-- (Present → Late → Late(officer) → Bench → Tentative → Absent → LE → RM).
-- UI surfaces iterate this when rendering per-status sections so the
-- order stays consistent across the rail, the Roster section, the
-- chat-share output, and any future surface.
WGS.SIGNUP_STATUS_ORDER = { "P", "L", "LT", "B", "T", "A", "LE", "RM" }

-- Convenience: full label including colour markup. Falls back to the
-- raw code if unknown so an unrecognised status still renders something.
function WGS:FormatSignupStatus(code)
    local label = self.SIGNUP_STATUS_LABELS[code] or code or "?"
    local color = self.SIGNUP_STATUS_COLORS[code] or "ffaaaaaa"
    return "|c" .. color .. label .. "|r"
end

-- True iff this status code counts as "committed" (Present / Late /
-- Late-officer / Bench). Used by chat-share + invite paths to filter
-- to people the officer expects to see in raid.
function WGS:IsCommittedStatus(code)
    return self.SIGNUP_STATUS_COMMITTED[code] == true
end

---------------------------------------------------------------------------
-- Officer signup-status mutation
---------------------------------------------------------------------------
--
-- Officers right-click a player in the Events Roster section to mark
-- them Late / Tentative / Bench / Absent / etc. without leaving WoW.
-- The change lands in db.global.signups in place AND gets queued in
-- db.global.pendingSignupChanges so the next addon-sync export ships
-- it to the platform. Idempotent: setting the same status twice is a
-- no-op; the queue collapses to one entry per (event, character).
--
-- Permission gate mirrors the other officer-side mutations (invite,
-- export, sortgroups). Non-officers see a clear "requires officer"
-- print and the mutation is rejected.

function WGS:UpdateSignupStatus(eventId, characterName, status)
    if not self:IsGuildOfficer() then
        self:Print("|cffff5555Marking signups requires officer rank.|r")
        return false, "not officer"
    end
    if not tonumber(eventId) or not characterName or characterName == "" then
        return false, "bad args"
    end
    if not self.SIGNUP_STATUS_LABELS[status] then
        return false, "unknown status: " .. tostring(status)
    end

    self.db.global.signups = self.db.global.signups or {}
    local signups = self.db.global.signups
    local matched
    for _, s in ipairs(signups) do
        if s.eventId == eventId and s.characterName == characterName then
            matched = s; break
        end
    end
    if matched then
        if matched.status == status then return true end   -- no-op
        matched.status = status
    else
        signups[#signups + 1] = {
            eventId       = eventId,
            characterName = characterName,
            status        = status,
        }
    end

    -- Queue for the next export. Collapse duplicates: if there's
    -- already a pending entry for this (event, character), update
    -- its status + timestamp in place rather than appending a
    -- second row. Keeps the queue small and idempotent.
    self.db.global.pendingSignupChanges = self.db.global.pendingSignupChanges or {}
    local queue = self.db.global.pendingSignupChanges
    local existing
    for _, q in ipairs(queue) do
        if q.eventId == eventId and q.characterName == characterName then
            existing = q; break
        end
    end
    if existing then
        existing.status = status
        existing.t      = self:GetTimestamp()
    else
        queue[#queue + 1] = {
            eventId       = eventId,
            characterName = characterName,
            status        = status,
            t             = self:GetTimestamp(),
        }
    end

    self:FireEvent("WGS_SIGNUP_EDITED", {
        eventId       = eventId,
        characterName = characterName,
        status        = status,
    })
    self:Print(string.format(
        "Marked |cffaaccff%s|r as %s for event #%s. Re-export to push.",
        characterName,
        self:FormatSignupStatus(status),
        tostring(eventId)))
    return true
end
