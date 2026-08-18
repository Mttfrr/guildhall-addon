---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Wishlists sub-view: a PIVOTABLE browser of which characters wishlisted
-- which items. Reads as a sibling of the Events tab — same row chrome
-- (subtle bg + Listbox highlight), same class-icon + class-coloured-name
-- rows as the Events Roster section.
--
-- ─── Why this replaced the boss-grouped + four-dropdown design ───
--
-- The first cut hardcoded ONE hierarchy (boss → item → wishers) and then
-- bolted four filter dropdowns on top to compensate. That conflated two
-- different things: boss was simultaneously the grouping AND a filter,
-- so "what does Bob want?" was unanswerable no matter how you filtered,
-- while narrowing to one boss cost a dropdown that duplicated a section
-- header already on screen.
--
-- The fix is to make the hierarchy itself the control:
--
--   Group by  Boss | Player | Raid/Dungeon | Slot | Armor
--             — one dropdown pivots the whole tree. Grouping SUBSUMES
--               filtering for these dimensions: grouping by Location and
--               collapsing everything is strictly better than a Location
--               filter, because you keep the other locations one click
--               away instead of hidden.
--   Search    — one box narrows across every dimension at once (item
--               name, player, boss, location, slot, armor). Replaces the
--               remaining three dropdowns with something strictly more
--               powerful: "plate" and "Nexus" and "Bob" all work, and
--               they compose with whatever grouping is active.
--   Collapse  — every group is collapsible, with counts on the header,
--               so a 40-item list is a scannable index instead of an
--               endless scroll. State persists per (groupBy, group).
--
-- Two leaf shapes fall out of the pivot, and both are correct:
--   item modes (Boss/Location/Slot/Armor) → item row + its wisher rows
--   player mode                           → the player IS the group, so
--                                            their items are the leaves,
--                                            priority-sorted, no
--                                            redundant wisher sub-rows.
--
-- ─── Data degradation (unchanged; older imports lack the new fields) ───
--   source   → majority vote over the item's wish sources, falling back
--              to the loot-history itemID→boss derivation, else the
--              "Unassigned" group.
--   class    → characterDetails / guild-roster lookup; icon omitted when
--              still unknown.
--   location/armorType → per-item fields; items lacking one land in an
--              "Unknown" group, which only materialises when the import
--              is MIXED. Group by a dimension no item carries and you
--              get a single Unknown group rather than a lying empty pane.
--
-- The grouping/pivot/search/sort logic is pure and lives in
-- WGS:BuildWishlistGroups — pinned by spec/wishlist_boss_groups_spec.lua
-- without a rendering harness.

ui.teams = ui.teams or {}

local ClearContainer = ui.ClearContainer
local ApplyClassIcon = ui.ApplyClassIcon

---------------------------------------------------------------------------
-- Layout constants
---------------------------------------------------------------------------

local CONTENT_W       = 660
local SECTION_H       = 24   -- collapsible group header row
local ITEM_ROW_H      = 22
local WISHER_ROW_H    = 18
local WISHER_ICON_X   = 26   -- left inset of the class icon under an item
local WISHER_NAME_X   = WISHER_ICON_X + 20   -- fixed so names align icon-or-not
local ITEM_GAP        = 4
local SECTION_GAP     = 6

local UNASSIGNED_KEY  = "__unassigned"
local UNASSIGNED_NAME = "Unassigned"

-- Shared "this item doesn't carry the field" bucket. In the pivoted
-- design this is a real GROUP (grouping by Location with half the import
-- pre-location gives you an honest "Unknown" section), not the filter-
-- only concept it used to be. Item rows still never print "Unknown" —
-- they just omit the missing segment.
local UNKNOWN_KEY     = "__unknown"
local UNKNOWN_NAME    = "Unknown"

-- The pivot vocabulary. Order here is the dropdown order: Boss first
-- (the loot-council default — "what drops here, who wants it"), Player
-- second (the raider question — "what does Bob still need"), then the
-- three item-attribute pivots.
-- NOTE the field is `name`, not `label`: these entries are fed straight
-- to the shared dropdown factory, which renders `o.name`. Shipping
-- `label` here made every menu row concatenate nil and throw, so the
-- dropdown looked simply dead — pinned by spec now.
local GROUP_MODES = {
    { key = "boss",     name = "Boss" },
    { key = "player",   name = "Player" },
    { key = "location", name = "Raid / Dungeon" },
    { key = "slot",     name = "Slot" },
    { key = "armor",    name = "Armor" },
}
local GROUP_MODE_LABEL = {}
for _, m in ipairs(GROUP_MODES) do GROUP_MODE_LABEL[m.key] = m.name end

