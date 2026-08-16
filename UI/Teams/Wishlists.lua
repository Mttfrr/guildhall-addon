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
--   source  → majority vote over the item's wish sources, falling back
--             to the loot-history itemID→boss derivation (the old view's
--             only mechanism), else the "Unassigned" bucket.
--   class   → characterDetails / guild-roster lookup; icon omitted when
--             still unknown.
--
-- The grouping/sorting/fallback logic is pure and lives in
-- WGS:BuildWishlistBossGroups so spec/wishlist_boss_groups_spec.lua can
-- pin it without a rendering harness.

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

-- Epic purple — the sensible default for raid loot whose quality isn't
-- cached yet. The old view hardcoded this for every item name.
local QUALITY_FALLBACK_HEX = "ffa335ee"

---------------------------------------------------------------------------
-- Pure grouping logic (exposed as WGS:BuildWishlistBossGroups)
---------------------------------------------------------------------------

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Normalise a free-text boss source into (mergeKey, displayName).
-- Returns nil for empty/absent sources. The key is trimmed+lowercased so
-- "Queen Ansurek" and " queen ansurek " land in one group.
local function bossKey(source)
    if type(source) ~= "string" then return nil end
    local t = trim(source)
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
---       priority, note?, source? } } }, ... }
--- (class + source are new fields; older imports lack both.)
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
--- Returns { bosses = { { key, name, itemCount, wishCount, items = {
---   { itemID, name, quality?, slot?, wishers = { { playerName, short,
---     class?, priority, note? } } } } } } } with:
---   bosses  sorted alphabetically, "Unassigned" always last
---   items   sorted by wisher count desc, then name, then itemID
---   wishers sorted by priority rank (BiS→Low, unknown last), then name
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
    local items   = {}   -- [itemID] = { itemID, name?, slot?, wishers, srcTally }
    local display = {}   -- [mergeKey] = first-seen display casing
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
                    local key, disp = bossKey(item.source)
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
                end
            end
        end
    end

    -- Pass 2 — loot-history fallback maps: itemID → boss tally (for
    -- items whose wishes carry no source) and itemID → itemName.
    local lootTally, lootName = {}, {}
    for _, e in ipairs(opts.loot or {}) do
        if e.itemID and items[e.itemID] then
            local key, disp = bossKey(e.boss)
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
    -- wishers, and bucket it.
    local getItemInfo = opts.getItemInfo or defaultGetItemInfo
    local groups = {}
    for _, rec in pairs(items) do
        if not rec.name then rec.name = lootName[rec.itemID] end
        local ciName, ciQuality = getItemInfo(rec.itemID)
        if not rec.name and ciName then rec.name = ciName end
        rec.name = rec.name or ("Item " .. rec.itemID)
        rec.quality = ciQuality

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

-- One item row: quality-coloured name on the left, dim "Slot · N wishers"
-- pill on the right — the rail-row chrome (subtle bg, Listbox highlight).
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

local function BuildSubView(sv)
    local lbl = sv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", sv, "TOPLEFT", 5, -2)
    lbl:SetText("Boss:")

    sv.dropBtn = CreateFrame("Button", nil, sv, "UIPanelButtonTemplate")
    sv.dropBtn:SetSize(280, 22)
    sv.dropBtn:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    sv.dropBtn:SetText(ALL_BOSSES)
    sv.selectedBossKey = nil

    sv.dropMenu = CreateFrame("Frame", nil, sv, "BackdropTemplate")
    sv.dropMenu:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    sv.dropMenu:SetBackdropColor(0, 0, 0, 0.95)
    sv.dropMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    sv.dropMenu:Hide()
    sv.dropMenuButtons = {}

    -- The dropdown lists exactly the boss groups present in the
    -- (team-filtered) wishlist data — Populate stashes them on
    -- sv._bossGroups each render — NOT the loot-history bosses the old
    -- view scanned (wrong/empty for bosses never looted).
    sv.dropBtn:SetScript("OnClick", function()
        if sv.dropMenu:IsShown() then sv.dropMenu:Hide(); return end
        for _, btn in ipairs(sv.dropMenuButtons) do btn:Hide() end

        local options = { { key = nil, name = ALL_BOSSES } }
        for _, g in ipairs(sv._bossGroups or {}) do
            options[#options + 1] = { key = g.key, name = g.name }
        end

        local bh = 22
        sv.dropMenu:SetSize(280, #options * bh + 8)
        sv.dropMenu:ClearAllPoints()
        sv.dropMenu:SetPoint("TOPLEFT", sv.dropBtn, "BOTTOMLEFT", 0, -2)

        for i, opt in ipairs(options) do
            local btn = sv.dropMenuButtons[i]
            if not btn then
                btn = CreateFrame("Button", nil, sv.dropMenu)
                btn:SetSize(272, bh)
                btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                btn.text:SetAllPoints()
                btn.text:SetJustifyH("LEFT")
                sv.dropMenuButtons[i] = btn
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", sv.dropMenu, "TOPLEFT", 4, -(i - 1) * bh - 4)
            btn.text:SetText("  " .. opt.name)
            btn:SetScript("OnClick", function()
                sv.selectedBossKey = opt.key
                sv.dropBtn:SetText(opt.name)
                sv.dropMenu:Hide()
                if sv._refreshFn then sv._refreshFn() end
            end)
            btn:Show()
        end
        sv.dropMenu:Show()
    end)

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

local function Populate(tab)
    if not tab or not tab:IsVisible() then return end
    ClearContainer(tab.content)

    local wishlists = WGS.db.global.wishlists or {}
    if #wishlists == 0 then
        tab._bossGroups = {}
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

    -- Drop a stale boss selection (team switch or re-import removed the
    -- group) instead of rendering an empty pane against a ghost filter.
    if tab.selectedBossKey then
        local present = false
        for _, g in ipairs(result.bosses) do
            if g.key == tab.selectedBossKey then present = true; break end
        end
        if not present then
            tab.selectedBossKey = nil
            tab.dropBtn:SetText(ALL_BOSSES)
        end
    end

    if #result.bosses == 0 then
        local noData = tab.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", tab.content, "TOPLEFT", 5, -5)
        noData:SetText("No wishlisted items found for the current team filter.")
        tab.content:SetHeight(30)
        return
    end

    local yOff = 0
    for _, boss in ipairs(result.bosses) do
        if not tab.selectedBossKey or boss.key == tab.selectedBossKey then
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
    end

    -- SetSize (not just SetHeight) + UpdateScrollChildRect — same
    -- scrollbar-wake dance as the Roster sub-view.
    tab.content:SetSize(CONTENT_W, math.abs(yOff) + 10)
    if tab.scrollFrame and tab.scrollFrame.UpdateScrollChildRect then
        tab.scrollFrame:UpdateScrollChildRect()
    end
end

ui.teams.wishlists = { build = BuildSubView, populate = Populate }
