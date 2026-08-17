# GuildHall 0.8.0-beta — RCLootCouncil integration

The council's decisions now land in your loot log automatically, and your
guild's wishlists show up where the council actually votes.

This is the biggest release since GuildHall shipped. Everything below is
inert if you don't run RCLootCouncil — nothing changes for guilds that
don't use it.

---

## Run RCLootCouncil? Your loot log fills itself in

When the master looter awards an item, **every raider running GuildHall
records the council's verdict** — not just the ML. The response
(Mainspec / Offspec / Minor Upgrade / …), the vote count, and award
reasons like Disenchant or Bank all land on the loot row and flow to the
website on your next export.

- **The right person gets credited.** On Retail a council drop lands on a
  random raider first and only reaches the winner by trade — so the chat
  capture names the wrong player. GuildHall now retires that temporary
  row when the award arrives, leaving one clean entry: the winner's.
- **`/gh rclc import`** backfills your *entire* existing RCLC history in
  one pass. Safe to re-run — the second run imports nothing.
- **`/gh interop`** gained an RCLC section: is it loaded, is capture on,
  how many rows came from the council.

Two new toggles under **Settings → RCLootCouncil**, both on by default.

## Your wishlists, inside RCLC's frames

With a wishlist import in the addon, the council sees it at the moment it
matters:

- A sortable **"GuildHall" column** in the voting frame, right after
  Response, showing each candidate's priority for the item on the table.
- Your own wish appended to the **roll window** (`GH: BiS`).

Every officer with GuildHall installed sees the column — it's drawn by
each client, so officers without the addon just see RCLC unchanged. When
the ML puts an item up, their wishlist data is shared to the group, so
the whole council reads from the **freshest import in the raid** even if
their own copy is stale.

## Droptimizer gains beside every wish

If a raider has imported a Raidbots Droptimizer report on the website,
their wishes now carry the sim's **real DPS gain** — and it shows up
everywhere a wish renders: the voting column reads **`BiS +2.3%`**, the
roll window, the Wishlists browser, and the loot tooltip.

Priority still sorts first, so a plain BiS always outranks a High with a
big number next to it; the gain only breaks ties *within* a priority
band. Green means a real upgrade, grey means "simmed, no gain" — which
is worth knowing too. Nothing shows for raiders who haven't simmed.

## Rebuilt Wishlists browser

**Teams → Wishlists** was rebuilt around one idea: you should be able to
re-hang the list on whatever question you're asking.

- **Group by — Boss, Player, Location, Slot or Armor.** One dropdown
  pivots the whole tree. Player mode answers "what does this raider still
  need?" at a glance — the raider becomes the section, their items the
  leaves, priority-sorted with their own gain on each row.
- **Search.** One box across everything at once — item name, boss,
  location, slot, armor, even wisher names. Works with any grouping.
- **Collapsible sections**, with item and wish counts on every header, so
  a long list reads as an index instead of an endless scroll. Big lists
  open collapsed, small ones open expanded, and searching expands what it
  finds.

Rows show class icons, class-coloured names, wishers ranked BiS-first,
real item tooltips on hover, and right-click for the usual player menu.

## Deleted loot no longer haunts the website

Delete a loot row in game — an officer correction, or the trade-flow
retiring a mis-captured holder — and the deletion now travels to the
website on your next export. It removes the phantom row there, un-marks
any wishlist item it had wrongly flagged as obtained, and remembers the
deletion so no later export from another raider's client can resurrect
it. Previously that row lived on the website forever.

## Fixed

- **Sync robustness.** Malformed or truncated import strings are now
  caught as malformed instead of half-importing; base64 decode fails
  loudly on junk; and an export that fails to encode tells you, instead
  of handing you an empty box to paste.
- **RCLC capture guards** against double-recording, plus caps so the
  internal dedup tables can't grow unbounded over a long raid week.
- **Attendance tests** no longer fail around midnight (a test-only bug —
  the addon's own day-boundary handling was always correct).

## Compatibility

Declares **WoW 12.0.5 and 12.1**, so one build stays current across the
patch. Requires nothing new — RCLootCouncil is optional, and every RCLC
feature is completely inert without it.

---

**Upgrading:** re-import your data from the website once after updating
(**Sync → Import**) so the addon picks up the new wishlist fields — boss,
location, armor type, and Droptimizer gains.
