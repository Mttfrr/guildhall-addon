# Changelog

All notable changes to GuildHall will be documented in this file.

## [0.7.0-beta] — Unreleased

### Changed
- **Attendance is fully automatic, no more HUD or team picker.** The 60×180 "Tracking" HUD frame is gone. The team-picker modal that used to appear on raid entry is gone. On `RAID_INSTANCE_WELCOME` the addon now looks for a scheduled event whose window (start − 30 min … start + 1 h) contains "now", uses its `team_id` if exactly one matches, and otherwise starts the session untagged. No prompts, no chat noise. `/gh attendance` is now a status read-out ("Attendance: recording since 20:14 (Team Alpha)") — there's no manual start/stop. The Dashboard's "Start/Stop Attendance Tracking" button was removed.
- **Bank capture auto-fires when the guild bank UI opens.** `GUILDBANKFRAME_OPENED` now triggers a silent gold snapshot + transaction-log scan (debounced 1 s). The "Capture Bank Gold" and "Scan Bank Transactions" buttons on the Dashboard were removed — they only existed to work around the fact that `GetNumGuildBankMoneyTransactions()` returns 0 before the bank window has been opened in a session. With the auto-trigger that workaround is unnecessary. Per-transaction chat lines were also dropped; the end-of-session export reminder is the single user-visible signal now.

