# Changelog

All notable changes to GuildHall will be documented in this file.

## [0.7.0-beta] — Unreleased

### Added
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
