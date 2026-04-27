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
- **Gear audit** — missing enchants/gems/ilvl, surfaced via the Readiness tab.

### In-game tools
- **Loot History** — scrollable log of every recorded item with live filter.
- **Wishlists browser** — "who wants loot from this boss?" — pick an encounter, see all wishers sorted by priority.
- **Roster Check** — diff today's expected roster against the actual raid. Shows Present / Missing / Extra (with alt annotations).
- **Raid composition tools** — `/gh invite` mass-invites the team, `/gh sortgroups` puts everyone in the right subgroup.
- **Wishlist tooltips** — hover any item to see who in the guild wants it.

## Installation

### From [Wago Addons](https://addons.wago.io)
Search for "GuildHall" in the Wago client.

### Manual
1. Download `GuildHall.zip` from the [latest release](https://github.com/Mttfrr/guildhall-addon/releases/latest)
2. Extract into `World of Warcraft/_retail_/Interface/AddOns/`
3. Restart WoW (or `/reload`)

## Quick start

1. Sign your guild up at [guildhall.run](https://guildhall.run) and create teams + events.
2. In-game, type `/gh` to open the main window.
3. Paste your guild's import string into the **Import/Export** tab → click **Import**.
4. Run a raid normally — attendance and loot are captured automatically.
5. After raid, open **Import/Export** → click **Export** → paste the result back into the web app.

## Slash commands

| Command | What it does |
|---|---|
| `/gh` or `/gh show` | Toggle the main window |
| `/gh teams` | Open Roster → Teams |
| `/gh rostercheck` | Open Roster → Roster Check |
| `/gh events` | Open Raid → Events |
| `/gh readiness` | Open Raid → Readiness |
| `/gh bossnotes <name>` | Open Raid → Boss Notes for a specific encounter |
| `/gh loot` | Open Loot → History |
| `/gh wishlists` | Open Loot → Wishlists |
| `/gh export` / `/gh import` | Open Import/Export tab |
| `/gh attendance` | Toggle attendance tracking manually |
| `/gh invite` | Auto-invite online team members for today's event (officer/leader only) |
| `/gh sortgroups` | Move players into the subgroups defined by today's raid comp |
| `/gh config` | Open the settings panel |

Aliases: `/guildhall` works for everything `/gh` does.

## Settings

Found at `/gh config` or via the cogwheel on the Dashboard tab.

- **Auto-Track Attendance** — start tracking automatically on raid entry (default on)
- **Auto-Track Loot** — record Epic+ drops automatically (default on)
- **Guild Groups Only** — only track when ≥80% of the group are guildmates (default on, prevents pug logging)
- **Loot Distribution Helper** — popup when wishlisted loot drops with announce/assign options
- **Raid Readiness Check** — auto-warning on raid entry if any member has missing enchants/gems
- **Auto-Show Boss Notes** — display imported notes when a boss encounter starts
- **Show Web MOTD on Login** — display the guild's web MOTD in chat

## How alt support works

Teams reference players, not characters. When the web platform sends down the team roster, each entry is a player with a main character and any number of alts. The addon stores this map and uses it to:

- Show the team roster grouped by player (with `+N alts` badges and a hover tooltip listing each character's online status)
- Recognize alts as team members during attendance — if a Druid main's Warlock alt is in the raid, attendance shows them as present (not as an unexpected pug)
- Tag attendance and loot entries with `playerId`, so the web platform can aggregate stats by player across all their characters

If a character isn't in the imported player map (a pug, a trial, an unmapped alt), the addon falls back gracefully — the entry just doesn't get a `playerId`.

## Privacy & data

The addon only captures data from raids and from your guild's bank. It doesn't read combat logs, doesn't track other guilds, doesn't phone home — every piece of data leaves your client only when you explicitly click **Export** and paste the resulting string into the web platform.

The export string is plain JSON wrapped in base64 with a `WGS` prefix. You can decode it yourself if you want to see exactly what's being sent.

## Compatibility

- **WoW retail** (Interface 120000+) — primary target
- Other clients (Classic, Cataclysm Classic, etc.) are not currently supported

## Reporting issues

[Open an issue](https://github.com/Mttfrr/guildhall-addon/issues) on GitHub or whisper an officer in your guild who has the addon. Bug reports are most useful with:
- The exact error message (with `/console scriptErrors 1` enabled, or via [BugSack](https://www.curseforge.com/wow/addons/bugsack))
- What you were doing when it happened
- Your addon version (visible at the top of `/gh` and on the minimap tooltip)

## Building & releasing

Releases are automated via the [BigWigs packager](https://github.com/BigWigsMods/packager) GitHub Action. Push a `v*` tag and the workflow packages the addon and uploads to Wago.

Manual release flow (for the maintainer):

```sh
# Bump version in Core.lua and GuildHall.toc, update CHANGELOG.md
git commit -am "Bump version to vX.Y.Z-beta"

# Tag and push
git tag -a vX.Y.Z-beta -m "vX.Y.Z-beta"
git push origin main vX.Y.Z-beta
```

The GitHub release also needs to be created (or the packager Action will handle it) for the Wago webhook to fire.

## Architecture overview

The addon is built on [Ace3](https://www.wowace.com/projects/ace3) (`AceAddon-3.0`, `AceDB-3.0`, `AceEvent-3.0`, `AceConsole-3.0`, `AceConfig-3.0`).

```
Core.lua            -- Main addon namespace, JSON/Base64, guild roster cache
Config.lua          -- AceConfig settings panel
GuildHall.toc       -- Addon manifest

Sync/
├── Encoder.lua     -- WGS export envelope (JSON + base64)
└── Decoder.lua     -- Inverse: parse import strings

Modules/
├── Attendance.lua  -- Tracks raid roster, late detection, comp snapshot
├── Loot.lua        -- Parses CHAT_MSG_LOOT, attributes to boss encounters
├── GuildBank.lua   -- Gold + transaction monitoring
├── Import.lua      -- Processes incoming web data into db.global
├── EventScheduler.lua -- /gh invite, /gh sortgroups, late-tracking helpers
└── MOTD.lua        -- Displays imported guild MOTD on login

UI/
├── MainFrame.lua       -- The 5-tab main window
├── MinimapButton.lua   -- LibDataBroker launcher
├── AttendanceFrame.lua -- HUD overlay during tracking + post-raid reminder
├── LootDistHelper.lua  -- Modal popup when wishlisted loot drops
├── WishlistTooltip.lua -- Item tooltip enrichment
├── LootFrame.lua       -- StaticPopup dialog for clearing exported data
├── RaidCompFrame.lua   -- PopulateRaidComp (sub-view in Raid tab)
├── ReadinessCheck.lua  -- PopulateReadiness + auto-warning on raid entry
├── EventsFrame.lua     -- PopulateEvents (sub-view in Raid tab)
└── BossNotesFrame.lua  -- PopulateBossNotes (sub-view in Raid tab)
```

The web platform is the source of truth for team rosters, wishlists, and events. The addon is a read-only consumer of that data and a write-only producer of in-game capture data.

## License

See [LICENSE](LICENSE) if present. Otherwise: all rights reserved by the author — inquiries welcome.

---

Built for [GuildHall](https://guildhall.run). The web platform handles team management, scheduling, loot history, and reporting — this addon is the in-game face of it.
