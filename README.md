# GuildHall

In-game companion addon for [guildhall.run](https://guildhall.run) — a guild management platform for World of Warcraft.

GuildHall handles the parts of raiding that don't belong in a spreadsheet: tracking who showed up, what dropped, who got it, who's wishlisting what, and keeping the roster in sync between the website and the game. Officers paste an export string into the web app after raid, the website does the heavy lifting on the data side, and the addon imports back everything raiders need to see in-game.

> **Beta** — verify exported data before relying on it for loot decisions.

## Features

### Captured automatically during raid
- **Attendance** — who joined, when, and which subgroup they were in. Late detection if the session is tied to a scheduled event.
- **Loot** — every Epic+ item that drops, attributed to the boss it came from (30-second window after `ENCOUNTER_END`).
- **Boss kills** — encounter ID, name, difficulty, group size, timestamp.
- **Guild bank** — gold balance changes and tab transactions.
- **Final raid composition** — snapshot of who was in groups 1-8 at session end, so the web platform can diff planned vs actual.

### Imported from the web platform
- **Teams** — with player-character mappings, so a Resto Druid main and their Warlock alt are recognized as the same player.
- **Raid comps** — the planned composition for each event, used by `/gh invite` and `/gh sortgroups`.
- **Events** — calendar with date/time, used for auto-attendance and late tracking.
- **Wishlists** — per-player item priorities (BiS / High / Medium / Low), shown on tooltips and in the Wishlists tab.
- **Boss notes** — strategy, assignments, video URLs. Auto-shown on encounter pull.
- **Character details** — class, spec, item level and missing enchants/gems per character, shown as gear pills on the Teams tab.
- **Event signups** — who committed to which event, driving `/gh invite`, the Roster Check diff and officer "Mark status" edits.

### In-game tools
- **Loot History** — scrollable log of every recorded item with live filter.
- **Wishlists browser** — "who wants loot from this boss?" — pick an encounter, see all wishers sorted by priority.
- **Roster Check** — diff today's expected roster against the actual raid. Shows Present / Missing / Extra (with alt annotations).
- **Raid composition tools** — `/gh invite` mass-invites the team, `/gh sortgroups` puts everyone in the right subgroup.
- **Wishlist tooltips** — hover any item to see who in the guild wants it.

## Quick start

1. Sign your guild up at [guildhall.run](https://guildhall.run) and create teams + events.
2. In-game, type `/gh` to open the main window.
3. Paste your guild's import string into the **Sync** tab → click **Import**.
4. Run a raid normally — attendance and loot are captured automatically.
5. After raid, open **Sync** → click **Export** → paste the result back into the web app.

## Slash commands

| Command | What it does |
|---|---|
| `/gh` or `/gh show` | Toggle the main window |
| `/gh teams` | Open Teams → Teams |
| `/gh rostercheck` | Open Teams → Roster Check |
| `/gh wishlists` | Open Teams → Wishlists |
| `/gh events` | Open the Events tab |
| `/gh bossnotes <name>` | Show boss notes for a specific encounter |
| `/gh loot` / `/gh logs` | Open Logs → Loot |
| `/gh bank` | Open Logs → Bank |
| `/gh attendance` | Print tracking status and open Logs → Attendance (capture is event-driven; there is no manual toggle) |
| `/gh attendance reconcile` | Back-fill event bindings on sessions recorded before the event was imported |
| `/gh export` / `/gh import` | Open the Sync tab |
| `/gh export <table>` | Selective single-table export (loot, attendance, encounters, raidCompResults, guildBankMoneyChanges, guildBankTransactions) |
| `/gh sync` | Manual officer-to-officer peer-sync catch-up |
| `/gh team <name\|all>` | Set / clear the global current-team filter |
| `/gh invite` | Auto-invite online team members for today's event (officer/leader only) |
| `/gh sortgroups` | Move players into the subgroups defined by today's raid comp |
| `/gh search <name>` | Cross-context character lookup (loot / attendance / signups / teams / wishlists) |
| `/gh diag` | One-screen data health summary (row counts, last import/export age) |
| `/gh clear` | Clear already-exported telemetry data (confirmed; undo within 24h via `/gh restore`) |
| `/gh restore` | Undo the last clear within its 24h window |
| `/gh rclc import` | Backfill RCLootCouncil's saved award history into the loot log |
| `/gh whatsnew` | Show the release-notes dialog |
| `/gh config` | Open the settings panel |

Aliases: `/guildhall` works for everything `/gh` does.

## Settings

Found at `/gh config` (or Blizzard's AddOns options panel).

- **Guild ID** — links the addon to your guild on guildhall.run
- **Auto-Track Attendance** — start tracking automatically on raid entry (default on)
- **Prompt to Track Scheduled Raids** — pop a one-click "start tracking?" window when you form a raid matching a scheduled event (default on)
- **Auto-Sort Into Comp Groups** — drop fresh joiners into their planned comp subgroup as they accept (default on)
- **Auto-Track Loot** — record Epic+ drops automatically (default on)
- **Guild Groups Only** — only track when ≥80% of the group are guildmates (default on, prevents pug logging)
- **Loot Distribution Helper** — popup when wishlisted loot drops with announce/assign options
- **Auto-Show Boss Notes** — display imported notes when a boss encounter starts
- **Capture RCLC Awards** / **Wishlists in RCLC Frames** — the RCLootCouncil bridge (both default on, inert without RCLC)
- **Enable Officer-to-Officer Sync** — broadcast captured data to other officers (default: on for officers)
- **Show Minimap Icon**

## How alt support works

Teams reference players, not characters. When the web platform sends down the team roster, each entry is a player with a main character and any number of alts. The addon stores this map and uses it to:

- Show the team roster grouped by player (with `+N alts` badges and a hover tooltip listing each character's online status)
- Recognize alts as team members during attendance — if a Druid main's Warlock alt is in the raid, attendance shows them as present (not as an unexpected pug)
- Tag attendance and loot entries with `playerId`, so the web platform can aggregate stats by player across all their characters

If a character isn't in the imported player map (a pug, a trial, an unmapped alt), the addon falls back gracefully — the entry just doesn't get a `playerId`.

## Privacy & data

The addon only captures data from raids and from your guild's bank. It doesn't read combat logs, doesn't track other guilds, doesn't phone home — every piece of data leaves your client only when you explicitly click **Export** and paste the resulting string into the web platform.

The export string is JSON in a `WGS4`-prefixed envelope: deflate-compressed, print-encoded (chat-safe alphabet) and checksummed so a truncated paste is detected instead of silently importing garbage. If the compression library is unavailable it falls back to a checksummed base64 envelope (`WGS3`). Either way it's inspectable — decompress/decode it yourself if you want to see exactly what's being sent.

## Compatibility

- **WoW retail** (Interface 120000+) — primary target
- Other clients (Classic, Cataclysm Classic, etc.) are not currently supported

## Reporting issues

[Open an issue](https://github.com/Mttfrr/guildhall-addon/issues) on GitHub or whisper an officer in your guild who has the addon. Bug reports are most useful with:
- The exact error message (with `/console scriptErrors 1` enabled, or via [BugSack](https://www.curseforge.com/wow/addons/bugsack))
- What you were doing when it happened
- Your addon version (visible at the top of `/gh` and on the minimap tooltip)

## Architecture overview

The addon is built on [Ace3](https://www.wowace.com/projects/ace3) (`AceAddon-3.0`, `AceDB-3.0`, `AceEvent-3.0`, `AceConsole-3.0`, `AceConfig-3.0`).

```
Core.lua            -- Addon namespace, slash dispatch, /gh diag + search, clear/restore snapshot
Config.lua          -- AceConfig settings panel + Data Management clears
GuildHall.toc       -- Addon manifest

Util/
├── JSON.lua        -- Minimal JSON encode/parse
├── Base64.lua      -- Strict base64 + djb2 hash
├── Time.lua        -- Timestamps, player key, shared relative-time formatter
├── Roster.lua      -- Guild roster cache, ShortName, character↔player lookup, guild-group check
├── Roles.lua       -- Role derivation helpers
├── Group.lua       -- Live group/raid helpers
├── Announce.lua    -- Chat announcement helpers
├── SignupStatus.lua-- Signup status codes + officer Mark-status mutator
└── Interop.lua     -- /gh interop diagnostic (MRT / NSRT / RCLC)

Sync/
├── Encoder.lua     -- WGS export envelope (v4: deflate + checksum; v3 fallback)
├── Decoder.lua     -- Inverse: parse import strings (v2/v3/v4)
└── PeerMessage.lua -- Chunked addon-channel wire format for PeerSync

Modules/
├── Attendance.lua  -- Raid roster tracking, late detection, comp snapshots, MRT boss rosters
├── Loot.lua        -- Parses CHAT_MSG_LOOT, attributes to boss encounters, MRT gap-fill
├── GuildBank.lua   -- Gold + transaction monitoring
├── Import.lua      -- Processes incoming web data into db.global
├── EventScheduler.lua -- /gh invite, /gh sortgroups, raid status snapshot, event windows
├── PeerSync.lua    -- Officer-to-officer sync (broadcast, trust gate, catch-up)
├── RCLC.lua        -- RCLootCouncil bridge (award capture + wishlist column)
└── MRTNotes.lua    -- MRT shared-note reader

UI/
├── MainFrame.lua       -- The tabbed main window (Teams / Events / Logs / Sync)
├── Tabs/               -- One file per tab (Teams.lua, Events.lua, Logs.lua, Sync.lua)
├── Teams/              -- Teams sub-views (Roster, RosterCheck, Wishlists)
├── UIHelpers.lua       -- Shared widgets, context menus, popups, priority vocabulary
├── MinimapButton.lua   -- LibDataBroker launcher
├── AttendanceFrame.lua -- HUD overlay during tracking + post-raid reminder
├── RaidTrackingPrompt.lua -- "You're about to raid — start tracking?" prompt
├── LootDistHelper.lua  -- Modal popup when wishlisted loot drops
├── WishlistTooltip.lua -- Item tooltip enrichment
├── LootFrame.lua       -- StaticPopup dialog for clearing exported data
├── EventsFrame.lua     -- Events rail + detail rendering
├── EventsDetail.lua    -- Event detail panel (roster, raid status, comp diff)
├── BossNotesFrame.lua  -- Boss-notes rendering
└── WhatsNew.lua        -- Release-notes dialog + title-bar badge
```

The web platform is the source of truth for team rosters, wishlists, and events. The addon is a read-only consumer of that data and a write-only producer of in-game capture data.

## License

See [LICENSE](LICENSE) if present. Otherwise: all rights reserved by the author — inquiries welcome.

---

Built for [GuildHall](https://guildhall.run). The web platform handles team management, scheduling, loot history, and reporting — this addon is the in-game face of it.
