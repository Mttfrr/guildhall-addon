# GuildHall Addon — Code Audit (August 2026)

Companion to the full-platform audit in the web repo (`guildhall/docs/feature-audit-2026-08.md`). This file holds the addon-specific findings: bugs, duplication, dead code, SavedVariables growth, and doc drift. Addon source is ~10.3k LOC (excl. `Libs/` 7.9k and `spec/` 7.4k), v0.7.7-beta, Interface 120005.

---

## 1. Correctness bugs (ordered by severity)

1. **`Util/JSON.lua` can infinite-loop (hard client freeze) on truncated input.** `parseArray` (lines ~112–116) and `parseObject` (~119–129) advance with a bare `pos = pos + 1` and never check `pos > len`. On input like `[1,2` the value parse returns nil, `str:sub(pos,pos)` is `""`, the closing-bracket test fails, and `pos` increments forever. The `pcall` at line ~144 does not rescue a hang. Reachable via the raw-JSON debug path (`Sync/Decoder.lua:37`) and the unchecksummed legacy v2 path (`Decoder.lua:73`) — a truncated legacy paste freezes the game client. **Fix: bounds-check both loops.**
2. **Truncated v4/v3 pastes silently downgrade to the v2 parser.** `Decoder.lua:45`/`63` require the `:` at an exact offset; if the paste is cut inside the checksum, both guards fail and control reaches the v2 branch (`WGS4…` starts with `WGS`), which base64-decodes garbage and reports a generic "Failed to parse JSON data" instead of "Export string appears truncated — please re-copy." Compounded by `Util/Base64.lua:37-39` mapping unknown chars to `0` instead of erroring.
3. **Sub-epic loot is broadcast to peers before being retracted.** `Modules/Loot.lua:204-207` inserts the row and fires `WGS_LOOT_RECORDED` (PeerSync broadcasts it) *before* the 1 s deferred quality re-check at line ~185 removes it locally. Peers keep a row the origin client deleted.
4. **Silent export failure.** `UI/Tabs/Sync.lua:213-221`: `if encoded then … end` with no `else`. If `WGS:Encode` returns nil, clicking Export does nothing — no message.
5. **`ProcessImport` is async but returns `true` immediately** (`Modules/Import.lua:324`); `Tabs/Sync.lua:161-165` clears the edit box and refreshes before the importers have run.
6. **`SnapshotRaidComp` dedup only checks the last row** (`Modules/Attendance.lua:576-581`) while its doc comment claims dedup against all session snapshots — an A→B→A comp sequence records A twice.
7. **`mergeSnapshot` trust surface**: any guild member with rank index ≤ 2 can wholesale replace another officer's imported teams/events/signups/wishlists over the addon channel (`Modules/PeerSync.lua:748`). At minimum, document this; consider a per-guild confirmation on first snapshot-accept from a new sender.
8. **Snapshot replay over GUILD is pathologically slow**: full-snapshot exchange fragmented at 220 B/chunk against the 2.0 s GUILD throttle (`PeerSync.lua:28`) takes minutes-to-tens-of-minutes; `replayTable` sends one message per row with no batching.
9. **`\u` escapes are discarded** — `JSON.lua:78` turns any `\uXXXX` into `"?"`; non-ASCII names, boss notes, event titles from the web are silently corrupted.
10. Minor: `Decoder.lua:110-119` prints a leftover "Import data keys: …" debug line on every import; `Config.lua:127-131` calls `LibStub("LibDBIcon-1.0")` unguarded; `UI/BossNotesFrame.lua:29` dereferences `container.noteText` without a nil check; `importTeams`/`importWishlists` assume array shape while `Core.lua:672-682` handles both shapes for the same tables; `MainFrame.lua:448` uses a per-frame `OnUpdate` for 2 s work (use `C_Timer.NewTicker`).

## 2. SavedVariables growth (no pruning anywhere)

All six capture tables (`loot`, `attendance`, `encounters`, `raidCompResults`, `guildBankMoneyChanges`, `guildBankTransactions`) are append-only; nothing prunes on export — the only removal is manual clear.

