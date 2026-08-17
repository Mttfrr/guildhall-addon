---@type GuildHall
local WGS = GuildHall

-- One-time release-notes modal. Shown on the first PLAYER_ENTERING_WORLD
-- after the addon updates to a new version, so users see what changed
-- without having to read the CHANGELOG.md on GitHub. Fires once per
-- version bump per character — `db.profile.lastSeenVersion` records
-- the highest version the user has acknowledged; the modal pops when
-- WGS.version > lastSeenVersion and the user closes it via "Got it"
-- to advance the marker.
--
-- Fresh installs (lastSeenVersion == nil) skip the modal entirely and
-- set lastSeenVersion = current. The release notes only matter when
-- there's a delta from a previous state; spamming three legacy
-- release blurbs at someone who just installed adds friction without
-- value.

-- Highlights per version. Kept in lockstep with CHANGELOG.md but
-- intentionally pithier — these are the "what's new" headlines, not
-- the full per-commit chronology. Add new entries at the top; old
-- entries stay so a user who skipped multiple versions sees all of
-- them stacked in one dialog (newest version on top).
local RELEASE_NOTES = {
    {
        version = "0.8.0-beta",
        title = "RCLootCouncil integration",
        sections = {
            { heading = "Added", items = {
                "Run RCLootCouncil? The council's decisions now land in the loot log — response (Mainspec / Offspec / …), vote count, and award reasons — captured by every raider running GuildHall, not just the loot master",
                "Your GuildHall wishlists show up where the council votes: a sortable GuildHall column in RCLC's voting frame, plus your own wish on the roll window",
                "Droptimizer gains ride along — a raider who imported their Raidbots sim on the platform shows as \"BiS +2.3%\" in the voting column, the roll window, the Wishlists browser and the loot tooltip",
                "Deleting a loot row in-game (or the trade-flow retiring a mis-captured holder) now deletes the platform's copy on your next export — no more phantom rows living on the website forever",
                "Trade-flow accuracy: when a drop lands on one raider and the council awards it to another, the log keeps one row — the winner's",
                "/gh rclc import backfills your entire RCLC loot history into GuildHall in one pass (safe to re-run)",
                "New toggles under Settings → RCLootCouncil — both on by default, and completely inert without RCLC installed",
            } },
            { heading = "Changed", items = {
                "Redesigned Wishlists browser — events-style rows with class icons, wishers ranked BiS-first, and items grouped under the boss each wish actually names (with loot-history fallback for older imports)",
                "Filter the Wishlists browser by Location (where the item drops), Slot and Armor type (Cloth → Plate) alongside Boss — the four combine, and item rows show the armor type and location next to the slot",
                "Wishlist imports are tier-scoped — a retired tier's wishes no longer show on tooltips or in RCLC frames",
                "Wishlist items added from Discord (/wishlist add) reach the addon on your next import — no website visit needed",
            } },
        },
    },
    {
        version = "0.7.7-beta",
        title = "Raid-forming tools",
        sections = {
            { heading = "Added", items = {
                "Raid Status snapshot on the Events detail panel — every expected raider bucketed live: In raid / Invited (waiting) / Not invited / Offline, with a one-line count summary",
                "\"Organize Groups\" button — one click sorts everyone into the subgroups your platform raid comp assigns",
                "Auto-sort into comp groups as raiders accept (on by default; never reshuffles people you've placed by hand)",
            } },
            { heading = "Changed", items = {
                "Mass invite has no cooldown any more — every press (re-)invites everyone online who isn't in the group yet",
            } },
        },
    },
    {
        version = "0.7.6-beta",
        title = "Raid-start tracking prompt",
        sections = {
            { heading = "Added", items = {
                "\"You're about to raid — start tracking?\" prompt when you form/join a raid that lines up with a scheduled event — one click starts attendance tracking (new toggle, on by default)",
            } },
            { heading = "Fixed", items = {
                "Mass invite now re-invites people who declined, let the invite expire, or reconnected — no more one-shot Invite button",
            } },
        },
    },
    {
        version = "0.7.5-beta",
        title = "Menus fixed + officer corrections sync",
        sections = {
            { heading = "Added", items = {
                "Corrections now propagate to other officers within seconds — re-tag a loot row, rebind or delete an attendance session, remove a member, and every officer's addon follows (no re-import round-trip)",
                "Live UI refresh — Mark-status, new loot drops, boss kills, and comp snapshots re-render the visible tab immediately",
                "Right-click player menu on the Teams → Roster sub-view",
            } },
            { heading = "Fixed", items = {
                "Right-click menu actions actually fire on live retail (Whisper / Invite / Copy name / Copy profile link)",
                "Right-click → Invite works cross-realm; Copy name / Copy profile link popups contain the value again",
                "Invite button correctly excludes players marked Bench",
            } },
        },
    },
    {
        version = "0.7.4-beta",
        title = "Comp diff, officer status edits + /gh tooling",
        sections = {
            { heading = "Added", items = {
                "Planned-vs-actual raid comp diff while mid-raid (Missing / Subbed in, per group)",
                "Class-balance warnings on the planned comp (no combat rez / no Bloodlust / class stacking)",
                "Officer right-click \"Mark status\" on Roster rows — all 8 status codes, exported to the platform",
                "Stale-data banner when the last import is older than 7 days, with a one-click jump to Sync",
                "/gh search <name> (cross-context lookup), /gh export <table> (selective export), /gh diag (data health summary)",
            } },
            { heading = "Fixed", items = {
                "Every right-click menu works on current retail again (EasyMenu was removed by Blizzard; migrated to MenuUtil)",
            } },
        },
    },
    {
        version = "0.7.3",
        title = "Contextual menus everywhere + /reload survival",
        sections = {
            { heading = "Added", items = {
                "Right-click on any player name → Whisper / Invite / Inspect / Copy name / Copy profile link",
                "Right-click on an event in the Events rail → Copy event link / Invite signups",
                "Right-click on the minimap button → Show frame, Sync now, Attendance toggle, Open Sync tab, Settings",
                "Roster section gets a filter-by-name search box (matches Logs → Loot's filter pattern)",
                "Hover tooltips on Events rail status pills explain the Today / Soon / Upcoming / Past cutoffs",
                "Chat lines on attendance start AND stop — matches the bank-capture confirmation style",
            } },
            { heading = "Changed", items = {
                "/reload mid-raid no longer drops the in-flight attendance session (rehydrated from SavedVariables with an 8h orphan guard)",
                "WGS:AutoInvite gained an optional event override so the rail kebab can target a specific event",
            } },
        },
    },
    {
        version = "0.7.2",
        title = "Timezone fix + Track button mid-raid",
        sections = {
            { heading = "Fixed", items = {
                "Cross-timezone event status — Paris raid viewed from HK no longer flips to \"Past\" mid-raid (platform now ships UTC start_ts)",
                "Track button stays enabled mid-raid even when EventStatus reads \"Past\" — IsInRaid carve-out",
            } },
            { heading = "Changed", items = {
                "Slash command dispatch table replaces the elseif chain in Core.lua",
                "Event-picker menu builder shared between Logs → Loot and Logs → Attendance",
                "Correction mutators share a hint + raidCompResults cascade helper",
            } },
            { heading = "Added", items = {
                "/gh peerloopback — dev-only PeerSync loopback for single-client testing",
            } },
        },
    },
}

