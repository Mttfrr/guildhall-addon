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

## What this layer doesn't do

- **Per-table semantics** — dedup keys, merge rules, ordering
  guarantees. Each capture module owns its merge fn (Phase 2).
- **Catch-up on raid entry** — sending historical rows to an officer
  who joined mid-shift. Handled by the `PROBE` / `OFFER` / `REQUEST`
  protocol in Phase 3.
- **Settings** — turning sync on/off per table. Phase 4 surfaces a
  toggle in the existing `Config.lua` AceConfig group.

These are deliberately separate because each one has different
production-stability characteristics: the wire format is the contract
peers must agree on, so we lock it down first; merge rules are
table-specific and can evolve independently per surface.
