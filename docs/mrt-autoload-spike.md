# Spike: load each boss's raid note into MRT automatically

Status: **not built — a spike to run before anyone writes the feature.**

## The idea

The platform already renders each lineup boss's cooldown plan as an
MRT/ERT note (`services/cdPlan.js#buildMrtNote`, the "Copy raid note"
action on the boss card). Today an officer copies it on the web and pastes
it into MRT by hand, once per boss, mid-raid.

The addon now follows the raid through tonight's lineup
(`WGS:GetCompBoss`, advanced on every kill — see `Modules/EventScheduler.lua`).
So it knows *which* boss is next. If the export also carried each boss's
note text, the addon could put the right note into MRT when the raid moves
onto that boss — no copy-paste.

## What has to be true first (verify, don't assume)

GuildHall only **reads** MRT's note today (`Modules/MRTNotes.lua`, via
`MRT.F.GetNote` / `GMRT.F:GetNote`, falling back to `VMRT.Note.Text1`).
Writing is a different contract and none of this is verified yet:

1. **Is there a supported write path?** Find out whether MRT exposes a
   public setter, or whether the only route is writing `VMRT.Note.Text1`
   and asking MRT to redraw. Writing another addon's saved variable is
   fragile — it can break on any MRT update — so a public API is a hard
   prerequisite for shipping, not a nice-to-have.
2. **Does a local write reach the raid?** MRT's note is shared by the
   raid leader *sending* it. Check whether setting it locally also sends
   it, or whether a separate send call is needed, and what permission
   (lead/assist) that send requires.
3. **NSRT and other MRT-family addons.** `Modules/MRTNotes.lua` already
   treats them as one family on the read side. Check each on the write side.
4. **Combat.** Confirm whether setting/sending a note is allowed during
   combat lockdown. If not, reuse `WGS:SortWhenSafe`'s defer-until-
   `PLAYER_REGEN_ENABLED` pattern.

## Shape if it checks out

- **Server:** add each lineup boss's rendered note to the `raidPlans`
  export (`bosses[].mrtNote`), built by the same `buildMrtNote` the web's
  copy button uses, so the two can't drift.
- **Addon:** on `WGS_COMP_BOSS_CHANGED`, if the new boss has a note and the
  player is raid lead or assist, offer it — a one-click "Load Boss B's note
  into MRT" prompt, not a silent overwrite. The raid leader may have edited
  the note by hand in-game; replacing that without asking would lose work.
- **Opt-in setting**, default off, until it has been run on a real raid night.

## Out of scope

Anything that has the game client fetch or scrape spell data. The note text
is built server-side from the plan; the addon only carries it.