### Added
- **Export envelope v4 with deflate compression.** When LibDeflate is loaded (now vendored at `Libs/LibDeflate/`, zlib license), `WGS:Encode` emits a `WGS4<8-hex-djb2>:<print-encoded compressed JSON>` envelope. Compresses typical raid-data payloads ~60% (lots of repeated keys + class names + character names → big deflate wins), removing the silent-truncation class of bugs that motivated the v3 checksum in the first place. The encoder uses LibDeflate's chat-safe `EncodeForPrint` alphabet (`[a-z][A-Z][0-9]()`) so the output never contains `+` or `/` that can break in WoW's edit boxes. If LibDeflate fails to load (vendored but somehow missing), the encoder falls back to v3 (base64 + checksum). Decoder accepts v2 / v3 / v4 — old paste strings still round-trip. Paired with a JS-side `decodeForPrint` + `DecompressionStream('deflate-raw')` in the web app so the platform's import flow handles v4 natively (zero added dependencies — uses the built-in browser API).
- **MRT loot gap-fill.** 5 seconds after `ENCOUNTER_END` on a kill, if Method Raid Tools is loaded, the addon now walks `VMRT.LootHistory.list` for drops from the same `encounterID` and back-fills any rows our own `CHAT_MSG_LOOT` parser missed (happens in laggy raids, on addon reloads mid-fight, or when a localized loot message doesn't match our patterns). New rows are tagged `source = "mrt"` so the web can distinguish reconstructed entries from native captures. Dedupes against existing rows by `(itemID, player, timestamp ±60s)` so a second run is a no-op. Strictly additive — MRT-less guilds see no behavior change.
- **MRT per-encounter attendance fold-in.** If Method Raid Tools is loaded, attendance sessions now include a `bossAttendance[]` array on every export — one row per pull, sourced from `VMRT.Attendance.data`, with the roster (decoded class letter → class name) and a kill flag. GuildHall's session-level roster is still authoritative for the raid as a whole; this gives the web a boss-by-boss "who was here for which pull" dimension that AI raid reports and the platform's per-encounter views can use. New helper: `WGS:BuildBossAttendanceFromMRT(startedAt, endedAt)` filters MRT's data to the session window and decodes the class-letter prefix (A=Warrior … M=Evoker per `docs/INTEROP.md`). Strictly additive — guilds not running MRT see no behavior change.
- **MRT shared-note read-through.** If Method Raid Tools is loaded, the BossNotes panel now surfaces `VMRT.Note.Text1` as a "MRT Note" section below the imported guild notes. Read-only — the MRT note is what raiders look at mid-pull, so officers stop alt-tabbing between MRT's note window and GuildHall. Reads through `MRT.F.GetNote(removeColors, removeExtraSpaces)` (preferred) with a fallback to `GMRT.F:GetNote()` and finally a raw `VMRT.Note.Text1` lookup; if MRT isn't loaded, nothing changes and the panel renders exactly as before. New helper: `WGS:HasAddon(name)` (cached) gates every MRT/NSRT bridge so guilds without those addons pay zero cost.
- **`docs/INTEROP.md`** — verified saved-variable + public-API contracts for MRT (`VMRT.Attendance.data`, `VMRT.LootHistory.list`, `VMRT.Note.Text1`) and NSRT (`NSRT.NickNames`, `NSAPI:ImportNickNames`, `NSRT.InviteList`). Provenance pinned to the upstream sources with a last-verified date.
- **Public event bus** — `GuildHall` is now a `CallbackHandler-1.0` registry. Other addons (or our own future MRT/NSRT bridge modules) can subscribe via `GuildHall.RegisterCallback(self, eventName, handler)`. Initial events: `WGS_SESSION_STARTED` and `WGS_SESSION_ENDED` (attendance), `WGS_IMPORT_APPLIED` (after a successful import merge), `WGS_LOOT_RECORDED` (each loot row). Documented in `docs/EVENTS.md` with payload shapes.
- **/gh invite uses event signups** — `WGS:GetEventInviteList` now picks the invite source in this order: (1) event signups from the web (committed statuses only — P/L/B/LT), (2) raid comp assignments, (3) team roster. Before, signups were ignored and the addon always went straight to comp/roster, which meant officers who used the web sign-up flow were inviting everyone on the team instead of just the people who said they were coming. The web now ships `data.signups` in the export response.
- **Instant invites** — the 3-second-per-invite stagger in `WGS:AutoInvite` is removed. A 25-person raid used to take 75 seconds to fully invite; now it fires in one tick. The post-invite sort-groups still waits 5s for accepts to land.
- **Export envelope v3 with checksum** — addon now emits `WGS3<8-hex-djb2>:<base64>` and the web emits the same format. The decoder validates the djb2 checksum on the base64 string and rejects truncated paste with a clear error ("Export string appears truncated — please re-copy the full string."). The legacy `WGS<base64>` (v2) envelope is still accepted on import for backwards compatibility.
- **Outdated-addon banner** — Dashboard tab now shows a banner when the running addon is older than the server's `MIN_ADDON_VERSION` (read from the web's export response on import). No more raw error strings on next sync.
- **Auto-populated export on Sync tab open** — the post-raid reminder's "Export Now" button now lands on the Sync tab with the export string already generated, selected and ready for Ctrl+C.
- **Snapshot-before-clear safety net** — "Clear exported data" now stashes a copy of loot/attendance/encounters/bank into `db.global.lastClearSnapshot` first. Type `/gh restore` within 24h to undo. Protects against the "I cleared but my paste was actually truncated" failure mode.

### Changed
- **Core.lua slimmed from 587 → 229 LOC** by extracting utilities into a new `Util/` directory: `Util/JSON.lua` (ToJson/FromJson/JSON_NULL), `Util/Base64.lua` (Base64Encode/Base64Decode/HashString), `Util/Time.lua` (GetTimestamp/GetPlayerKey), `Util/Roster.lua` (NormalizeFullName, BuildCharacterLookup, ResolvePlayerForCharacter, GetGuildRosterLookup, IsGuildGroup, CLASS_COLORS). Same methods on the same `WGS` namespace — no caller had to change. Load order via the new `Util/Util.xml` between Core and Sync.

### Tooling
- **`.luacheckrc`** — Lua 5.1 static analysis with the WoW global allowlist; the codebase passes clean (0 warnings, 0 errors).
- **`spec/`** — busted test harness (`spec/helpers.lua` + `spec/sync_spec.lua` + `spec/clear_spec.lua` + `spec/util_spec.lua`) covering the envelope v3 round-trip, truncation detection, v2 legacy acceptance, djb2 parity with the web's `djb2Hex`, Base64/JSON codecs, version comparison, snapshot-restore lifecycle, and character-lookup/identity helpers. 27 tests, all green.
- **`.github/workflows/ci.yml`** — replaces the old `lint.yml`; runs `luacheck .` and `busted --lua=lua5.1 spec/` on every push and PR.

