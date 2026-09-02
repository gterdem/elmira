# Changelog
## Unreleased
- Options at `/elm config` or the minimap button: how many icons, scale, lock, glow style, and
  whether to glow your action bars too.
- Screen-edge cues for the moments you are not looking at the UI. **Off unless you turn one on**,
  one at a time — the build suggests a short list and you pick from it. A cue that cannot fire yet
  is shown greyed out with the reason rather than quietly missing.
- Elmira now glows the button on your ElvUI bars, not just its own icon.
- The addon has its own icon and colour, so its messages no longer look like every other addon's.
- **Elmira now shows you something.** A queue of your next casts appears on screen, largest first,
  with cooldown sweeps and your keybinds. Drag it with `/elm lock`; hover an icon to see why it is
  being suggested. Set how many icons to show, and the scale, in the options.
- `/elm debug perf` reports how much work the display skipped, so a framerate problem is visible
  rather than guessed at.
- Recordings now note what each spell costs, so a suggestion you could not afford can be told apart
  from one that was simply cheap, and mark timestamps are rounded like every other recorded number.
- The Exodin build now lists Seal of Martyrdom as a requirement. It is bought from a book at level 10
  rather than being a rune, so it is easy to reach 60 without it — and without a seal most of the
  rotation has nothing to suggest.
- Exodin now suggests Judgement when nothing better is ready, instead of leaving you with nothing to
  press. This matters most on a fresh level 60 with no runes, who previously had no suggestion for
  most of their globals; at full gear the rest of the rotation still outranks it, so little changes.
- Exodin moves Consecration up when there are 3 or more enemies. Single-target behaviour is
  unchanged. (This has no effect yet — counting nearby enemies arrives in a later milestone.)
- Exodin now judges only in the last 1.5 seconds of your seal rather than the last 3, so the seal is
  kept up longer.
- The recording now names Seal of Martyrdom's damage effect instead of logging an unrecognised spell
  id, and marks it as something the game casts for you rather than something you pressed.
- Recording now captures **what you actually cast**, next to what Elmira was suggesting a moment
  earlier. Until the display lands there is no way to see a suggestion mid-fight and no way to type a
  command during one, so this is the only way to check whether the rotation advice is any good.
- Recorded marks now carry real timestamps. Every mark in every recording so far was stamped zero, so
  a recording could not be read in time order at all.
- Each entry in a recorded mark now says **which condition rejected it** (`buff:VENGEANCE_BUFF`,
  `any(target_type:Undead,rune:RUNE_PURIFYING_POWER)`), and marks now also record your buffs, active
  seal, mana, target, global cooldown and each spell's learned cooldown. Previously a rejected
  suggestion gave no reason and had to be guessed at backwards.
- Recordings hold 120 marks rather than 40. A four-fight session overran the old limit and discarded
  76 snapshots, keeping only the end of the run.
- Recorded numbers are rounded to two decimals, which is all the precision the client has.
- While recording, the addon now samples every 3 seconds during combat. Combat start happens before
  anything is on cooldown and combat end after most have expired, so neither captured the state the
  rotation actually runs in.
- Combat detection now uses the player's actual combat state rather than UI lockdown, which is a
  different thing and lags the start of a fight — previously every recorded mark claimed you were out
  of combat. Recorded marks also no longer collapse a combat transition into the previous mark.
- `/elm rec start` now refuses to begin while you are in combat, and prints the run steps in chat so
  you do not need a document open on another screen. Repeated identical snapshots are no longer
  recorded, so pulling a dummy several times cannot bury the gear states you are comparing.
- Weapon speed now actually reads the item's speed: it lives in the tooltip's right-hand column, which
  the previous attempt did not read, so it had been silently falling back to the haste-modified value.
- Recorded marks no longer lose `false` values — combat state and per-entry "usable" verdicts were
  being saved as "not evaluated" instead of "no".
- `/elm rec start` … `/elm rec stop` records a whole test session — combat start/end and gear swaps
  mark themselves — and one `/reload` writes it all out. Previously each snapshot cost its own reload
  or had to be copied out of the chat frame mid-fight.
- Fixed the suggestion queue advancing no time: every slot was computed for the same instant, so the
  queue after the first suggestion was meaningless. Fixed the queue repeating "cast your seal" five
  times out of combat. Both were only visible on a live character.
- `/elm debug dump` now saves the full queue and each entry's pass/fail verdict to SavedVariables, so
  results no longer have to be copied out of the chat frame mid-fight.
- `/elm debug queue [build] [depth]` prints the live suggestion queue and, beneath it, why each entry
  passed or failed its conditions. Until the display lands this is the only way to see what the
  engine actually decides on a real character.
- Weapon speed is now the base item speed read from the tooltip, not the haste-modified attack speed.
  A weapon with an attack-speed proc previously reported a different speed mid-fight, which could
  flip a build's speed requirement while you were playing.
