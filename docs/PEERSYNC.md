# Peer-to-peer officer sync

This document is the contract for GuildHall's officer↔officer in-raid
sync. The goal: when officer-A's addon captures a loot drop, attendance
session, raid-comp snapshot, or boss kill, officer-B's addon receives
that row within a few seconds — no copy-paste, no waiting for the next
platform export.

It splits cleanly into two layers:

| File | Responsibility |
|---|---|
| `Sync/PeerMessage.lua` | Pure transport — encode a delta into 255-byte chunks, reassemble on the receiver, compress via LibDeflate, no side effects |
| `Modules/PeerSync.lua` | Orchestration — channel selection, outbound throttle, trust gate, dispatch to per-table merge fns |

Per-table merge logic (loot dedup keys, attendance member-list union,
encounter ±2s tolerance, raid-comp signature compare) lives alongside
each capture module and registers itself via
`WGS:PeerSync_RegisterMerge(tableName, fn)`. Phase 2 of the rollout
fills these in.

## Wire format

Every addon-message carries one chunk in this shape:

    WGS|<msgId>|<chunkIdx>/<chunkTotal>|<payload>

- `WGS` — addon-message prefix, registered via
  `C_ChatInfo.RegisterAddonMessagePrefix("WGS")` in
  `Modules/PeerSync.lua` `OnEnable`.
- `msgId` — 8-hex-char `WGS:HashString(senderKey .. counter .. time())`.
  Distinct per outbound message; receivers key the reassembly buffer
  on `(sender, msgId)`.
- `chunkIdx/chunkTotal` — 1-indexed integers. Receivers address chunks
  by their explicit index, so out-of-order arrival is fine.
- `payload` — up to 220 bytes per chunk (255-byte channel cap minus
  ~20 bytes of framing, plus headroom).

The full payload, after concatenation, is:

    LibDeflate:EncodeForWoWAddonChannel( LibDeflate:CompressDeflate( ToJson(delta) ) )

where `delta = { table = "<tableName>", row = {...} }`. Same JSON and
hash machinery used by the existing v3/v4 export envelope — nothing new
to vendor.

## Trust gate

Every received chunk goes through the gate before the decoder runs:

1. **Self-loopback** — if the sender's normalised key matches our
   `WGS:GetPlayerKey()`, drop. (WoW sometimes echoes our own
   addon-messages back to us in cross-realm raids.)
2. **Guild membership** — if `IsInGuild()` is false on our side, drop.
   We rely on guild rank as the source of authority, so we have to
   actually have a guild to evaluate it.
3. **Officer rank** — the sender must appear in `GetGuildRosterInfo` with
   `rankIndex <= 2` (same threshold as `WGS:IsGuildOfficer`). A kicked
   officer (demoted but still in the guild) can no longer inject writes.
4. Failed gate → `WGS_INTERNAL_ERROR` fires with
   `source = "PeerSync.gate.rejected"`, dropped silently otherwise.

The same threshold gates outgoing broadcasts: if we ourselves aren't an
officer, `WGS:PeerSync_Broadcast` returns `false, "not officer"`
without touching the wire.

### Known limitation: rank is the whole trust model

The gate authenticates *rank*, not *content*. Any guild member whose
rank index is ≤ 2 can broadcast rows — and, via the snapshot path
(`mergeSnapshot`), an **entire import payload** that wholesale replaces
another officer's imported teams / events / signups / wishlists the
moment its stamp is newer than the receiver's `lastImport`. There is no
per-sender confirmation, no payload signature, and no way to
distinguish a well-meaning officer with stale data from a compromised
or malicious officer account: officer rank IS the credential.

Practical blast radius: capture tables merge row-by-row with dedup /
LWW rules (bounded damage), but a snapshot apply rewrites the imported
state in one shot. Recovery is a re-import from the web platform (the
platform stays the source of truth; nothing addon-side writes back to
it). If your guild hands rank ≤ 2 to people who shouldn't be able to
rewrite officer addon data, either tighten your rank structure or turn
Officer Sync off (`/gh config` → Officer Sync). A per-guild
confirmation on first snapshot-accept from a new sender is a
possible future hardening — deliberately not implemented yet.

## Channel selection

`WGS:PeerSync_PreferredChannel()` returns the highest-priority channel
we can use right now:

