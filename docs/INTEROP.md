# Cross-addon Interop Contract

GuildHall integrates opportunistically with three third-party addons:

- **MRT** — Method Raid Tools by ykiigor (a.k.a. ExRT, Exorsus Raid Tools)
- **NSRT** — Northern Sky Raid Tools by Reloe
- **RCLC** — RCLootCouncil by Potdisc

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

## RCLootCouncil (`RCLootCouncil`)

**Detection:** `WGS:GetRCLC()` / `WGS:HasRCLC()` (Util/Interop.lua) — a
silent `LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)` probe,
accepted only when the object exposes `Require` (RCLC's class-system
entry point, the surface we consume). Cached per session.

**Bridge module:** `Modules/RCLC.lua`. Two surfaces, each behind a
profile toggle: award capture (`rclcCapture`) and wishlist injection
(`rclcWishlistColumn`). Diagnostics: `/gh interop` (or `/gh rclc`);
bulk backfill: `/gh rclc import`.

### Award capture — the `"RCLC"` comm prefix

RCLC's comms layer is `RCLootCouncil.Require("Services.Comms")`
(Classes/Services/Comms.lua). Subscriptions are RxLua subjects and
**additive** — `Comms:BulkSubscribe(prefix, { command = fn })` never
interferes with RCLC's own handlers. Receiver signature is
`fn(data, sender, command, distri)` where `data` is the raw arg array
(`unpack(data)` to get the command's payload).

We subscribe to two commands on `RCLootCouncil.PREFIXES.MAIN`
(`"RCLC"`, Core/Constants.lua):

| Command | Payload | Sent when |
|---|---|---|
| `history` | `(winner, history_table)` | The ML awards an item (ml_core.lua `TrackAndLogLoot`), broadcast to the whole raid **iff the ML's `db.sendHistory` is on** (default on). Every GuildHall user in the raid records it — not just the ML. |
| `delete_history` | `(id)` | The ML retracts an award (`UnTrackAndLogLoot`). |

**Sharp edges** (all verified against RCLC 3.23.0):

- **`sendHistory` gate.** With the ML's `sendHistory` off, `history` is
  only whisper-sent to the ML themself — nobody else receives it. We
  additionally register the `RCMLLootHistorySend` AceEvent message
  (fires on the ML's client regardless, args
  `(history_table, winner, responseID, boss, reason, session, candData)`
  — table FIRST) as an ML-side fallback. With `sendHistory` on, both
  paths fire on the ML; `rclcId` idempotency absorbs the duplicate.
- **`reason.log == false` awards are never tracked or broadcast** —
  `TrackAndLogLoot` early-returns. Award reasons configured not to log
  simply don't exist for us.
- **`entry.date` uses SLASHES**, `"YYYY/MM/DD"`, and both `date` and
  `time` (`"HH:MM:SS"`) are **UTC**. The authoritative clock is the
  `entry.id` epoch prefix (`"<serverTime>-<counter>"`, ML-local counter
  — unique only per ML, which is why our dedup key is
  `winner .. "@" .. id`).
- **`entry.instance` is `"InstanceName-DifficultyName"` concatenated**
  with a bare hyphen — split on the LAST hyphen; difficulty names never
  contain one, instance names can.
- **`responseID` is only a plain button index for real responses.** For
  award reasons it's `reason.sort - 400`, and RCLC's personal-loot modes
  ship strings (`"PL"`, `"BONUS_ROLL"`). The response **text** is the
  durable label; treat `awardResponseId` as opaque unless
  `awardIsReason` disambiguates.
- **`Comms:OnDisable` wipes ALL subscriptions** (ours included). We
  `hooksecurefunc` RCLC's `OnEnable` to re-install; the installers drop
  their previous subscription handles first so re-wiring can't stack
  double deliveries.
- **`owner` may differ from `winner`** — owner is who physically looted;
  we attribute to the winner.

### HistoryEntry → loot row mapping

| HistoryEntry field | Loot row field | Notes |
|---|---|---|
| `id` epoch prefix | `timestamp` | fallback: `date`+`time` parse, then now |
| *(winner arg)* | `player` | realm suffix appended when missing |
| `lootWon` | `itemLink`, `itemID`, `itemName`/`itemQuality`/`itemLevel` | item info `""`/`0` when uncached (web hydrates from itemID) |
| `instance` | `instance` | last-hyphen split, name part |
| `difficultyID` | `difficulty` | |
| `boss` | `boss` | |
| `response` | `awardResponse` | display text — the durable label |
| `responseID` | `awardResponseId` | opaque, see above |
| `isAwardReason` | `awardIsReason` | `true` or omitted |
| `votes` | `awardVotes` | number or omitted |
| *(winner + id)* | `rclcId` | `"<winner>@<id>"`, exact-dedup key |
| — | `source` | `"rclc"` |

The award-field names are a **wire contract with the platform** —
`Sync/Encoder.lua#CleanLootForExport` copies every field except
`itemLink`, so they flow into the export unchanged.

**Dedup rules** (order matters, `WGS:RecordRCLCAward`):

1. Same `rclcId` already stored → skip (idempotent).
2. An unclaimed row with the same `itemID` + short player name within
   **±15 minutes** (councils deliberate; the award lags the drop) →
   **upgrade in place**: award fields + `rclcId` land on the existing
   chat/MRT row, `source` stays as-is, `rev` bumps, and
   `WGS_LOOT_EDITED` (kind `"award"`) rides PeerSync so peers converge.
3. Otherwise insert fresh (Epic+ floor when quality is cached), firing
   `WGS_LOOT_RECORDED`.

`delete_history` finds the row by `rclcId` suffix (`"@<id>"`, any
winner) and routes through the standard `DeleteLootRow` tombstone path.
History-UI response edits (`RCHistory_ResponseEdit` AceEvent message,
Modules/History/lootHistory.lua:1438-1540 — payload is the lib-st row;
`cols[3].args.id` is the entry id, `cols[6].args` the post-edit
`{response, responseID}`) update the matching row the same rev-bumped
way. `RCHistory_NameEdit` (award moved to another player) is **not**
handled — the row keeps the original winner until re-imported.

**Bulk backfill:** `WGS:ImportRCLCHistory()` walks
`RCLootCouncil:GetHistoryDB()` (`lootDB.factionrealm` =
`{ ["Name-Realm"] = { entry, ... } }`) through the same map + dedup
path, with no event/team stamp. Pre-2.7 entries without an `id` get a
timestamp-derived stand-in so re-runs stay idempotent.

### Wishlist injection

- **Voting-frame column** via the official Column API (3.23+):
  `RCVotingFrame:AddColumn(spec, "response", "after")`, colName
  `guildhall_wish`. The cell shows the candidate's imported wish
  priority for the current session's item (canonical
  `ui.PRIORITY_COLORS` chrome, read at call time) plus the wish's
  Droptimizer gain (`simPct`, e.g. `BiS +4.2%`) when the wisher's sim
  shipped one; `comparesort` orders BiS=4 > High=3 > Medium=2 > Low=1 >
  absent=0 (gain doesn't affect the sort). The voting frame builds its
  columns inside RCLC's `OnInitialize`, so the install poll-retries
  (1s, ≤30 tries) like the wowaudit plugin.
- **Roll-window note**: `hooksecurefunc` on
  `RCLootFrame.EntryManager.GetEntry` + per-entry `Update` post-hooks
  append the player's own wish (`GH: BiS`, with the `simPct` gain when
  present) to the entry's `itemLvl` line. `Update` rebuilds that text
  each call, so the append can't stack.
