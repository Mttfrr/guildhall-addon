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