- M2 gear matrix: every shipped build is now exercised across 11 gear states (no runes, runes only,
  each tier threshold, soul-granted bonuses, best-in-slot), asserting the actual suggestion queue. A
  build that ships without scenarios fails the suite.
- M2 adapter: `Adapters/Vanilla.lua` implements the State contract against the live client — observed
  cooldowns with GCD readings filtered out, rune matching on ability IDs, tooltip-based soul and set
  detection, and `bonus()` resolving a set threshold or a soul interchangeably. `runes` and
  `engraving` are now independent capabilities.
- Verified in game: all seven engraved rune slots now resolve correctly, tooltip scanning works on
  1.15.x (souls and set counts are readable), and the live-vs-shipped cost disagreement is reported.
  Ruled out using soul "hidden auras" for detection — they are not visible to `UnitAura`, so soul
  detection stays tooltip-based and enUS-only in v1.
- Paladin T2.5 4-set reclassified from passive to an aura: it applies **Excommunication** (1217927,
  +36% Exorcism damage, 20s, 3 stacks), so builds can gate on the buff instead of counting set pieces
  (ADR-0004). Its rotation guidance is unchanged — this is not a reason to hold Exorcism.
- Corrected the T2 4-set attribution: 467526 is the Soul of the Judicator effect (Judgement cooldown
  -5s, damage -45%), not Soul of the Retributor.
- `/elm debug dump` now scans for provisional aura IDs and reports whether the client returns them,
  which is the only way to tell whether a "permanent hidden aura" is visible to `UnitAura` at all.
- Data sourcing: IDs for server-side-scripted SoD bonuses may now come from the WoWSims simulator
  source, which is the only place they exist — Wowhead shows those bonuses as a dummy aura and never
  names the buff the player receives. Any such ID ships tagged `verify = "in-game"`, the one
  sanctioned way an ID passes CI without a fetched Wowhead `src`, and `/elm debug dump` lists every
  provisional entry so it cannot sit unresolved. Enforced by `tests/spec/data_sourcing_spec.lua`.
- Paladin T2 Ret set corrected to **Radiant Judgement** (item-set 1810, aliases "Judgement Armor" and
  "Draconic"); its 6-set now names the buff builds actually watch, *Swift Judgement* (467530). The
  T3.5 6-set likewise names *Templar* (1226464), which was previously "id TBD".
- M2 collector: `Adapters/Collector.lua` and `/elm debug dump` write a machine-readable character
  snapshot to SavedVariables. It prints the raw client value beside our interpretation of it — the
  one-sided view is what let a rune-ID bug survive two probe rounds — and reports how many rune slots
  disagree with the shipped data. On demand only; a single snapshot is kept, not a history.
- M2 data: paladin `Spells`/`Sets`/`Souls` IDs verified (102 `UNVERIFIED()` markers down to the M5
  out-of-scope keys). Every `RUNE_*` entry now holds the *ability* ID rather than the teach-spell ID,
  which is what rune detection actually matches; the previous values silently reported "not engraved"
  for runes the player was wearing. `Schema.validate` now rejects a non-numeric spell cost at load.
- Project scaffold (kit v1, 2026-09-01).
- M0 skeleton: addon-family layout (Elmira core + Elmira_Paladin/ElvUI/ItemRack/WoWSims/Insights
  stubs), `Elmira.API` v1 registry, AceDB defaults with `dbVersion` + migrations, `/elm` slash
  (help, debug state|bars|perf, modules, version), busted + luacheck harness with the Core/Adapters
  boundary enforced by `.luacheckrc`. Interface bumped to 11509 across all TOCs. Author: Valermus.
- M1 core: `Core/Schema.lua` (build validation + condition compilation, all 28 condition types from
  docs/02 including `all`/`any`/`not` and the `custom` escape hatch), `Core/Engine.lua`
  (`Engine.pick`), `Core/Simulation.lua` (`Simulation.queue` with a pluggable time step). Added
  `level`, `rune` and `sealLinger` to the State contract so every documented condition has something
  to read. Headless: no in-game behaviour changes yet.
- Overlay reworked before any of it was built (ADR-0009): screen-edge flares are opt-in peripheral
  cues, off by default, firing when the now-slot *changes to* an opted-in spell — not a third mirror
  of "what do I press" alongside the queue and bar glow. `db.profile.overlay` reshaped to
  `{ cues = {} }` accordingly; no migration needed, since the old keys equalled their defaults and
  AceDB never wrote them.
- Fixed: `Elmira_ElvUI` and `Elmira_ItemRack` registered nothing on login. `## LoadWith:` loaded
  them alongside ElvUI/ItemRack, ahead of their own `## Dependencies: Elmira`, so their file
  scope saw a nil `Elmira` global and their guard returned. Both TOCs now rely on hard
  `Dependencies` for ordering, and the guard prints instead of returning silently.
