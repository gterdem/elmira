-- Elmira/Classes/Mage.lua — shipped Mage data for Season of Discovery (ADR-0011).
--
-- Elmira's second class pack, built the way Paladin.lua was: one registered THUNK, so a warrior's
-- login never allocates a mage's data (see Paladin.lua's own header for why that matters — WoW
-- parses and runs every TOC file on every character regardless of class).
--
-- Sources (cite in every comment below as these paths, never a bare claim):
--   docs/research/sod-mage-dossier.md               — builds, priority lists, runes by slot
--   docs/research/mage-ids-verified-2026-09-14.md   — id verification pass + the 2026-09-14 follow-up note
--                                                      addendum at the end, which settles the aura ids
--                                                      (Hot Streak 48108, Fingers of Frost 400647 =
--                                                      the rune's own id, Brain Freeze 400730, Fire
--                                                      Vulnerability 22959, Glaciate 1218345, the
--                                                      Enigma 2pc buff 1213317) and the Balefire Bolt
--                                                      self-aura mechanic (same id as the ability,
--                                                      428878, 5 stacks max, 30s, fatal at 5 stacks)
--   docs/research/mage-set-bonus-auras.md           — which set bonuses are auras vs pure passives
--   docs/research/wowsims-mage-p8/README.md         — decoded P8 BiS Single Target sim APLs (Fire
--                                                      13830 DPS, Frost Spellfrost 13440 DPS)
--
-- No still-unresolved placeholder ids from the research pass are pasted here (CI fails on that
-- marker; hard rule 2): Hot Streak/Fingers of Frost/Brain Freeze/Fire Vulnerability/Glaciate/the
-- Enigma 2pc buff were all resolved by the follow-up note's direct Wowhead fetches, so none of
-- the "provisional" entries the first two passes left open ship unresolved — the one that remains provisional
-- (ENIGMA_FIRE_CRIT_BUFF) has a real Wowhead src AND `verify = "in-game"`, because the addendum
-- found the aura sharing its name with the real Fire Blast ability and wants an in-game confirmation
-- before trusting the id belongs to the buff and not the spell.
--
-- No `sealLingerWindow` (Paladin-only mechanic; its absence is inert, not a gap — MG1-D1).
--
-- MG2 (2026-09-14) adds the third Mage playstyle, "Mage — Arcane healer". Sources:
--   docs/research/sod-mage-healer-dossier.md            — priority list, rune table incl. the wrist
--                                                          conflict (Rewind Time vs Balefire Bolt),
--                                                          sets, soul, "what Elmira can and cannot show"
--   docs/research/mage-healer-ids-verified-2026-09-14.md — paste-ready ids + the 2026-09-14 follow-up note
--                                                          addendum, which settles the four cooldowns
--                                                          MG2's reminder lines depend on (Mass
--                                                          Regeneration 12s, Rewind Time 30s, Arcane
--                                                          Power/Presence of Mind 3min; Chronostatic
--                                                          Preservation has none, so it ships with no
--                                                          reminder line at all — see MAGE_ARCANE_HEALER)
--   docs/research/mage-set-bonus-auras.md § "Arcane (healer) auras" — Fireleaf Vestments (item-set
--                                                          1944) bonuses, Arcane Tunneling
-- Unlike MG1, MG2 DOES carry `cooldown` fields (the four named above): the healer reminder lines are
-- the first Mage consumer of Simulation's cooldown fallback chain, and every one of the four numbers
-- above was read directly off a fetched Wowhead page, never guessed (hard rule 2).
local ADDON, ns = ...

