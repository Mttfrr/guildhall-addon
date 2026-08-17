---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Wishlists sub-view: boss-grouped browser of which characters wishlisted
-- which items. Redesigned to read as a sibling of the Events tab — same
-- row chrome (subtle bg + Listbox highlight), same section-header idiom
-- (thin divider + gold label), same class-icon + class-coloured-name rows
-- as the Events Roster section.
--
-- Boss grouping comes from the wishlist data itself: the platform's
-- export now carries a per-item `source` (the boss free-text from the
-- platform wishlist) and a per-player `class`. Older imports in the
-- field lack both, so every consumer degrades:
--   source   → majority vote over the item's wish sources, falling back
--              to the loot-history itemID→boss derivation (the old view's
--              only mechanism), else the "Unassigned" bucket.
--   class    → characterDetails / guild-roster lookup; icon omitted when
--              still unknown.
--   location → newest per-item field (the zone/raid the item drops
--              from). Older exports lack it entirely: an item without
--              one lands in the Location filter's "Unknown" bucket —
--              which only appears when imports are mixed — and a fully
--              location-less import produces an empty location list, so
--              the dropdown offers nothing beyond "All locations".
--
-- Three filters sit above the list — Boss, Location, Slot — and they
-- combine (AND). Boss sections emptied by the combination disappear
-- entirely rather than rendering hollow headers.
--
-- The grouping/sorting/fallback logic is pure and lives in
-- WGS:BuildWishlistBossGroups (which also derives the distinct
-- location/slot option lists the dropdowns render); the filter
-- application is equally pure in WGS:FilterWishlistBossGroups. Both are
-- pinned by spec/wishlist_boss_groups_spec.lua without a rendering
-- harness.

ui.teams = ui.teams or {}

local ClearContainer = ui.ClearContainer
local ApplyClassIcon = ui.ApplyClassIcon

---------------------------------------------------------------------------
-- Layout constants
---------------------------------------------------------------------------

local CONTENT_W       = 660
local SECTION_H       = 26   -- boss section header (divider + gold label)
local ITEM_ROW_H      = 22
local WISHER_ROW_H    = 18
local WISHER_ICON_X   = 26   -- left inset of the class icon under an item
local WISHER_NAME_X   = WISHER_ICON_X + 20   -- fixed so names align icon-or-not
local ITEM_GAP        = 4
local SECTION_GAP     = 6

local UNASSIGNED_KEY  = "__unassigned"
local UNASSIGNED_NAME = "Unassigned"
local ALL_BOSSES      = "All bosses"
local ALL_LOCATIONS   = "All locations"
local ALL_SLOTS       = "All slots"

-- Shared "this item doesn't carry the field" bucket for the Location
-- and Slot filters. Distinct from the boss UNASSIGNED bucket, which is
-- a *group* the browser renders — Unknown is purely a filter concept
-- (item rows never print "Unknown"; they just omit the missing bit).
local UNKNOWN_KEY     = "__unknown"
local UNKNOWN_NAME    = "Unknown"

-- Canonical equipment-slot order for the Slot filter. The platform's
-- slot vocabulary is fixed, so the dropdown reads like a character
-- sheet instead of alphabetically ("Back" before "Head" helps nobody).
-- Unrecognised values a future export might carry aren't dropped —
-- they sort after the canonical list, alphabetically; items with no
-- slot at all fall into the Unknown bucket, last.
local SLOT_ORDER = {
    "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands",
    "Waist", "Legs", "Feet", "Ring", "Trinket", "Main Hand", "Off Hand",
    "Other",
}
local SLOT_RANK = {}   -- [lowercased slot] = canonical position
for i, s in ipairs(SLOT_ORDER) do SLOT_RANK[s:lower()] = i end

-- Epic purple — the sensible default for raid loot whose quality isn't
-- cached yet. The old view hardcoded this for every item name.
local QUALITY_FALLBACK_HEX = "ffa335ee"