### Fixed
- Removed a dead `local L` in `Config.lua`, a duplicate `hdr2` declaration in `UI/MainFrame.lua`, and an empty-if branch in `UI/ReadinessCheck.lua` (all surfaced by the new luacheck gate).

## [0.6.0-beta] — 2026-04-13

### Added
- **EventScheduler module** — `/gh invite` (officer/leader only) auto-invites online team members for today's event. Uses raid comp assignments when available, falls back to team roster.
- **`/gh sortgroups`** — automatically moves players into the raid groups defined by the imported comp. Falls back to role-based grouping (tanks→1, healers→2, dps→3+) when no group data.
- **Auto-attendance with late detection** — when a session is started for a scheduled event, members joining after the event time get `late = true` on their attendance record.
- **Bidirectional raid comp** — when attendance stops, the actual raid composition (who was in groups 1-8) is captured and exported alongside attendance data. Web platform can diff planned vs actual.
- **Loot History tab** — scrollable log of recorded loot with live text filter (player/item/boss). Quality-colored items, class-colored players.
- **Wishlists tab** — boss-centric wishlist browser. Pick a boss → see who wishlisted what items from that encounter, sorted by priority (BiS → High → Medium → Low).
- **Roster Check tab** — diff today's expected roster against actual attendance. Three sections: Present (green, with alt annotation), Missing (red, with online/offline status), Extra (yellow, pugs or alts of team members). "Announce Missing to Raid" button.

### Changed
- **Tabbed UI consolidated to 5 tabs** — Dashboard, Roster (Teams + Roster Check), Raid (Comp + Readiness + Events + Boss Notes), Loot (History + Wishlists), Import/Export. Single window with sub-navigation replaces the previous overlapping floating frames.
- **Frame size** — main frame widened to 720x580 to accommodate sub-nav buttons.
- **Slash command targets** — `/gh teams`, `/gh events`, `/gh readiness`, `/gh loot`, `/gh wishlists`, `/gh rostercheck` now open the appropriate tab/sub-view.

### Fixed
- ESC closes the main frame (registered with `UISpecialFrames`).
- Frames respect screen bounds via `SetClampedToScreen(true)`.
- Live UI refresh — attendance button text and status bar update on state changes via 2-second ticker.

### Removed
- ~370 lines of dead code: standalone window creation functions that became unreachable after the tab refactor (`CreateExportFrame`, `CreateImportFrame`, `CreateRaidCompFrame`, etc.), unused locale imports, and the legacy `UpdateMainFrameSummary` wrapper.

## [0.5.0-beta] — 2026-04-12

### Added
- Tabbed main frame interface (initial version).

### Fixed
- Various syntax errors and load-order issues.

## [0.4.1-beta] — 2026-04-07

### Added
- Wago Addons release pipeline — BigWigs packager GitHub Action triggered on version tags.
- `X-Wago-ID` in TOC for automatic publishing.

### Changed
- Switched `.toc` to XML manifests for libraries, modules, sync layer, and UI.
- Cleaned up code style — removed verbose narrating comments.
- Slash commands renamed to `/gh` and `/guildhall`.

## [0.4.0-beta] — 2026-04-07

### Added
- **Alt support** — first-class player-character mapping. Teams reference players, not just characters. Alt swaps don't break roster, attendance, or loot tracking.
- Player roster UI with `+N alts` badges and hover tooltip listing all characters.

### Changed
- Renamed addon namespace from `WoWGuildSync` to `GuildHall` everywhere.
- Tightened guild group filter — 80% guildmates required (up from 50%); fallback denies tracking when members can't be inspected.

### Fixed
- `WishlistTooltip` crash on `ShoppingTooltip1` — uses modern `TooltipDataProcessor` data instead of `tooltip:GetItem()`.
