# CLAUDE.md — GuildHall Addon

The in-game WoW Retail companion for [GuildHall](https://guildhall.run) (web repo: `Mttfrr/guildhall`). It captures loot, attendance, bank gold and raid sessions in-game and syncs them with the platform via export/import strings; it also renders wishlist data inside RCLootCouncil's voting frames. Published to **CurseForge and Wago** — there is no in-repo download.

## Layout

- `Core.lua` — addon bootstrap, `WGS.version`, slash commands
- `Modules/`, `Sync/`, `UI/` — feature code; `Libs/` — vendored libraries (don't lint or hand-edit)
- `spec/` — busted tests (Lua 5.1); `scripts/` — CI guard scripts

## CI (runs on every push/PR)

```bash
bash scripts/check_toc.sh        # TOC ↔ Core.lua version lockstep + Interface sanity
bash scripts/check_removed_apis.sh
luacheck .                       # Lua 5.1 lint (.luacheckrc)
busted --lua=lua5.1 spec/        # tests
```

## Commits & Releases

- **Conventional Commits are required** — `fix:` (patch), `feat:` (minor while pre-1.0), plus non-releasing `chore:` / `docs:` / `test:` / `refactor:` / `ci:`. PR titles too (squash merges).
- **Nobody hand-bumps a version.** `release-please` (`.github/workflows/release-please.yml`) maintains a rolling release PR on `main` that bumps `GuildHall.toc` and `Core.lua` **together** (via the `x-release-please` annotations — the same lockstep `check_toc.sh` guards) and prepends `CHANGELOG.md`. Merging it tags `vX.Y.Z-beta`, which fires `release.yml`: the BigWigs packager builds the zip and uploads to CurseForge + Wago (secrets `CF_API_KEY` / `WAGO_API_TOKEN`).
- **The `-beta` tag suffix is load-bearing.** The packager derives the store release *channel* from the tag name — a tag without `-beta` publishes to the stable channel on both stores. Leaving beta is a deliberate config change (`prerelease-type` in `release-please-config.json`), never a side effect.
- `version.txt` is release-please's own version file (`release-type: simple`) — it, the release-please configs and this file are excluded from the published zip via `.pkgmeta`.

## Conventions

- Lua 5.1 / WoW API only — no LuaJIT-isms; new files must pass `luacheck` and get registered in `GuildHall.toc`'s load list.
- User-visible behaviour changes get a `CHANGELOG.md`-worthy commit message — the generated changelog is what Wago/CurseForge display.
- The addon never scrapes spell/item data the platform can supply — data flows through the export/import strings.