---------------------------------------------------------------------------
-- Pure grouping logic (exposed as WGS:BuildWishlistBossGroups)
---------------------------------------------------------------------------

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Normalise a free-text field (boss source, location, slot) into
-- (mergeKey, displayName). Returns nil for empty/absent values. The key
-- is trimmed+lowercased so "Queen Ansurek" and " queen ansurek " land
-- in one group.
local function textKey(s)
    if type(s) ~= "string" then return nil end
    local t = trim(s)
    if t == "" then return nil end
    return t:lower(), t
end

-- Majority pick from a { [key] = count } tally. Ties break to the
-- lexicographically-smallest key so the result is deterministic across
-- renders/imports. nil when the tally is empty.
local function majorityKey(tally)
    local best, bestN
    for key, n in pairs(tally or {}) do
        if not best or n > bestN or (n == bestN and key < best) then
            best, bestN = key, n
        end
    end
    return best
end

-- Resolve a wisher's classFile constant. Chain: the wishlist entry's own
-- class (new platform field) → imported characterDetails → guild-roster
-- lookup. Returns nil when unknown/garbage so the renderer can omit the
-- icon instead of drawing a broken grey tile.
local function resolveClassFile(entryClass, short, opts)
    local raw = entryClass
    if not raw or raw == "" then
        local d = opts.characterDetails and opts.characterDetails[short]
        raw = d and d.class
    end
    if not raw or raw == "" then
        local gi = opts.roster and opts.roster[short]
        raw = gi and gi.class
    end
    if not raw or raw == "" then return nil end
    local file = WGS:NormalizeClassFile(raw)
    if file == "" or not WGS.CLASS_COLORS[file] then return nil end
    return file
end

-- C_Item-backed default for opts.getItemInfo. Tolerant: uncached items
-- return nil name/quality and the caller falls back ("Item <id>" + epic
-- purple). Import pre-warms the cache so this is usually a hit.
local function defaultGetItemInfo(itemID)
    if C_Item and C_Item.GetItemInfo then
        local name, _, quality = C_Item.GetItemInfo(itemID)
        return name, quality
    end
end