-- Exposed so specs can pin the dropdown's option contract against the
-- pivots BuildWishlistGroups actually accepts.
WGS.WISHLIST_GROUP_MODES = GROUP_MODES

-- Above this many groups the view opens collapsed — an index you drill
-- into. At or below it, everything is open, because a handful of groups
-- reads better whole than as a row of closed drawers.
local AUTO_COLLAPSE_THRESHOLD = 6

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

-- Fixed armor-class order for the Armor filter — lightest to heaviest,
-- the order every WoW player already knows, not alphabetical. The
-- platform's vocabulary is exactly these four ("" for non-armor items);
-- values outside it aren't dropped — they sort after, alphabetically —
-- mirroring the Slot filter's tolerance for a future export.
local ARMOR_ORDER = { "Cloth", "Leather", "Mail", "Plate" }
local ARMOR_RANK = {}   -- [lowercased armor type] = canonical position
for i, a in ipairs(ARMOR_ORDER) do ARMOR_RANK[a:lower()] = i end

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

--- Build the grouped, sorted structure the Wishlists browser renders,
--- pivoted on whichever dimension the user picked. Pure with respect to
--- `opts` — no db reads — so specs can pin every fallback path.
---
--- wishlists: platform export shape —
---   { { playerName, class?, items = { { itemID, itemName?, slot?,
---       priority, note?, source?, location?, armorType?, simPct? } } }, ... }
--- (class + source + location + armorType are new fields; older
--- imports lack them.)
---
--- opts:
---   allowed          set of permitted player names (full AND short
---                    forms), or nil for no team filter
---   loot             db.global.loot-shaped array — the itemID→boss +
---                    itemID→itemName fallback source
---   characterDetails db.global.characterDetails-shaped map (class fallback)
---   roster           WGS:GetGuildRosterLookup()-shaped map (class fallback)
---   getItemInfo      fn(itemID) → name?, quality? (defaults to C_Item)
---   groupBy          "boss" (default) | "player" | "location" | "slot"
---                    | "armor" — the pivot
---   search           free text; narrows to items matching on ANY of
---                    item name / boss / location / slot / armor / a
---                    wisher's name. Case-insensitive substring, applied
---                    BEFORE grouping so counts and empty groups stay
---                    honest.
---
--- Returns { groupBy, groups, itemCount, wishCount } where groups =
--- { { key, name, class?, playerName?, itemCount, wishCount, items } }.
---
--- Group ORDER is per-pivot and deliberately not alphabetical-everywhere:
---   boss      alphabetical, "Unassigned" always last
---   player    alphabetical by short name
---   location  alphabetical, "Unknown" last
---   slot      SLOT_ORDER (character-sheet order), unrecognised values
---             after alphabetically, "Unknown" last
---   armor     ARMOR_ORDER (Cloth → Plate), same tail rules
---
--- ITEM shape depends on the pivot, because the useful leaf differs:
---   item modes (boss/location/slot/armor) — the item is the leaf and
---     carries `wishers` = { { playerName, short, class?, priority,
---     note?, simPct? } }, sorted by priority rank (BiS→Low, unknown
---     last) then name. Items sort by demand (wisher count desc), then
---     name, then itemID.
---   player mode — the PLAYER is the group, so their wish is folded onto
---     the item itself (priority/note/simPct) and there are no wisher
---     sub-rows to repeat the group header. Items sort by priority rank,
---     then name.
---
--- Every item carries itemID, name, quality?, slot?, location?,
--- armorType?, bossName regardless of pivot, so the row renderer can
--- show the dimensions that AREN'T the current grouping as meta.
function WGS:BuildWishlistGroups(wishlists, opts)
    opts = opts or {}
    local allowed = opts.allowed

    -- Accept both full ("Foo-Realm") and short ("Foo") forms since
    -- wishlist.playerName drifts between the two depending on the
    -- import path.
    local function inScope(playerName)
        if not allowed then return true end
        if not playerName then return false end
        if allowed[playerName] then return true end
        local short = WGS:ShortName(playerName)
        return allowed[short] == true
    end

    -- Pass 1 — walk the wishes: per item, collect wishers + a tally of
    -- the wish-supplied sources. Wish-supplied casing wins the display
    -- name for a merge key (platform-authored beats loot-log capture).
    -- Location/slot display casing is recorded here too — first-seen in
    -- WISH order, so the option lists stay deterministic even though
    -- pass 3 walks the item map in pairs() order.
    local items   = {}   -- [itemID] = { itemID, name?, slot?, wishers, srcTally }
    local display = {}   -- [bossMergeKey] = first-seen display casing
    for _, entry in ipairs(wishlists or {}) do
        if type(entry) == "table" and type(entry.items) == "table"
            and inScope(entry.playerName) then
            local short = WGS:ShortName(entry.playerName)
            if short == "" then short = "?" end
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
                        -- Droptimizer gain from the wisher's own sim
                        -- (platform export simPct) — nil for pre-sim
                        -- imports; rendered beside the priority.
                        simPct     = tonumber(item.simPct),
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
                    -- location is item metadata, so first-non-blank
                    -- wins — same rule as slot/name. Stored trimmed +
                    -- keyed so the Location pivot can bucket on it.
                    local lk, ld = textKey(item.location)
                    if lk and not rec.locationKey then
                        rec.locationKey, rec.location = lk, ld
                    end
                    -- armorType likewise — first non-blank wins, but
                    -- the four known values display in canonical
                    -- casing ("cloth" → "Cloth") since the vocabulary
                    -- is fixed; unrecognised values keep their casing.
                    local ak, ad = textKey(item.armorType)
                    if ak and not rec.armorTypeKey then
                        rec.armorTypeKey = ak
                        rec.armorType = ARMOR_RANK[ak] and ARMOR_ORDER[ARMOR_RANK[ak]] or ad
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

    -- Pass 3 — resolve each item's name/quality, stamp its boss group
    -- onto the record, and sort its wishers. No bucketing here any more:
    -- the record carries every dimension and pass 5 decides which one
    -- becomes the grouping.
    local getItemInfo = opts.getItemInfo or defaultGetItemInfo
    local records = {}
    for _, rec in pairs(items) do
        if not rec.name then rec.name = lootName[rec.itemID] end
        local ciName, ciQuality = getItemInfo(rec.itemID)
        if not rec.name and ciName then rec.name = ciName end
        rec.name = rec.name or ("Item " .. rec.itemID)
        rec.quality = ciQuality
        rec.slotKey = (textKey(rec.slot))
        -- Canonical slot casing so the Slot pivot's headers read
        -- "Head" whatever the export sent.
        if rec.slotKey and SLOT_RANK[rec.slotKey] then
            rec.slot = SLOT_ORDER[SLOT_RANK[rec.slotKey]]
        end

        rec.bossKey = majorityKey(rec.srcTally)
            or majorityKey(lootTally[rec.itemID])
            or UNASSIGNED_KEY
        rec.bossName = (rec.bossKey == UNASSIGNED_KEY) and UNASSIGNED_NAME
            or (display[rec.bossKey] or rec.bossKey)
        rec.srcTally = nil

        table.sort(rec.wishers, function(a, b)
            local ra = ui.PRIORITY_ORDER[a.priority] or 99
            local rb = ui.PRIORITY_ORDER[b.priority] or 99
            if ra ~= rb then return ra < rb end
            local na, nb = (a.short or ""):lower(), (b.short or ""):lower()
            if na ~= nb then return na < nb end
            return (a.playerName or "") < (b.playerName or "")
        end)

        records[#records + 1] = rec
    end

    -- Pass 4 — search. Applied to whole records BEFORE grouping so the
    -- headers' counts describe what's actually listed. A record survives
    -- if the needle appears in any dimension a user might type: the item
    -- itself, where it drops, what it is, or who wants it.
    local needle = type(opts.search) == "string" and trim(opts.search):lower() or ""
    if needle ~= "" then
        local kept = {}
        for _, rec in ipairs(records) do
            local hay = table.concat({
                rec.name or "", rec.bossName or "", rec.location or "",
                rec.slot or "", rec.armorType or "",
            }, "\1"):lower()
            local hit = hay:find(needle, 1, true) ~= nil
            if not hit then
                for _, w in ipairs(rec.wishers) do
                    local who = ((w.short or "") .. "\1" .. (w.playerName or "")):lower()
                    if who:find(needle, 1, true) then hit = true; break end
                end
            end
            if hit then kept[#kept + 1] = rec end
        end
        records = kept
    end

    -- Pass 5 — pivot. Player mode inverts the tree (the player becomes
    -- the group and their wish folds onto the item); every other mode
    -- buckets the record on one of its own fields.
    local groupBy = opts.groupBy
    if not GROUP_MODE_LABEL[groupBy] then groupBy = "boss" end

    local buckets, order = {}, {}
    local function bucket(key, name, extra)
        local g = buckets[key]
        if not g then
            g = { key = key, name = name, items = {} }
            if extra then for k, v in pairs(extra) do g[k] = v end end
            buckets[key] = g
            order[#order + 1] = g
        end
        return g
    end

    if groupBy == "player" then
        for _, rec in ipairs(records) do
            for _, w in ipairs(rec.wishers) do
                local g = bucket(w.short or w.playerName or "?", w.short or "?", {
                    class = w.class, playerName = w.playerName,
                })
                g.items[#g.items + 1] = {
                    itemID    = rec.itemID,
                    name      = rec.name,
                    quality   = rec.quality,
                    slot      = rec.slot,
                    location  = rec.location,
                    armorType = rec.armorType,
                    bossName  = rec.bossName,
                    -- THIS player's wish, folded onto the item — the
                    -- group header already says who, so a wisher row
                    -- under it would just repeat the name.
                    priority  = w.priority,
                    note      = w.note,
                    simPct    = w.simPct,
                }
            end
        end
    else
        for _, rec in ipairs(records) do
            local key, name
            if groupBy == "location" then
                key, name = rec.locationKey or UNKNOWN_KEY, rec.location or UNKNOWN_NAME
            elseif groupBy == "slot" then
                key, name = rec.slotKey or UNKNOWN_KEY, rec.slot or UNKNOWN_NAME
            elseif groupBy == "armor" then
                key, name = rec.armorTypeKey or UNKNOWN_KEY, rec.armorType or UNKNOWN_NAME
            else
                key, name = rec.bossKey, rec.bossName
            end
            local g = bucket(key, name)
            g.items[#g.items + 1] = rec
        end
    end

    -- Pass 6 — order items inside each group, tally, then order groups.
    local byPriority = function(a, b)
        local ra = ui.PRIORITY_ORDER[a.priority] or 99
        local rb = ui.PRIORITY_ORDER[b.priority] or 99
        if ra ~= rb then return ra < rb end
        local na, nb = (a.name or ""):lower(), (b.name or ""):lower()
        if na ~= nb then return na < nb end
        return a.itemID < b.itemID
    end
    local byDemand = function(a, b)
        if #a.wishers ~= #b.wishers then return #a.wishers > #b.wishers end
        local na, nb = (a.name or ""):lower(), (b.name or ""):lower()
        if na ~= nb then return na < nb end
        return a.itemID < b.itemID
    end

    local totalItems, totalWishes = 0, 0
    for _, g in ipairs(order) do
        table.sort(g.items, groupBy == "player" and byPriority or byDemand)
        g.itemCount = #g.items
        if groupBy == "player" then
            g.wishCount = #g.items   -- one wish per row in player mode
        else
            local wishes = 0
            for _, it in ipairs(g.items) do wishes = wishes + #it.wishers end
            g.wishCount = wishes
        end
        totalItems = totalItems + g.itemCount
        totalWishes = totalWishes + g.wishCount
    end

    local rankOf
    if groupBy == "slot" then
        rankOf = function(g) return SLOT_RANK[g.key] end
    elseif groupBy == "armor" then
        rankOf = function(g) return ARMOR_RANK[g.key] end
    end
    table.sort(order, function(a, b)
        -- The catch-all buckets always sink, whatever the pivot.
        local aTail = (a.key == UNKNOWN_KEY or a.key == UNASSIGNED_KEY)
        local bTail = (b.key == UNKNOWN_KEY or b.key == UNASSIGNED_KEY)
        if aTail ~= bTail then return bTail end
        if rankOf then
            local ra, rb = rankOf(a) or 99, rankOf(b) or 99
            if ra ~= rb then return ra < rb end
        end
        local na, nb = (a.name or ""):lower(), (b.name or ""):lower()
        if na ~= nb then return na < nb end
        return a.key < b.key
    end)

    return {
        groupBy = groupBy, groups = order,
        itemCount = totalItems, wishCount = totalWishes,
    }
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
                local short = WGS:ShortName(memberName)
                allowed[short] = true
            end
            local chars = WGS.db.global.characters or {}
            for _, pm in ipairs(t.playerMembers or {}) do
                local info = chars[pm.playerId]
                if info and info.alts then
                    for _, alt in ipairs(info.alts) do
                        allowed[alt] = true
                        local altShort = WGS:ShortName(alt)
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

-- Collapsible group header: divider + chevron + label + dim counts, and
-- the whole row is the hit area. Keeps EventsDetail's section idiom
-- (thin divider + gold label) but earns its click: with five pivots the
-- header is now the primary navigation, not decoration.
--
-- In player mode the label carries the class icon + class colour, so the
-- group reads exactly like a wisher row one level up.
-- Blizzard's own tree-expander art. The first cut used UTF-8 chevrons
-- (▼/▶) in a FontString, which render as an empty box: WoW's default
-- fonts carry no glyph at those codepoints. These two textures are the
-- collapse idiom the spellbook/tradeskill trees use and have shipped
-- since vanilla, so they can't go missing.
local TEX_EXPANDED  = "Interface\\Buttons\\UI-MinusButton-Up"
local TEX_COLLAPSED = "Interface\\Buttons\\UI-PlusButton-Up"

local function BuildGroupHeader(content, yOff, group, collapsed, onToggle)
    local row = CreateFrame("Button", nil, content)
    row:SetSize(CONTENT_W, SECTION_H)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)
    row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    local hl = row:GetHighlightTexture()
    if hl then hl:SetAlpha(0.2) end

    local divider = content:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, yOff - 2)
    divider:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, yOff - 2)
    divider:SetHeight(1)
    divider:SetColorTexture(0.3, 0.3, 0.3, 0.6)

    local x = 4
    local chev = row:CreateTexture(nil, "ARTWORK")
    chev:SetSize(14, 14)
    chev:SetPoint("LEFT", row, "LEFT", x, -1)
    chev:SetTexture(collapsed and TEX_COLLAPSED or TEX_EXPANDED)
    x = x + 18

    -- Player groups get the class icon, same 16px tile as a wisher row.
    local nameHex = "ffffd100"   -- gold, the section-label colour
    if group.class then
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", row, "LEFT", x, -1)
        local classHex = WGS.CLASS_COLORS[group.class] or "ffffffff"
        ApplyClassIcon(icon, group.class, classHex)
        nameHex = classHex
        x = x + 20
    elseif group.playerName then
        nameHex = "ffffffff"   -- known player, unknown class
    end

    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", row, "LEFT", x, -1)
    fs:SetJustifyH("LEFT")
    local counts
    if group.playerName then
        counts = string.format("(%d item%s)", group.itemCount,
            group.itemCount == 1 and "" or "s")
    else
        counts = string.format("(%d item%s \194\183 %d wish%s)",
            group.itemCount, group.itemCount == 1 and "" or "s",
            group.wishCount, group.wishCount == 1 and "" or "es")
    end
    fs:SetText("|c" .. nameHex .. group.name .. "|r  |cff888888" .. counts .. "|r")

    row:SetScript("OnClick", function() onToggle(group.key) end)
    if group.playerName then
        ui.AttachPlayerContextMenu(row, group.playerName, group.class)
    end

    return yOff - SECTION_H
end

-- Compose an item row's dim meta line. Deliberately OMITS whatever
-- dimension is currently the grouping — repeating "Head" on every row
-- under a "Head" header is noise that costs the useful segments room.
-- Segments drop out when the import doesn't carry them (legacy data).
local function ItemMetaSegments(item, groupBy)
    local segs = {}
    local function push(v) if v and v ~= "" then segs[#segs + 1] = v end end
    if groupBy == "player" then
        -- The player IS the header, so no item dimension is redundant;
        -- keep it to the two that drive a loot decision (what it is,
        -- where it drops) since priority takes the right edge.
        push(item.slot)
        push(item.bossName)
    else
        if groupBy ~= "slot"     then push(item.slot) end
        if groupBy ~= "armor"    then push(item.armorType) end
        if groupBy ~= "location" then push(item.location) end
        if groupBy ~= "boss"     then push(item.bossName) end
    end
    return segs
end

-- One item row: quality-coloured name on the left, dim meta on the
-- right — the rail-row chrome (subtle bg, Listbox highlight).
--
-- Item modes end the meta with the wisher count (the demand signal the
-- list is sorted by). Player mode instead right-aligns THAT player's
-- priority + Droptimizer gain, exactly like a wisher row, because in
-- that pivot the row IS the wish.
-- Hover shows the real item tooltip when the client has the item cached.
local function BuildItemRow(content, item, yOff, groupBy)
    local row = CreateFrame("Button", nil, content)
    row:SetSize(CONTENT_W, ITEM_ROW_H)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    bg:SetColorTexture(1, 1, 1, 0.025)

    row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    local hl = row:GetHighlightTexture()
    if hl then hl:SetAlpha(0.25) end

    local rightAnchor = row
    local rightInset = -8
    if groupBy == "player" then
        local prio = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        prio:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        prio:SetJustifyH("RIGHT")
        local text = "|c" .. (ui.PRIORITY_COLORS[item.priority] or "ffffffff")
            .. (item.priority or "?") .. "|r"
        local sim = WGS.FormatWishSimPct and WGS:FormatWishSimPct(item.simPct)
        if sim then
            local color = (tonumber(item.simPct) or 0) > 0 and "|cff44cc66" or "|cff999999"
            text = text .. " " .. color .. sim .. "|r"
        end
        prio:SetText(text)
        rightAnchor, rightInset = prio, -10
    end

    local segs = ItemMetaSegments(item, groupBy)
    if groupBy ~= "player" then
        local n = #item.wishers
        segs[#segs + 1] = n .. (n == 1 and " wisher" or " wishers")
    end
    local meta = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if rightAnchor == row then
        meta:SetPoint("RIGHT", row, "RIGHT", rightInset, 0)
    else
        meta:SetPoint("RIGHT", rightAnchor, "LEFT", rightInset, 0)
    end
    meta:SetJustifyH("RIGHT")
    meta:SetText("|cffaaaaaa" .. table.concat(segs, "  \194\183  ") .. "|r")

    local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameFs:SetPoint("LEFT", row, "LEFT", 8, 0)
    nameFs:SetPoint("RIGHT", meta, "LEFT", -8, 0)
    nameFs:SetJustifyH("LEFT")
    nameFs:SetWordWrap(false)
    nameFs:SetText("|c" .. qualityHex(item.quality) .. item.name .. "|r")
    if item.note and item.note ~= "" and groupBy == "player" then
        nameFs:SetText("|c" .. qualityHex(item.quality) .. item.name
            .. "|r  |cff888888(" .. item.note .. ")|r")
    end

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
    local prioText = "|c" .. (ui.PRIORITY_COLORS[w.priority] or "ffffffff")
        .. (w.priority or "?") .. "|r"
    -- Droptimizer gain beside the priority ("BiS +2.3%") — the number
    -- that separates "wants it" from "gains from it". Shared formatter
    -- with the RCLC voting column (Modules/RCLC.lua).
    local sim = WGS.FormatWishSimPct and WGS:FormatWishSimPct(w.simPct)
    if sim then
        local color = (tonumber(w.simPct) or 0) > 0 and "|cff44cc66" or "|cff999999"
        prioText = prioText .. " " .. color .. sim .. "|r"
    end
    prio:SetText(prioText)

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
-- chrome the redesign gave the Boss filter, now shared by all four.
-- Every dropdown lists exactly what's present in the (team-filtered)
-- wishlist data — Populate stashes the option lists on sv each render —
-- NOT the loot-history values the old view scanned (wrong/empty for
-- bosses never looted). cfg:
--   label     the prefix FontString text ("Boss:")
--   anchor    frame the label hangs off (nil = sv's top-left corner,
--             optionally pushed down by `y` to start a second row)
--   y         top offset when anchor is nil (default -2, the first
--             row; -30 starts the second row on the same 28px pitch)
--   width     button + menu width (budgeted per row against CONTENT_W)
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
        lbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, cfg.y or -2)
    end
    lbl:SetText(cfg.label)

    local btn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    btn:SetSize(cfg.width, 22)
    btn:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    -- `noAll` dropdowns always hold a value (the pivot must be
    -- *something*); the rest start on their "All …" nil selection.
    btn:SetText(cfg.noAll and (cfg.defaultLabel or "") or cfg.allLabel)
    sv[cfg.stateKey] = cfg.noAll and cfg.default or nil

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

    -- Dismiss on any click outside the open menu (GLOBAL_MOUSE_DOWN
    -- fires for every mouse press, anywhere). The opening button is
    -- excluded: its press would hide the menu here on mouse-down, then
    -- its OnClick toggle would immediately re-open it on mouse-up.
    -- Registered only while shown so hidden menus cost nothing. The
    -- RegisterEvent guard keeps stripped test frames harmless.
    if menu.RegisterEvent then
        menu:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
        menu:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
        menu:SetScript("OnEvent", function(self)
            if not self:IsMouseOver() and not btn:IsMouseOver() then
                self:Hide()
            end
        end)
    end

    local menuButtons = {}
    btn:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide(); return end
        -- One open menu at a time — clicking Location while Boss is
        -- open swaps them instead of stacking overlapping panels.
        for _, m in ipairs(sv._filterMenus) do m:Hide() end
        for _, b in ipairs(menuButtons) do b:Hide() end

        local options = {}
        if not cfg.noAll then options[1] = { key = nil, name = cfg.allLabel } end
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

---------------------------------------------------------------------------
-- Collapse state (persisted per profile, keyed by pivot + group)
---------------------------------------------------------------------------
--
-- Keyed by (groupBy, groupKey) so collapsing "Nexus-King" under the Boss
-- pivot doesn't also collapse a same-named group under another pivot.
-- Only EXPLICIT user toggles are stored; a group with no stored state
-- falls back to the size heuristic, so a re-import that changes the
-- group count re-applies the sensible default instead of freezing an
-- old one.

local function CollapseStore()
    local p = WGS.db and WGS.db.profile
    if not p then return {} end
    p.wishlistCollapsed = p.wishlistCollapsed or {}
    return p.wishlistCollapsed
end

local function CollapseKey(groupBy, key) return groupBy .. "\1" .. tostring(key) end

local function IsCollapsed(groupBy, key, groupCount, searching)
    -- An active search means the user asked to SEE things; honouring a
    -- stale collapse would hide their own hits.
    if searching then return false end
    local stored = CollapseStore()[CollapseKey(groupBy, key)]
    if stored ~= nil then return stored end
    return groupCount > AUTO_COLLAPSE_THRESHOLD
end

local function SetCollapsed(groupBy, key, collapsed)
    CollapseStore()[CollapseKey(groupBy, key)] = collapsed
end

---------------------------------------------------------------------------
-- Sub-view build
---------------------------------------------------------------------------

local function BuildSubView(sv)
    -- ONE control row now: the pivot, a search box, and expand/collapse.
    -- The old design spent two rows on four dropdowns; grouping subsumes
    -- three of them and search covers every dimension at once, so the
    -- list starts 28px higher with strictly more reach.
    sv.groupByBtn = BuildFilterDropdown(sv, {
        label = "Group by:", width = 110,
        noAll = true, default = "boss", defaultLabel = GROUP_MODE_LABEL.boss,
        stateKey = "groupBy",
        options = function() return GROUP_MODES end,
    })

    local searchLbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    searchLbl:SetPoint("LEFT", sv.groupByBtn, "RIGHT", 14, 0)
    searchLbl:SetText("Search:")

    local eb = CreateFrame("EditBox", nil, sv, "InputBoxTemplate")
    eb:SetSize(180, 20)
    eb:SetPoint("LEFT", searchLbl, "RIGHT", 10, 0)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(40)
    sv.searchBox = eb
    sv._search = ""

    -- Debounced: rebuilding the whole list on every keystroke stutters
    -- once a guild's wishlists run to a few hundred rows.
    local token = 0
    eb:SetScript("OnTextChanged", function(self)
        sv._search = self:GetText() or ""
        token = token + 1
        local mine = token
        if C_Timer and C_Timer.After then
            C_Timer.After(0.2, function()
                if mine == token and sv._refreshFn then sv._refreshFn() end
            end)
        elseif sv._refreshFn then
            sv._refreshFn()
        end
    end)
    eb:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- Bulk toggle. Label reflects what the click will DO, derived each
    -- render from whether anything is currently open.
    local toggleAll = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    toggleAll:SetSize(96, 22)
    toggleAll:SetPoint("LEFT", eb, "RIGHT", 14, 0)
    toggleAll:SetText("Collapse all")
    toggleAll:SetScript("OnClick", function()
        local collapse = not sv._allCollapsed
        for _, key in ipairs(sv._visibleGroupKeys or {}) do
            SetCollapsed(sv.groupBy or "boss", key, collapse)
        end
        if sv._refreshFn then sv._refreshFn() end
    end)
    sv.toggleAllBtn = toggleAll

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

local function EmptyMessage(tab, text)
    local fs = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
    fs:SetText(text)
    tab.content:SetHeight(30)
end

local function Populate(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)
    tab._visibleGroupKeys = {}

    local wishlists = WGS.db.global.wishlists or {}
    if #wishlists == 0 then
        -- Nothing sticky to clear: the pivot always holds a valid value
        -- and search is its own state, so an empty import can't ghost a
        -- stale selection into the next populate (which is what the old
        -- four-dropdown design had to guard against here).
        ui.CreateImportHint(tab.content, "No wishlists imported yet.", 5, -5)
        tab.content:SetHeight(72)
        return
    end

    local groupBy = tab.groupBy or "boss"
    local search = tab._search or ""
    local searching = trim(search) ~= ""

    local result = WGS:BuildWishlistGroups(wishlists, {
        allowed          = BuildAllowedPlayers(),
        loot             = WGS.db.global.loot,
        characterDetails = WGS.db.global.characterDetails,
        roster           = WGS:GetGuildRosterLookup(),
        groupBy          = groupBy,
        search           = search,
    })

    if #result.groups == 0 then
        EmptyMessage(tab, searching
            and ('Nothing matches "' .. trim(search) .. '".')
            or "No wishlisted items found for the current team filter.")
        return
    end

    local groupCount = #result.groups
    local anyExpanded = false
    local yOff = 0
    for _, group in ipairs(result.groups) do
        tab._visibleGroupKeys[#tab._visibleGroupKeys + 1] = group.key
        local collapsed = IsCollapsed(groupBy, group.key, groupCount, searching)
        if not collapsed then anyExpanded = true end

        yOff = BuildGroupHeader(tab.content, yOff, group, collapsed, function(key)
            -- Toggling while searching writes the state the user just
            -- expressed, so it sticks once the search is cleared.
            SetCollapsed(groupBy, key,
                not IsCollapsed(groupBy, key, groupCount, searching))
            if tab._refreshFn then tab._refreshFn() end
        end)

        if not collapsed then
            for _, item in ipairs(group.items) do
                yOff = BuildItemRow(tab.content, item, yOff, groupBy)
                -- Player mode folds the wish onto the item row itself,
                -- so there are no wisher rows to draw.
                if groupBy ~= "player" then
                    for _, w in ipairs(item.wishers) do
                        yOff = BuildWisherRow(tab.content, w, yOff)
                    end
                end
                yOff = yOff - ITEM_GAP
            end
        end
        yOff = yOff - SECTION_GAP
    end

    tab._allCollapsed = not anyExpanded
    if tab.toggleAllBtn then
        tab.toggleAllBtn:SetText(anyExpanded and "Collapse all" or "Expand all")
    end

    -- SetSize (not just SetHeight) + UpdateScrollChildRect — same
    -- scrollbar-wake dance as the Roster sub-view.
    tab.content:SetSize(CONTENT_W, math.abs(yOff) + 10)
    if tab.scrollFrame and tab.scrollFrame.UpdateScrollChildRect then
        tab.scrollFrame:UpdateScrollChildRect()
    end
end

ui.teams.wishlists = { build = BuildSubView, populate = Populate }