ns.RegisterBuiltinPack("MAGE", function()
  local D = {}

  -- ---------------------------------------------------------------------------------------------
  -- Spells
  -- ---------------------------------------------------------------------------------------------
  -- Symbolic key -> spell record, exactly Paladin.lua's shape. Every id below is a direct Wowhead
  -- fetch (mage-ids-verified-2026-09-14.md + its follow-up note) unless the record says
  -- otherwise. No `cooldown` field ships anywhere in this file: no fetched Mage page in this pass
  -- quoted an exact cooldown in seconds (contrast Paladin's Avenging Wrath/Aura Mastery, which had
  -- "Cooldown: 3 minutes"/"2 minutes" printed on the page) — the client's real answer is the
  -- fallback docs/02 documents, and guessing a number here would be exactly what hard rule 2 forbids.
  --
  -- No EVOCATION, no COUNTERSPELL: both are on the verified-ids list, but the task's
  -- Not-in-scope section excludes Evocation/Counterspell/prepull lines outright. Shipping the record
  -- with zero rotation consumer would be dead data (and an unprotected mutants target), so both are
  -- left out entirely rather than added unused.
  D.Spells = {
    -- ------------------------------------------------------------------------------- castables
    FIREBALL         = { id = 25306,  src = "https://www.wowhead.com/classic/spell=25306" },  -- Tome of Fireball XII, max rank
    FROSTBOLT        = { id = 10181,  src = "https://www.wowhead.com/classic/spell=10181" },   -- rank 10, level 56
    FIRE_BLAST       = { id = 10199,  src = "https://www.wowhead.com/classic/spell=10199", cdVolatile = true }, -- rank 7; Overheat + Fireleaf 6p both change its cooldown
    SCORCH           = { id = 10207,  src = "https://www.wowhead.com/classic/spell=10207" },   -- rank 7, level 58
    PYROBLAST        = { id = 18809,  src = "https://www.wowhead.com/classic/spell=18809" },   -- rank 8, talent
    BLAST_WAVE       = { id = 13021,  src = "https://www.wowhead.com/classic/spell=13021" },   -- rank 5
    CONE_OF_COLD     = { id = 10161,  src = "https://www.wowhead.com/classic/spell=10161" },   -- rank 5, level 54
    -- AT9-D3: puts a shield buff on the caster — see Paladin.lua's header comment on `buff` for what
    -- the flag opens (buff-only moments/warning seconds before the ability has ever been cast).
    ICE_BARRIER      = { id = 13033,  src = "https://www.wowhead.com/classic/spell=13033", buff = true }, -- rank 4, level 58
    COLD_SNAP        = { id = 12472,  src = "https://www.wowhead.com/classic/spell=12472" },
    COMBUSTION       = { id = 11129,  src = "https://www.wowhead.com/classic/spell=11129", buff = true },
    -- AT7: the id verification pass fetched only rank 1 for these three (Frost Nova, Blizzard, Mana Shield),
    -- unlike Fireball/Frostbolt/etc. above whose dossier ranks already read as the max/near-max rung
    -- of the classic ladder. An ability is a NAME (Core/Palette, docs/01) — the shipped id resolves
    -- the SPELL, and the client's own spellbook answers with whatever rank the character actually
    -- owns at cast time, never this file's id. Shipped anyway (not gated on any build line) because
    -- Frost Nova is real kiting utility and Mana Shield real defensive utility a player presses by
    -- hand, the same way Paladin ships REBUKE with no priority-list entry at all.
    FROST_NOVA       = { id = 122,    src = "https://www.wowhead.com/classic/spell=122" },     -- rank 1; spellbook resolves the rank (AT7)
    ARCANE_EXPLOSION = { id = 1449,   src = "https://www.wowhead.com/classic/spell=1449" },     -- single rank in Classic
    BLIZZARD         = { id = 10,     src = "https://www.wowhead.com/classic/spell=10" },       -- rank 1; spellbook resolves the rank (AT7)
    FLAMESTRIKE      = { id = 10216,  src = "https://www.wowhead.com/classic/spell=10216" },    -- max rank, level 56
    MANA_SHIELD      = { id = 1463,   src = "https://www.wowhead.com/classic/spell=1463" },     -- rank 1/base; spellbook resolves the rank (AT7)
    EVOCATION        = { id = 12051,  src = "https://www.wowhead.com/classic/spell=12051" },     -- verified in the DPS dossier pass, unshipped until now (no consumer); MG2's Evocation-on-low-mana line is the first

    -- ---------------------------------------------------------- healer castables (MG2-D1)
    -- ARCANE_BLAST/ARCANE_BARRAGE/MASS_REGENERATION/CHRONOSTATIC_PRESERVATION/REWIND_TIME are all
    -- SoD healer rune abilities (mage-healer-ids-verified-2026-09-14.md); each carries a same-id
    -- RUNE_* twin below with `rune = "<slot>"`, except ARCANE_BARRAGE (see RUNE_ARCANE_BARRAGE's own
    -- comment). PRESENCE_OF_MIND/ARCANE_POWER are talents (no rune), same shape as Paladin's own
    -- burst-cooldown talents.
    ARCANE_MISSILES  = { id = 5145,   src = "https://www.wowhead.com/classic/spell=5145" },      -- rank 1 base; spellbook resolves max rank (AT7)
    ARCANE_BLAST     = { id = 400574, src = "https://www.wowhead.com/classic/spell=400574" },    -- confirmed current over the healer talent page's stale 401729 (dossier drift table, Open Q2)
    -- The castable ability id. The rune ENGRAVE is a *different* id (401719, a passive override) —
    -- see RUNE_ARCANE_BARRAGE below and the verified file's "Arcane Barrage Clarification" section.
    ARCANE_BARRAGE   = { id = 400610, src = "https://www.wowhead.com/classic/spell=400610" },
    -- No RUNE_REGENERATION record ships: the verified file's own healer rune table carries no id for
    -- Regeneration at all (only Mass Regeneration does), matching the dossier's own open question
    -- ("base Regeneration may not be a rune at all"). Shipped as a plain castable, named in
    -- MAGE_ARCANE_HEALER's `notes` as the single-target beacon cast by hand (MG2-D3).
    REGENERATION     = { id = 401417, src = "https://www.wowhead.com/classic/spell=401417" },
    -- Cooldown src: Wowhead spell page, "12 sec cooldown" (follow-up note, 2026-09-14) — the
    -- MASS_REGENERATION reminder line depends on this number existing (MG2-D3).
    MASS_REGENERATION = { id = 412510, src = "https://www.wowhead.com/classic/spell=412510", cooldown = 12 },
    -- No stated cooldown on a direct re-fetch of the page (follow-up note) — MG2-D3 ships NO
    -- reminder line for this spell because a `hold = true` entry with no real cooldown would sit in
    -- slot 1 forever; it is castable on its own, just never surfaced as a reminder.
    CHRONOSTATIC_PRESERVATION = { id = 436516, src = "https://www.wowhead.com/classic/spell=436516" },
    -- Cooldown src: Wowhead spell page, "30 sec cooldown" (follow-up note).
    REWIND_TIME      = { id = 401462, src = "https://www.wowhead.com/classic/spell=401462", cooldown = 30 },
    -- Talent, not a rune. `buff = true` (AT9-D3): the ability puts a self-buff on the caster.
    -- Cooldown src: Wowhead spell page, "3 min cooldown" (follow-up note).
    PRESENCE_OF_MIND = { id = 12043,  src = "https://www.wowhead.com/classic/spell=12043", buff = true, cooldown = 180 },
    ARCANE_POWER     = { id = 12042,  src = "https://www.wowhead.com/classic/spell=12042", buff = true, cooldown = 180 },

    -- ------------------------------------------------------------------------- rune-taught abilities
    -- Both the castable record AND its RUNE_* twin below carry the SAME id, exactly the way
    -- Paladin's RUNE_CRUSADER_STRIKE/CRUSADER_STRIKE pair does: the build's `spell = "LIVING_BOMB"`
    -- entries reference the castable, `requires.runes`/`advice.runes` reference the RUNE_ twin so the
    -- wizard's shopping list and gear/rune detection can tell "engraved" from "castable".
    LIVING_BOMB      = { id = 400613, src = "https://www.wowhead.com/classic/spell=400613" },
    FROSTFIRE_BOLT   = { id = 401502, src = "https://www.wowhead.com/classic/spell=401502" },
    -- The self-debuff IS this same id (428878) per the follow-up note, quoting wowsims/sod
    -- sim/mage/balefire_bolt.go (5 stacks max, 30s) and the Wowhead tooltip itself ("decreases Spirit
    -- by 20% ... Reaching 0 Spirit is fatal"). `selfAura = "either"` (MG1-D5c) is what lets
    -- `S:buff("BALEFIRE_BOLT")` find it even if the client files a self-applied, Spirit-draining aura
    -- under the HARMFUL list rather than HELPFUL — the checklist's `/dump` settles which, in game.
    BALEFIRE_BOLT    = { id = 428878, src = "https://www.wowhead.com/classic/spell=428878", buff = true, selfAura = "either" },
    ICY_VEINS        = { id = 425121, src = "https://www.wowhead.com/classic/spell=425121", buff = true },
    DEEP_FREEZE      = { id = 428739, src = "https://www.wowhead.com/classic/spell=428739", cdVolatile = true }, -- Fireleaf 6p reduces its CD per Glaciate stack consumed
    FROZEN_ORB       = { id = 440802, src = "https://www.wowhead.com/classic/spell=440802", cdVolatile = true }, -- Fireleaf 6p: -25s CD
    ICE_LANCE        = { id = 400640, src = "https://www.wowhead.com/classic/spell=400640" },
    SPELLFROST_BOLT  = { id = 412532, src = "https://www.wowhead.com/classic/spell=412532" },
    LIVING_FLAME     = { id = 401556, src = "https://www.wowhead.com/classic/spell=401556" },
    MOLTEN_ARMOR     = { id = 428741, src = "https://www.wowhead.com/classic/spell=428741", buff = true },

    -- ------------------------------------------------------------------------- passive runes only
    -- No castable twin: these are pure passive engraves, detected only via `rune`/`no_rune` or their
    -- OWN observable effect (Hot Streak's effect is the HOT_STREAK_BUFF proc below, not a button).
    RUNE_HOT_STREAK            = { id = 400624, src = "https://www.wowhead.com/classic/spell=400624", rune = "head" },
    -- Confirmed via a direct spell fetch (dossier): rewrites Fire Blast to always crit, castable
    -- while casting, off the GCD. That rewrite is WHY the Fire build can `hold = true` its
    -- Fire-Blast-on-Overheat line — the ability itself no longer costs a global.
    RUNE_OVERHEAT              = { id = 400615, src = "https://www.wowhead.com/classic/spell=400615", rune = "back" },
    RUNE_ENLIGHTENMENT         = { id = 412324, src = "https://www.wowhead.com/classic/spell=412324", rune = "chest" },
    -- Frost's chest rune is genuinely disputed between this and Enlightenment (dossier open Q1,
    -- Wowhead's own table vs the P8 BiS sim) — shipped, but deliberately absent from
    -- MAGE_FROST_SPELLFROST's `requires.runes` (MG1-D4); its lines simply never fire unarmed.
    RUNE_FINGERS_OF_FROST      = { id = 400647, src = "https://www.wowhead.com/classic/spell=400647", rune = "chest" },
    -- AoE-only alternative (Icy Veins' separate Frost AoE rune table); no shipped build takes it yet,
    -- but MAGE_FROST_LEVELING's dossier text names it for the feet slot (MG1-D4).
    RUNE_BRAIN_FREEZE          = { id = 400731, src = "https://www.wowhead.com/classic/spell=400731", rune = "feet" },
    RUNE_SPELL_POWER           = { id = 412322, src = "https://www.wowhead.com/classic/spell=412322", rune = "feet" },
    RUNE_FIRE_SPECIALIZATION   = { id = 442894, src = "https://www.wowhead.com/classic/spell=442894", rune = "ring1" },
    RUNE_FROST_SPECIALIZATION  = { id = 442895, src = "https://www.wowhead.com/classic/spell=442895", rune = "ring2" },

    -- ------------------------------------------------------------------------- rune ABILITY twins
    -- Same id as the castable record above, `rune = "<slot>"` added — see the header comment on
    -- this section and Paladin.lua's own RUNE_CRUSADER_STRIKE comment for why the ability id (never
    -- the teach id) belongs here.
    RUNE_LIVING_BOMB       = { id = 400613, src = "https://www.wowhead.com/classic/spell=400613", rune = "hands" },
    RUNE_FROSTFIRE_BOLT    = { id = 401502, src = "https://www.wowhead.com/classic/spell=401502", rune = "waist" },
    RUNE_BALEFIRE_BOLT     = { id = 428878, src = "https://www.wowhead.com/classic/spell=428878", rune = "wrist" },
    RUNE_ICY_VEINS         = { id = 425121, src = "https://www.wowhead.com/classic/spell=425121", rune = "legs" },
    RUNE_DEEP_FREEZE       = { id = 428739, src = "https://www.wowhead.com/classic/spell=428739", rune = "head" },
    RUNE_FROZEN_ORB        = { id = 440802, src = "https://www.wowhead.com/classic/spell=440802", rune = "back" },
    RUNE_ICE_LANCE         = { id = 400640, src = "https://www.wowhead.com/classic/spell=400640", rune = "hands" },
    RUNE_SPELLFROST_BOLT   = { id = 412532, src = "https://www.wowhead.com/classic/spell=412532", rune = "waist" },
    RUNE_LIVING_FLAME      = { id = 401556, src = "https://www.wowhead.com/classic/spell=401556", rune = "legs" },
    RUNE_MOLTEN_ARMOR      = { id = 428741, src = "https://www.wowhead.com/classic/spell=428741", rune = "wrist" },

    -- ------------------------------------------------------------------------- healer rune ABILITY twins (MG2-D1)
    -- Same-id twins, exactly the convention above, for the four healer castables that are also SoD
    -- rune abilities. Every id below is confirmed current per the verified file's drift-resolution
    -- table (mage-healer-ids-verified-2026-09-14.md): the healer talent page (dated 2023-11-23,
    -- self-labelled "Phase 7") disagreed on nine of thirteen shared runes, always with an OLDER,
    -- stale number — the comment on each disputed one below names the number it is NOT.
    RUNE_ARCANE_BLAST      = { id = 400574, src = "https://www.wowhead.com/classic/spell=400574", rune = "hands" }, -- not the healer page's stale 401729
    RUNE_MISSILE_BARRAGE   = { id = 400588, src = "https://www.wowhead.com/classic/spell=400588", rune = "waist" }, -- not the healer page's stale 401736; healer-exclusive rune, no castable twin ships (its own ability is never pressed directly — see ARCANE_MISSILES/MISSILE_BARRAGE_BUFF)
    RUNE_MASS_REGENERATION = { id = 412510, src = "https://www.wowhead.com/classic/spell=412510", rune = "legs" }, -- not the healer page's stale 415467
    RUNE_CHRONOSTATIC_PRESERVATION = { id = 436516, src = "https://www.wowhead.com/classic/spell=436516", rune = "feet" }, -- not the healer page's stale 425187
    RUNE_REWIND_TIME       = { id = 401462, src = "https://www.wowhead.com/classic/spell=401462", rune = "wrist" }, -- not the healer page's stale 401734; same-slot alternative to RUNE_BALEFIRE_BOLT above (dossier's "wrist conflict" — only one can be engraved)
    -- The engrave's OWN id (401719, "Overrides Actionbar Spell Arcane Barrage" per its Wowhead page)
    -- is NOT the castable ability's id (400610, ARCANE_BARRAGE above) — a genuine two-id case, unlike
    -- every other twin in this file. See the verified file's "Arcane Barrage Clarification" section.
    RUNE_ARCANE_BARRAGE    = { id = 401719, src = "https://www.wowhead.com/classic/spell=401719", rune = "back" },
    -- Purely passive; healer-exclusive, no castable twin.
    RUNE_ADVANCED_WARDING  = { id = 412115, src = "https://www.wowhead.com/classic/spell=412115", rune = "head" }, -- not the healer page's stale 401726
    -- RUNE_FIRE_SPECIALIZATION (ring1) already shipped above (MG1); this is its ring2 pair, unshipped
    -- until MG2 gives it a consumer (D.Advice.MAGE.MAGE_ARCANE_HEALER's `ringRunes`).
    RUNE_ARCANE_SPECIALIZATION = { id = 442893, src = "https://www.wowhead.com/classic/spell=442893", rune = "ring2" },

    -- ------------------------------------------------------------------------- procs / debuffs
    -- `proc = true` (docs/02 Simulation semantics): false for every simulated slot past t=0, since a
    -- proc is unpredictable and Schema must not pretend the virtual future knows it will be up.
    HOT_STREAK_BUFF       = { id = 48108,  src = "https://www.wowhead.com/classic/spell=48108", proc = true },
    -- Same id as its own rune (wowsims/sod runes.go:191, cited by the follow-up note) — the
    -- proc IS the rune's own aura, not a separate spell.
    FINGERS_OF_FROST_BUFF = { id = 400647, src = "https://www.wowhead.com/classic/spell=400647", proc = true },
    -- Wowhead names the buff "Fireball!", not "Brain Freeze" — the addendum fetched the page
    -- directly under that title; kept here under the descriptive key the dossier and the build use.
    BRAIN_FREEZE_BUFF     = { id = 400730, src = "https://www.wowhead.com/classic/spell=400730", proc = true },
    -- Target debuff (Improved Scorch). No separate LIVING_BOMB_DEBUFF key: Living Bomb's DoT shares
    -- the ability's own id (400613 above), the same way the debuff a judgement seal applies would if
    -- Wowhead had ever split it — one real Wowhead-verified id, one key, used as both `spell` and as
    -- the `debuff`/`no_debuff` key in MAGE_FIRE's Living Bomb line.
    FIRE_VULNERABILITY    = { id = 22959,   src = "https://www.wowhead.com/classic/spell=22959", aura = true },
    -- Ice Lance's stacking chill debuff on the target. Not gated by any shipped build entry yet
    -- (mage_pack_spec.lua pins it directly) — Fireleaf 2p raises its cap to 10 stacks, worth having
    -- named before a build wants to read it.
    GLACIATE              = { id = 1218345, src = "https://www.wowhead.com/classic/spell=1218345", aura = true },
    -- The Enigma Insight 2pc's REAL applied buff (mage-set-bonus-auras.md: WoWSims
    -- item_sets_pve_phase_6.go registers ActionID{SpellID: 1213317}, Label "Fire Blast", +50% Fire
    -- crit, 10s). The follow-up note fetched 1213317 directly and confirms the page exists —
    -- but its title reads "Fire Blast", identical to the real ability above, so `verify = "in-game"`
    -- stays on it as the addendum instructs: a name collision this exact is worth an in-game
    -- `/dump AuraUtil.FindAuraByName("Fire Blast","player")` before trusting which one fired.
    ENIGMA_FIRE_CRIT_BUFF = { id = 1213317, src = "https://www.wowhead.com/classic/spell=1213317", verify = "in-game",
                              proc = true, note = "Enigma Insight 2pc: Fire Blast -> next Fire spell +50% crit, 10s" },

    -- ------------------------------------------------------------------------- healer auras (MG2-D1)
    -- Neither is a Wowhead spell page (hard rule 2's sanctioned WoWSims fallback): `verify = "in-game"`
    -- on both, per mage-healer-ids-verified-2026-09-14.md — extend data_sourcing_spec's MAGE
    -- provisional list to match (MG2-D5).
    --
    -- Self-stacking buff from casting Arcane Blast (6s, 4 max stacks per wowsims). Not a proc — a
    -- guaranteed, deterministic cast result — so `aura = true` (not `proc = true`) is what keeps it
    -- out of the Palette (Palette.castable checks both flags) without suppressing it in Simulation's
    -- virtual future the way a real proc must be.
    ARCANE_BLAST_BUFF     = { id = 400573, src = "wowsims sod sim/mage/arcane_blast.go (2026-09-14)", verify = "in-game",
                              aura = true, note = "Arcane Blast's own self-stack; 6s duration, 4 max stacks" },
    -- Genuine proc (a % chance on cast), 15s: instant, free Arcane Missiles window.
    MISSILE_BARRAGE_BUFF  = { id = 400589, src = "wowsims sod sim/mage/runes.go (2026-09-14)", verify = "in-game",
                              proc = true, note = "Missile Barrage proc: next Arcane Missiles instant and free" },
    -- Fireleaf Vestments 2pc proc (10% chance on Arcane Blast hit); prevents the next Arcane spell
    -- from consuming the Arcane Blast stack. Not gated by any shipped MAGE_ARCANE_HEALER entry (Not
    -- in scope: "Fireleaf Vestments 2pc/4pc/6pc lines") — named here so the set bonus below (D2) has
    -- a real key to point `aura` at, per ADR-0004.
    ARCANE_TUNNELING      = { id = 1226406, src = "wowsims sod sim/mage/item_sets_pve_phase_8.go (2026-09-14)", verify = "in-game",
                              proc = true, note = "Fireleaf Vestments 2pc: 10% chance on Arcane Blast hit; prevents the next Arcane spell consuming the stack" },
  }

  -- ---------------------------------------------------------------------------------------------
  -- Sets
  -- ---------------------------------------------------------------------------------------------
  -- Item ids and bonus spell ids from mage-ids-verified-2026-09-14.md section 4 (item-set pages
  -- captured directly, per mage-set-bonus-auras.md's confirmation pass). Fireleaf Regalia is shared
  -- by both Fire and Frost; Enigma Insight is Fire's own secondary set (Wowhead's P8 BiS gear page
  -- names it Fire-only).
  D.Sets = {
    MAGE_FIRELEAF_REGALIA = {
      name = "Fireleaf Regalia", src = "https://www.wowhead.com/classic/item-set=1943/fireleaf-regalia",
      items = { 240056, 240054, 240053, 240055, 240058, 240052, 240057, 240059 },
      bonuses = {
        -- All three thresholds are internal spell-mod scripts (mage-set-bonus-auras.md: "registers a
        -- permanent internal aura to apply spell modifiers... no separate aura displayed to the
        -- player"), so ADR-0004 does not apply — there is no player-visible aura to prefer over
        -- counting pieces. `kind = "passive"` throughout, matching Paladin's own T3 Redemption 6p.
        [2] = { spell = 1226423, src = "https://www.wowhead.com/classic/item-set=1943/fireleaf-regalia", spec = "MAGE", kind = "passive",
                note = "Living Bomb ticks every 1s and detonates on target death; Ice Lance's Glaciate stacks to 10; Spellfrost Bolt grants 2 Glaciate stacks per hit" },
        [4] = { spell = 1226446, src = "https://www.wowhead.com/classic/item-set=1943/fireleaf-regalia", spec = "MAGE", kind = "passive",
                note = "Deep Freeze extends Icy Veins by 10s; Pyroblast cancels 2 stacks of the caster's own Balefire Bolt debuff" },
        [6] = { spell = 1226432, src = "https://www.wowhead.com/classic/item-set=1943/fireleaf-regalia", spec = "MAGE", kind = "passive",
                note = "Frozen Orb CD -25s; Deep Freeze CD -1s per Glaciate stack consumed; Fire Blast CD -5s and refreshes Living Bomb's duration on the target" },
      },
    },
    MAGE_ENIGMA_INSIGHT = {
      name = "Enigma Insight", src = "https://www.wowhead.com/classic/item-set=1841/enigma-insight",
      items = { 233404, 233403, 233406, 233405, 233402 },
      bonuses = {
        -- Stacking, timed buff on the player => an aura per ADR-0004 (hard rule 5), not a passive.
        -- 1213318 is the bonus's own server-side dummy script; ENIGMA_FIRE_CRIT_BUFF (Spells above,
        -- 1213317) is the buff a `buff` condition actually watches.
        [2] = { spell = 1213318, src = "https://www.wowhead.com/classic/item-set=1841/enigma-insight", spec = "MAGE", kind = "aura", aura = "ENIGMA_FIRE_CRIT_BUFF",
                note = "Fire Blast also grants the next Fire spell +50% crit for 10s" },
        [4] = { spell = 1213319, src = "https://www.wowhead.com/classic/item-set=1841/enigma-insight", spec = "MAGE", kind = "passive",
                note = "+10% Ignite damage — pure passive, does not change the rotation" },
      },
    },
    -- Healer-exclusive variant (MG2-D2), distinct from Fire/Frost's own Fireleaf Regalia (1943)
    -- above — same tier prefix, different armor group, different set id (mage-healer-ids-verified-
    -- 2026-09-14.md Q6, cross-confirmed by the dossier's own H7 finding). Item-set id and all eight
    -- piece ids per a direct Wowhead item-set page fetch.
    --
    -- 4pc/6pc spell ids (1226415/1226378) are the ones the item-set page itself links (follow-up
    -- direct fetch, 2026-09-14, spell slugs "...-healer-4p-bonus"/"...-healer-6p-bonus") — the
    -- healer-ids-verified file had it right. mage-set-bonus-auras.md's "Arcane (healer) auras" section
    -- (1226408/1226409) was a WoWSims internal aura-label mix-up, not a spell id off this page.
    MAGE_FIRELEAF_VESTMENTS = {
      name = "Fireleaf Vestments", src = "https://www.wowhead.com/classic/item-set=1944/fireleaf-vestments",
      items = { 240048, 240046, 240045, 240047, 240050, 240044, 240049, 240051 },
      bonuses = {
        -- Stacking, timed buff on the player => an aura per ADR-0004 (hard rule 5): 1226407 is the
        -- bonus's own server-side dummy script, ARCANE_TUNNELING (Spells above, 1226406) is the buff
        -- a `buff` condition actually watches.
        [2] = { spell = 1226407, src = "https://www.wowhead.com/classic/item-set=1944/fireleaf-vestments", spec = "MAGE", kind = "aura", aura = "ARCANE_TUNNELING",
                note = "Arcane Blast 10% chance -> Arcane Tunneling (prevents the next Arcane spell consuming the stack); Arcane Power resets Mass Regeneration's cooldown" },
        [4] = { spell = 1226415, src = "https://www.wowhead.com/classic/item-set=1944/fireleaf-vestments", spec = "MAGE", kind = "passive",
                note = "Rewind Time also reduces the target's damage taken by 20% for 8s — ally-facing, no live condition (dossier: 'what Elmira can and cannot show')" },
        [6] = { spell = 1226378, src = "https://www.wowhead.com/classic/item-set=1944/fireleaf-vestments", spec = "MAGE", kind = "passive",
                note = "Arcane Power's cooldown -90s and duration +10s; +10% Arcane Tunneling proc chance while Arcane Power is active; each Arcane Blast cast -1s off Mass Regeneration's cooldown" },
      },
    },
  }

  -- ---------------------------------------------------------------------------------------------
  -- Souls / Bonuses
  -- ---------------------------------------------------------------------------------------------
  -- Detected from the shoulder TOOLTIP (`short`), exactly like Paladin's souls — no enchant id is
  -- carried on the item link (docs/01 §5a). Neither soul replicates a set bonus (mage-set-bonus-
  -- auras.md: both are internal damage-modifier scripts, not player-visible auras), so `grants = {}`
  -- for both, matching the aura note's own conclusion.
  D.Souls = {
    -- The item page itself was found by search but not captured as a clean Wowhead fetch (WebFetch's
    -- nav-only limitation on Wowhead item pages, same one Paladin's dossier hit repeatedly) — the
    -- tooltip TEXT is a search-result quote, not a page verified directly, so `short`
    -- (what the detector actually matches) carries the same uncertainty Paladin tags with
    -- `verify = "in-game"`.
    SOUL_OF_THE_TORCHER = { itemID = 236529, grants = {},
                            src = "https://www.wowhead.com/classic/item=236529/soul-of-the-torcher", short = "Torcher",
                            verify = "in-game", roles = { "MAGE_FIRE" },
                            note = "+4% Fireball/Frostfire Bolt/Balefire Bolt damage per Fire effect on the target, max 12% (tooltip via search snippet)" },
    -- The tooltip snippet states +75% Frostbolt/Spellfrost Bolt damage, which the dossier flags as
    -- implausible next to every other sourced Mage/Paladin soul this project has verified — do not
    -- treat that percentage as ship-ready; nothing in this file stores it, only the `short` name a
    -- detection scan matches, and even that stays provisional until a real tooltip read confirms it.
    SOUL_OF_THE_CRYOMANCER = { itemID = 236520, grants = {},
                               src = "https://www.wowhead.com/classic/item=236520/soul-of-the-cryomancer", short = "Cryomancer",
                               verify = "in-game", roles = { "MAGE_FROST_SPELLFROST" },
                               note = "Frostbolt/Spellfrost Bolt damage bonus; tooltip snippet says +75%, flagged implausible, verify in game" },
    -- Healer soul (MG2-D2). Item and granted-spell ids from mage-healer-ids-verified-2026-09-14.md,
    -- itself tagged `verify = "in-game"` there (the item page was found via a search-result snippet,
    -- the same uncertainty Torcher/Cryomancer above carry). Affects an ALLY's Temporal Beacon
    -- duration, never the player's own state — dossier: "gear-advice only, never a condition" — so
    -- `grants = {}` (no bonus is soul-replicated) and this key is never read by any `when` clause,
    -- only by the wizard's advice text (D.Advice.MAGE.MAGE_ARCANE_HEALER.soul).
    SOUL_OF_THE_ETERNAL_CARETAKER = { itemID = 236516, grants = {},
                               src = "https://www.wowhead.com/classic/item=236516/soul-of-the-eternal-caretaker", short = "Eternal Caretaker",
                               verify = "in-game", roles = { "MAGE_ARCANE_HEALER" },
                               note = "Temporal Beacons placed by Mass Regeneration last 21s on the ally wearing them (base duration not found this pass)" },
  }
  -- Fireleaf's three thresholds are pure passive numeric interactions no soul replicates (no Mage
  -- soul grants any of them) — MG1-D3 asks for them as `D.Bonuses` entries anyway so the set's
  -- effect has a symbolic name a future build (or the wizard's gear text) can read without spelling
  -- out "Fireleaf Regalia 2 pieces" itself. No shipped build entry gates on any of the three yet
  -- (Wowhead: none of them describe a DECISION, only a numeric change) — pinned directly by
  -- tests/spec/mage_pack_spec.lua rather than invented into a `when` clause the dossier never asked
  -- for.
  D.Bonuses = {
    LIVING_BOMB_FAST_TICK    = { note = "Fireleaf Regalia 2pc: Living Bomb ticks every 1s and detonates on target death",
                                  from = { { set = "MAGE_FIRELEAF_REGALIA", pieces = 2 } } },
    PYROBLAST_CLEARS_BALEFIRE = { note = "Fireleaf Regalia 4pc: Pyroblast cancels 2 stacks of the caster's own Balefire Bolt debuff",
                                  from = { { set = "MAGE_FIRELEAF_REGALIA", pieces = 4 } } },
    FIRE_BLAST_REFRESHES_LB  = { note = "Fireleaf Regalia 6pc: Fire Blast CD -5s and refreshes Living Bomb's duration on the target",
                                  from = { { set = "MAGE_FIRELEAF_REGALIA", pieces = 6 } } },
  }

  -- ---------------------------------------------------------------------------------------------
  -- Catalog
  -- ---------------------------------------------------------------------------------------------
  -- Read by Setup/Wizard.lua (ADR-0011); enforced by tests/spec/data_sourcing_spec.lua. Sim sheet:
  -- https://docs.google.com/spreadsheets/d/e/2PACX-1vSWYkkIsvWV4N09okuB2vTi2yEAYJD-QbOUli9kQgK1xzcLbA6EaLHwxDVfvwwPHUpYdSgLQ6wrSEAL/pubhtml
  -- (docs/research/wowsims-mage-p8/README.md, decoded 2026-09-14; sheet itself dated March/April
  -- 2025, P8 launch) — the P8 BiS Single Target tab is the authority both sim figures below cite.
  D.Catalog = {
    version = 2, flavor = "SoD", phase = "P8",  -- bumped for MG2's fourth entry (MAGE_ARCANE_HEALER); the wizard re-offers once
    MAGE = {
      { build = "MAGE_FIRE", available = true, playstyle = "Fire — Hot Streak / Overheat proc chain", difficulty = "medium", recommended = true,
        updated = "2026-09-14", phase = "SoD P8",
        source = "https://www.icy-veins.com/wow-classic/fire-mage-dps-season-of-discovery-pve-rotation-cooldowns-abilities",
        summary = "Fire Blast (Overheat) weaves a guaranteed crit into Hot Streak Pyroblasts, Scorch keeps 5 stacks of Fire Vulnerability up, Living Bomb and Balefire Bolt fill the gaps. 13.8k in the P8 BiS single-target sim.",
        requires = { runes = { "RUNE_HOT_STREAK", "RUNE_OVERHEAT", "RUNE_ENLIGHTENMENT", "RUNE_BALEFIRE_BOLT",
                               "RUNE_LIVING_BOMB", "RUNE_FROSTFIRE_BOLT", "RUNE_ICY_VEINS", "RUNE_SPELL_POWER" } } },
      { build = "MAGE_FROST_SPELLFROST", available = true, playstyle = "Frost (Spellfrost) — Fingers of Frost shatter", difficulty = "medium",
        updated = "2026-09-14", phase = "SoD P8",
        source = "https://www.icy-veins.com/wow-classic/frost-mage-dps-season-of-discovery-pve-rotation-cooldowns-abilities",
        summary = "Deep Freeze and Ice Lance shatter off Fingers of Frost procs from Frozen Orb, Spellfrost Bolt and Living Bomb sustain the rest. 13.4k in the P8 BiS single-target sim; strong into 2-4 target cleave.",
        requires = { runes = { "RUNE_DEEP_FREEZE", "RUNE_FROZEN_ORB", "RUNE_MOLTEN_ARMOR", "RUNE_ICE_LANCE",
                               "RUNE_SPELLFROST_BOLT", "RUNE_ICY_VEINS", "RUNE_SPELL_POWER" } } },
      { build = "MAGE_FROST_LEVELING", available = true, playstyle = "Frost leveling (questing)", difficulty = "easy",
        updated = "2026-09-14", phase = "SoD P8",
        source = "https://www.icy-veins.com/wow-classic/frost-mage-dps-season-of-discovery-leveling",
        summary = "Frostbolt to kite and slow, Living Bomb and Frozen Orb for sustained damage, Frost Nova for control. Icy Veins recommends Frost for leveling's consistency and flexibility in world PvP.",
        requires = { runes = { "RUNE_LIVING_BOMB", "RUNE_LIVING_FLAME", "RUNE_FROSTFIRE_BOLT",
                               "RUNE_DEEP_FREEZE", "RUNE_FROZEN_ORB", "RUNE_BRAIN_FREEZE" }, spells = {} } },
      -- MG2: Elmira's first healer playstyle. No `recommended` (unlike MAGE_FIRE) — the dossier's
      -- own summary makes plain this build's real job (ally healing) is half-invisible to Elmira; the
      -- catalog card must not oversell it.
      { build = "MAGE_ARCANE_HEALER", available = true, playstyle = "Arcane healer — beacons and Arcane damage (Healer)", difficulty = "medium",
        updated = "2026-09-14", phase = "SoD P8",
        source = "https://www.wowhead.com/classic/guide/season-of-discovery/classes/mage/healer-rotation-cooldowns-abilities-pve",
        summary = "Arcane Blast, Missile Barrage and Arcane Barrage on the enemy target feed Temporal Beacon healing on allies. Elmira shows that damage half as real suggestions; Regeneration, Mass Regeneration, Chronostatic Preservation and Rewind Time show only as cooldown reminders, since Elmira cannot see who needs the heal.",
        requires = { runes = { "RUNE_ADVANCED_WARDING", "RUNE_ARCANE_BLAST", "RUNE_MISSILE_BARRAGE",
                               "RUNE_MASS_REGENERATION", "RUNE_ARCANE_BARRAGE" }, spells = { "ARCANE_MISSILES" } } },
    },
  }

  -- ---------------------------------------------------------------------------------------------
  -- Advice
  -- ---------------------------------------------------------------------------------------------
  -- `runes` lists the build's full slot-by-slot kit (dossier's own "Runes" line per build, all 10
  -- slots including both rings) — broader than `requires.runes` above on purpose: `requires` is the
  -- hard shopping list evaluation never depends on (ADR-0006/0013), `advice.runes` is what the
  -- Advisor tells the player to go engrave, and it is allowed to name the BiS-only or either-is-fine
  -- choices `requires` deliberately leaves out (the Frost chest rune, the ring pair).
  D.Advice = D.Advice or {}
  D.Advice.MAGE = {
    MAGE_FIRE = {
      soul = { { pick = "SOUL_OF_THE_TORCHER", reason = "Scales with Fire effects already on the target from this rotation" } },
      runes = { "RUNE_HOT_STREAK", "RUNE_OVERHEAT", "RUNE_ENLIGHTENMENT", "RUNE_BALEFIRE_BOLT", "RUNE_LIVING_BOMB",
                "RUNE_FROSTFIRE_BOLT", "RUNE_ICY_VEINS", "RUNE_SPELL_POWER", "RUNE_FIRE_SPECIALIZATION", "RUNE_FROST_SPECIALIZATION" },
      ringRunes = { default = { "FIRE_SPECIALIZATION", "FROST_SPECIALIZATION" } },
    },
    MAGE_FROST_SPELLFROST = {
      soul = { { pick = "SOUL_OF_THE_CRYOMANCER", reason = "Scales Frostbolt/Spellfrost Bolt, this build's two nukes" } },
      -- RUNE_FINGERS_OF_FROST named here (not in `requires.runes`) is the build's own identity choice
      -- the dossier calls out explicitly: "Frost's entire Spellfrost identity ... depends on Fingers
      -- of Frost procs" — worth telling the player even though `requires` stays silent on the split.
      runes = { "RUNE_DEEP_FREEZE", "RUNE_FROZEN_ORB", "RUNE_FINGERS_OF_FROST", "RUNE_MOLTEN_ARMOR", "RUNE_ICE_LANCE",
                "RUNE_SPELLFROST_BOLT", "RUNE_ICY_VEINS", "RUNE_SPELL_POWER", "RUNE_FROST_SPECIALIZATION", "RUNE_FIRE_SPECIALIZATION" },
      ringRunes = { default = { "FROST_SPECIALIZATION", "FIRE_SPECIALIZATION" } },
    },
    MAGE_FROST_LEVELING = {
      soul = {},  -- a leveling character is not assumed to have a P8 shoulder soul; none is guessed
      runes = { "RUNE_LIVING_BOMB", "RUNE_LIVING_FLAME", "RUNE_FROSTFIRE_BOLT", "RUNE_DEEP_FREEZE",
                "RUNE_FROZEN_ORB", "RUNE_BRAIN_FREEZE" },
      ringRunes = { default = { "FROST_SPECIALIZATION" } },
    },
    MAGE_ARCANE_HEALER = {
      soul = { { pick = "SOUL_OF_THE_ETERNAL_CARETAKER", reason = "Extends Mass Regeneration's Temporal Beacon on the ally wearing it to 21s" } },
      -- The build's full slot-by-slot kit (dossier's own "Runes" line), broader than `requires.runes`
      -- above on purpose (ADR-0006/0013): chest and feet name their guide-sanctioned alternative
      -- inline in a comment, the way MAGE_FROST_SPELLFROST's chest rune already does.
      runes = { "RUNE_ADVANCED_WARDING", "RUNE_ENLIGHTENMENT", "RUNE_ARCANE_BLAST", "RUNE_MISSILE_BARRAGE",
                "RUNE_MASS_REGENERATION", "RUNE_CHRONOSTATIC_PRESERVATION", "RUNE_REWIND_TIME", "RUNE_ARCANE_BARRAGE",
                "RUNE_FIRE_SPECIALIZATION", "RUNE_ARCANE_SPECIALIZATION" },
      -- RUNE_ENLIGHTENMENT (chest) is the default named above; RUNE_CHRONOSTATIC_PRESERVATION (feet)
      -- and RUNE_REWIND_TIME (wrist) are each one half of a guide-sanctioned same-slot swap (feet:
      -- Chronostatic Preservation vs Spell Power; wrist: Rewind Time vs Balefire Bolt, dossier's
      -- "wrist conflict") — `requires.runes` deliberately leaves all three slots out (MG2-D3).
      ringRunes = { default = { "FIRE_SPECIALIZATION", "ARCANE_SPECIALIZATION" } },
    },
  }

  -- ---------------------------------------------------------------------------------------------
  -- Builds
  -- ---------------------------------------------------------------------------------------------
  -- ADR-0006 order: baseline first, gated upgrades ranked above the baseline entries they outrank.
  -- AoE lines are gated `{"enemies", min = 3}` exactly like Paladin's — Adapters/Vanilla.lua's
  -- state:enemies() is hardcoded to 1 until M5a, so these are a safe no-op today, not a bug.
  D.Builds = D.Builds or {}

  -- Mage — Fire. Baseline: Icy Veins SoD Fire rotation (dossier S1). BiS upgrade lines: WoWSims P8
  -- BiS Single Target (sheet DPS 13830, docs/research/wowsims-mage-p8/README.md).
  D.Builds.MAGE_FIRE = {
    schema = 1, key = "MAGE_FIRE", name = "Mage — Fire", class = "MAGE", flavor = "SoD",
    notes = "Fire Blast is guaranteed-crit and off the GCD with Overheat engraved — weave it whenever it is up. Hot Streak Pyroblast is free and instant; never hold it. Keep 5 stacks of Fire Vulnerability on the boss with Scorch, maintain Living Bomb, and watch Balefire Bolt's self-stack cap.",
    requires = { runes = { "RUNE_HOT_STREAK", "RUNE_OVERHEAT", "RUNE_ENLIGHTENMENT", "RUNE_BALEFIRE_BOLT",
                          "RUNE_LIVING_BOMB", "RUNE_FROSTFIRE_BOLT", "RUNE_ICY_VEINS", "RUNE_SPELL_POWER" } },
    entries = {
      ---------------------------------------------------------------- 1: never hold a Hot Streak proc
      { spell = "PYROBLAST", when = { {"buff","HOT_STREAK_BUFF"} }, label = "Hot Streak" },

      ---------------------------------------------------------------- 2: Overheat makes Fire Blast a free off-GCD weave
      { spell = "FIRE_BLAST", hold = true, when = { {"rune","RUNE_OVERHEAT"} }, label = "Overheat" },

      ---------------------------------------------------------------- 3: Improved Scorch / Fire Vulnerability maintenance
      { spell = "SCORCH", when = { {"no_debuff","FIRE_VULNERABILITY"} }, label = "Stack Scorch" },
      { spell = "SCORCH", when = { {"debuff","FIRE_VULNERABILITY", maxRemaining = 4} }, label = "Refresh Scorch" },
      { spell = "SCORCH", when = { {"not", {"debuff","FIRE_VULNERABILITY", min = 5}} }, label = "5 stacks" },

      ---------------------------------------------------------------- 4: Living Bomb maintenance
      { spell = "LIVING_BOMB", when = { {"no_debuff","LIVING_BOMB"} } },

      ---------------------------------------------------------------- 5: cooldowns
      { spell = "COMBUSTION", hold = true },
      { spell = "ICY_VEINS", hold = true },
      { item  = 13, hold = true, label = "Trinket", when = { {"item_ready", 13} } },
      { item  = 14, hold = true, label = "Trinket", when = { {"item_ready", 14} } },
      { spell = "COLD_SNAP", hold = true, when = { {"cooldown_gt","ICY_VEINS", 30} }, label = "Reset Icy Veins" },

      ---------------------------------------------------------------- 6: Balefire Bolt filler under its self-stack cap
      -- MG1-D5(a) semantics: `max = 3` passes when the debuff is absent too, so this is reachable
      -- from the very first cast, not only once the stack is already up and low.
      { spell = "BALEFIRE_BOLT", when = { {"buff","BALEFIRE_BOLT", max = 3} }, label = "3 or fewer stacks" },

      ---------------------------------------------------------------- AoE (3+ targets), ranked above the single-target fillers
      { spell = "LIVING_FLAME", label = "AoE", when = { {"enemies", min = 3} } },
      { spell = "BLAST_WAVE",   label = "AoE", when = { {"enemies", min = 3} } },
      { spell = "FLAMESTRIKE",  label = "AoE", when = { {"enemies", min = 3} } },

      ---------------------------------------------------------------- 7: baseline fillers
      -- The un-engraved-Overheat case: a plain Fire Blast is still a real button on its own cooldown.
      { spell = "FIRE_BLAST" },
      { spell = "FROSTFIRE_BOLT" },
      { spell = "FIREBALL" },  -- baseline filler when the waist rune is not engraved
    },
  }

  -- Mage — Frost (Spellfrost). Baseline: Icy Veins SoD Frost rotation (dossier S2). BiS upgrade
  -- lines: WoWSims P8 BiS Single Target (sheet DPS 13440).
  D.Builds.MAGE_FROST_SPELLFROST = {
    schema = 1, key = "MAGE_FROST_SPELLFROST", name = "Mage — Frost (Spellfrost)", class = "MAGE", flavor = "SoD",
    notes = "Deep Freeze a target under Fingers of Frost for a guaranteed stun, then shatter it with Ice Lance. Frozen Orb on cooldown even on single target — it also feeds Fingers of Frost procs. Living Bomb maintained between casts; Balefire Bolt filler under its self-stack cap. The chest rune is a real choice: Enlightenment for easier mana, Fingers of Frost for the shatter combo this build is named after.",
    requires = { runes = { "RUNE_DEEP_FREEZE", "RUNE_FROZEN_ORB", "RUNE_MOLTEN_ARMOR", "RUNE_ICE_LANCE",
                          "RUNE_SPELLFROST_BOLT", "RUNE_ICY_VEINS", "RUNE_SPELL_POWER" } },
    entries = {
      ---------------------------------------------------------------- always: Molten Armor before the pull
      { spell = "MOLTEN_ARMOR", when = { {"out_of_combat"}, {"no_buff","MOLTEN_ARMOR"} } },

      ---------------------------------------------------------------- Fingers of Frost shatter combo
      { spell = "DEEP_FREEZE", when = { {"buff","FINGERS_OF_FROST_BUFF"} }, label = "FoF" },
      { spell = "ICE_LANCE",   when = { {"buff","FINGERS_OF_FROST_BUFF"} }, label = "Shatter" },

      ---------------------------------------------------------------- sustained damage / proc feed
      { spell = "FROZEN_ORB" },
      { spell = "LIVING_BOMB", when = { {"no_debuff","LIVING_BOMB"} } },

      ---------------------------------------------------------------- cooldowns
      { spell = "ICY_VEINS", hold = true },
      { item  = 13, hold = true, label = "Trinket", when = { {"item_ready", 13} } },
      { item  = 14, hold = true, label = "Trinket", when = { {"item_ready", 14} } },
      { spell = "COLD_SNAP", hold = true, when = { {"cooldown_gt","ICY_VEINS", 30} }, label = "Reset Icy Veins" },

      ---------------------------------------------------------------- AoE (3+ targets)
      { spell = "LIVING_FLAME", label = "AoE", when = { {"enemies", min = 3} } },

      ---------------------------------------------------------------- Balefire Bolt filler under its self-stack cap
      { spell = "BALEFIRE_BOLT", when = { {"buff","BALEFIRE_BOLT", max = 3} }, label = "3 or fewer stacks" },

      ---------------------------------------------------------------- baseline fillers
      { spell = "SPELLFROST_BOLT" },
      { spell = "FROSTBOLT" },  -- baseline filler when the waist rune is not engraved
    },
  }

  -- Mage — Frost leveling (questing). Source: Icy Veins SoD Frost Mage Leveling (dossier S5) — "the
  -- recommended leveling build due to its consistency and flexibility... in World PvP". Wowhead's
  -- own leveling guide (dossier S9) recommends a Fire-leaning hybrid instead; both exist and
  -- disagree, and this pack follows S5 per the task's explicit ask for a Frost questing build.
  -- AT7: an ability is a NAME, so no `level` gates — the spellbook already answers "known or not" at
  -- whatever rank the character owns (hard rule 8's reasoning applied to levelling, not just gear).
  D.Builds.MAGE_FROST_LEVELING = {
    schema = 1, key = "MAGE_FROST_LEVELING", name = "Mage — Frost leveling (questing)", class = "MAGE", flavor = "SoD",
    notes = "Frostbolt to kite and slow, Fireball or Frostfire Bolt for burst, Frost Nova for control. Living Bomb and Frozen Orb carry the sustained damage; group up with Blizzard/Arcane Explosion/Cone of Cold on 3 or more enemies.",
    requires = { runes = { "RUNE_LIVING_BOMB", "RUNE_LIVING_FLAME", "RUNE_FROSTFIRE_BOLT",
                          "RUNE_DEEP_FREEZE", "RUNE_FROZEN_ORB", "RUNE_BRAIN_FREEZE" }, spells = {} },
    entries = {
      ---------------------------------------------------------------- sustained damage
      { spell = "LIVING_BOMB", when = { {"no_debuff","LIVING_BOMB"} } },
      { spell = "FROZEN_ORB" },
      { spell = "FIRE_BLAST" },

      ---------------------------------------------------------------- AoE grinding (3+ enemies), ranked above the fillers
      { spell = "BLIZZARD",         label = "AoE", when = { {"enemies", min = 3} } },
      { spell = "ARCANE_EXPLOSION", label = "AoE", when = { {"enemies", min = 3} } },
      { spell = "CONE_OF_COLD",     label = "AoE", when = { {"enemies", min = 3} } },

      ---------------------------------------------------------------- baseline fillers
      { spell = "FROSTFIRE_BOLT" },
      { spell = "FROSTBOLT" },
      { spell = "FIREBALL" },  -- last: baseline filler when nothing else applies
    },
  }

  -- Mage — Arcane healer (MG2). Baseline: Icy Veins SoD Arcane Healer rotation (dossier H1), cross-
  -- read against Wowhead's own narrative healer guide (H5). Elmira's State contract is player+enemy
  -- target only (hard rule 3) — it has no ally/raid awareness, so the beacon-application spells
  -- (Regeneration, Mass Regeneration, Chronostatic Preservation, Rewind Time) can only ever be shown
  -- as cooldown reminders, never as "cast this now because someone needs it" (dossier: "What Elmira
  -- can and cannot show"). Everything else here is the damage-rotation half wearing a healer's
  -- clothes — Arcane Blast/Missiles/Barrage stack and proc management read only the player's own
  -- buffs and the boss, exactly like a DPS build.
  D.Builds.MAGE_ARCANE_HEALER = {
    schema = 1, key = "MAGE_ARCANE_HEALER", name = "Mage — Arcane healer", class = "MAGE", flavor = "SoD",
    notes = "Regeneration, Mass Regeneration, Chronostatic Preservation and Rewind Time show only as cooldown reminders here -- Elmira cannot see who needs the heal, so cast them by hand when your raid awareness says to. Build Arcane Blast to 2 stacks, spend it on a Missile Barrage proc or Arcane Barrage, and swap to Arcane Explosion at 2 or more enemies. Balefire Bolt fills between if your wrist rune is Balefire Bolt rather than Rewind Time -- mind its self-stack cap.",
    requires = { runes = { "RUNE_ADVANCED_WARDING", "RUNE_ARCANE_BLAST", "RUNE_MISSILE_BARRAGE",
                          "RUNE_MASS_REGENERATION", "RUNE_ARCANE_BARRAGE" }, spells = { "ARCANE_MISSILES" } },
    entries = {
      ---------------------------------------------------------------- 1: cooldown-only reminders (dossier: never "cast now")
      -- `hold = true`, no `when`: Engine.eligible already refuses any entry while its own spell is on
      -- cooldown (Core/Engine.lua), so the reminder is naturally held while off cooldown and gone
      -- once cast -- exactly the mechanism MASS_REGENERATION/REWIND_TIME's `cooldown` fields (D1) feed.
      -- No CHRONOSTATIC_PRESERVATION line: a direct re-fetch of its Wowhead page found no stated
      -- cooldown (follow-up note), and a `hold = true` line with nothing to make it clear would
      -- sit in slot 1 forever. No REGENERATION line either -- it has no cooldown at all; it is named
      -- above in `notes` as the beacon cast by hand instead.
      { spell = "MASS_REGENERATION", hold = true, label = "Beacons (reminder)" },
      { spell = "REWIND_TIME", hold = true, label = "Rewind (reminder)" },

      ---------------------------------------------------------------- 2: self-buff cooldowns (real, player-only state)
      { spell = "ARCANE_POWER", hold = true },
      { spell = "PRESENCE_OF_MIND", hold = true },
      { item  = 13, hold = true, label = "Trinket", when = { {"item_ready", 13} } },
      { item  = 14, hold = true, label = "Trinket", when = { {"item_ready", 14} } },

      ---------------------------------------------------------------- 3: mana
      { spell = "EVOCATION", when = { {"resource","MANA", maxPct = 20} }, label = "Mana" },

      ---------------------------------------------------------------- 4: Missile Barrage proc window
      { spell = "ARCANE_MISSILES", when = { {"buff","MISSILE_BARRAGE_BUFF"} }, label = "Missile Barrage" },

      ---------------------------------------------------------------- 5: AoE (2+ enemies), ranked above the single-target stack chain
      { spell = "ARCANE_EXPLOSION", when = { {"enemies", min = 2}, {"buff","ARCANE_BLAST_BUFF", min = 2} }, label = "AoE" },

      ---------------------------------------------------------------- 6: Arcane Blast stack management
      { spell = "ARCANE_BARRAGE", when = { {"buff","ARCANE_BLAST_BUFF", min = 2} }, label = "2 stacks" },

      ---------------------------------------------------------------- 7: Balefire Bolt filler under its self-stack cap
      -- wrist rune not engraved (Rewind Time chosen instead) -> BALEFIRE_BOLT is unknown and this
      -- line is skipped automatically (hard rule 8; ADR-0006 rule 5); no `rune` gate needed.
      { spell = "BALEFIRE_BOLT", when = { {"buff","BALEFIRE_BOLT", max = 3} }, label = "3 or fewer stacks" },

      ---------------------------------------------------------------- 8: baseline stack building
      { spell = "ARCANE_BLAST", when = { {"buff","ARCANE_BLAST_BUFF", max = 1} }, label = "Build stacks" },

      ---------------------------------------------------------------- 9: baseline filler so the strip never goes empty
      { spell = "ARCANE_BLAST" },
    },
  }

  -- Field-for-field what Paladin.lua's own return block builds (ADR-0011 §2/§3).
  return {
    class = "MAGE", flavor = "SoD",
    spells = D.Spells, sets = D.Sets, souls = D.Souls, bonuses = D.Bonuses,
    builds = D.Builds, catalog = D.Catalog, advice = D.Advice,
    catalogVersion = D.Catalog.version,
  }
end)
