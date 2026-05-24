# Cross-addon Interop Contract

GuildHall integrates opportunistically with two third-party addons:

- **MRT** — Method Raid Tools by ykiigor (a.k.a. ExRT, Exorsus Raid Tools)
- **NSRT** — Northern Sky Raid Tools by Reloe

This document pins the **verified** saved-variable shapes and public
APIs we read from / write to. Verified against the canonical upstream
sources (see "Provenance" at the bottom). If MRT or NSRT bumps a major
version, this is the file to re-verify against — the bridge modules
(`Modules/MRTNotes.lua`, future MRT attendance/loot bridges, future
NSRT modules) read these contracts and should fail soft (no crash, no
behavior change) when the shape drifts.

`WGS:HasAddon(name)` (Util/Interop.lua) is the gate. Bridge modules
should always check it before touching `VMRT.*` or `NSRT.*` — neither
global is guaranteed to exist.

---

## MRT (`VMRT`)

**SavedVariables:** `VMRT`

**Detection:** `WGS:HasAddon("MRT")`

### Attendance — `VMRT.Attendance.data[]`

Per-encounter roster snapshots. One row per pull (kill or wipe).

```lua
VMRT.Attendance = {
    -- Top-level siblings we don't read but worth listing for completeness:
    enabled       = true,
    specialEdit   = "boss;diff;...",   -- semicolon-delimited per-encounter rules
    OptionsSortPD = "...",
    data = {
        {
            t   = 1716480000,         -- unix timestamp
            eI  = 2902,               -- encounterID
            eN  = "Ulgrax the Devourer", -- encounterName (localized)
            d   = 16,                 -- difficultyID (14 N, 15 H, 16 M)
            k   = true,               -- isKill (boolean)
            c   = "Foo-Realm",        -- recording character key
            g   = 25,                 -- group size
            -- Players 1..40 as positional ints; each value is a one-
            -- character class code followed by the character name.
            [1] = "APlayerOne",       -- "A" = Warrior, "B" = Paladin, ...
            [2] = "BPlayerTwo",
            -- etc.
        },
        -- more pulls
    },
    alts = {
        -- Array of { altName, mainName } pairs. Read-only; not used today.
        { "AltOne", "MainOne" },
    },
}
```

**Class code mapping** (one char prefixes the player name; same order as
`CLASS_SORT_ORDER` in WoW):

| Code | Class |
|---|---|
| A | WARRIOR |
| B | PALADIN |
| C | HUNTER |
| D | ROGUE |
| E | PRIEST |
| F | DEATHKNIGHT |
| G | SHAMAN |
| H | MAGE |
| I | WARLOCK |
| J | MONK |
| K | DRUID |
| L | DEMONHUNTER |
| M | EVOKER |

(Verify against `ExLib.lua` if a new class is added — MRT updates this
table on every expansion.)

### Loot — `VMRT.LootHistory.list[]`

Per-item drop log. Same surface as `CHAT_MSG_LOOT`, **not** richer
attribution — master-loot decisions aren't here.

```lua
VMRT.LootHistory = {
    list = {
        -- Each entry is a pipe-delimited string:
        --   "timestamp#encounterID#instanceID#difficulty#playerName#classID#quantity#itemLink"
        "1716480123#2902#2657#16#PlayerOne#1#1#|cffa335ee|Hitem:212425::::::::80:...|h[Item Name]|h|r",
    },
    bossNames     = { },  -- localized encounter names
    instanceNames = { },  -- localized instance names
    disable       = false, -- user can disable the history capture; respect it
}
```

Filters: rarity ≥ 4 (Epic+), difficulty ∈ {14, 15, 16, 23, 8}
(Normal / Heroic / Mythic / Mythic+ / Heroic-warfront). Same as our
addon's `Modules/Loot.lua` `QUALITY_THRESHOLD`.

### Notes — `VMRT.Note.*`

```lua
VMRT.Note = {
    Text1    = "Phase 1: tanks swap on stack 3...",  -- the shared raid note
    SelfText = "personal note text",
    Black    = { },     -- saved drafts (array)
    AutoLoad = { },     -- per-encounter auto-load associations
}
```

**Public read API** (preferred over raw saved-variable access):

```lua
local note = MRT.F.GetNote(removeColors, removeExtraSpaces)
-- or:
local note = GMRT.F:GetNote()
```

