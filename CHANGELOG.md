# Changelog
## Unreleased
- **Every screen-edge cue now has its own colour, edge and intensity.** Previously a cue flared in
  whatever the playstyle suggested and only on the edge it named, which is no use if you want two
  cues on different sides of the screen or you cannot pick that particular red out of your peripheral
  vision. Each change flares once as you make it, because a colour swatch tells you nothing about
  whether you will actually catch it mid-fight. The controls stay greyed out until the cue is on.
- Fixed: a screen-edge cue you turned on during a fight never fired. Elmira remembers which
  suggestion it last flared for, so it does not flash ten times a second while the same spell stays
  on top — but it kept that memory when you enabled a cue, so a cue switched on while its spell was
  already the top suggestion counted as "already shown" and stayed silent. Since that is exactly when
  you turn a cue on, it looked like the feature did nothing. Enabling or disabling a cue now clears
  that memory and repaints, and so does switching build or profile, which had the same flaw.
- `/elm debug cues` says why a screen edge is dark: which cues this build offers, which are on, which
  cannot fire yet and why, whether the cue's spell is the current suggestion, and how long ago each
  one last flared. `/elm debug cues <n>` test-fires one so a silent cue can be told apart from a
  broken display.
- Fixed: the setup window claimed you did not know Seal of Martyrdom even when you did — it was
  checking a list of your spells that was never filled in, so every ability requirement read as
  missing. It now reads your spellbook, and when it genuinely cannot, it says so instead of telling
  you something is wrong.
- **A setup window.** `/elm setup` (or the button in the options) shows what Elmira thinks your
  character is and lists the playstyles that have shipped for your class, recommended first, each
  with what it expects of your gear. A playstyle you do not currently meet is marked, not hidden —
  you can still pick it. Offered once on a new character, and once more if the shipped list changes.
- `/elm profile` lists the builds, says which one is active and why, and pins one.
  `/elm profile auto` hands the choice back to Elmira.
- `/elm advise` tells you what to **change**: which shoulder soul your build wants, which runes it
  expects, and whether the weapon you are holding suits it. Conditional on the gear you actually
  have, and advice only — nothing here changes what the rotation suggests.
- **Elmira now tells you when it cannot find a spell on your bars**, once per spell, instead of
  quietly showing only the queue icon. That failure was invisible before, which is how the rank
  problem lasted a whole build.
- When Elmira cannot read something, it now says so instead of guessing. An unreadable shoulder
  enchant or weapon speed shows as "could not tell", never as "wrong" — so you are never sent to fix
  something that is already fine.
- **Switching your ItemRack set can switch your build.** Map a set name to a playstyle and Elmira
  follows your gear. ItemRack's own internal sets are ignored, so restoring gear after a fight does
  not change anything.
- Elmira now picks a starting build by what your character can actually play, rather than always
  taking the first one in the list — and still falls back gracefully when it cannot tell.
- Elmira can now read your **swing timer** (via LibClassicSwingTimerAPI), which is what seal-twisting
  builds need. Nothing shipped uses it yet — the twist and stacking builds arrive later — but
  `/elm debug swing` shows what it can see, and says why when it cannot see anything: no library, no
  swing observed yet, or a stale reading because you are standing still.
- Suggestions projected a few casts ahead now age the swing timer with them, instead of asking "how
  long until my next swing" and getting the answer for right now.
- The seal-twist window ships as a **sourced** number rather than a remembered one. Blizzard's hotfix
  note says the replaced seal lasts "a short time" and gives no figure, so the 0.4s Elmira uses is
  taken from the wowsims simulator and labelled as such. If it is ever removed, twisting goes inert
  rather than falling back to a guess.
- Fixed: the bar glow missed any spell whose **rank** on your bar differs from the one Elmira ships.
  Classic gives every rank its own spell id, so a bar holding Exorcism (Rank 5) never matched — for
  that spell the glow simply never appeared, with no error anywhere. Buttons are now matched by name
  as well as by id, which has no ranks.
- Fixed: the ElvUI provider's fallback lookup passed the word "action" where a slot number belonged,
  so it found nothing whenever the fast path did not already work.
- **The queue now hides when you are not fighting.** New setting under Display: *Always*, *In
  combat*, or *In combat, or when you have a target* (the default). Until now it was on screen from
  login to logout, glowing your action bar while you stood in a city — there was no setting because
  there was no rule. Hidden also stops the update loop, so a hidden queue costs nothing.
- Fixed: with ElvUI, the bar glow could land on a hidden Blizzard action button. ElvUI hides those
  bars rather than removing them, so Elmira found the spell, glowed the button, and nothing appeared
  on screen. Only buttons that are actually visible are considered now.
- `/elm debug bars` now walks the whole chain — which providers registered, whether ElvUI's button
  library is present and how many buttons it holds, and for each spell in the queue whether a visible
  button was found and which source answered. It used to report only the number of providers, which
  is the one fact that was never the problem.
- The suggestion strip can now actually be moved. `/elm lock` showed the drag panel, but the icons
  sitting on top of the frame swallowed every drag, so the strip could not be moved at all.
- Choosing the **Autocast** glow style no longer breaks the display. It passed Elmira's name into a
  position the glow library expected a number in, and the whole strip stopped updating.
- Hovering an icon now explains the suggestion. The rule's name, the build it came from, and each
  condition in green or red — and for a rule with no conditions, it says so rather than showing you
  the plain spell tooltip and nothing else.
- The strip keeps its unlocked state across a `/reload`, instead of needing `/elm lock` twice to get
  the drag panel back.
- A display error is now reported once instead of on every queue change, so one bug can no longer
  bury a fight in chat.
- Learning mode: one suggestion at a time, larger, with the name of the rule that chose it underneath.
  It sets icons to 1 and scale to 140% and says so, and both stay yours to change afterwards.
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
