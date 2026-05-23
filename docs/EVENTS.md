# GuildHall Public Events

GuildHall emits a small set of in-process events that other addons (or
internal bridge modules — MRT/NSRT integrations live here once they
land) can subscribe to. The bus is a standard Ace3 `CallbackHandler-1.0`
registry attached to the `GuildHall` namespace, so the subscribe / fire
shape is the same as `AceDB-3.0`, `AceComm-3.0`, etc. — there's nothing
GuildHall-specific to learn.

## Subscribing

```lua
local GuildHall = LibStub("AceAddon-3.0"):GetAddon("GuildHall")

local listener = {}
function listener:OnSessionStarted(event, session)
    -- event is the literal "WGS_SESSION_STARTED"
    -- session is the table described below
end

GuildHall.RegisterCallback(listener, "WGS_SESSION_STARTED", "OnSessionStarted")

-- ...

GuildHall.UnregisterCallback(listener, "WGS_SESSION_STARTED")
```

You can also pass a function instead of a method name:

```lua
GuildHall.RegisterCallback(listener, "WGS_LOOT_RECORDED", function(event, entry)
    -- ...
end)
```

## Stability

These event names + payload shapes are part of GuildHall's public API.
Breaking changes go through a deprecation cycle: the old event continues
to fire alongside the new one for at least one minor release, and the
removal is called out in `CHANGELOG.md` and here.

Anything else inside `GuildHall.*` is internal and may change without
notice.

## Events

### `WGS_SESSION_STARTED`

Fires when attendance capture starts for a raid (RAID_INSTANCE_WELCOME →
auto-start, or manual start via API). Payload: the session table being
built up, with at least:

| Field | Type | Notes |
|---|---|---|
| `startedAt` | integer | unix timestamp |
| `startedBy` | string | full character key, e.g. `"Foo-Realm"` |
| `instanceName` | string | from `GetInstanceInfo()` |
| `difficultyID` | integer | WoW difficulty enum |
| `difficultyName` | string | localized |
| `teamId` | integer or nil | nil = untagged session |
| `teamName` | string or nil | resolved from `db.global.teams` |
| `eventId` | integer or nil | matched scheduled event, if any |
| `eventTitle` | string or nil | |
| `pullTime` | integer or nil | parsed event time, used for late-detection |

The `members` field is present but mutates during the session — don't
hold a reference, snapshot what you need.

### `WGS_SESSION_ENDED`

Fires when the attendance session is finalized and pushed into
`db.global.attendance`. Payload: the same session table as
`WGS_SESSION_STARTED`, additionally with:

| Field | Type | Notes |
|---|---|---|
| `endedAt` | integer | unix timestamp |
| `memberList` | array | flattened member rows (the table you saw mutating during the session, now frozen) |

Fires before the export-reminder popup, so subscribers can decorate
the reminder text or push the session somewhere else without racing.

### `WGS_IMPORT_APPLIED`

Fires after a successful import has been merged into `db.global` (signups,
events, teams, wishlists, raid comps, gear audit, etc.) and
`db.global.lastImport` has been stamped. Payload:

| Field | Type | Notes |
|---|---|---|
| `count` | integer | total rows merged across all tables |
| `importedAt` | integer | matches `db.global.lastImport` |

Use this if you're caching anything derived from imported data (e.g. a
nickname push to NSRT) — the registries you care about are guaranteed
to be in their post-import state by the time this fires.

### `WGS_ENCOUNTER_RECORDED`

Fires for each kill recorded into `db.global.encounters` from
`ENCOUNTER_END`. Payload: the encounter row itself —

| Field | Type | Notes |
|---|---|---|
| `encounterID` | integer | WoW encounter ID |
| `encounterName` | string | localized |
| `difficultyID` | integer | |
| `difficultyName` | string | |
| `groupSize` | integer | |
| `instance` | string | from `GetInstanceInfo()` |
| `timestamp` | integer | |
| `recordedBy` | string | full character key of the local player |

