# Changelog

All notable changes to GuildHall will be documented in this file.

## [0.7.0-beta] — Unreleased

### Added
- **Global current-team picker.** A dropdown in the main frame's title bar (left of the close X) lets you scope the addon to one team — Events rail, Teams tab, and the team-aware Logs sub-views all read it. Default state is "All Teams" (no filter); per-character profile so different officers keep their own default view across `/reload`. New `WGS:GetCurrentTeamId()` + `WGS:SetCurrentTeamId(teamId)` public API on the addon namespace; Set fires a new `WGS_CURRENT_TEAM_CHANGED { teamId }` event (documented in `docs/EVENTS.md`) so UI surfaces re-render. New `/gh team <name>` slash command (case-insensitive substring match against team names) sets the picker; `/gh team all` clears it; `/gh team` with no argument prints the current state. Get coerces orphan ids (set to a team that's since been removed from `db.global.teams` via re-import) back to nil so the filter doesn't silently hide every row. This commit ships the API + the widget; tab readers wire up in the follow-ups. 6 new specs; 195 specs green, luacheck clean.

### Changed
- **Tab order: Events · Teams · Bank · Raids · Sync.** Promotes Events to position 1 (officer's daily driver after the master-detail rework) and demotes Teams to position 2. The Import/Export tab is renamed to "Sync" — same surface, shorter label that matches the slash command and the `/gh sync` peer catch-up. Default tab on open is now Events instead of Teams. First step in a follow-up that collapses Bank+Raids into a single "Logs" tab with Loot/Bank/Attendance sub-views.
- **Events tab is now master-detail; Raid Comp + Readiness + Boss Notes folded in.** Click an event in the left rail and the right-hand panel fills with that event's roster (signed-up characters with class colour, status badge, ilvl, missing-enchant/gem counts), raid comp (from `db.global.raidComps` matched by `eventId`, grouped by role), boss notes (clickable boss-name picker + body), and four action buttons (Invite, Share Roster, Share Gear Gaps, Share Comp). The three standalone Raids sub-views — Raid Comp, Readiness, Boss Notes — go away; they were per-event concepts living in the wrong place. The Raids tab is now a single loot capture log (no sub-nav). The live-raid Readiness flow (the one that walked `GetRaidRosterInfo`) is dropped along with its `/gh readiness` slash command — the per-event Roster section's gear column covers pre-night planning, and the Teams tab's per-character gear pills cover ongoing roster admin. `/gh bossnotes <name>` now routes through the Events tab and pre-selects the requested note. New `Util/Announce.lua` (`SendChatLine` / `SendChatChunked` / `PackChatTokens`) centralises the `[GuildHall]` chat-output convention + the 200-byte whitespace-aware split; the Roster Check and pre-existing Readiness announce paths both migrate to it, removing duplicated chunking code. The misleading "Ready" idle text at the bottom of the main frame is gone — the bar still shows the green "Attendance tracking active" when actually tracking, and stays hidden otherwise. 13 new specs cover the chat helper end to end; 189 specs green, luacheck clean.

### Removed
- **Web MOTD feature.** The platform's "Web MOTD" was a separate message-of-the-day field officers could set on guildhall.run, surfaced via a Chat print on import + an opt-in second print on `PLAYER_ENTERING_WORLD` (with a 5s post-login delay). In practice it duplicated WoW's own guild MOTD — which the client already prints on login — and added another auto-chat line to disable. Removed: `Modules/MOTD.lua`, the `showWebMOTD` profile toggle, the `webMOTD` global DB field, the `importMOTD` step in `ProcessImport`, and the per-action clearing in the Data Management buttons. The platform still ships `data.motd` in the export (no addon coordination needed — the field is just ignored now).

### Added
- **`/gh sync` slash command — manual officer-sync catch-up.** The peer-sync flow auto-probes on `GROUP_ROSTER_UPDATE` after a raid join, debounced 60s. The new `/gh sync` (alias `/gh catchup`) bypasses the debounce and forces a probe immediately — useful when you join late, suspect a peer's data drifted, or want to verify the channel is working. Prints "Officer sync: probing peers on RAID…" so the operator sees something happened. Officer-rank + channel requirements are unchanged; failures print a clear reason instead of going silent.

### Changed
- **Events tab is now a sortable table.** Replaces the old date/title/description prose-row layout with the same column-table pattern used on the Teams tab. Columns: Date · Time | Title | Type | Team | Signups | Status. Signups shows committed vs tentative as `18 / 4 ?` with a colour bucket (≥20 green, ≥14 orange, below red — rough 20-raider mythic rule). Status pill reads TODAY / SOON (this week) / UPCOMING / PAST based on the parsed start timestamp. Click any header to sort; default is date asc (next event first). Row hover surfaces the full description + signup breakdown in a tooltip.

### Changed
- **Import no longer hitches WoW on paste.** The Import flow used to run all 13 per-section importers — plus the wishlist tooltip-cache preload (potentially 200-500 `C_Item.RequestLoadItemDataByID` calls back-to-back) — in one frame tick. For a 100-character guild that produced a visible stutter every time an officer pasted the export string. Two changes: (1) `WGS:ProcessImport` now streams importers one-per-frame via `C_Timer.After(0, ...)` when the scheduler is available, and (2) the wishlist preload drains in batches of 50 items per frame instead of firing all of them at once. Total wall-clock time is unchanged but per-frame work stays small enough that the client doesn't visibly hitch. Each importer also runs under `pcall` now — a malformed section (server bug, partial paste) fires `WGS_INTERNAL_ERROR` with `source = "Import.step.<n>"` and the rest of the import continues against `db.global`. The `WGS_IMPORT_APPLIED` event still fires exactly once at the tail of the chain so subscribers see a fully-consistent db. Tests without `C_Timer` continue to run synchronously, preserving the legacy contract that `ProcessImport` is observable inline.

### Added
- **Peer-to-peer officer sync — catch-up on raid entry + settings toggle (Phases 3 & 4).** Closes out the rollout. An officer who logs in mid-raid now picks up the captures other officers have already broadcast: on `GROUP_ROSTER_UPDATE` (debounced 60s) the addon ships a `__probe`, peers reply with their per-table max timestamps (`__offer`), and the joiner sends a `__request` to the peer who's furthest ahead per table — that peer replays the matching rows through the normal broadcast path so the joiner's merge fns dedup against anything already local. The three reserved table names (`__probe`, `__offer`, `__request`) ride the same wire frame as data deltas; the dispatcher intercepts them before the per-table merge lookup. Replay is floored at 7 days of history so a fresh install doesn't flood the channel. Settings toggle lives in `/gh config` → Officer Sync → "Enable Officer-to-Officer Sync"; default is "on for officers, off otherwise" (explicit user choice overrides). Takes effect on `/reload`. Behavioural change for the broadcast throttle: when no `C_Timer` is available (only happens in tests), the queue drains inline instead of stalling — production is unchanged. 12 new tests for the catch-up flow (probe emission, debounce, officer gate, offer collection, request targeting, replay window, ignore-when-not-addressed); 176 specs green, luacheck clean. Protocol contract in `docs/PEERSYNC.md` updated.

### Added
- **Peer-to-peer officer sync — per-table subscribers (Phase 2).** Wires the transport from Phase 1 to the four capture surfaces officers actually care about: `loot` (broadcast on `WGS_LOOT_RECORDED`, dedup by `(itemID, player-short, ±60s)` mirroring the MRT reconciliation pattern), `attendance` (broadcast on `WGS_SESSION_ENDED`, first-wins per `(startedAt, startedBy)`), `encounters` (new event `WGS_ENCOUNTER_RECORDED` fired from `Modules/Loot.lua` ENCOUNTER_END handler, dedup by `(encounterID, ±2s)`), and `raidCompResults` (new event `WGS_RAID_COMP_SNAPSHOT` fired from `Modules/Attendance.lua` after each comp insert, skip when `(startedAt, signature)` matches). Merge fns insert directly into `db.global` without re-firing the capture event (no broadcast loop). Each subscriber is a one-liner that hands the row to `WGS:PeerSync_Broadcast`; the broadcast layer drops silently when we aren't an officer or have no channel, so capture sites stay oblivious to sync state. End-to-end test covers the full A-broadcasts → B-receives → B's db.loot grows path. Two new public events documented in `docs/EVENTS.md`.
- **Peer-to-peer officer sync — transport layer (Phase 1).** Officer addons can now exchange capture deltas over WoW's addon-message channel: each delta is JSON-encoded → LibDeflate-compressed → `EncodeForWoWAddonChannel`'d → split into ≤220-byte chunks framed as `WGS|<msgId>|<idx>/<total>|<payload>` and shipped via `C_ChatInfo.SendAddonMessage`. The receiver reassembles by explicit chunk index (out-of-order arrival is fine), gates incoming chunks on `IsInGuild()` + sender `rankIndex <= 2` (same threshold as `WGS:IsGuildOfficer`), drops self-loopbacks, then dispatches the decoded `{ table, row }` to a registered per-table merge fn. Channel selection is `RAID > PARTY > GUILD > nil` with a 2s throttle on GUILD (WoW silently drops bursts above ~1/s there). Two new files: `Sync/PeerMessage.lua` (pure transport — encode/chunk/reassemble, 30s TTL on partial messages) and `Modules/PeerSync.lua` (orchestration — `C_ChatInfo` registration, trust gate, throttled outbound queue, dispatch). New public event `WGS_PEER_SYNC_APPLIED { table, row, action, from }` fires per merged row. New `WGS_INTERNAL_ERROR` sources for ops visibility: `PeerSync.gate.rejected`, `PeerSync.Broadcast`, `PeerSync.dispatch`, `PeerSync.merge.<table>`, `PeerMessage.Decode`. Per-table merge fns + capture-side wire-up land in Phase 2; this commit is transport + trust gate only, fully covered by busted specs (26 new tests across `spec/peer_message_spec.lua` and `spec/peer_sync_spec.lua`). Protocol contract documented in `docs/PEERSYNC.md`.

### Fixed
- **Team members no longer disappear when a team mixes linked + unlinked characters.** The Teams sub-view used to take an `elseif team.members` branch — if `team.playerMembers` had any rows, the flat `team.members` list was skipped entirely. So a team with 5 web-linked raiders + 3 newly-added characters that hadn't yet been claimed by a user would render only the 5 linked ones, and the 3 new additions were invisible until they linked. Same shape of bug in `BuildRosterCheckData` (Roster Check sub-view). Both now iterate `team.members` (the canonical full list) and decorate each row from `team.playerMembers` when a link exists.

### Changed
- **Teams sub-view redesigned: main-on-left, alts-on-right, class icons, per-character gear pills.** Each team member row now leads with a class icon + the main's name + a gear-status pill, then a horizontal strip of their alts (up to 3 inline, "+N more" with a hover tooltip listing the rest). Guild rank dropped — the user pointed out it wasn't useful info on this surface. The class icon comes from WoW's `Interface\Glues\CharacterCreate\UI-CharacterCreate-Classes` sprite via `CLASS_ICON_TCOORDS`; falls back to a class-coloured square if the class is unknown. Gear pills now appear on alts too (was only on mains), sourced from a new `characterDetails` field on the export that covers every level-80 character — not just the ones with issues like the existing `gearAudit` did.

### Changed
- **UI restructured to mirror the platform layout.** Tabs are now Teams / Bank / Events / Raids / Import-Export (was Dashboard / Roster / Raid / Loot / Sync). The Dashboard tab is gone — its summary tiles were duplicated by the surfaces they pointed at. Roster became **Teams** with a new gear-issue column (missing enchants, missing gems, ilvl-vs-target) sourced from the existing `gearAudit` import. Events was promoted from a Raid sub-view to a top-level tab. Loot was folded in: Loot History now lives under Bank (capture-log data), Wishlists now lives under Teams (per-player data). Slash commands updated: `/gh bank` opens the new Bank tab; `/gh teams`, `/gh events`, `/gh readiness`, `/gh loot`, `/gh wishlists`, `/gh rostercheck` all still work and land on the right place.
- **Bank-capture confirmation in chat.** Opening the guild bank used to produce no visible feedback (Track A removed the per-transaction chat noise). Now after the 1s debounce settles, GuildHall prints one line: "Bank captured: 12345g 67s 89c." with a "N new transaction(s)" suffix when the money log scan picked up new rows. Captures stay silent when not in a guild or when the API hasn't loaded yet.
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
