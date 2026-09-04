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
    SHIELD_OF_RIGHTEOUSNESS = { id = 440658, src = "https://www.wowhead.com/classic/spell=440658/shield-of-righteousness", cooldown = 6 },
    -- No `cost`: Wowhead states "26% of base mana", and a percentage is not a usable fallback.
    AVENGERS_SHIELD         = { id = 407669, src = "https://www.wowhead.com/classic/spell=407669/avengers-shield", cooldown = 15 }, -- "Cooldown: 15 seconds" on the page
    HAMMER_OF_THE_RIGHTEOUS = { id = 407632, src = "https://www.wowhead.com/classic/spell=407632/hammer-of-the-righteous", cooldown = 6 }, -- "6% of base mana": no cost
    HOLY_SHIELD             = { id = 20928,  src = "https://www.wowhead.com/classic/spell=20928/holy-shield", cost = { mana = 150 }, cooldown = 10 }, -- max rank; the self-buff is gated by this key
    RIGHTEOUS_FURY          = { id = 25780,  src = "https://www.wowhead.com/classic/spell=25780/righteous-fury" },
    -- Protection runes (ability ids, see the rule above). Slots per Wowhead's P8 tank Talents & Runes page.
    -- No HAND_OF_RECKONING or DIVINE_PROTECTION ability records: the queue cannot see threat or the
    -- player's health, so no entry names them (see the Prot build's notes), and a record nothing reads
    -- is exactly the debt the mutation gate exists to refuse. Their ids live on the rune records below
    -- (Hand of Reckoning IS its rune's ability; Divine Protection 458371 is Malleable Protection's,
    -- pending the owner's /dump) and in docs/staging/data/m5-prot-ids-v2.lua. Likewise Guarded by the
    -- Light (415059): a leveling/farm rune Wowhead says never to run over Art of War in raids; it
    -- arrives with the leveling builds that want it.
    RUNE_HAND_OF_RECKONING       = { id = 407631, src = "https://www.wowhead.com/classic/spell=407631/hand-of-reckoning", rune = "hands" },
    RUNE_SHIELD_OF_RIGHTEOUSNESS = { id = 440658, src = "https://www.wowhead.com/classic/spell=440658/shield-of-righteousness", rune = "back" },
    RUNE_AVENGERS_SHIELD         = { id = 407669, src = "https://www.wowhead.com/classic/spell=407669/avengers-shield", rune = "legs" },
    RUNE_HAMMER_OF_THE_RIGHTEOUS = { id = 407632, src = "https://www.wowhead.com/classic/spell=407632/hammer-of-the-righteous", rune = "wrist" },
    RUNE_AEGIS                   = { id = 425589, src = "https://www.wowhead.com/classic/spell=425589/aegis", rune = "chest" },
    -- 458318 over 426174 is the weaker of the resolutions (both are "Malleable Protection" passives;
    -- the guide's Divine Protection text links 458318). Checklist step 4 reads the slot to settle it.
    RUNE_MALLEABLE_PROTECTION    = { id = 458318, src = "https://www.wowhead.com/classic/spell=458318/malleable-protection", rune = "waist" },
    RUNE_IMPROVED_SANCTUARY      = { id = 429133, src = "https://www.wowhead.com/classic/spell=429133/improved-sanctuary", rune = "head" },
    -- Shockadin (M5, theorycraft build -- ADR-0013 §6). Verified 2026-09-03, docs/staging/data/m5-shockadin-ids.lua.
    SEAL_OF_RIGHTEOUSNESS   = { id = 20289,  src = "https://www.wowhead.com/classic/spell=20289/seal-of-righteousness", seal = true, cost = { mana = 90 } }, -- Shockadin's seal
    HOLY_SHOCK              = { id = 20473,  src = "https://www.wowhead.com/classic/spell=20473/holy-shock", cost = { mana = 225 }, cooldown = 30 }, -- Holy talent, not a rune
    -- Back slot: shares it with RUNE_RIGHTEOUS_VENGEANCE (every Ret build) and RUNE_SHIELD_OF_RIGHTEOUSNESS (Prot).
    RUNE_SHOCK_AND_AWE      = { id = 440791, src = "https://www.wowhead.com/classic/spell=440791/shock-and-awe", rune = "back" },
    -- Execute (< 20% HP), trained. Max rank 24239 (425 mana); 24275 is a lower rank. Verified 2026-09-03
    -- (docs/staging/data/m5-ret-additions.lua). Consumed by Exodin's execute line.
    HAMMER_OF_WRATH         = { id = 24239,  src = "https://www.wowhead.com/classic/spell=24239/hammer-of-wrath", cost = { mana = 425 }, cooldown = 6 },
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
    -- The HOLY T3.5 set -- a different item-set from the Ret Warplate above (1963 vs 1940), with its
    -- own pieces and bonuses. Its 2-set only generates Holy Power "while Shock and Awe is active".
    -- ASSUMED, not verified: that it applies the SAME Holy Power aura (1226461) as the Ret 2-set. The
    -- text is identical ("+10% Holy damage per stack, 3 max") but 1226461 is sourced only against the
    -- Ret set, and the Holy bonus spell (1240571) is a server-side dummy on Wowhead. If the Holy set
    -- applies a different aura, every Shockadin "3 HP" line silently never fires -- which is why the
    -- build ships experimental and why m5-dumps.md step 9d exists. Do not promote it before that dump.
    -- The 4-set spell id (1226462) is the same number Wowhead attaches to the Ret 4-set: taken as
    -- fetched from item-set=1963 and unconfirmed as a distinct effect; runtime never reads it (bonus()
    -- counts equipped pieces against each set's own item list), so nothing depends on it.
    -- The 6-set is weapon-dependent (+8% spell power per stack with a one-hander, +18% with a
    -- two-hander) -- the reason the catalog no longer demands a 1H.
    PALADIN_T35_INQUISITION_HOLY = {
      name = "Inquisition Shockplate (T3.5 Holy, Scarlet Enclave)", src = "https://www.wowhead.com/classic/item-set=1963/inquisition-shockplate",
      items = { 246062, 246061, 246060, 246059,
                246058, 246057, 246056, 246055 },
      bonuses = {
        [2] = { spell = 1240571, src = "https://www.wowhead.com/classic/item-set=1963/inquisition-shockplate", spec = "HOLY", kind = "aura", aura = "HOLY_POWER_BUFF",
                verify = "in-game", note = "While Shock and Awe is active, CS/Exorcism grant Holy Power (+10% Holy dmg/stack, 3 max) — aura ASSUMED shared with the Ret 2-set" },
        [4] = { spell = 1226462, src = "https://www.wowhead.com/classic/item-set=1963/inquisition-shockplate", spec = "HOLY", kind = "passive",
                note = "Divine Storm, Holy Shock and Holy Wrath consume Holy Power, +100%/stack" },
        [6] = { spell = 1240573, src = "https://www.wowhead.com/classic/item-set=1963/inquisition-shockplate", spec = "HOLY", kind = "passive",
                note = "+8% spell power per Holy Power consumed (1H) / +18% (2H), 10s" },
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
    -- Distinct from the Judicator (236549): Wowhead names them separately throughout the twisting
    -- section -- Justicar = the Draconic 2-set effect, Judicator = the 4-set effect. `short` is NOT yet
    -- read from a shoulder tooltip (id verification inferred it from the naming pattern); souls are
    -- detected by that tooltip line, so until the owner confirms it (m5-dumps.md) this soul may
    -- silently fail to detect. verify = "in-game" marks exactly that.
    SOUL_OF_THE_JUSTICAR   = { itemID = 236548, grants = { "JUDGEMENT_NO_CONSUME" },
                               src = "https://www.wowhead.com/classic/item=236548/soul-of-the-justicar", short = "Justicar", verify = "in-game", roles = { "RET_TWIST", "RET_STACK" } },
    SOUL_OF_THE_JUDICATOR  = { itemID = 236549, grants = { "JUDICATOR_SOUL" },
                               src = "https://www.wowhead.com/classic/item=236549/soul-of-the-judicator", short = "Judicator", roles = { "RET_TWIST" } },
    SOUL_OF_THE_SEALBEARER = { itemID = 236547, grants = { "SEAL_LINGER_6S" },
                               src = "https://www.wowhead.com/classic/item=236547/soul-of-the-sealbearer", short = "Sealbearer", roles = { "RET_STACK" }, note = "Nerfed in P8 (S1)" },
    SOUL_OF_THE_TEMPLAR    = { itemID = 236555, grants = {},
                               src = "https://www.wowhead.com/classic/item=236555/soul-of-the-templar", short = "Templar", note = "No longer works with 2H weapons (S6)" },
    SOUL_OF_THE_VINDICATOR = { itemID = 236544, grants = {}, src = "https://www.wowhead.com/classic/item=236544/soul-of-the-vindicator", short = "Vindicator", roles = { "HOLY_HEALER" } },
    -- Prot's soul (Wowhead tank guide: one of "our strongest damage dealing options, while also not
    -- editing our rotation"). Its effect changes how Holy Shield behaves, not when to press it.
    SOUL_OF_THE_RADIANT_DEFENDER = { itemID = 236532, grants = { "HOLY_SHIELD_UNLIMITED" },
                               src = "https://www.wowhead.com/classic/item=236532/soul-of-the-radiant-defender", short = "Radiant Defender", roles = { "PROT" } },
  }
  -- Bonus keys that can come from EITHER set pieces OR a soul. This table is the resolution
  -- source: Sets.lua thresholds do NOT carry a `bonus` key, so `from` below is what state.bonus() walks.
  D.Bonuses = {
    CRUSADER_STRIKE_150 = { note = "150% Crusader Strike damage", from = { { set = "PALADIN_T25_AVENGERS", pieces = 2 }, { soul = "SOUL_OF_THE_RETRIBUTOR" } } },
    -- Core Forged also grants this at 6 pieces, but it is not an enumerable set (see Sets.lua) and its
    -- only consumer is the M5d Stack build, so the set source is deferred with it. Soul-only for now.
    SEAL_LINGER_6S      = { note = "Both seals linger 6s after casting a second seal", from = { { soul = "SOUL_OF_THE_SEALBEARER" } } },
    -- Two sources, as Wowhead states it ("Draconic 2-set bonus, or Soul of the Justicar"): the effect
    -- is what the builds gate on, never which of the two provides it (ADR-0004).
    JUDGEMENT_NO_CONSUME = { note = "+5% damaging Judgements; seals not consumed", from = { { set = "PALADIN_T2_JUDGEMENT", pieces = 2 }, { soul = "SOUL_OF_THE_JUSTICAR" } } },
    HOLY_POWER_CONSUME  = { note = "Divine Storm consumes Holy Power", from = { { set = "PALADIN_T35_INQUISITION", pieces = 4 } } },
    -- The Holy set's twin of the line above. Kept separate on purpose: the spenders differ (Holy Shock
    -- and Holy Wrath join Divine Storm), so a build must not confuse the two 4-sets.
    HOLY_POWER_CONSUME_HOLY = { note = "Divine Storm/Holy Shock/Holy Wrath consume Holy Power (Holy T3.5 4-set)", from = { { set = "PALADIN_T35_INQUISITION_HOLY", pieces = 4 } } },
    HOLY_WRATH_INSTANT  = { note = "Holy Wrath instant + shorter CD", from = { { set = "PALADIN_T3_REDEMPTION", pieces = 4 } } },
    EXORCISM_DAMAGE_SOUL = { note = "Exorcism damage (soul only)", from = { { soul = "SOUL_OF_THE_EXILE" } } },
    -- Effect text read from Wowhead 2026-09-01. Rotation-relevant: it moves Judgement's cooldown, so
    -- whether any shipped build should react to it is a build question, not a data one.
    JUDICATOR_SOUL      = { note = "Judgement cooldown -5s, Judgement damage -45%", from = { { soul = "SOUL_OF_THE_JUDICATOR" } } },
    -- Wowhead also names the Lawbringer (T1) 6-set as a second route to this effect (bonus spell lead
    -- 456541, unverified); it is not an enumerable set in Sets.lua yet, so soul-only for now.
    HOLY_SHIELD_UNLIMITED = { note = "Holy Shield has no charges and scales with block value", from = { { soul = "SOUL_OF_THE_RADIANT_DEFENDER" } } },
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
    version = 4, flavor = "SoD", phase = "P8",  -- 4: Wrath-like, Protection and Shockadin (experimental) shipped 2026-09-03; the wizard re-offers once
    PALADIN = {
      { build = "PALADIN_EXODIN", available = true, playstyle = "Exodin — fast 2H, single seal (Ret)", difficulty = "easy", recommended = true,
        updated = "2026-09-03", phase = "SoD P8",
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
      { build = "PALADIN_PROT", available = true, playstyle = "Protection — sword & board tank", difficulty = "easy",
        updated = "2026-09-03", phase = "SoD P8",
        source = "https://www.wowhead.com/classic/guide/season-of-discovery/classes/paladin/tank-rotation-cooldowns-abilities-pve",
        summary = "Holy Shield and Righteous Fury always up, then Hammer of the Righteous, Shield of Righteousness, Exorcism and Avenger's Shield on cooldown. Needs its runes: Hand of Reckoning is the only taunt a paladin has.",
        requires = { weapon = "1H", spells = { "SEAL_OF_MARTYRDOM" },
                     runes = { "RUNE_HAND_OF_RECKONING", "RUNE_MALLEABLE_PROTECTION", "RUNE_HAMMER_OF_THE_RIGHTEOUS",
                              "RUNE_SHIELD_OF_RIGHTEOUSNESS", "RUNE_AVENGERS_SHIELD", "RUNE_AEGIS" } } },
      -- THEORYCRAFT (ADR-0013 §6): the only published Shockadin guide is Phase 2 / level 40. Offered as
      -- experimental so the wizard says so; `source` is that guide because it is what the loop came from.
      { build = "PALADIN_SHOCKADIN", available = true, experimental = true, playstyle = "Shockadin — Holy caster DPS", difficulty = "medium",
        updated = "2026-09-03", phase = "SoD P8",
        source = "https://www.wowhead.com/classic/guide/shockadin-the-holy-spellslinger-phase-2-season-of-discovery-23293",
        summary = "Theorycrafted for Phase 8 — no published endgame guide. Holy Shock and Exorcism on cooldown, Judgement of Righteousness, Crusader Strike when runed; spend 3 Holy Power with the Holy T3.5 4-set. Two-handers scale best with the 6-set.",
        requires = { spells = { "HOLY_SHOCK" }, runes = { "RUNE_SHOCK_AND_AWE", "RUNE_CRUSADER_STRIKE", "RUNE_INFUSION_OF_LIGHT" } } },
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
      soul = { { pick = "SOUL_OF_THE_RADIANT_DEFENDER", reason = "Holy Shield loses its charges and scales with block value" } },
      weapon = { type = "1H", reason = "Sword and board: block value drives Shield of Righteousness" },
      -- Wowhead's P8 kit, all ten slots (docs/research/sod-paladin-damage-model.md, Protection section).
      runes = { "RUNE_HAND_OF_RECKONING", "RUNE_MALLEABLE_PROTECTION", "RUNE_AEGIS", "RUNE_HAMMER_OF_THE_RIGHTEOUS",
                "RUNE_AVENGERS_SHIELD", "RUNE_SHIELD_OF_RIGHTEOUSNESS", "RUNE_IMPROVED_SANCTUARY", "RUNE_ART_OF_WAR" },
      ringRunes = { default = { "DEFENSE_SPECIALIZATION", "HOLY_SPECIALIZATION" } },
    },
    PALADIN_SHOCKADIN = {
      soul = {},  -- no soul is sourced for a Holy caster DPS; none is guessed
      weapon = { type = "2H", reason = "Holy T3.5 6-set: +18% spell power per Holy Power with a 2H, +8% with a 1H" },
      runes = { "RUNE_SHOCK_AND_AWE", "RUNE_CRUSADER_STRIKE", "RUNE_INFUSION_OF_LIGHT" },
      ringRunes = { default = { "HOLY_SPECIALIZATION" } },  -- Holy spell hit; the P2 guide's pick, nothing newer contradicts it
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

      -- Naxxramas (T3.5 2-set + T3 Redemption 6-set, no Holy Power consumed): Wowhead wants Divine Storm
      -- below Exorcism. That is already this list's shape -- the "3 HP" line above needs the 4-set,
      -- so with the 2-set only the baseline Divine Storm below Crusader Strike is what fires. No extra
      -- line; recorded here so the gather's G5 is not re-reported as missing.
      ---------------------------------------------------------------- UPGRADE: Naxx — T3 Redemption 4-set makes Holy Wrath instant/short CD
      { spell = "HOLY_WRATH", label = "Naxx", when = { {"bonus","HOLY_WRATH_INSTANT"}, {"any", {"target_type","Undead","Demon"}, {"rune","RUNE_PURIFYING_POWER"}} } },

      { spell = "DIVINE_STORM" },      -- rune; below CS by default (fast weapon)

      ---------------------------------------------------------------- execute (Default side; Wowhead's per-build tables omit it)
      -- Icy Veins lists Hammer of Wrath twice at the bottom of its priority (below 20% health); Wowhead
      -- names it only in the ability reference. A residual per ADR-0013 §1: kept, placed under the core
      -- so it never displaces a Holy Power generator, above the fillers it beats. With the Improved
      -- Hammer of Wrath wrist rune (429152, docs/staging/data/m5-ret-additions.lua) it is instant and
      -- self-resetting under 10% -- but that rune shares the wrist with Purifying Power, so it is the
      -- player's choice, not the build's, and it ships as data only once advice can name an alternative.
      { spell = "HAMMER_OF_WRATH", label = "Execute", when = { {"target_hp", maxPct = 20} } },

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

  -- Paladin Protection (sword and board tank). BiS side: Wowhead SoD Paladin Tank Rotation, modified
  -- 2025-04-18 (docs/research/wowhead/paladin-tank-rotation-cooldowns-abilities-pve.md) with the owner's
  -- reads of its Overview and Talents & Runes pages; Default side: Icy Veins Prot rotation, 2025-04-08.
  -- Gate list: docs/research/paladin-p8-gather-prot-shockadin.md. Mechanism: docs/research/paladin-prot-how-tanking-works.md.
  -- Authored per ADR-0013: WRITTEN for its runes -- in SoD the runes are what make a paladin a tank at
  -- all (Hand of Reckoning is the only taunt) -- and the engine still evaluates what is engraved: an
  -- un-engraved rune's ability is unknown and skipped. Nothing here assumes gear.
  D.Builds.PALADIN_PROT = {
    schema = 1, key = "PALADIN_PROT", name = "Paladin — Protection (sword & board)", class = "PALADIN", flavor = "SoD",
    notes = "Keep Holy Shield and Righteous Fury up, Seal of Martyrdom on, then Hammer of the Righteous, Shield of Righteousness, Exorcism and Avenger's Shield on cooldown, Judgement as filler. Taunt (Hand of Reckoning) and Divine Protection are yours to call: the queue cannot see threat or your health.",
    -- Advisory (ADR-0013): the wizard's shopping list. Wowhead tags Hand of Reckoning MANDATORY; the
    -- rest are the P8 kit. The shield itself cannot be expressed here (weapon checks read the main hand).
    requires = { weapon = "1H", spells = { "SEAL_OF_MARTYRDOM" },
                 runes = { "RUNE_HAND_OF_RECKONING", "RUNE_MALLEABLE_PROTECTION", "RUNE_HAMMER_OF_THE_RIGHTEOUS",
                          "RUNE_SHIELD_OF_RIGHTEOUSNESS", "RUNE_AVENGERS_SHIELD", "RUNE_AEGIS" } },
    visuals = {
      cues = {
        -- The one thing a tank must not let lapse; both guides open every list with it.
        { event = "now_slot", spell = "HOLY_SHIELD", color = {1.0,0.85,0.2}, edge = "top",
          reason = "Holy Shield is down" },
        { event = "check", key = "SEAL_DROPPED", color = {1.0,1.0,1.0}, edge = "bottom",
          reason = "Seal dropped", peripheral = true },
      },
    },
    entries = {
      ---------------------------------------------------------------- always up
      -- With Hand of Reckoning known, Righteous Fury "will remain active until cancelled", so this
      -- line is quiet in practice and loud exactly when it matters (after a death, or a forgotten stance).
      { spell = "RIGHTEOUS_FURY", when = { {"no_buff","RIGHTEOUS_FURY"} }, label = "Threat on" },
      { spell = "SEAL_OF_MARTYRDOM", when = { {"no_seal"} }, label = "Seal up" },
      -- "Always have this active before you engage with an enemy and always reapply it on cooldown."
      { spell = "HOLY_SHIELD", when = { {"no_buff","HOLY_SHIELD"} }, label = "Keep up" },

      ---------------------------------------------------------------- pull: Avenging Wrath as soon as it is ready
      -- Wowhead frames it as pull consistency ("better to use this ASAP on a pull in order to facilitate
      -- a better threat curve"), not burst timing -- so no Vengeance/Holy Power gate as in the Ret builds.
      { spell = "AVENGING_WRATH", hold = true, label = "Threat burst", when = { {"in_combat"} } },

      ---------------------------------------------------------------- AoE (3+): Wowhead's separate AoE list promotes these two
      -- Inert until nameplate counting lands at M5a (state:enemies() is a hardcoded 1), like every
      -- `enemies` line in the paladin pack.
      { spell = "AVENGERS_SHIELD", label = "AoE", when = { {"enemies", min = 3} } },
      { spell = "CONSECRATION", label = "AoE", when = { {"enemies", min = 3}, {"resource","MANA", minPct = 30} } },

      ---------------------------------------------------------------- a seal about to fall off outranks the core
      -- Same placement as the Ret builds. Below the core it could only fire with all four core buttons
      -- on cooldown at once, so the seal would drop before the queue ever said so (found by the
      -- scenario that tried it). Judging it and resealing costs two globals; losing Martyrdom's
      -- on-hit threat for a swing or two costs more.
      { spell = "JUDGEMENT", label = "Seal expiring", when = { {"seal","SEAL_OF_MARTYRDOM"}, {"buff","SEAL_OF_MARTYRDOM", maxRemaining = 1.5} } },

      ---------------------------------------------------------------- single-target core, in Wowhead's order
      { spell = "HAMMER_OF_THE_RIGHTEOUS" },   -- wrist rune; "our strongest threat generating ability"
      { spell = "SHIELD_OF_RIGHTEOUSNESS" },   -- back rune; block value + Holy
      { spell = "EXORCISM" },
      { spell = "AVENGERS_SHIELD" },           -- legs rune; "good single- and multi-target"
      -- The chest is a choice: Aegis (passive, the default) or Divine Storm, "the swap-in for threat"
      -- on cleave. Only reachable when the character engraved Divine Storm; skipped otherwise.
      { spell = "DIVINE_STORM", label = "chest: Divine Storm", when = { {"enemies", min = 2} } },
      -- Holy Wrath on AoE, Undead/Demon only unless Purifying Power (Prot's wrist is usually Hammer of
      -- the Righteous, so in practice this is Naxxramas). Wowhead: not while being attacked, because of
      -- pushback -- the queue cannot see that; the entry stays low and the player judges the moment.
      { spell = "HOLY_WRATH", label = "AoE", when = { {"enemies", min = 3}, {"any", {"target_type","Undead","Demon"}, {"rune","RUNE_PURIFYING_POWER"}} } },

      ---------------------------------------------------------------- Judgement as filler, then reseal (Wowhead's step 6)
      { spell = "JUDGEMENT", label = "Filler (then reseal)", when = { {"seal","SEAL_OF_MARTYRDOM"} } },

      ---------------------------------------------------------------- filler
      -- Consecration is a Holy talent Wowhead's P8 build does not take ("does not generate enough damage
      -- or threat"); when it is not known the entry is skipped, when it is, it is the last resort.
      { spell = "CONSECRATION", when = { {"resource","MANA", minPct = 40} } },
      { item  = 13, hold = true, label = "Trinket", when = { {"item_ready", 13} } },
      { item  = 14, hold = true, label = "Trinket", when = { {"item_ready", 14} } },
    },
  }

  -- Paladin Shockadin (Holy caster DPS). THEORYCRAFT, not a guide's rotation (ADR-0013 §6): no Phase 8
  -- Shockadin guide exists on Wowhead or Icy Veins; Wowhead's only one is Phase 2 (patch 1.15.1,
  -- level-capped at 40, docs/research/wowhead/paladin-shockadin-holy-spellslinger-phase-2.md). This list is
  -- derived in docs/research/paladin-p8-gather-prot-shockadin.md from that guide's still-true core loop,
  -- the T3.5 Holy set's own bonus text, and the damage-model coefficients. Marked experimental in the
  -- catalog until a sim or the owner's logs confirm it. Seal of Righteousness over Martyrdom is a
  -- reasoned pick (spell-power scaling on its Judgement), recorded there with the alternative.
  D.Builds.PALADIN_SHOCKADIN = {
    schema = 1, key = "PALADIN_SHOCKADIN", name = "Paladin — Shockadin (Holy caster)", class = "PALADIN", flavor = "SoD",
    notes = "Theorycrafted for Phase 8 — no published endgame guide exists. Holy Shock and Exorcism on cooldown, Judgement of Righteousness as the seal's payload, Crusader Strike when runed. With the Holy T3.5 4-set, spend 3 Holy Power on Holy Shock or Divine Storm.",
    requires = { spells = { "HOLY_SHOCK" },
                 runes = { "RUNE_SHOCK_AND_AWE", "RUNE_CRUSADER_STRIKE", "RUNE_INFUSION_OF_LIGHT" } },
    visuals = {
      cues = {
        { event = "now_slot", spell = "HOLY_SHOCK", color = {1.0,0.9,0.4}, edge = "left",
          reason = "Holy Shock came off cooldown" },
        { event = "check", key = "SEAL_DROPPED", color = {1.0,1.0,1.0}, edge = "bottom",
          reason = "Seal dropped", peripheral = true },
      },
    },
    entries = {
      ---------------------------------------------------------------- always
      { spell = "SEAL_OF_RIGHTEOUSNESS", when = { {"no_seal"} }, label = "Seal up" },

      ---------------------------------------------------------------- burst: same shape as the Ret builds, keyed to the Holy set
      { spell = "AVENGING_WRATH", hold = true, label = "Burst",
        when = { {"in_combat"},
                 {"any", {"buff","HOLY_POWER_BUFF", min = 3}, {"not", {"set","PALADIN_T35_INQUISITION_HOLY", min = 2}}} } },

      ---------------------------------------------------------------- UPGRADE: Holy T3.5 4-set -- spend 3 Holy Power
      -- "Promote whichever of the three is off cooldown with 3 stacks up": Holy Shock first (the build's
      -- own button), Divine Storm when runed, Holy Wrath where it can be cast at all.
      { spell = "HOLY_SHOCK",   label = "3 HP", when = { {"buff","HOLY_POWER_BUFF", min = 3}, {"bonus","HOLY_POWER_CONSUME_HOLY"} } },
      { spell = "DIVINE_STORM", label = "3 HP", when = { {"buff","HOLY_POWER_BUFF", min = 3}, {"bonus","HOLY_POWER_CONSUME_HOLY"} } },
      { spell = "HOLY_WRATH",   label = "3 HP", when = { {"buff","HOLY_POWER_BUFF", min = 3}, {"bonus","HOLY_POWER_CONSUME_HOLY"},
                                                        {"any", {"target_type","Undead","Demon"}, {"rune","RUNE_PURIFYING_POWER"}} } },

      ---------------------------------------------------------------- BASELINE core: a 60 with Holy Shock talented and nothing else
      { spell = "HOLY_SHOCK" },
      { spell = "EXORCISM" },
      { spell = "JUDGEMENT", label = "Seal expiring", when = { {"seal","SEAL_OF_RIGHTEOUSNESS"}, {"buff","SEAL_OF_RIGHTEOUSNESS", maxRemaining = 1.5} } },
      { spell = "CRUSADER_STRIKE" },   -- rune; skipped if not engraved

      ---------------------------------------------------------------- fillers
      { spell = "JUDGEMENT", label = "Filler (then reseal)", when = { {"seal","SEAL_OF_RIGHTEOUSNESS"} } },
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