--- Build the boss-grouped, priority-sorted structure the Wishlists
--- browser renders. Pure with respect to `opts` — no db reads — so specs
--- can pin every fallback path.
---
--- wishlists: platform export shape —
---   { { playerName, class?, items = { { itemID, itemName?, slot?,
---       priority, note?, source?, location? } } }, ... }
--- (class + source + location are new fields; older imports lack them.)
---
--- opts:
---   allowed          set of permitted player names (full AND short
---                    forms), or nil for no team filter
---   loot             db.global.loot-shaped array — the itemID→boss +
---                    itemID→itemName fallback source
---   characterDetails db.global.characterDetails-shaped map (class fallback)
---   roster           WGS:GetGuildRosterLookup()-shaped map (class fallback)
---   getItemInfo      fn(itemID) → name?, quality? (defaults to C_Item)
---
--- Returns { bosses, locations, slots } where bosses = { { key, name,
--- itemCount, wishCount, items = { { itemID, name, quality?, slot?,
--- slotKey?, location?, locationKey?, wishers = { { playerName, short,
--- class?, priority, note? } } } } } } with:
---   bosses  sorted alphabetically, "Unassigned" always last
---   items   sorted by wisher count desc, then name, then itemID
---   wishers sorted by priority rank (BiS→Low, unknown last), then name
---
--- locations/slots are the filter dropdowns' option lists — the
--- distinct values present across the (team-filtered) items, each as
--- { key, name }:
---   locations sorted alphabetically (first-seen display casing)
---   slots     in SLOT_ORDER, unrecognised values after (alphabetical),
---             recognised values displayed in canonical casing
--- Both grow a trailing Unknown bucket only when the data is MIXED
--- (some items carry the field, some don't); when no item carries it
--- the list stays empty, so the dropdown offers nothing beyond "All" —
--- a filter over a field the import doesn't have would never narrow
--- anything.
function WGS:BuildWishlistBossGroups(wishlists, opts)
    opts = opts or {}
    local allowed = opts.allowed

    -- Accept both full ("Foo-Realm") and short ("Foo") forms since
    -- wishlist.playerName drifts between the two depending on the
    -- import path.
    local function inScope(playerName)
        if not allowed then return true end
        if not playerName then return false end
        if allowed[playerName] then return true end
        local short = playerName:match("^([^%-]+)") or playerName
        return allowed[short] == true
    end

    -- Pass 1 — walk the wishes: per item, collect wishers + a tally of
    -- the wish-supplied sources. Wish-supplied casing wins the display
    -- name for a merge key (platform-authored beats loot-log capture).
    -- Location/slot display casing is recorded here too — first-seen in
    -- WISH order, so the option lists stay deterministic even though
    -- pass 3 walks the item map in pairs() order.
    local items   = {}   -- [itemID] = { itemID, name?, slot?, wishers, srcTally }
    local display = {}   -- [mergeKey] = first-seen display casing
    local locDisplay, slotDisplay = {}, {}   -- ditto, for location / slot
    for _, entry in ipairs(wishlists or {}) do
        if type(entry) == "table" and type(entry.items) == "table"
            and inScope(entry.playerName) then
            local short = (entry.playerName or ""):match("^([^%-]+)")
                or entry.playerName or "?"
            for _, item in ipairs(entry.items) do
                if item.itemID then
                    local rec = items[item.itemID]
                    if not rec then
                        rec = { itemID = item.itemID, wishers = {}, srcTally = {} }
                        items[item.itemID] = rec
                    end
                    rec.wishers[#rec.wishers + 1] = {
                        playerName = entry.playerName,
                        short      = short,
                        class      = resolveClassFile(entry.class, short, opts),
                        priority   = item.priority,
                        note       = item.note,
                    }
                    local key, disp = textKey(item.source)
                    if key then
                        rec.srcTally[key] = (rec.srcTally[key] or 0) + 1
                        if not display[key] then display[key] = disp end
                    end
                    if not rec.name and item.itemName and item.itemName ~= "" then
                        rec.name = item.itemName
                    end
                    if not rec.slot and item.slot and item.slot ~= "" then
                        rec.slot = item.slot
                    end
                    local sk, sd = textKey(item.slot)
                    if sk and not slotDisplay[sk] then slotDisplay[sk] = sd end
                    -- location is item metadata, so first-non-blank
                    -- wins — same rule as slot/name. Stored trimmed +
                    -- keyed for the filter.
                    local lk, ld = textKey(item.location)
                    if lk then
                        if not locDisplay[lk] then locDisplay[lk] = ld end
                        if not rec.locationKey then
                            rec.locationKey, rec.location = lk, ld
                        end
                    end
                end
            end
        end
    end

    -- Pass 2 — loot-history fallback maps: itemID → boss tally (for
    -- items whose wishes carry no source) and itemID → itemName.
    local lootTally, lootName = {}, {}
    for _, e in ipairs(opts.loot or {}) do
        if e.itemID and items[e.itemID] then
            local key, disp = textKey(e.boss)
            if key then
                local t = lootTally[e.itemID]
                if not t then t = {}; lootTally[e.itemID] = t end
                t[key] = (t[key] or 0) + 1
                if not display[key] then display[key] = disp end
            end
            if e.itemName and e.itemName ~= "" and not lootName[e.itemID] then
                lootName[e.itemID] = e.itemName
            end
        end
    end

    -- Pass 3 — resolve each item's name/quality + boss group, sort its
    -- wishers, and bucket it. Also tallies the distinct location/slot
    -- values (per ITEM, post-resolution — not per wish) that become the
    -- filter dropdowns' option lists.
    local getItemInfo = opts.getItemInfo or defaultGetItemInfo
    local groups = {}
    local locSeen, slotSeen = {}, {}   -- [key] = true; display casing is pass 1's
    local anyNoLocation, anyNoSlot = false, false
    for _, rec in pairs(items) do
        if not rec.name then rec.name = lootName[rec.itemID] end
        local ciName, ciQuality = getItemInfo(rec.itemID)
        if not rec.name and ciName then rec.name = ciName end
        rec.name = rec.name or ("Item " .. rec.itemID)
        rec.quality = ciQuality
        rec.slotKey = (textKey(rec.slot))

        if rec.locationKey then
            locSeen[rec.locationKey] = true
        else
            anyNoLocation = true
        end
        if rec.slotKey then
            slotSeen[rec.slotKey] = true
        else
            anyNoSlot = true
        end

        local key = majorityKey(rec.srcTally)
            or majorityKey(lootTally[rec.itemID])
            or UNASSIGNED_KEY
        rec.srcTally = nil

        table.sort(rec.wishers, function(a, b)
            local ra = ui.PRIORITY_ORDER[a.priority] or 99
            local rb = ui.PRIORITY_ORDER[b.priority] or 99
            if ra ~= rb then return ra < rb end
            local na, nb = (a.short or ""):lower(), (b.short or ""):lower()
            if na ~= nb then return na < nb end
            return (a.playerName or "") < (b.playerName or "")
        end)

        local g = groups[key]
        if not g then
            g = {
                key  = key,
                name = (key == UNASSIGNED_KEY) and UNASSIGNED_NAME
                    or (display[key] or key),
                items = {},
            }
            groups[key] = g
        end
        g.items[#g.items + 1] = rec
    end

    -- Pass 4 — order items within each boss, tally counts, order bosses.
    local bosses = {}
    for _, g in pairs(groups) do
        table.sort(g.items, function(a, b)
            if #a.wishers ~= #b.wishers then return #a.wishers > #b.wishers end
            local na, nb = (a.name or ""):lower(), (b.name or ""):lower()
            if na ~= nb then return na < nb end
            return a.itemID < b.itemID
        end)
        g.itemCount = #g.items
        local wishes = 0
        for _, it in ipairs(g.items) do wishes = wishes + #it.wishers end
        g.wishCount = wishes
        bosses[#bosses + 1] = g
    end
    table.sort(bosses, function(a, b)
        if a.key == UNASSIGNED_KEY then return false end
        if b.key == UNASSIGNED_KEY then return true end
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    -- Pass 5 — the filter option lists. Unknown only joins a list when
    -- the data is mixed: an all-or-nothing field either needs no bucket
    -- or would make the whole dropdown a no-op.
    local locations = {}
    for key in pairs(locSeen) do
        locations[#locations + 1] = { key = key, name = locDisplay[key] or key }
    end
    table.sort(locations, function(a, b) return a.key < b.key end)
    if #locations > 0 and anyNoLocation then
        locations[#locations + 1] = { key = UNKNOWN_KEY, name = UNKNOWN_NAME }
    end

    local slots = {}
    for key in pairs(slotSeen) do
        local rank = SLOT_RANK[key]
        slots[#slots + 1] = {
            key  = key,
            -- Canonical casing for recognised slots ("head" → "Head");
            -- first-seen casing for values outside the vocabulary.
            name = rank and SLOT_ORDER[rank] or slotDisplay[key] or key,
            rank = rank,
        }
    end
    table.sort(slots, function(a, b)
        local ra, rb = a.rank or 99, b.rank or 99
        if ra ~= rb then return ra < rb end
        return a.key < b.key   -- unrecognised slots: alphabetical
    end)
    for _, s in ipairs(slots) do s.rank = nil end
    if #slots > 0 and anyNoSlot then
        slots[#slots + 1] = { key = UNKNOWN_KEY, name = UNKNOWN_NAME }
    end

    return { bosses = bosses, locations = locations, slots = slots }
end

--- Apply the browser's filter selections to a BuildWishlistBossGroups
--- result. Pure and non-mutating: returns a fresh { bosses } view in
--- which the three filters combine (AND). Groups whose items all fail
--- the filters vanish entirely — no hollow section headers — and the
--- surviving groups' item/wish counts are recomputed so the headers
--- stay honest against what's actually listed. Items and wishers are
--- shared by reference with the input, which itself is never touched.
---
--- filters:
---   boss      group key (from result.bosses), or nil for all
---   location  location key (from result.locations) — the Unknown
---             bucket matches items that carry no location — or nil
---   slot      slot key (from result.slots), Unknown likewise, or nil
function WGS:FilterWishlistBossGroups(result, filters)
    filters = filters or {}
    local fBoss, fLoc, fSlot = filters.boss, filters.location, filters.slot
    if not (fBoss or fLoc or fSlot) then
        return { bosses = (result and result.bosses) or {} }
    end

    local bosses = {}
    for _, g in ipairs((result and result.bosses) or {}) do
        if not fBoss or g.key == fBoss then
            local kept = {}
            for _, it in ipairs(g.items) do
                if (not fLoc or (it.locationKey or UNKNOWN_KEY) == fLoc)
                    and (not fSlot or (it.slotKey or UNKNOWN_KEY) == fSlot) then
                    kept[#kept + 1] = it
                end
            end
            if #kept > 0 then
                local wishes = 0
                for _, it in ipairs(kept) do wishes = wishes + #it.wishers end
                bosses[#bosses + 1] = {
                    key       = g.key,
                    name      = g.name,
                    items     = kept,
                    itemCount = #kept,
                    wishCount = wishes,
                }
            end
        end
    end
    return { bosses = bosses }
end

---------------------------------------------------------------------------
-- Impure input builders (db / live-state reads kept out of the grouper)
---------------------------------------------------------------------------

-- Set of player names allowed by the global current-team picker, in both
-- full and short forms (nil = no filter). Includes linked-character alts
-- so a wishlist on an alt of a team main still shows under the filter.
local function BuildAllowedPlayers()
    local currentTeamId = WGS.GetCurrentTeamId and WGS:GetCurrentTeamId() or nil
    if not currentTeamId then return nil end

    local allowed = {}
    for _, t in ipairs(WGS.db.global.teams or {}) do
        if t.id == currentTeamId then
            for _, memberName in ipairs(t.members or {}) do
                allowed[memberName] = true
                local short = memberName:match("^([^%-]+)") or memberName
                allowed[short] = true
            end
            local chars = WGS.db.global.characters or {}
            for _, pm in ipairs(t.playerMembers or {}) do
                local info = chars[pm.playerId]
                if info and info.alts then
                    for _, alt in ipairs(info.alts) do
                        allowed[alt] = true
                        local altShort = alt:match("^([^%-]+)") or alt
                        allowed[altShort] = true
                    end
                end
            end
            break
        end
    end
    return allowed
end

-- Item-quality colour as bare "AARRGGBB" hex. ITEM_QUALITY_COLORS[q].hex
-- ships as "|cffa335ee" — strip the |c so call sites compose the same way
-- as CLASS_COLORS / PRIORITY_COLORS. Falls back to epic purple when the
-- quality isn't known (item not cached yet).
local function qualityHex(quality)
    local qc = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if type(qc) == "table" and type(qc.hex) == "string" then
        local hex = qc.hex:match("^|c(%x%x%x%x%x%x%x%x)$")
        if hex then return hex end
    end
    return QUALITY_FALLBACK_HEX
end

---------------------------------------------------------------------------
-- Row builders — Events-tab visual language
---------------------------------------------------------------------------

-- Boss section header: thin divider + gold label + dim meta, the same
-- idiom as EventsDetail's BuildSectionHeader (yOff-based here since the
-- browser lays out with running offsets like the Roster sub-view).
local function BuildBossHeader(content, yOff, boss)
    local divider = content:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, yOff - 4)
    divider:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, yOff - 4)
    divider:SetHeight(1)
    divider:SetColorTexture(0.3, 0.3, 0.3, 0.6)

    local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 4, yOff - 10)
    fs:SetText(string.format(
        "|cffffd100%s|r  |cff888888(%d item%s \194\183 %d wish%s)|r",
        boss.name,
        boss.itemCount, boss.itemCount == 1 and "" or "s",
        boss.wishCount, boss.wishCount == 1 and "" or "es"))

    return yOff - SECTION_H
end

-- One item row: quality-coloured name on the left, dim
-- "Slot · Location · N wishers" pill on the right — the rail-row chrome
-- (subtle bg, Listbox highlight). Slot/location segments drop out when
-- unknown (legacy imports), leaving just the wisher count.
-- Hover shows the real item tooltip when the client has the item cached.
local function BuildItemRow(content, item, yOff)
    local row = CreateFrame("Button", nil, content)
    row:SetSize(CONTENT_W, ITEM_ROW_H)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    bg:SetColorTexture(1, 1, 1, 0.025)

    row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    local hl = row:GetHighlightTexture()
    if hl then hl:SetAlpha(0.25) end

    local meta = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    meta:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    local n = #item.wishers
    local metaText = n .. (n == 1 and " wisher" or " wishers")
    if item.location and item.location ~= "" then
        metaText = item.location .. "  \194\183  " .. metaText
    end
    if item.slot and item.slot ~= "" then
        metaText = item.slot .. "  \194\183  " .. metaText
    end
    meta:SetText("|cffaaaaaa" .. metaText .. "|r")

    local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    nameFs:SetPoint("RIGHT", meta, "LEFT", -8, 0)
    nameFs:SetJustifyH("LEFT")
    nameFs:SetWordWrap(false)
    nameFs:SetText("|c" .. qualityHex(item.quality) .. item.name .. "|r")

    local itemID = item.itemID
    row:SetScript("OnEnter", function(self)
        if not (itemID and GameTooltip and GameTooltip.SetItemByID) then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        -- pcall: SetItemByID errors on ids the server refuses to resolve;
        -- an item row must never wedge the cursor with a broken tooltip.
        local ok = pcall(GameTooltip.SetItemByID, GameTooltip, itemID)
        if ok then GameTooltip:Show() else GameTooltip:Hide() end
    end)
    row:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    return yOff - ITEM_ROW_H
end

-- One wisher row under an item: class icon (omitted when class unknown —
-- the name column stays put so mixed rows align) + class-coloured name +
-- dim note, priority right-aligned in the shared PRIORITY_COLORS. Right-
-- click opens the shared player context menu, same as every other place
-- a player name appears.
local function BuildWisherRow(content, w, yOff)
    local row = CreateFrame("Button", nil, content)
    row:SetSize(CONTENT_W, WISHER_ROW_H)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)

    row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    local hl = row:GetHighlightTexture()
    if hl then hl:SetAlpha(0.25) end

    local colorHex = (w.class and WGS.CLASS_COLORS[w.class]) or "ffffffff"

    if w.class then
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", row, "LEFT", WISHER_ICON_X, 0)
        ApplyClassIcon(icon, w.class, colorHex)
    end

    local prio = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    prio:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    prio:SetJustifyH("RIGHT")
    prio:SetText("|c" .. (ui.PRIORITY_COLORS[w.priority] or "ffffffff")
        .. (w.priority or "?") .. "|r")

    local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameFs:SetPoint("LEFT", row, "LEFT", WISHER_NAME_X, 0)
    nameFs:SetPoint("RIGHT", prio, "LEFT", -10, 0)
    nameFs:SetJustifyH("LEFT")
    nameFs:SetWordWrap(false)
    local text = "|c" .. colorHex .. (w.short or "?") .. "|r"
    if w.note and w.note ~= "" then
        text = text .. "  |cff888888(" .. w.note .. ")|r"
    end
    nameFs:SetText(text)

    ui.AttachPlayerContextMenu(row, w.playerName, w.class)

    return yOff - WISHER_ROW_H
end

---------------------------------------------------------------------------
-- Sub-view build + populate (registered on ui.teams.wishlists)
---------------------------------------------------------------------------

-- One filter dropdown — label + button + hand-rolled menu, the same
-- chrome the redesign gave the Boss filter, now shared by all three.
-- Every dropdown lists exactly what's present in the (team-filtered)
-- wishlist data — Populate stashes the option lists on sv each render —
-- NOT the loot-history values the old view scanned (wrong/empty for
-- bosses never looted). cfg:
--   label     the prefix FontString text ("Boss:")
--   anchor    frame the label hangs off (nil = sv's top-left corner)
--   width     button + menu width (the three shrink to share one row)
--   allLabel  the nil-selection option ("All bosses")
--   stateKey  sv field holding the selected KEY (sv[stateKey]) so
--             Populate's stale-selection reset can clear it in one place
--   options   fn() → { { key, name }, ... } read fresh at open time
-- Returns the button (also the label's owner for anchoring the next
-- dropdown in the row).
local function BuildFilterDropdown(sv, cfg)
    local lbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if cfg.anchor then
        lbl:SetPoint("LEFT", cfg.anchor, "RIGHT", 12, 0)
    else
        lbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -2)
    end
    lbl:SetText(cfg.label)

    local btn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    btn:SetSize(cfg.width, 22)
    btn:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    btn:SetText(cfg.allLabel)
    sv[cfg.stateKey] = nil

    local menu = CreateFrame("Frame", nil, sv, "BackdropTemplate")
    menu:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    menu:SetBackdropColor(0, 0, 0, 0.95)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:Hide()
    sv._filterMenus = sv._filterMenus or {}
    sv._filterMenus[#sv._filterMenus + 1] = menu

    local menuButtons = {}
    btn:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide(); return end
        -- One open menu at a time — clicking Location while Boss is
        -- open swaps them instead of stacking overlapping panels.
        for _, m in ipairs(sv._filterMenus) do m:Hide() end
        for _, b in ipairs(menuButtons) do b:Hide() end

        local options = { { key = nil, name = cfg.allLabel } }
        for _, o in ipairs(cfg.options() or {}) do
            options[#options + 1] = { key = o.key, name = o.name }
        end

        local bh = 22
        menu:SetSize(cfg.width, #options * bh + 8)
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)

        for i, opt in ipairs(options) do
            local b = menuButtons[i]
            if not b then
                b = CreateFrame("Button", nil, menu)
                b:SetSize(cfg.width - 8, bh)
                b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                b.text:SetAllPoints()
                b.text:SetJustifyH("LEFT")
                menuButtons[i] = b
            end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -(i - 1) * bh - 4)
            b.text:SetText("  " .. opt.name)
            b:SetScript("OnClick", function()
                sv[cfg.stateKey] = opt.key
                btn:SetText(opt.name)
                menu:Hide()
                if sv._refreshFn then sv._refreshFn() end
            end)
            b:Show()
        end
        menu:Show()
    end)

    return btn
end

local function BuildSubView(sv)
    -- The three filters share one row above the list and AND together.
    -- Widths are budgeted against CONTENT_W: boss names run longest,
    -- locations are zone names, slot labels are short.
    sv.bossBtn = BuildFilterDropdown(sv, {
        label = "Boss:", width = 200,
        allLabel = ALL_BOSSES, stateKey = "selectedBossKey",
        options = function() return sv._bossGroups end,
    })
    sv.locationBtn = BuildFilterDropdown(sv, {
        label = "Location:", anchor = sv.bossBtn, width = 170,
        allLabel = ALL_LOCATIONS, stateKey = "selectedLocationKey",
        options = function() return sv._locations end,
    })
    sv.slotBtn = BuildFilterDropdown(sv, {
        label = "Slot:", anchor = sv.locationBtn, width = 110,
        allLabel = ALL_SLOTS, stateKey = "selectedSlotKey",
        options = function() return sv._slots end,
    })

    local sf = CreateFrame("ScrollFrame", nil, sv, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", sv, "TOPLEFT", 0, -28)
    sf:SetPoint("BOTTOMRIGHT", sv, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(CONTENT_W)
    content:SetHeight(1)
    sf:SetScrollChild(content)

    sv.scrollFrame = sf
    sv.content = content
end

-- Drop a stale selection (team switch or re-import removed the value)
-- instead of rendering an empty pane against a ghost filter. `list` is
-- the freshly-built option list the selection must still appear in.
local function ResetStaleFilter(tab, stateKey, btn, list, allLabel)
    local selected = tab[stateKey]
    if not selected then return end
    for _, o in ipairs(list) do
        if o.key == selected then return end
    end
    tab[stateKey] = nil
    btn:SetText(allLabel)
end

local function Populate(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local wishlists = WGS.db.global.wishlists or {}
    if #wishlists == 0 then
        tab._bossGroups, tab._locations, tab._slots = {}, {}, {}
        ui.CreateImportHint(tab.content, "No wishlists imported yet.", 5, -5)
        tab.content:SetHeight(72)
        return
    end

    local result = WGS:BuildWishlistBossGroups(wishlists, {
        allowed          = BuildAllowedPlayers(),
        loot             = WGS.db.global.loot,
        characterDetails = WGS.db.global.characterDetails,
        roster           = WGS:GetGuildRosterLookup(),
    })
    tab._bossGroups = result.bosses
    tab._locations  = result.locations
    tab._slots      = result.slots

    ResetStaleFilter(tab, "selectedBossKey",     tab.bossBtn,     result.bosses,    ALL_BOSSES)
    ResetStaleFilter(tab, "selectedLocationKey", tab.locationBtn, result.locations, ALL_LOCATIONS)
    ResetStaleFilter(tab, "selectedSlotKey",     tab.slotBtn,     result.slots,     ALL_SLOTS)

    if #result.bosses == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText("No wishlisted items found for the current team filter.")
        tab.content:SetHeight(30)
        return
    end

    -- The three filters AND together in the pure core; sections the
    -- combination empties are gone from the view entirely. Each
    -- dropdown's options stay derived from the UNfiltered result (like
    -- the boss list always has), so a combination can legitimately
    -- match nothing — that gets its own message, distinct from the
    -- team-filter one above.
    local view = WGS:FilterWishlistBossGroups(result, {
        boss     = tab.selectedBossKey,
        location = tab.selectedLocationKey,
        slot     = tab.selectedSlotKey,
    })
    if #view.bosses == 0 then
        local noMatch = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noMatch:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noMatch:SetText("No wishlisted items match the current filters.")
        tab.content:SetHeight(30)
        return
    end

    local yOff = 0
    for _, boss in ipairs(view.bosses) do
        yOff = BuildBossHeader(tab.content, yOff, boss)
        for _, item in ipairs(boss.items) do
            yOff = BuildItemRow(tab.content, item, yOff)
            for _, w in ipairs(item.wishers) do
                yOff = BuildWisherRow(tab.content, w, yOff)
            end
            yOff = yOff - ITEM_GAP
        end
        yOff = yOff - SECTION_GAP
    end

    -- SetSize (not just SetHeight) + UpdateScrollChildRect — same
    -- scrollbar-wake dance as the Roster sub-view.
    tab.content:SetSize(CONTENT_W, math.abs(yOff) + 10)
    if tab.scrollFrame and tab.scrollFrame.UpdateScrollChildRect then
        tab.scrollFrame:UpdateScrollChildRect()
    end
end

ui.teams.wishlists = { build = BuildSubView, populate = Populate }