- **`bossAttendance` is the fastest grower**: one 40-name roster snapshot *per pull* (`Attendance.lua:364`) — a 5-hour prog night on one boss can add 50+ rosters to a single attendance row.
- **`lastClearSnapshot` permanently doubles storage**: `SnapshotExportedData` (`Core.lua:375`) copies all six tables; `HasRestorableSnapshot` only *reports* 24 h expiry — the data is never deleted from disk.
- **`/gh diag` recommends `/gh clear` — a command that does not exist** (`Core.lua:483` `DIAG_LARGE_THRESHOLDS`; the handler table has `restore` but no `clear`).
- `characterLookup` is persisted but fully derivable from `characters` (`Util/Roster.lua:32`); four parallel character maps live in `db.global`.
- Suggested: prune-on-export (or age-based cap) for exported rows, actually expire `lastClearSnapshot`, cap `bossAttendance` per session, add `/gh clear`.

## 3. Duplication

- `GetLibDeflate()` lazy loader ×3: `Sync/Encoder.lua:21`, `Sync/Decoder.lua:12`, `Sync/PeerMessage.lua:40`.
- Relative-time formatter ×3: `Core.lua:507`, `UI/Tabs/Sync.lua:23`, `Util/Interop.lua:147`.
- Short-name strip `name:match("^([^%-]+)")` inlined **41×** across 13 files, plus three named helpers (`Core.lua:575`, `PeerSync.lua:586`, `UIHelpers.lua:377`). Add one `WGS:ShortName`.
- Team-roster expansion block copy-pasted within `Modules/EventScheduler.lua` (`:171-193` ≡ `:227-254`).
- Event-time parsing: `EventScheduler.lua:73` vs `UI/EventsFrame.lua:87` (the latter's comment admits it mirrors the former).
- Gold-snapshot row built identically in `GuildBank.lua:149` and `:282`.
- `CleanLootForExport` dispatch ×3 inside `Encoder.lua`; `itemID`-from-link twice in `Loot.lua` (`:231`, `:281`).
- Priority colour/order tables in both `UI/WishlistTooltip.lua` and `UI/LootDistHelper.lua`.
- Clear-data field lists in **four** places (`Config.lua:190`, `:210`, `UI/LootFrame.lua:14`, `Core.lua:370`) — adding a table means four edits.

## 4. Dead code

No callers found for: `WGS:ExportModules` (`Encoder.lua:222`), `WGS:ListTeams` (`Core.lua:446`), `WGS:GetWishlistForPlayer` (`Import.lua:332`), `WGS:ShowImportFrame` (`LootFrame.lua:34`), `WGS:ToggleEventsFrame` (`EventsFrame.lua:388`). `db.global.exportHistory` is declared, never used. `db.global.gearAudit` is imported and clearable but **never read by any UI** (the Readiness tab it fed doesn't exist). Empty-but-registered handlers: `EventScheduler.lua:551`, `Core.lua:139`. Seven unused locale keys in `Locales/enUS.lua`.

## 5. Documentation / release drift

- **README** lists four files that don't exist (`Modules/MOTD.lua`, `UI/RaidCompFrame.lua`, `UI/ReadinessCheck.lua`, …), advertises **`/gh readiness`** (not implemented — silently falls to help text), advertises "Raid Readiness Check" and "Show Web MOTD on Login" settings that aren't in `Config.lua`, and says `/gh attendance` toggles tracking (it's status-only now).
- **`UI/WhatsNew.lua` release notes stop at 0.7.3** while the addon is 0.7.7-beta — upgraders see an empty modal. CHANGELOG is missing its `## [0.7.5-beta]` header (body sits orphaned inside the 0.7.6 section).
- **`docs/EVENTS.md`**: 14 events fired, 9 documented; `WGS_ATTENDANCE_EDITED`, `WGS_BANK_CAPTURED`, `WGS_GROUP_ROSTER_CHANGED`, `WGS_LOOT_EDITED`, `WGS_SIGNUP_EDITED` undocumented — and `spec/public_events_spec.lua` only pins the documented subset, so the drift is invisible to CI. Pin the full fired list.
- `Config.lua:68` says Guild Groups Only needs "at least half the group"; the code requires ≥ 0.8 (`Util/Roster.lua:168`). `PeerSync.lua` comments claim a 60 s debounce; the constant is 300. `Import.lua:250` says "13 importers"; there are 12.
- Packaging: no `LICENSE` file though README links one; `release.yml` publishes on tag push with **no pre-flight CI gate** (ci.yml runs on push/PR, not tags).

## 6. What's in good shape

The 31-spec/354-case busted suite with a WoW mock layer, the removed-API CI grep, the TOC/version lockstep check, the v4 envelope design (checksum for edit-box truncation, chat-safe alphabet, graceful v3 fallback), the dispatch-table slash handling, `/reload` session survival, and the MRT interop are all solid for an addon of this size.