| Group state | Channel | Throttle |
|---|---|---|
| `IsInRaid()` | `"RAID"` | 0.1s between sends |
| `IsInGroup()` (party, not raid) | `"PARTY"` | 0.1s between sends |
| `IsInGuild()`, solo | `"GUILD"` | 2.0s between sends |
| solo + no guild | `nil` | broadcasts no-op |

The GUILD throttle is mandatory: WoW's hidden global rate-limit on the
guild addon-channel is ~1 message/sec, and exceeding it causes silent
drops. We queue excess chunks and flush via `C_Timer.After`.

## Reassembly + GC

`Sync/PeerMessage.lua` holds a per-sender buffer keyed by `msgId`. Each
entry has a 30-second TTL refreshed on every chunk arrival. A
disconnect mid-message leaves the partial entry in the buffer; the next
`DecodePeerMessage` call sweeps anything past its TTL. No periodic
timer is needed — the sweep is O(senders), amortised against the
broadcast traffic that's already happening.

Duplicate chunks are idempotent — the second arrival is ignored, state
is preserved. A peer reusing the same `msgId` with a different
`chunkTotal` (shouldn't happen, but defensive) resets the partial
state.

## Public surface

| API | Side |
|---|---|
| `WGS:EncodePeerMessage(delta)` → `chunks[]`, `err` | sender (transport) |
| `WGS:DecodePeerMessage(senderKey, chunkStr)` → `delta` or `nil` | receiver (transport) |
| `WGS:PeerSync_PreferredChannel()` → `"RAID"` / `"PARTY"` / `"GUILD"` / `nil` | both |
| `WGS:PeerSync_Broadcast(tableName, row)` → `ok`, `err` | sender (orchestration) |
| `WGS:PeerSync_RegisterMerge(tableName, fn)` | receiver setup |
| `WGS:PeerSync_HandleIncoming(senderKey, chunkStr, isSelf)` | called by `CHAT_MSG_ADDON` handler; exposed for tests |

Plus the `WGS_PEER_SYNC_APPLIED` and `WGS_INTERNAL_ERROR` events
documented in `docs/EVENTS.md`.

## Catch-up handshake

An officer who logs in mid-raid has none of the captures peers have
already broadcast. The handshake fills that gap without requiring
either side to know "who's new":

```
joiner  →  __probe            broadcast: GROUP_ROSTER_UPDATE saw IsInRaid()
peers   →  __offer            broadcast: each peer responds with their per-table max(ts)
joiner  →  __request          broadcast: pick best peer per table, ask for since=local_max
peer    →  normal deltas      replays matching rows via PeerSync_Broadcast
```

The three reserved table names (`__probe`, `__offer`, `__request`)
ride the same wire format as data deltas — the dispatcher in
`PeerSync_HandleIncoming` intercepts them before the per-table merge
lookup. They go through the same trust gate (officer rank, in-guild)
as normal traffic, so a kicked officer can't catch themselves up.

Knobs:

| Name | Default | What |
|---|---|---|
| `CATCHUP_DEBOUNCE` | 300s (5 min) | minimum gap between probes (`/gh sync` bypasses it) |
| `CATCHUP_OFFER_WAIT` | 5s | how long the joiner waits to collect offers before requesting |
| `CATCHUP_MAX_HISTORY` | 7 days | replay floor — never re-broadcast rows older than this regardless of `since` |

Each `__offer` carries a `replyTo` so the joiner can distinguish
offers responding to *their* probe from incidental traffic between
other peers; each `__request` carries a `target` so only the chosen
peer replays. Replay still goes out on the shared channel (addon
messages don't unicast outside WHISPER), but other peers' merge fns
treat the rows as duplicates and skip — wasted bandwidth, not wasted
state.

## Settings

`/gh config` → **Officer Sync** → "Enable Officer-to-Officer Sync".

The flag lives at `db.profile.peerSyncEnabled` and is read at
`module:OnEnable`. Default is `nil`, which means "use the officer
default" — on for officers, off otherwise. Explicit `true` / `false`
overrides. Takes effect on `/reload` because the gate runs once at
module enable rather than on every broadcast (cheap, but also lets
us stop registering for `GROUP_ROSTER_UPDATE` etc. when the feature
is off).

## What this layer doesn't do

- **Per-table semantics** — dedup keys, merge rules, ordering
  guarantees. Each capture module owns its merge fn.
- **Settings per table** — there's a single on/off; per-table opt-out
  was specced but cut because the merge fns already make per-table
  participation cheap to ignore.
