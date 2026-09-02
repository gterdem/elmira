-- Data/SoD/Spells.lua — symbolic key -> spell record. Every id is verified and carries its `src`.
-- Keys never change across flavors; IDs do. Prot/Shockadin abilities, the four unused seals and
-- DIVINE_FAVOR_BUFF are deliberately absent: they return at M5 with the builds that need them.
local ADDON, ns = ...

ns.Data = ns.Data or {}
ns.Data.SoD = ns.Data.SoD or {}
ns.Data.SoD.Spells = {
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