PeerSync subscribes to this to fan kills out to other officers; the
matching merge fn dedupes by `(encounterID, timestamp ±2s)`.

### `WGS_RAID_COMP_SNAPSHOT`

Fires when a raid-comp snapshot is inserted into
`db.global.raidCompResults`. Same payload as the row itself —

| Field | Type | Notes |
|---|---|---|
| `startedAt` | integer | session start, used as the snapshot's group key |
| `signature` | string | stable hash of the slots array; identical comps share a signature |
| `slots` | array | `{ { name, playerId, class, role, group }, ... }` |
| `boss` | string or nil | name of the kill that triggered the snapshot, if any |
| `encounterID` | integer or nil | |
| `recordedBy` | string | |

Useful for any subscriber that wants to react to a real comp change
(as opposed to listening to every session-end event).

### `WGS_PEER_SYNC_APPLIED`

Fires after the PeerSync module receives a delta from another officer,
runs it through the trust gate, decodes the chunk stream, and applies
the registered merge function for that table. Subscribers (UI tabs,
notifiers, badge counters) get a single hook regardless of which
underlying table changed. Payload:

| Field | Type | Notes |
|---|---|---|
| `table` | string | one of `"loot"`, `"attendance"`, `"encounters"`, `"raidCompResults"` (more land as Phase 2 wires them) |
| `row` | table | the decoded row, in the same shape used by the local capture path |
| `action` | string | `"added"`, `"updated"`, or `"skipped"` — whatever the merge fn returned |
| `from` | string | sender's normalised character key, e.g. `"Foo-Realm"` |

UI tabs typically subscribe with a debounce — multiple rows can arrive
in rapid succession during catch-up — and re-render their visible list.

### `WGS_INTERNAL_ERROR`

Fires when a `pcall`-guarded internal operation throws. The addon
catches and continues so the user-visible flow doesn't break, but
subscribers (e.g. a future `/gh diag` UI, a Discord error reporter)
can surface or aggregate these for debugging. Payload:

| Field | Type | Notes |
|---|---|---|
| `source` | string | Stable identifier of the failing call site, e.g. `"Attendance.OnGroupRosterUpdate"`, `"MRTNotes.MRT.F.GetNote"`, `"JSON.FromJson"` |
| `error` | string | The `pcall` error message — may include file/line info from the underlying throw |

Sites that fire today: `Modules/Attendance.lua` (roster-walk
exception during a session), `Modules/MRTNotes.lua` (MRT's note
accessor throwing), `Util/JSON.lua` (parse failure on import),
`Modules/PeerSync.lua` (`PeerSync.gate.rejected`, `PeerSync.Broadcast`,
`PeerSync.dispatch`, `PeerSync.merge.<table>`),
`Sync/PeerMessage.lua` (`PeerMessage.Decode`). Stable contract —
adding new sites is additive.

### `WGS_LOOT_RECORDED`

Fires for each loot row inserted into `db.global.loot` (one event per
item, regardless of whether it came from `CHAT_MSG_LOOT` or — in the
future — a richer source like MRT). Payload: the loot row itself:

| Field | Type | Notes |
|---|---|---|
| `itemLink` | string | full WoW item link |
| `itemID` | integer | |
| `player` | string | looter / receiver |
| `timestamp` | integer | |
| `encounterID` | integer or nil | the boss this loot was attributed to (if known) |
| `encounterName` | string or nil | |
| `difficultyID` | integer or nil | |

Plus any future fields. Treat unknown keys as forward-compat — read
what you need, ignore the rest.

## Implementation note

`GuildHall:FireEvent(event, ...)` is the internal entry point modules
use; it's a thin wrapper around `self.callbacks:Fire(...)` that's
tolerant of being called before `OnInitialize` has wired the registry
up (rare during early bootstrap). External subscribers should not call
it — use `RegisterCallback`.
