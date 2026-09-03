-- Elmira/Classes/Paladin.lua — shipped Paladin data for Season of Discovery (ADR-0011).
--
-- Everything below is INSIDE a thunk on purpose. WoW parses and executes every file listed in a TOC,
-- so this file runs on a mage's login too; building the tables here at file scope would cost every
-- character every class's data. Registering a closure costs one closure, and Core/Init.lua calls
-- exactly one of them — the player's. Never move a table constructor out of the function; a spec
-- (tests/spec/builtin_packs_spec.lua) fails if this file registers anything but a function.
--
-- Migrated from the Elmira_Paladin LoadOnDemand addon at M4b. The data, the comments and every
-- `-- src:` URL are unchanged: hard rule 2 means IDs come from a fetched page, and a file move is
-- not a re-verification. The seven former Data/*.lua files are the seven sections below.
local ADDON, ns = ...

ns.RegisterBuiltinPack("PALADIN", function()
  -- `D` is what `ns.Data.SoD` used to be. Local to this call, so nothing survives it but the
  -- returned pack, and a mage never allocates any of it.
  local D = {}

  -- ---------------------------------------------------------------------------------------------
  -- Spells (was Elmira_Paladin/Data/Spells.lua)
  -- ---------------------------------------------------------------------------------------------
  -- Data/SoD/Spells.lua — symbolic key -> spell record. Every id is verified and carries its `src`.
  -- Keys never change across flavors; IDs do. Prot/Shockadin abilities, the four unused seals and
  -- DIVINE_FAVOR_BUFF are deliberately absent: they return at M5 with the builds that need them.

  D.Spells = {
    -- Paladin abilities (castable)
    -- No `cost`: Wowhead states this as "6% of base mana", and a percentage is not a usable fallback
    -- (the cost table is numeric — see Schema's cost normalisation). state.powerCost() reads the real
    -- number from the client, which the probe showed is the authority anyway (docs/07 §9.3).
    JUDGEMENT           = { id = 20271,  src = "https://www.wowhead.com/classic/spell=20271", cooldown = 10 },
    EXORCISM            = { id = 415073, src = "https://www.wowhead.com/classic/spell=415073", cost = { mana = 345 }, cooldown = 15, cdVolatile = true }, -- SoD; Art of War rune shortens CD
    CRUSADER_STRIKE     = { id = 407676, src = "https://www.wowhead.com/classic/spell=407676", cost = { mana = 0 }, cooldown = 6 }, -- ability, not teach 409914
    DIVINE_STORM        = { id = 407778, src = "https://www.wowhead.com/classic/spell=407778", cooldown = 10 }, -- ability, not teach 409924; no `cost`, Wowhead gives "12% of base mana"
    -- 429146 read from the live client via GetSpellInfo("Holy Wrath") on 2026-09-01 (docs/07 §9.6);
    -- 2812 was the dossier's rank-1 guide link. Fetch 429146 on Wowhead to satisfy hard rule 2.
    HOLY_WRATH          = { id = 429146, src = "https://www.wowhead.com/classic/spell=429146", cost = { mana = 805 }, cooldown = 60 },   -- rank max; max-rank id
    CONSECRATION        = { id = 20924,  src = "https://www.wowhead.com/classic/spell=20924", cost = { mana = 565 }, cooldown = 8 },  -- rank max; use max-rank id

    -- Seals (castable) — used by `seal`/`no_seal` conditions via the active-seal buff
    SEAL_OF_MARTYRDOM   = { id = 407798, src = "https://www.wowhead.com/classic/spell=407798", seal = true },
    -- 407798 and 407799 are BOTH named "Seal of Martyrdom" with the same icon (135961) on Wowhead,
    -- which is why id verification came back ambiguous. The live client separates them and Wowhead
    -- cannot: GetSpellInfo maxRange is 0 for 407798 (self-cast -- the seal you press) and 100 for
    -- 407799 (lands on the target). 407799 is the melee-triggered damage component: in the 2026-09-02
    -- recording it fired 13x at 1.43-1.93 s intervals (swing cadence on a 2.10 weapon) and never once
    -- before the first seal cast. `triggered` marks it as something the client reports on the player's
    -- behalf, NOT a button press -- without that flag it is 13 rows of noise in any "did the player
    -- follow the suggestion?" comparison. No build references it; it exists so the cast log can name
    -- it. Client dumped 2026-09-02 (docs/07); Wowhead src satisfies the docs/03 sourcing rule.
    SEAL_OF_MARTYRDOM_HIT = { id = 407799, src = "https://www.wowhead.com/classic/spell=407799", triggered = true },
    SEAL_OF_COMMAND     = { id = 20920,  src = "https://www.wowhead.com/classic/spell=20920",  seal = true },

    -- Auras / procs (buff IDs differ from ability IDs — verify via the skill)
    -- (No ART_OF_WAR_BUFF: the rune is a passive CD/mana reduction on Exorcism, not a proc aura. Verified in M2.)
    -- Applied by the Radiant Judgement 6-set. Its source is WoWSims' simulator code, NOT a fetched
    -- Wowhead tooltip: the 6p passive (467529) is a server-side dummy script, so no Wowhead page can
    -- show this aura. `verify = "in-game"` marks it provisional — the only sanctioned way an id ships
    -- without a Wowhead src (docs/03). Confirm with a 6p wearer:
    --   /dump AuraUtil.FindAuraByName("Swift Judgement", "player")
    SWIFT_JUDGEMENT_BUFF = { id = 467530, src = "wowsims sod sim/paladin/item_sets_pve.go (2026-09-01)",
                             verify = "in-game",
                             note = "+1% Holy damage per stack, max 5, 8s; refreshed by each Judgement" },
    -- REFUTED 2026-09-01, kept as a comment so nobody re-derives it. Research claimed each shoulder
    -- soul applies a permanent hidden aura reusing the matching set bonus's id (Exile 468431,
    -- Retributor 1213397, Judicator 467526, Sealbearer 456533) and that these were readable via
    -- UnitAura — which would have freed soul detection from the enUS tooltip scan.
    -- `/elm debug dump` on a character WEARING Soul of the Exile reported 468431 absent. A permanent
    -- aura that is up cannot be absent, so the auras are not visible to a HELPFUL UnitAura scan and
    -- cannot drive detection. Tooltip scanning stays primary; the enUS limitation stands. docs/07 §9.13.
    -- Applied by the T2.5 4-set on melee white hits. Wowhead has a real page for the aura itself, so
    -- unlike SWIFT_JUDGEMENT/TEMPLAR this needs no `verify = "in-game"` tag — only the 3-stack cap comes
    -- from WoWSims, and stacks are not an id. The rotation guidance is unchanged: this boosts the next
    -- Exorcism, it is NOT a reason to hold Exorcism.
    EXCOMMUNICATION_BUFF = { id = 1217927, src = "https://www.wowhead.com/classic/spell=1217927",
                             note = "+36% Exorcism damage, 20s, max 3 stacks (stack cap per wowsims)" },
    -- Applied by the T3.5 6-set when Holy Power is consumed. Same situation as SWIFT_JUDGEMENT_BUFF:
    -- server-side scripted, so no Wowhead page shows it. NOT related to SOUL_OF_THE_TEMPLAR, which is
    -- a shoulder soul that merely shares the word.
    TEMPLAR_BUFF        = { id = 1226464, src = "wowsims sod sim/paladin/item_sets_pve_phase_8.go (2026-09-01)",
                            verify = "in-game",
                            note = "+15% attack power per Holy Power consumed, max 3 stacks, 10s" },
    HOLY_POWER_BUFF     = { id = 1226461, src = "https://www.wowhead.com/classic/spell=1226461" }, -- T3.5 Ret 2-set stack
    JUDGEMENT_OF_COMMAND = { id = 20966, src = "https://www.wowhead.com/classic/spell=20966" },
    JUDGEMENT_OF_LIGHT   = { id = 20343, src = "https://www.wowhead.com/classic/spell=20343" },
    JUDGEMENT_OF_WISDOM  = { id = 20354, src = "https://www.wowhead.com/classic/spell=20354" },
    JUDGEMENT_OF_THE_CRUSADER = { id = 20303, src = "https://www.wowhead.com/classic/spell=20303" },
    -- Read from the live client 2026-09-01 (docs/07 §9.12): the applied aura's spellId IS the ability's
    -- id, confirming the staged guess. Duration 20 s, dispel type Magic.
    AVENGING_WRATH_BUFF  = { id = 407788, src = "https://www.wowhead.com/classic/spell=407788" },
    AVENGING_WRATH       = { id = 407788, src = "https://www.wowhead.com/classic/spell=407788" },
    AURA_MASTERY         = { id = 407624, src = "https://www.wowhead.com/classic/spell=407624" },
    REBUKE               = { id = 425609, src = "https://www.wowhead.com/classic/spell=425609" },
    HORN_OF_LORDAERON    = { id = 425600, src = "https://www.wowhead.com/classic/spell=425600" },
    VENGEANCE_BUFF       = { id = 20049,  src = "https://www.wowhead.com/classic/spell=20049", proc = true },
    VINDICATION_DEBUFF   = { id = 26021,  src = "https://www.wowhead.com/classic/spell=26021" },
    THE_ART_OF_WAR       = { id = 426157, src = "https://www.wowhead.com/classic/spell=426157",
                             note = "Passive cooldown/mana reduction on Exorcism, not a proc aura (verified in M2)" },
    PURIFYING_POWER      = { id = 429144, src = "https://www.wowhead.com/classic/spell=429144" },

    -- Rune entries. **These must hold the ABILITY spell id, not the teach-spell id.** Detection reads
    -- `C_Engraving.GetRuneForEquipmentSlot(slot).learnedAbilitySpellIDs`, which returns the ability the
    -- rune teaches (docs/07 §9.5). A teach id here compares false against every slot and `rune()`
    -- silently reports "not engraved" for a rune the player is wearing — no error anywhere.
    -- All entries below now hold ability ids. Two are client-verified (Hallowed Ground, Rebuke) and one
    -- was client-supplied (Wrath); the rest came from Wowhead AFTER Wowhead was found systematically
    -- wrong about this field, so `/elm debug dump` re-checks them against the live slots. Re-checked by `/elm debug dump`.
    -- 429139 supplied from the client 2026-09-01; Wowhead confirms it is "Wrath", a passive rune
    -- ability (hidden aura, Consecration crit damage). The sweep's 429248 could not be classed at all
    -- and 429249 is the engrave/teach spell — neither would have matched learnedAbilitySpellIDs.
    RUNE_WRATH          = { id = 429139, src = "https://www.wowhead.com/classic/spell=429139", rune = "head" },
    RUNE_RIGHTEOUS_VENGEANCE = { id = 440794, src = "https://www.wowhead.com/classic/spell=440794", rune = "back" },
    RUNE_DIVINE_STORM   = { id = 407778, src = "https://www.wowhead.com/classic/spell=407778", rune = "chest" },
    RUNE_PURIFYING_POWER = { id = 429144, src = "https://www.wowhead.com/classic/spell=429144", rune = "wrist" },
    RUNE_CRUSADER_STRIKE = { id = 407676, src = "https://www.wowhead.com/classic/spell=407676", rune = "hands" },
    RUNE_SHEATH_OF_LIGHT = { id = 426158, src = "https://www.wowhead.com/classic/spell=426158", rune = "waist" },
    RUNE_AURA_MASTERY   = { id = 407624, src = "https://www.wowhead.com/classic/spell=407624", rune = "legs" },
    RUNE_ART_OF_WAR     = { id = 426157, src = "https://www.wowhead.com/classic/spell=426157", rune = "feet" },
    -- Client-verified: round 2 dumped chest as learnedAbilitySpellIDs = { 458287 } while this entry
    -- said 425614 (the teach spell). This mismatch is what exposed the whole class of bug.
    RUNE_HALLOWED_GROUND = { id = 458287, src = "https://www.wowhead.com/classic/spell=458287", rune = "chest" },
    -- Observed engraved in game on Arthorion 2026-09-01 (docs/07 §9.5). Not a conflict with the three
    -- entries above for the same slots: a slot hosts many runes and the player picks one. Needed so
    -- `rune`/`no_rune` conditions and the wizard can reason about a Holy build too.
    RUNE_FANATICISM     = { id = 429142, src = "https://www.wowhead.com/classic/spell=429142", rune = "head" },
    RUNE_INFUSION_OF_LIGHT = { id = 426065, src = "https://www.wowhead.com/classic/spell=426065", rune = "waist" },
    -- Client-verified 2026-09-01: GetRuneForEquipmentSlot(7).learnedAbilitySpellIDs = { 425609 }.
    -- Equal to the REBUKE ability above, which is the expected shape. The PTR-only 425616 was the
    -- teach spell and would never have matched.
    RUNE_REBUKE         = { id = 425609, src = "https://www.wowhead.com/classic/spell=425609", rune = "legs" },
  }

  -- ---------------------------------------------------------------------------------------------
  -- Sets (was Elmira_Paladin/Data/Sets.lua)
  -- ---------------------------------------------------------------------------------------------
  -- Data/SoD/Sets.lua — item IDs per set + bonus spell IDs per threshold (spec-specific in SoD).

  D.Sets = {
    PALADIN_T2_JUDGEMENT = {
      -- Proper set name is Radiant Judgement; guides call it "Draconic" after the item quality tag and
      -- the vanilla-era name was Judgement Armor, so both are kept as aliases for search/advice text.
      -- NOT the same set as Lawbringer Radiance (the Molten Core "Core Forged" twin), which is a
      -- separate key and the likely source of the seal-linger 6p — deliberately not merged here.
      name = "Radiant Judgement", aliases = { "Judgement Armor", "Draconic" },
      src = "https://www.wowhead.com/classic/item-set=1810",
      items = { 231178, 231176, 231181, 231174,
                231179, 231175, 231177, 231180 },
      bonuses = { -- spec = "RETRIBUTION"; kind = "passive" (no aura) | "aura" (use buff condition instead)
        [2] = { spell = 467518, src = "https://www.wowhead.com/classic/item-set=1810", spec = "RETRIBUTION", kind = "passive",
                note = "+5% damaging Judgements; Judgements no longer consume seals; can trigger multiple seals (S1)" },
        -- Corrected 2026-09-01: this is the SOUL OF THE JUDICATOR effect, not the Retributor. Both the
        -- soul research and the Judicator's own Wowhead text give Judgement CD -5s / damage -45%; the
        -- dossier's "Soul of the Retributor" attribution was wrong (that soul maps to the T2.5 2-set).
        [4] = { spell = 467526, src = "https://www.wowhead.com/classic/item-set=1810", spec = "RETRIBUTION", kind = "passive",
                note = "Judgement cooldown -5s, Judgement damage -45% (same effect as Soul of the Judicator)" },
        -- Stacking, timed buff => an aura, not a passive (hard rule 5: detect effects, not causes).
        -- The APPLIED aura's id is not on Wowhead; 467529 is the bonus spell, the same split as the
        -- T3.5 2-set's 1226460 (bonus) vs 1226461 (HOLY_POWER_BUFF). Needs a /dump in game.
        -- Not Exodin-blocking: no shipped build gates on the T2 6-set yet.
        -- 467529 is a server-side dummy script, so Wowhead cannot show the aura it applies. The aura is
        -- Swift Judgement (see Spells.lua) and that is what a condition watches — ADR-0004, detect the
        -- effect, not the cause. A build must never gate on {"set", ..., min = 6} for this.
        [6] = { spell = 467529, src = "https://www.wowhead.com/classic/item-set=1810", spec = "RETRIBUTION", kind = "aura", aura = "SWIFT_JUDGEMENT_BUFF",
                note = "Judgement grants +1% Holy damage per stack, 5 stacks max, 8s (Swift Judgement)" },
      },
    },
    PALADIN_T25_AVENGERS = {
      name = "Avenger's Radiance (T2.5, SoD)", src = "https://www.wowhead.com/classic/item-set=1845",
      items = { 233398, 233401, 233397, 233400, 233399 },
      bonuses = {
        [2] = { spell = 1213397, src = "https://www.wowhead.com/classic/item-set=1845", spec = "RETRIBUTION", kind = "passive", note = "150% Crusader Strike damage (P8 retune)" },
        -- Resolved 2026-09-01: a buff DOES land on the player — Excommunication (1217927), 20s, 3
        -- stacks, +36% Exorcism damage, applied on melee white hits. Was `passive` on a conservative
        -- reading, which was wrong; ADR-0004 makes this an aura. The rotation guidance is unchanged
        -- and still matters: it boosts the next Exorcism, it is NOT a reason to hold Exorcism.
        [4] = { spell = 1213406, src = "https://www.wowhead.com/classic/item-set=1845", spec = "RETRIBUTION", kind = "aura", aura = "EXCOMMUNICATION_BUFF",
                note = "Excommunication: +36% next Exorcism, 20s, 3 stacks; does NOT change rotation — never hold Exorcism (S1)" },
      },
    },
    PALADIN_T3_REDEMPTION = {
      name = "Redemption Warplate (T3, SoD)", src = "https://www.wowhead.com/classic/item-set=1896",
      -- 9 pieces, NOT 8: the in-game tooltip reads "(n/9)" and the thresholds are 2/9, 4/9, 6/9.
      -- Band of Redemption (236130) IS a member and counts — confirmed in game 2026-09-01 (docs/07
      -- §9.12). A ring in an armour set is unusual, which is why this was worth checking rather than
      -- assuming; excluding it would have withheld the 4-set HOLY_WRATH_INSTANT the Exodin build gates
      -- on from anyone wearing the ring as one of their four.
      -- The Holy and Prot variants have their own rings for M5: Redemption Armor 236116,
      -- Redemption Bulwark 236139.
      items = { 236128, 236126, 236132, 236124,
                236129, 236125, 236127, 236131, 236130 },
      bonuses = {
        [2] = { spell = 1219189, src = "https://www.wowhead.com/classic/item-set=1896", spec = "RETRIBUTION", kind = "passive", note = "Divine Storm damage bonus (S1/S6)" },
        -- Exact in-game text 2026-09-02 (docs/07 §9.14): "Reduces the cast time of your Holy Wrath
        -- ability by 100%, reduces its cooldown by 25%, and reduces its mana cost by 75%." The mana
        -- reduction was not recorded before and shows up live as Holy Wrath costing 201 vs a shipped
        -- fallback of 805 — another reason the shipped cost is a fallback only.
        [4] = { spell = 1219191, src = "https://www.wowhead.com/classic/item-set=1896", spec = "RETRIBUTION", kind = "passive", note = "Holy Wrath: instant cast, -25% cooldown, -75% mana" },
        -- Exact in-game text: the Undead bonus applies only "while Righteous Fury is not active and
        -- Hand of Reckoning is not engraved" — i.e. it is silently off for a tanking paladin. Those
        -- conditions were not in the dossier's summary.
        [6] = { spell = 1219193, src = "https://www.wowhead.com/classic/item-set=1896", spec = "RETRIBUTION", kind = "passive", note = "vs Undead only, and only while Righteous Fury is inactive and Hand of Reckoning is not engraved" },
      },
    },
    PALADIN_T35_INQUISITION = {
      name = "Inquisition Warplate (T3.5, Scarlet Enclave)", src = "https://www.wowhead.com/classic/item-set=1940",
      items = { 240027, 240025, 240030, 240023,
                240028, 240024, 240026, 240029 },
      bonuses = {
        [2] = { spell = 1226460, src = "https://www.wowhead.com/classic/item-set=1940", spec = "RETRIBUTION", kind = "aura", aura = "HOLY_POWER_BUFF",
                note = "CS/Exorcism grant Holy Power (+10% Holy dmg/stack, 3 max, 15s) with a 2H — detect via buff" },
        [4] = { spell = 1226462, src = "https://www.wowhead.com/classic/item-set=1940", spec = "RETRIBUTION", kind = "passive", note = "DS/Holy Shock/Holy Wrath consume Holy Power" },
        [6] = { spell = 1226463, src = "https://www.wowhead.com/classic/item-set=1940", spec = "RETRIBUTION", kind = "aura", aura = "TEMPLAR_BUFF",
                note = "Templar: +15% AP per Holy Power consumed, max 3 stacks, 10s" },
      },
    },
    -- PALADIN_T1_T2_CORE_FORGED is DEFERRED TO M5d, not lost. Core Forged is not a set: it is a P5
    -- stat/bonus trading mechanic (BWL stats + MC bonuses, from the Hydraxian vendors), so it has no
    -- Wowhead item-set page and no enumerable piece list — nothing to verify against, and the entry
    -- could only ever hold a placeholder id. Its one consumer is SEAL_LINGER_6S for the
    -- Stack build, which is M5d; until then that bonus comes from Soul of the Sealbearer alone.
  }

  -- ---------------------------------------------------------------------------------------------
  -- Souls / Bonuses (was Elmira_Paladin/Data/Souls.lua)
  -- ---------------------------------------------------------------------------------------------
  -- Data/SoD/Souls.lua — shoulder "Soul of the …" enchants.
  -- Detected from the shoulder TOOLTIP, matching `short` — NOT from the item link. Verified in game
  -- 2026-09-01 (docs/07 §9.10, docs/01 §5a): the link's enchant field is empty even when a soul is on
  -- the shoulder, so there is no enchant ID to carry and the old `enchantID` key has been dropped
  -- rather than left as a permanent placeholder. `short` is the localized name as it appears in the
  -- tooltip line, which makes v1 soul detection enUS-only (known limitation).
  -- `grants` lists abstract bonus keys resolved by state.bonus(); a build conditions on the bonus, not the source.
  D.Souls = {
    SOUL_OF_THE_EXILE      = { itemID = 236554, grants = { "EXORCISM_DAMAGE_SOUL" },
                               src = "https://www.wowhead.com/classic/item=236554/soul-of-the-exile", short = "Exile", roles = { "RET_EXODIN", "RET_WRATHLIKE" } },
    SOUL_OF_THE_RETRIBUTOR = { itemID = 236551, grants = { "CRUSADER_STRIKE_150" },
                               src = "https://www.wowhead.com/classic/item=236551/soul-of-the-retributor", short = "Retributor", roles = { "RET_WRATHLIKE", "RET_TWIST" } },
    SOUL_OF_THE_JUDICATOR  = { itemID = 236549, grants = { "JUDICATOR_SOUL" },
                               src = "https://www.wowhead.com/classic/item=236549/soul-of-the-judicator", short = "Judicator", roles = { "RET_TWIST" } },
    SOUL_OF_THE_SEALBEARER = { itemID = 236547, grants = { "SEAL_LINGER_6S" },
                               src = "https://www.wowhead.com/classic/item=236547/soul-of-the-sealbearer", short = "Sealbearer", roles = { "RET_STACK" }, note = "Nerfed in P8 (S1)" },
    SOUL_OF_THE_TEMPLAR    = { itemID = 236555, grants = {},
                               src = "https://www.wowhead.com/classic/item=236555/soul-of-the-templar", short = "Templar", note = "No longer works with 2H weapons (S6)" },
    SOUL_OF_THE_VINDICATOR = { itemID = 236544, grants = {}, src = "https://www.wowhead.com/classic/item=236544/soul-of-the-vindicator", short = "Vindicator", roles = { "HOLY_HEALER" } },
  }
  -- Bonus keys that can come from EITHER set pieces OR a soul. This table is the resolution
  -- source: Sets.lua thresholds do NOT carry a `bonus` key, so `from` below is what state.bonus() walks.
  D.Bonuses = {
    CRUSADER_STRIKE_150 = { note = "150% Crusader Strike damage", from = { { set = "PALADIN_T25_AVENGERS", pieces = 2 }, { soul = "SOUL_OF_THE_RETRIBUTOR" } } },
    -- Core Forged also grants this at 6 pieces, but it is not an enumerable set (see Sets.lua) and its
    -- only consumer is the M5d Stack build, so the set source is deferred with it. Soul-only for now.
    SEAL_LINGER_6S      = { note = "Both seals linger 6s after casting a second seal", from = { { soul = "SOUL_OF_THE_SEALBEARER" } } },
    JUDGEMENT_NO_CONSUME = { note = "+5% damaging Judgements; seals not consumed", from = { { set = "PALADIN_T2_JUDGEMENT", pieces = 2 } } },
    HOLY_POWER_CONSUME  = { note = "Divine Storm consumes Holy Power", from = { { set = "PALADIN_T35_INQUISITION", pieces = 4 } } },
    HOLY_WRATH_INSTANT  = { note = "Holy Wrath instant + shorter CD", from = { { set = "PALADIN_T3_REDEMPTION", pieces = 4 } } },
    EXORCISM_DAMAGE_SOUL = { note = "Exorcism damage (soul only)", from = { { soul = "SOUL_OF_THE_EXILE" } } },
    -- Effect text read from Wowhead 2026-09-01. Rotation-relevant: it moves Judgement's cooldown, so
    -- whether any shipped build should react to it is a build question, not a data one.
    JUDICATOR_SOUL      = { note = "Judgement cooldown -5s, Judgement damage -45%", from = { { soul = "SOUL_OF_THE_JUDICATOR" } } },
  }

  -- ---------------------------------------------------------------------------------------------
  -- Timing (was Elmira_Paladin/Data/Timing.lua)
  -- ---------------------------------------------------------------------------------------------
  -- Data/SoD/Timing.lua — server-side timing constants for the paladin pack.
  --
  -- These are not spell ids, but hard rule 2's reasoning applies to them exactly: they are numbers the
  -- server owns, they change on a tuning pass, and remembering one is not the same as knowing it. Every
  -- value here carries its source and the date it was checked, and an unsourced value is simply absent
  -- — which leaves the feature that needs it inert rather than mis-timed (docs/02, `seal_linger`).

  D.Timing = {
    -- How long a REPLACED seal can still proc on a swing — the twist window (docs/02 "seal_linger").
    --
    -- PROVENANCE, because this one is weaker than an id from Wowhead and must not be mistaken for it:
    -- Blizzard reintroduced seal twisting as an intentional mechanic in the 2024-04-23 hotfix, but the
    -- note says only that the old seal is "slightly extend[ed] ... for a short time" and gives NO
    -- number. 400 ms is the figure the community and every guide use, and it traces to exactly one
    -- primary artefact: the wowsims/sod simulator's own constant. Two independent readings of that
    -- source agree, and an Icy Veins guide and a published WeakAura both restate 0.4s.
    --
    -- So: sim-derived and community-corroborated, NOT Blizzard-confirmed. It is shipped because the
    -- alternative is leaving twisting permanently inert, and because nothing that ships today reads it
    -- — every build using `seal_linger` is `available = false` until M5d. Re-measure in game before
    -- any twist build goes available; docs/research/seal-twist-window.md carries the measurement
    -- procedure and the open question of whether Seal of Command lingers at all.
    -- src: https://github.com/wowsims/sod/blob/master/sim/paladin/paladin.go  (lingerDuration, read 2026-09-02)
    -- src: https://news.blizzard.com/en-us/world-of-warcraft/24057474/hotfixes-april-23-2024
    sealLingerWindow = 0.4,
  }

  -- ---------------------------------------------------------------------------------------------
  -- Catalog (was Elmira_Paladin/Data/Catalog.lua)
  -- ---------------------------------------------------------------------------------------------
  -- Data/SoD/Catalog.lua — shipped playstyle catalog read by Setup/Wizard.lua. Refresh with the
  -- build-catalog-refresh skill each phase. Dates/sources reflect what the entry was derived from.
  -- `available` gates what the wizard may offer. Only PALADIN_EXODIN ships a build file at M2; the
  -- other five are researched and dated but have no Builds/*.lua yet, and offering them would hand the
  -- user a playstyle that resolves to nil. Flip an entry to available when its build lands (M5).
  -- Enforced by tests/spec/data_sourcing_spec.lua.
  D.Catalog = {
    version = 2, flavor = "SoD", phase = "P8",  -- 2: Wrath-like shipped (2026-09-03); the wizard re-offers once
    PALADIN = {
      { build = "PALADIN_EXODIN", available = true, playstyle = "Exodin — fast 2H, single seal (Ret)", difficulty = "easy", recommended = true,
        updated = "2026-09-02", phase = "SoD P8",
        source = "https://www.wowhead.com/classic/guide/season-of-discovery/classes/paladin/dps-rotation-cooldowns-abilities-pve",
        summary = "Seal of Martyrdom, Exorcism never held, Crusader Strike; DS at 3 Holy Power with T3.5 4-set. ~20-33% ahead in Naxx; viable in SE.",
        -- `spells` mirrors the build file: Seal of Martyrdom is a level-10 book purchase, not a rune
        -- and not granted by levelling, so the wizard should warn when it is missing.
        requires = { weapon = "2H", maxSpeed = 3.0, spells = { "SEAL_OF_MARTYRDOM" },
                     runes = { "RUNE_ART_OF_WAR", "RUNE_CRUSADER_STRIKE", "RUNE_DIVINE_STORM" } } },
      { build = "PALADIN_WRATHLIKE", available = true, playstyle = "Wrath-like — slow 2H, mono seal (Ret)", difficulty = "easy",
        updated = "2026-09-03", phase = "SoD P8",
        source = "https://www.wowhead.com/classic/guide/season-of-discovery/classes/paladin/dps-rotation-cooldowns-abilities-pve",
        summary = "Seal of Martyrdom, then Divine Storm at 3 Holy Power (T3.5 4-set), Crusader Strike and Exorcism — the soul decides which first — Judgement as filler. The relaxed build; on par with the rest in P8.",
        requires = { weapon = "2H", minSpeed = 3.0, spells = { "SEAL_OF_MARTYRDOM" },
                     runes = { "RUNE_ART_OF_WAR", "RUNE_CRUSADER_STRIKE", "RUNE_DIVINE_STORM" } } },
      { build = "PALADIN_PROT", available = false, playstyle = "Protection — sword & board tank", difficulty = "easy",
        updated = "2026-08-31", phase = "SoD P8",
        source = "https://www.wowhead.com/classic/guide/season-of-discovery/classes/paladin/tank-talent-builds-runes",
        summary = "Holy Shield uptime, Shield of Righteousness + Hammer of the Righteous on cooldown, Judgement, Exorcism procs.",
        requires = { weapon = "Shield", runes = { "RUNE_HAND_OF_RECKONING" } } },
      { build = "PALADIN_SHOCKADIN", available = false, playstyle = "Shockadin — Holy caster DPS", difficulty = "medium",
        updated = "2026-08-31", phase = "SoD P8", source = "https://www.zockify.com/wowclassic/paladin/dps/",
        summary = "Seal of Righteousness, Judgement of Righteousness and Holy Shock on cooldown; JotC maintenance.",
        requires = { weapon = "1H" } },
      { build = "PALADIN_TWIST", available = false, playstyle = "Seal twisting (Ret)", difficulty = "hard", experimental = true,
        updated = "2026-08-31", phase = "SoD P8", source = "https://onlyfarms.gg/guides/season-of-discovery-paladin-dps-bis-gear-pve-guide/",
        summary = "Highest ceiling (~7-9% in SE). Swing-timer driven; experimental — watch the twist-success readout.", requires = { weapon = "2H", minSpeed = 3.0, runes = { "RUNE_CRUSADER_STRIKE", "RUNE_DIVINE_STORM" } } },
      { build = "PALADIN_STACK", available = false, playstyle = "Seal stacking (Ret)", difficulty = "medium", experimental = true,
        updated = "2026-08-31", phase = "SoD P8", source = "https://onlyfarms.gg/guides/season-of-discovery-paladin-dps-bis-gear-pve-guide/",
        summary = "Twist-like damage with fewer casts; needs Soul of the Sealbearer (or Core Forged 6-set). Experimental.",
        requires = { weapon = "2H", minSpeed = 3.0, souls = { "SOUL_OF_THE_SEALBEARER" } } },
    },
    MAGE = {
      -- Filled by build-catalog-refresh in M5.
    },
  }

  -- ---------------------------------------------------------------------------------------------
  -- Advice (was Elmira_Paladin/Data/Advice/Paladin.lua)
  -- ---------------------------------------------------------------------------------------------
  -- Data/SoD/Advice/Paladin.lua — gear-conditional recommendations per build (S1/S6). Evaluated by Core/Advisor.lua
  -- against what the player CURRENTLY has. First matching `soul` rule wins. Never assumes BiS.
  D.Advice = D.Advice or {}
  D.Advice.PALADIN = {
    PALADIN_EXODIN = {
      soul = { { pick = "SOUL_OF_THE_EXILE", reason = "Always for Exodin; boosts Exorcism (Sealbearer was nerfed)" } },
      weapon = { type = "2H", maxSpeed = 3.0, reason = "Fast 2H maximises Art of War/SoM value" },
      runes = { "RUNE_ART_OF_WAR", "RUNE_CRUSADER_STRIKE", "RUNE_DIVINE_STORM", "RUNE_PURIFYING_POWER", "RUNE_WRATH",
                "RUNE_RIGHTEOUS_VENGEANCE", "RUNE_SHEATH_OF_LIGHT", "RUNE_AURA_MASTERY" },
      ringRunes = { human = { "HOLY_SPECIALIZATION" }, default = { "HOLY_SPECIALIZATION", "WEAPON_SPECIALIZATION_MATCHING_WEAPON" } },
    },
    PALADIN_WRATHLIKE = {
      soul = { { when = { {"set","PALADIN_T25_AVENGERS", min = 2} }, pick = "SOUL_OF_THE_EXILE", reason = "Exile with Avenger's 2-set" },
               { pick = "SOUL_OF_THE_RETRIBUTOR", reason = "Retributor when not using T2.5 (also after T3.5 6-set)" } },
      weapon = { type = "2H", minSpeed = 3.0, reason = "Slow 2H: Divine Storm and Judgement of Martyrdom are not normalized" },
      -- The same eight runes as Exodin: no source gives Wrath-like a different kit (gather dossier, Runes by slot).
      runes = { "RUNE_ART_OF_WAR", "RUNE_CRUSADER_STRIKE", "RUNE_DIVINE_STORM", "RUNE_PURIFYING_POWER", "RUNE_WRATH",
                "RUNE_RIGHTEOUS_VENGEANCE", "RUNE_SHEATH_OF_LIGHT", "RUNE_AURA_MASTERY" },
      ringRunes = { human = { "HOLY_SPECIALIZATION" }, default = { "HOLY_SPECIALIZATION", "WEAPON_SPECIALIZATION_MATCHING_WEAPON" } },
    },
    PALADIN_TWIST = {
      soul = { { when = { {"set","PALADIN_T2_JUDGEMENT", min = 4} }, pick = "SOUL_OF_THE_RETRIBUTOR", reason = "With Draconic 4-set" },
               { pick = "SOUL_OF_THE_JUDICATOR", reason = "Default with Draconic 2-set" } },
      weapon = { type = "2H", minSpeed = 3.0 },
    },
    PALADIN_STACK = {
      soul = { { pick = "SOUL_OF_THE_SEALBEARER", reason = "Required for seal stacking" } },
      weapon = { type = "2H", minSpeed = 3.0 },
    },
    PALADIN_PROT = {
      soul = {},  -- TODO M2: research tank souls
      weapon = { type = "Shield" },
      runes = { "RUNE_HAND_OF_RECKONING", "RUNE_MALLEABLE_PROTECTION", "RUNE_AEGIS", "RUNE_HAMMER_OF_THE_RIGHTEOUS", "RUNE_AVENGERS_SHIELD" },
    },
    -- Cross-build warnings
    warnings = {
      { soul = "SOUL_OF_THE_TEMPLAR", when = { {"weapon","2H"} }, text = "Soul of the Templar no longer works with two-handed weapons." },
      { soul = "SOUL_OF_THE_SEALBEARER", unlessBuild = "PALADIN_STACK", text = "Sealbearer was nerfed; only Seal Stacking wants it." },
    },
  }

  -- ---------------------------------------------------------------------------------------------
  -- Builds (was Elmira_Paladin/Data/Builds/Paladin_Exodin.lua)
  -- ---------------------------------------------------------------------------------------------
  -- Paladin Exodin (fast 2H, single seal). Source: Wowhead SoD Paladin DPS Rotation (dossier S1), upd. 2025-06-06.
  -- 2026-09-02: Judgement filler + Consecration AoE promotion + seal window 3s -> 1.5s, from
  -- docs/research/exodin-filler-policy.md (wowsims/sod phase presets decoded against our own IDs).
  -- Authored per ADR-0006: BASELINE (no sets, no runes, blues) + GATED UPGRADES the addon switches on when detected.
  -- Unknown spells (un-engraved runes) are skipped by the engine automatically.
  D.Builds = D.Builds or {}
  D.Builds.PALADIN_EXODIN = {
    schema = 1, key = "PALADIN_EXODIN", name = "Paladin — Exodin (fast 2H)", class = "PALADIN", flavor = "SoD",
    notes = "Seal of Martyrdom only. Exorcism is the core button and is never held. Gear-dependent lines switch on when detected.",
    -- Advisory only: the wizard warns about these; evaluation never depends on them.
    -- Seal of Martyrdom stopped being a chest rune in Patch 1.15.3 (2024-07-09) and is now learned
    -- from a purchasable book at level 10 for well under a gold. Cheap and universally recommended, so
    -- a level 60 will almost certainly have it -- but it is a PURCHASE, not something levelling grants,
    -- and without it every entry here that needs a seal is skipped and the build has almost nothing to
    -- say. That is why it is named as a requirement rather than assumed.
    -- The book's item id is deliberately absent: it is not Wowhead-verified yet (hard rule 2).
    -- docs/research/seal-of-martyrdom-acquisition.md
    requires = { weapon = "2H", maxSpeed = 3.0, spells = { "SEAL_OF_MARTYRDOM" },
                 runes = { "RUNE_ART_OF_WAR", "RUNE_CRUSADER_STRIKE", "RUNE_DIVINE_STORM", "RUNE_PURIFYING_POWER" } },
    -- Suggested PERIPHERAL cues, not a colour table for every spell. The overlay is off by default and
    -- opted into per cue (docs/01 "Overlay.lua", PRD F16); the wizard offers this list as "recommended
    -- peripheral cues" with one-click enable and never turns any of it on by itself. Deliberately short:
    -- these are the moments worth pulling the eye back from a boss, and a longer list trains the user to
    -- ignore the screen edge. Every other spell in the rotation is served by the queue strip and the
    -- bar glow, which is why Crusader Strike and Judgement are absent here.
    visuals = {
      cues = {
        -- Exorcism is the core button and its cooldown is rune-shortened, so the reset is the single
        -- most valuable thing to notice while looking away.
        { event = "now_slot", spell = "EXORCISM", color = {0.9,0.2,0.2}, edge = "left",
          reason = "Exorcism came off cooldown" },
        -- Readiness event, not a now-slot change: the most expensive miss in the rotation, and it is
        -- invisible until damage has already been lost. Also appears in the readiness row.
        -- INERT UNTIL M5b: Overlay ships at M3, Core/Checks.lua at M5b. The wizard lists this as
        -- unavailable until then rather than offering an opt-in that could never fire (ADR-0009).
        { event = "check", key = "SEAL_DROPPED", color = {1.0,1.0,1.0}, edge = "bottom",
          reason = "Seal dropped", peripheral = true },
        -- Only meaningful with the T3.5 4-set, which is what makes Divine Storm consume Holy Power;
        -- the wizard hides a cue whose gating bonus the character does not have.
        { event = "now_slot", spell = "DIVINE_STORM", color = {0.3,0.6,1.0}, edge = "right",
          requiresBonus = "HOLY_POWER_CONSUME", reason = "Divine Storm at 3 Holy Power" },
      },
    },
    entries = {
      ---------------------------------------------------------------- always
      { spell = "SEAL_OF_MARTYRDOM", when = { {"no_seal"} }, label = "Seal up" },

      ---------------------------------------------------------------- burst cooldowns (gear-aware)
      -- With T3.5 2-set: wait for 3 Holy Power. Without it: use on Vengeance as soon as ready.
      { spell = "AVENGING_WRATH", hold = true, label = "Burst",
        when = { {"buff","VENGEANCE_BUFF"},
                 {"any", {"buff","HOLY_POWER_BUFF", min = 3}, {"not", {"set","PALADIN_T35_INQUISITION", min = 2}}} } },
      { spell = "AURA_MASTERY", hold = true, label = "with AW", when = { {"buff","AVENGING_WRATH_BUFF"} } },

      ---------------------------------------------------------------- Judgement (gear-aware)
      -- UPGRADE: T2 Draconic 2-set -> Judgement never consumes the seal -> on cooldown.
      { spell = "JUDGEMENT", label = "Draconic 2p", when = { {"bonus","JUDGEMENT_NO_CONSUME"} } },
      -- BASELINE: judge only when the seal is about to expire, then reseal (next slot shows Seal up).
      -- 1.5s, not the 3s this carried before: wowsims/sod uses 1-1.5s in every preset that has this
      -- line, and no source was found for 3. A wider window judges the seal off earlier than it needs
      -- to be, which costs seal uptime for nothing.
      { spell = "JUDGEMENT", label = "Seal expiring", when = { {"seal","SEAL_OF_MARTYRDOM"}, {"buff","SEAL_OF_MARTYRDOM", maxRemaining = 1.5} } },

      ---------------------------------------------------------------- UPGRADE: T3.5 4-set consumes Holy Power
      { spell = "DIVINE_STORM", label = "3 HP", when = { {"buff","HOLY_POWER_BUFF", min = 3}, {"bonus","HOLY_POWER_CONSUME"} } },

      ---------------------------------------------------------------- BASELINE core (valid with zero sets)
      { spell = "EXORCISM" },          -- baseline ability in P8; never held
      { spell = "CRUSADER_STRIKE" },   -- rune; skipped if not engraved

      ---------------------------------------------------------------- UPGRADE: Naxx — T3 Redemption 4-set makes Holy Wrath instant/short CD
      { spell = "HOLY_WRATH", label = "Naxx", when = { {"bonus","HOLY_WRATH_INSTANT"}, {"any", {"target_type","Undead","Demon"}, {"rune","RUNE_PURIFYING_POWER"}} } },

      { spell = "DIVINE_STORM" },      -- rune; below CS by default (fast weapon)

      ---------------------------------------------------------------- AoE helper only when Holy Power exists
      { spell = "CONSECRATION", label = "AoE, 3 HP", when = { {"buff","HOLY_POWER_BUFF", min = 3}, {"cooldown_gt","DIVINE_STORM", 1} } },

      ---------------------------------------------------------------- AoE: PROMOTE Consecration on 3+ targets
      -- A promotion, not a gate. The baseline entry below still allows single-target Consecration:
      -- wowsims/sod never target-count-gates its baseline eligibility in any phase preset, so
      -- restricting it would remove value no source supports removing (docs/research/
      -- exodin-filler-policy.md Q2).
      -- Inert until nameplate counting lands at M5a: Adapters/Vanilla.lua's state:enemies() returns a
      -- hardcoded 1, so `enemies min 3` is false everywhere today. A safe no-op, not a bug -- but it
      -- means this line cannot be verified in game yet.
      { spell = "CONSECRATION", label = "AoE (3+ targets)", when = { {"enemies", min = 3}, {"resource","MANA", minPct = 40} } },

      ---------------------------------------------------------------- BASELINE filler: Judgement when nothing better is ready
      -- No set or rune gate, deliberately. An entry is skipped while its spell is on cooldown, so a
      -- bottom-of-list Judgement self-throttles by list POSITION alone: it fires nearly every global
      -- for a fresh 60 with no runes (~28 idle GCDs a minute, because Crusader Strike and Divine Storm
      -- are runes and Exorcism is on 15s without Art of War) and almost never at T3 4pc + full runes,
      -- where the list already fills 94% of the GCD budget. That is exactly the split in wowsims/sod's
      -- own presets -- p8-wrath (slow weapon, idle globals) keeps a Judgement filler, p8-exodin (fast
      -- weapon, saturated) omits it -- arrived at with no gear condition at all.
      -- Judging consumes the seal without the T2 2-set, so "Seal up" at the top of the list re-applies
      -- it on the next global. That 2-GCD round trip is only worth paying when a global would
      -- otherwise be idle, which is precisely when this entry is reachable.
      -- POSITION: the dossier said "before the Consecration entries". Placed below the two AoE ones
      -- instead -- above `AoE, 3 HP` it would shadow that entry on every global the seal is up and
      -- silently kill it. Above the plain filler is what the sim evidence actually says (p8-wrath
      -- ranks Judgement-filler over Consecration-filler).
      { spell = "JUDGEMENT", label = "Filler (nothing else ready)", when = { {"seal","SEAL_OF_MARTYRDOM"} } },

      ---------------------------------------------------------------- BASELINE filler
      -- minPct = 40 is UNSOURCED: it predates this research and nothing corroborates the number.
      -- Left alone rather than replaced with another guess. Flagged for testing.
      { spell = "CONSECRATION", when = { {"resource","MANA", minPct = 40} } },
      { item  = 13, hold = true, label = "Trinket", when = { {"item_ready", 13} } },
      { item  = 14, hold = true, label = "Trinket", when = { {"item_ready", 14} } },
    },
  }

  -- Paladin Wrath-like (slow 2H, single seal). BiS side: Wowhead SoD Paladin DPS Rotation, modified
  -- 2025-06-06 (docs/research/wowhead/paladin-dps-rotation-cooldowns-abilities-pve.md); Default side:
  -- Icy Veins Ret rotation, 2025-04-08. Gate list W1-W5: docs/research/paladin-p8-gather-ret.md.
  -- Authored per ADR-0013: written for the same eight runes as Exodin; every set- or soul-dependent line
  -- is gated and the engine detects what is actually engraved and worn. Wowhead: "the rotation is
  -- largely the same without [T3.5]", and it "fully comes online with Tier 3.5 Inquisition gear".
  D.Builds.PALADIN_WRATHLIKE = {
    schema = 1, key = "PALADIN_WRATHLIKE", name = "Paladin — Wrath-like (slow 2H)", class = "PALADIN", flavor = "SoD",
    notes = "One seal, a simple priority, a slow two-hander. The shoulder soul decides the order: with Soul of the Exile, Exorcism before Crusader Strike; otherwise Crusader Strike first. Judgement is the filler.",
    -- Advisory only (ADR-0013: the wizard's shopping list; evaluation never depends on it). minSpeed 3.0
    -- is the shared slow-weapon floor; Wowhead gives Wrath-like no explicit speed range of its own.
    requires = { weapon = "2H", minSpeed = 3.0, spells = { "SEAL_OF_MARTYRDOM" },
                 runes = { "RUNE_ART_OF_WAR", "RUNE_CRUSADER_STRIKE", "RUNE_DIVINE_STORM", "RUNE_PURIFYING_POWER" } },
    visuals = {
      cues = {
        -- The one moment worth a glance away: 3 Holy Power with the 4-set, Divine Storm to the top.
        { event = "now_slot", spell = "DIVINE_STORM", color = {0.3,0.6,1.0}, edge = "right",
          requiresBonus = "HOLY_POWER_CONSUME", reason = "Divine Storm at 3 Holy Power" },
        { event = "check", key = "SEAL_DROPPED", color = {1.0,1.0,1.0}, edge = "bottom",
          reason = "Seal dropped", peripheral = true },
      },
    },
    entries = {
      ---------------------------------------------------------------- always
      { spell = "SEAL_OF_MARTYRDOM", when = { {"no_seal"} }, label = "Seal up" },

      ---------------------------------------------------------------- burst: Wowhead's opener is identical to Exodin's
      { spell = "AVENGING_WRATH", hold = true, label = "Burst",
        when = { {"buff","VENGEANCE_BUFF"},
                 {"any", {"buff","HOLY_POWER_BUFF", min = 3}, {"not", {"set","PALADIN_T35_INQUISITION", min = 2}}} } },
      { spell = "AURA_MASTERY", hold = true, label = "with AW", when = { {"buff","AVENGING_WRATH_BUFF"} } },

      ---------------------------------------------------------------- W3: T2 Draconic 2-set -> Judgement on cooldown, no reseal
      { spell = "JUDGEMENT", label = "Draconic 2p", when = { {"bonus","JUDGEMENT_NO_CONSUME"} } },
      -- Judge a seal that is about to fall off rather than let it drop (then "Seal up" re-applies it).
      -- Not gear-dependent; same 1.5s window as Exodin (wowsims/sod presets, docs/research/exodin-filler-policy.md).
      { spell = "JUDGEMENT", label = "Seal expiring", when = { {"seal","SEAL_OF_MARTYRDOM"}, {"buff","SEAL_OF_MARTYRDOM", maxRemaining = 1.5} } },

      ---------------------------------------------------------------- W4: T3.5 4-set -> Divine Storm at 3 Holy Power is the top priority
      { spell = "DIVINE_STORM", label = "3 HP", when = { {"buff","HOLY_POWER_BUFF", min = 3}, {"bonus","HOLY_POWER_CONSUME"} } },

      ---------------------------------------------------------------- W5: without T3.5, Consecration is promoted on large pulls
      -- Wowhead: "If you don't yet have T3.5 then you can cast Consecration at a higher priority for
      -- large pulls, that's it." With T3.5 the AoE rotation makes "zero changes". Inert until nameplate
      -- counting lands at M5a (state:enemies() is a hardcoded 1 today), exactly like Exodin's AoE line.
      { spell = "CONSECRATION", label = "AoE, no T3.5",
        when = { {"not", {"set","PALADIN_T35_INQUISITION", min = 2}}, {"enemies", min = 3}, {"resource","MANA", minPct = 40} } },

      ---------------------------------------------------------------- W1: Soul of the Exile -> Exorcism before Crusader Strike
      -- Detected through the effect the soul grants (EXORCISM_DAMAGE_SOUL, ADR-0004), not the item.
      { spell = "EXORCISM", label = "Exile: Exorcism first", when = { {"bonus","EXORCISM_DAMAGE_SOUL"} } },

      ---------------------------------------------------------------- BASELINE core (W2 order: Crusader Strike, then Exorcism)
      { spell = "CRUSADER_STRIKE" },   -- rune; skipped if not engraved
      { spell = "EXORCISM" },          -- baseline ability in P8
      -- Wowhead's Wrath-like table lists Divine Storm only at 3 Holy Power; wowsims/sod's p8-wrath preset
      -- keeps it as a plain priority below Crusader Strike/Exorcism, which is what this line encodes.
      -- Residual per ADR-0013 §1: recorded in the gather dossier, alternative exposed in the editor.
      { spell = "DIVINE_STORM" },      -- rune; skipped if not engraved

      ---------------------------------------------------------------- BASELINE filler: "cast Judgement and instantly refresh Seal of Martyrdom"
      -- Below the core abilities so it self-throttles by list position: it fires on the idle globals a
      -- slow two-hander leaves, and almost never once T3.5 fills the GCD budget.
      { spell = "JUDGEMENT", label = "Filler (then reseal)", when = { {"seal","SEAL_OF_MARTYRDOM"} } },

      ---------------------------------------------------------------- BASELINE filler
      -- minPct = 40 mirrors Exodin's line and is equally unsourced there; kept identical on purpose.
      { spell = "CONSECRATION", when = { {"resource","MANA", minPct = 40} } },
      { item  = 13, hold = true, label = "Trinket", when = { {"item_ready", 13} } },
      { item  = 14, hold = true, label = "Trinket", when = { {"item_ready", 14} } },
    },
  }

  -- The spec handed to API.RegisterDataPack. Field-for-field what Elmira_Paladin/Register.lua built,
  -- minus its "did the data files load?" guard: the data is now lexically in this function, so it
  -- cannot be half-present the way seven separately-loaded TOC entries could.
  return {
    class = "PALADIN", flavor = "SoD",
    spells = D.Spells, sets = D.Sets, souls = D.Souls, bonuses = D.Bonuses,
    builds = D.Builds, catalog = D.Catalog, advice = D.Advice,
    -- Absent constant = feature inert, never a default guess (was Data/Timing.lua). The old
    -- `D.Timing and ...` guard is gone with the folder: seven separately-loaded TOC entries could be
    -- half-present, one lexical scope cannot, so that branch was now unreachable and untestable.
    sealLingerWindow = D.Timing.sealLingerWindow,
    -- The wizard re-offers itself once when this rises (docs/01 §5b). It lives on the catalog table,
    -- so a refresh that bumps it cannot forget to bump this.
    catalogVersion = D.Catalog.version,
  }
end)