Sync channel (for situational awareness — we don't subscribe today):
addon-message prefix `"multiline"` for note chunks, `"multiline_add"` for
metadata (encounter ID, note name), `"multiline_timer_sync"` for timers.

### Deaths

`VMRT.Deaths` **does not exist** in current MRT. `WhoPulled.lua` tracks
pulls, not deaths. Modern WoW exposes a built-in death log API
(`C_DeathLog`) — that's the right source if we ever want this data.
No MRT bridge needed.

---

## NSRT (`NSRT`)

**SavedVariables:** `NSRT`, `NSRTTimelineData`

**Detection:** `WGS:HasAddon("NorthernSkyRaidTools")`

### Nicknames — `NSRT.NickNames`

```lua
NSRT.NickNames = {
    ["CharacterName-RealmName"] = "Nick",   -- max 12 UTF-8 chars
    -- ...
}
```

**Public read/write API** (use these — direct table writes bypass UI refresh):

```lua
-- Write:
NSAPI:ImportNickNames("Name-Realm:nick;Name-Realm:nick;...")
NSI:GlobalNickNameUpdate()  -- refresh raid frames (Grid2/ElvUI/Cell/VuhDo/Blizzard)

-- Read (prefer over poking NSRT.NickNames directly):
local map = NSAPI:GetAllCharacters()        -- copy of the full nick map
local nick = NSAPI:GetName(name, addon)     -- resolve, honoring per-addon settings
local hits = NSAPI:GetCharacters(query)     -- everyone matching a nick OR name
```

**Semantic note (important):** NSRT nicknames are *display labels*
shown on raid frames across every raider's screen. They are **not**
internal alt-tracking like GuildHall's `db.global.characters[].alts`.
Pushing GuildHall alts as NSRT nicknames would make every alt display
as the main's name to every raider — a behavior change with consent
implications. GuildHall does not push to this surface today; the
bridge would only be appropriate if GuildHall adds nicknames as a
distinct user-facing field.

### Invite list — `NSRT.InviteList`

```lua
NSRT.InviteList = {
    -- Keyed by list name; each value is an array of name strings.
    -- Populated from Viserio "Copy All" paste or the in-game UI.
    [listName] = { "PlayerName", "Player-Realm", ... },
}
```

Read by `NSI:InviteFromReminder()` and `NSI:ArrangeFromReminder()` in
`SetupManager.lua`. No documented public push API. GuildHall does not
write to this surface today; `/gh invite` does the same job through
its own signup-resolution pipeline.

---

## Provenance

These contracts were extracted from:

- **MRT**: `https://github.com/akbyrd/method-raid-tools` (a snapshot of
  ykiigor's upstream `ExRT` source). Files inspected:
  - `MRT-Mainline.toc` — SavedVariables line
  - `RaidAttendance.lua` — attendance shape
  - `LootHistory.lua` — loot record format
  - `Note.lua` — shared-note surface
- **NSRT**: `https://github.com/Reloe/NorthernSkyRaidTools`. Files
  inspected:
  - `NorthernSkyRaidTools.toc` — SavedVariables
  - `NickNames.lua` — nickname store + public API
  - `SetupManager.lua` — invite-list consumer

Last verification: 2026-05-24. No breaking drift from the prior pass;
tightened four sibling-field/shape gaps (Attendance siblings + `alts`,
LootHistory `disable`, InviteList shape, `NSAPI:GetAllCharacters` read
path). If MRT/NSRT release a major version, re-verify these files and
bump this date.

### Known new surfaces we don't read yet (not contracts — feature notes)

- **MRT `VMRT.Marks.list[1..8]`** — raid-target → unit-name with public
  `SetName/GetName/ClearNames/Enable/Disable`. Plausible bridge: a
  GuildHall "tank/kick assignment export" surface.
- **MRT `VMRT.ExCD2.*`** — raid cooldown DB keyed by `playerName+spellID`.
  Plausible bridge: cross-reference with GuildHall fight-plan CDs.
- **MRT `VMRT.RaidCheck.*`** — consumables/flask/food/durability state
  with module accessors. Plausible bridge: pre-pull readiness panel.
- **MRT `VMRT.WhoPulled`** — last-pull attribution. Plausible bridge:
  post-wipe "who pulled" line in GuildHall pull logs.
- **NSRT `NSRT.CooldownList[specID]`** — spec → spell-id cooldowns with
  `NSI:CheckCooldowns / AddTrackedCooldown / RemoveTrackedCooldown`.
- **NSRT `ReadyCheck.lua`** — `NSI:GearCheck / BuffCheck /
  SoulstoneCheck / SourceOfMagicCheck / BlisteringScalesCheck /
  SymbioticRelationshipCheck / GatewayControlCheck` against
  `NSRT.ReadyCheckSettings`. Plausible bridge: borrow NSRT's existing
  gear/enchant/gem/ilvl/tier checks instead of GuildHall's own
  Readiness panel.

Neither addon exposes a master-loot / loot-council surface — confirmed
in this pass.
