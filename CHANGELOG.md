# Changelog

All notable changes to GuildHall will be documented in this file.

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
