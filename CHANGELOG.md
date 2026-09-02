# Changelog
## Unreleased
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
