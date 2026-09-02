-- Gear scenarios for gear_matrix_spec.lua (docs/04-TESTING.md, ADR-0006 rule 6). Each scenario is
-- merged into a FakeState (tests/gear_matrix_spec.lua adds a default gcd = 1.5 unless the scenario
-- overrides it — without a nonzero GCD, Simulation's virtual clock never advances and every slot
-- after the first sees the same t=0, which produces meaningless "queues"). `expect` lists the exact
-- top-N spells/items Simulation.queue(build, state, 3) must produce; it may be shorter than 3 when
-- nothing else is castable — Simulation documents that it "shortens rather than repeating or
-- erroring" once every entry is exhausted, and gear_matrix_spec asserts the queue's real length.
--
-- Every `expect` here was hand-derived by walking Elmira_Paladin/Data/Builds/Paladin_Exodin.lua's
-- entries top-to-bottom against Engine.eligible + Simulation.applyCast's actual cooldown/resource
-- bookkeeping, not copied from whatever the engine happens to output — see the gear_matrix_spec.lua
-- report for the ones that changed from what was staged here before reconciliation.
return {
  PALADIN_EXODIN = {
    -- Hard rule 8 / ADR-0006 rule 1: fresh level-60 in dungeon blues, nothing engraved. Crusader
    -- Strike and Divine Storm are rune-taught abilities the character does not know yet.
    { name = "blues_no_runes", sets = {},
      usable = { CRUSADER_STRIKE = false, DIVINE_STORM = false, AVENGING_WRATH = false, AURA_MASTERY = false },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      -- Only Exorcism (15s CD) and the baseline Consecration filler are known abilities here.
      -- This scenario used to expect a 2-slot queue and called the truncation legitimate. It was
      -- not: a fresh 60 in blues has ~28 idle GCDs a minute and the build had nothing to offer for
      -- them, which is exactly the hole the bottom-of-list Judgement filler was added to close
      -- (docs/research/exodin-filler-policy.md Q1). Judgement now fills slot 2. If this ever
      -- truncates to 2 again, the filler has stopped reaching the character who needs it most.
      expect = { "EXORCISM", "JUDGEMENT", "CONSECRATION" } },

    -- All four gated runes engraved, no set bonuses yet.
    { name = "runes_only", sets = {}, seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" } },

    -- Extra (not mandated by docs/04, kept for coverage): the "Seal expiring" Judgement gate.
    -- Note: Simulation's virtual state does not model Judgement consuming the seal aura (it only
    -- tracks cooldown/resource, per Core/Simulation.lua's newVirtualState) — see the report for why
    -- slot 2 is EXORCISM, not a re-triggered "Seal up", even though live gameplay would reseal here.
    -- `remaining` is an input, not an expectation: the sourced window tightened from 3s to 1.5s
    -- (wowsims uses 1-1.5s; the 3 was unsourced), so 2 no longer sits inside it. 1.0 keeps this
    -- scenario exercising the behaviour its name claims. The expected queue is unchanged.
    { name = "seal_expiring_no_t2", sets = {}, seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 1 } },
      expect = { "JUDGEMENT", "EXORCISM", "CRUSADER_STRIKE" } },

    -- Boundary the 3s -> 1.5s tightening exists to protect: 2s used to sit INSIDE the old 3s window
    -- (promoting "Seal expiring" Judgement to slot 1) and now sits OUTSIDE the 1.5s one. If the
    -- window were ever widened back, this scenario is what would go red -- Judgement would jump back
    -- ahead of Exorcism. The bottom-of-list filler still makes Judgement reachable somewhere in the
    -- queue (seal is up throughout), but it must not outrank Exorcism/Crusader Strike/Divine Storm;
    -- see paladin_exodin_filler_spec.lua for the direct "not ahead of Exorcism" assertion.
    { name = "seal_expiring_outside_window", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 2.0 } },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" } },

    -- Radiant Judgement (T2) 2-set: Judgement no longer consumes the seal -> jumps to slot 1.
    { name = "t2_2p", sets = { PALADIN_T2_JUDGEMENT = 2 }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "JUDGEMENT", "EXORCISM", "CRUSADER_STRIKE" } },

    -- Inquisition (T3.5) 2-set only: the aura grants Holy Power, but nothing consumes it yet (that's
    -- the 4-set), so Divine Storm's "3 HP" entry never passes bonus("HOLY_POWER_CONSUME") and stays
    -- below Crusader Strike in priority.
    { name = "t35_2p", sets = { PALADIN_T35_INQUISITION = 2 }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" } }, -- HP never consumed -> DS stays below CS

    -- Inquisition (T3.5) 4-set: Divine Storm now consumes Holy Power -> jumps to slot 1 at 3 stacks.
    { name = "t35_4p", sets = { PALADIN_T35_INQUISITION = 4 }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      expect = { "DIVINE_STORM", "EXORCISM", "CRUSADER_STRIKE" } },

    -- Required by docs/04: full T3 (Redemption) 6-set + T3.5 (Inquisition) 2-set, against a
    -- non-Undead/Demon target with no Purifying Power rune. The T3 6-set satisfies the T3 4-set's
    -- HOLY_WRATH_INSTANT bonus threshold (6 >= 4), but Holy Wrath's `any` branch still requires
    -- Undead/Demon or the Purifying Power rune, so it stays gated out here — proving the 6p/2p
    -- combination does not accidentally unlock it against the wrong target, and (like t35_2p) that
    -- only 2 T3.5 pieces still leaves Divine Storm below Crusader Strike.
    { name = "naxx_t3_6p_t35_2p", sets = { PALADIN_T3_REDEMPTION = 6, PALADIN_T35_INQUISITION = 2 },
      targetType = "Humanoid", seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" } },

    -- Extra (not mandated by docs/04, kept for coverage): the Holy Wrath target-type gate itself,
    -- T3 4-set against an actual Undead target.
    { name = "naxx_t3_4p_undead", sets = { PALADIN_T3_REDEMPTION = 4, PALADIN_T35_INQUISITION = 2 },
      targetType = "Undead", seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "HOLY_WRATH" } },

    ---------------------------------------------------------------- Judgement filler self-throttling
    -- Contract point 2 (bottom-of-list Judgement filler): fully geared -- T3 Redemption 4-set, T3.5
    -- Inquisition 2-set, all four runes engraved -- with nothing on cooldown. No target-type override
    -- needed: RUNE_PURIFYING_POWER alone satisfies Holy Wrath's `any` branch. Deliberately no
    -- HOLY_POWER_BUFF here (unlike t35_2p/t35_4p) -- that buff is a separate, unrelated claim and
    -- entangling it would leave this scenario proving the wrong thing. Judgement must NOT be in this
    -- top-3: Exorcism, Crusader Strike and Holy Wrath all outrank it (Divine Storm is 4th, see
    -- paladin_exodin_filler_spec.lua depth-5 assertion for that one -- top-3 alone cannot show it).
    { name = "fully_geared_judgement_not_top3",
      sets = { PALADIN_T3_REDEMPTION = 4, PALADIN_T35_INQUISITION = 2 },
      runes = { RUNE_ART_OF_WAR = true, RUNE_CRUSADER_STRIKE = true, RUNE_DIVINE_STORM = true, RUNE_PURIFYING_POWER = true },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "HOLY_WRATH" } },

    -- Contract point 3: same gear as above, but Exorcism/Crusader Strike/Divine Storm/Holy Wrath are
    -- all on cooldown -- the idle-global case the filler exists for. Judgement must be slot 1. (Label
    -- is asserted in paladin_exodin_filler_spec.lua -- this fixture only sees spell keys, and a
    -- spell-only check can't tell "Filler" apart from "Seal expiring"; the seal has 25s remaining
    -- here, well outside the 1.5s window, so this is unambiguously the filler in practice.)
    { name = "fully_geared_judgement_slot1_when_idle",
      sets = { PALADIN_T3_REDEMPTION = 4, PALADIN_T35_INQUISITION = 2 },
      runes = { RUNE_ART_OF_WAR = true, RUNE_CRUSADER_STRIKE = true, RUNE_DIVINE_STORM = true, RUNE_PURIFYING_POWER = true },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      cooldowns = { EXORCISM = 10, CRUSADER_STRIKE = 10, DIVINE_STORM = 10, HOLY_WRATH = 10 },
      expect = { "JUDGEMENT", "CONSECRATION" } },

    -- Contract point 5: mana below the plain Consecration filler's 40% floor, core abilities on
    -- cooldown. The plain filler drops out (gated on {"resource","MANA",minPct=40}); Judgement must
    -- still be offered. The queue legitimately truncates to 1: Judgement's own 10s cooldown (from
    -- Data/Spells.lua) takes it off the table for the rest of this simulated window too.
    { name = "low_mana_judgement_still_offered", sets = {},
      usable = { CRUSADER_STRIKE = false, DIVINE_STORM = false, AVENGING_WRATH = false, AURA_MASTERY = false },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      power = { MANA = { 300, 1000 } }, cooldowns = { EXORCISM = 10 },
      expect = { "JUDGEMENT" } },

    -- Required by docs/04: best-in-slot Scarlet Enclave -- full Inquisition (T3.5) 6-set plus the
    -- soul Data/Advice/Paladin.lua recommends for this build (Soul of the Exile). The soul only
    -- boosts Exorcism damage (EXORCISM_DAMAGE_SOUL) and no Exodin entry gates on that bonus, so the
    -- top-3 is identical in shape to t35_4p; bonusExpected below is what actually exercises the soul.
    { name = "bis_se", sets = { PALADIN_T35_INQUISITION = 6 }, souls = { "SOUL_OF_THE_EXILE" },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME = true, EXORCISM_DAMAGE_SOUL = true },
      expect = { "DIVINE_STORM", "EXORCISM", "CRUSADER_STRIKE" } },

    -- Soul case ADR-0006 cares about: the bonus is granted with zero set pieces equipped. No Exodin
    -- entry gates on CRUSADER_STRIKE_150 either, so the queue matches runes_only/soul-free shape;
    -- bonusExpected is what actually proves the soul path.
    { name = "soul_grants_bonus_without_pieces", sets = { PALADIN_T25_AVENGERS = 0 }, souls = { "SOUL_OF_THE_RETRIBUTOR" },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      bonusExpected = { CRUSADER_STRIKE_150 = true }, expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" } },

    -- Wrong-soul advisor case: Data/Advice/Paladin.lua always recommends Soul of the Exile for
    -- Exodin; wearing Sealbearer instead (nerfed, and meant for the Stack build) should surface as a
    -- mismatch. No `expect`: this scenario doesn't drive a queue.
    { name = "advisor_wrong_soul", souls = { "SOUL_OF_THE_SEALBEARER" }, build = "PALADIN_EXODIN",
      adviseExpected = { soul = "SOUL_OF_THE_EXILE" } },
  },
}