- **Freshness share** on our own `"GHall"` prefix
  (`Comms:GetSender("GHall")` auto-registers it — the sender MUST be
  created before `BulkSubscribe`, which asserts the prefix is known).
  On `RCMLAddItem` (ML added an item to a session) we broadcast
  `gh_wish (itemID, wishes, importedAt)` where `importedAt` is
  `db.global.wishlistImportedAt` (stamped by
  `Modules/Import.lua#importWishlists`). Receivers keep a session-local
  overlay per item, used by the column/roll lookups only when strictly
  newer than their own import. Not persisted.

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
- **RCLC**: `https://github.com/evil-morfar/RCLootCouncil2` @ 3.23.0.
  Files inspected:
  - `Core/Constants.lua` — `PREFIXES.MAIN = "RCLC"`
  - `Classes/Services/Comms.lua` — BulkSubscribe / GetSender / OnDisable wipe
  - `ml_core.lua` — `TrackAndLogLoot` (HistoryEntry shape, `history` /
    `delete_history` sends, `RCMLLootHistorySend` / `RCMLAddItem` messages)
  - `Modules/History/lootHistory.lua` — `RCHistory_ResponseEdit` /
    `RCHistory_NameEdit` payloads, `GetHistoryDB` consumer paths
  - `Modules/VotingFrame/ColumnAPI.lua` + `VotingFrame.lua` — `AddColumn`
    spec + default colNames
  - `Modules/lootFrame.lua` — EntryManager `GetEntry` / `Update` hooks
  - Plus the `RCLootCouncil_wowaudit` plugin as the reference consumer
    of the same surfaces.

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

Neither MRT nor NSRT exposes a master-loot / loot-council surface —
confirmed in this pass. Loot-council data comes from the RCLootCouncil
bridge above instead.