---------------------------------------------------------------------------
-- Modal frame
---------------------------------------------------------------------------

local modalFrame
local function CreateWhatsNewModal()
    local f = CreateFrame("Frame", "GuildHallWhatsNewFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(560, 480)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "GuildHallWhatsNewFrame")

    f.TitleBg:SetHeight(30)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", f.TitleBg, "TOPLEFT", 5, -3)
    f.title:SetText("What's new in GuildHall")

    -- Scroll area for the per-version content. Sized to leave room for
    -- the "Got it" button at the bottom.
    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -35)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 50)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(510)
    content:SetHeight(1)
    sf:SetScrollChild(content)
    f.content = content

    -- Footer button.
    local gotIt = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    gotIt:SetSize(120, 24)
    gotIt:SetPoint("BOTTOM", f, "BOTTOM", 0, 15)
    gotIt:SetText("Got it")
    gotIt:SetScript("OnClick", function()
        -- Mark every version up through current as seen so this user
        -- doesn't see the same notes again on next reload.
        WGS.db.profile.lastSeenVersion = WGS.version
        f:Hide()
    end)

    return f
end

local function PopulateContent(f)
    -- Wipe any previous children/regions. ClearContainer-style — we
    -- can re-show with a different version range without leaking
    -- font strings across renders.
    for _, child in ipairs({ f.content:GetChildren() }) do child:Hide() end
    for _, region in ipairs({ f.content:GetRegions() }) do region:Hide() end

    -- Render every version newer than lastSeenVersion, newest first.
    local lastSeen = WGS.db.profile.lastSeenVersion
    local toShow = {}
    for _, entry in ipairs(RELEASE_NOTES) do
        if not lastSeen or WGS:CompareVersions(entry.version, lastSeen) > 0 then
            toShow[#toShow + 1] = entry
        end
    end
    if #toShow == 0 then return end

    local y = 0
    for _, entry in ipairs(toShow) do
        local versionHdr = f.content:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        versionHdr:SetPoint("TOPLEFT", f.content, "TOPLEFT", 4, y)
        versionHdr:SetText("|cffffd100v" .. entry.version .. "|r  " ..
            "|cffaaaaaa\194\183|r  |cffcccccc" .. entry.title .. "|r")
        y = y - 22

        for _, section in ipairs(entry.sections) do
            local sectionHdr = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            sectionHdr:SetPoint("TOPLEFT", f.content, "TOPLEFT", 16, y)
            sectionHdr:SetText("|cffffa040" .. section.heading .. "|r")
            y = y - 18

            for _, item in ipairs(section.items) do
                local bullet = f.content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                bullet:SetPoint("TOPLEFT", f.content, "TOPLEFT", 28, y)
                bullet:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", -4, y)
                bullet:SetJustifyH("LEFT")
                bullet:SetWordWrap(true)
                bullet:SetText("|cffaaaaaa\226\128\162|r  " .. item)
                -- Wrap the height calculation — long bullets multi-line.
                y = y - math.max(16, bullet:GetStringHeight() + 4)
            end
            y = y - 6   -- breathing room between sections
        end
        y = y - 10   -- between versions
    end

    f.content:SetHeight(math.abs(y) + 8)
end

---------------------------------------------------------------------------
-- Public entry points
---------------------------------------------------------------------------

-- Show the modal regardless of seen-state. Used by /gh whatsnew so a
-- user can re-open the dialog any time, by the main frame's title-bar
-- badge when there's an unread version bump, and from anywhere else
-- that wants to surface it.
function WGS:ShowWhatsNew()
    if not modalFrame then modalFrame = CreateWhatsNewModal() end
    PopulateContent(modalFrame)
    modalFrame:Show()
end

-- Does this character have a pending "what's new" — i.e. is the
-- running addon version newer than the last one acknowledged? The
-- main frame's title-bar badge surfaces this so the user opts INTO
-- viewing the notes (vs the old PLAYER_ENTERING_WORLD pop-on-login,
-- which was intrusive and felt like a forced interruption every
-- update). Fresh installs (lastSeenVersion == nil) get stamped
-- silently here so a brand-new user doesn't see the badge either.
function WGS:HasUnreadWhatsNew()
    if not self.db or not self.db.profile then return false end
    local seen = self.db.profile.lastSeenVersion
    if not seen then
        self.db.profile.lastSeenVersion = self.version
        return false
    end
    return self:CompareVersions(self.version, seen) > 0
end
