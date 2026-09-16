-- Gear scenarios for gear_matrix_spec.lua (docs/04-TESTING.md, ADR-0006 rule 6). Each scenario is
-- merged into a FakeState (tests/gear_matrix_spec.lua adds a default gcd = 1.5 unless the scenario
-- overrides it — without a nonzero GCD, Simulation's virtual clock never advances and every slot
-- after the first sees the same t=0, which produces meaningless "queues"). `expect` lists the exact
-- top-N spells/items Simulation.queue(build, state, 3) must produce; it may be shorter than 3 when
-- nothing else is castable — Simulation documents that it "shortens rather than repeating or
-- erroring" once every entry is exhausted, and gear_matrix_spec asserts the queue's real length.
--
-- Every `expect` here was hand-derived by walking Elmira/Classes/Paladin.lua's PALADIN_EXODIN
-- entries top-to-bottom against Engine.eligible + Simulation.applyCast's actual cooldown/resource
-- bookkeeping, not copied from whatever the engine happens to output — see the gear_matrix_spec.lua
-- report for the ones that changed from what was staged here before reconciliation.
--
-- `expectLabels`, where present, is parallel to `expect` and names the compiled entry's `label` that
-- must have produced each slot — gear_matrix_spec.lua's ambiguity guard requires it on every scenario
-- whose `expect` touches a spell key more than one PALADIN_EXODIN entry can produce (as of
-- 2026-09-03: JUDGEMENT x3, CONSECRATION x3, DIVINE_STORM x2; EXORCISM and the new HAMMER_OF_WRATH
-- execute line are both x1 and so unambiguous on their own, but carry labels below anyway per the next
-- sentence), since a spell-only comparison can't tell those entries apart. Every entry in the array is
-- filled in, not just the ambiguous slots —
-- once a scenario needs the array at all, labelling every slot is free and closes the same class of
-- gap for the unambiguous ones too. A slot produced by an entry with NO `label` field (the unlabelled
-- baseline entries) is written as `false`: entry.label is Lua `nil` in that case, and a plain array
-- cannot hold a `nil` element without leaving a hole `ipairs`/`#` would stop at, so `false` is used as
-- an unambiguous stand-in that can never collide with a real (string) label.
--
-- Labels below were derived from each scenario's own stated intent (the comment on the scenario) plus
-- Paladin_Exodin.lua's `when` conditions, worked out BEFORE running the suite — never copied back from
-- whatever the engine happened to output, which would just re-encode current behaviour as "correct".
return {
  PALADIN_EXODIN = {
    -- ADR-0013 §4: the "blues, no runes" floor is retired. Exodin is authored for its named runes
    -- (requires.runes: Art of War, Crusader Strike, Divine Storm, Purifying Power), so the new floor is
    -- "dungeon blues WITH the build's runes engraved" — no sets, no souls, but Crusader Strike and
    -- Divine Storm are known abilities, not silenced. This scenario already WAS exactly that gear point
    -- before today (nothing in it ever set `usable`, so every rune-taught ability defaults to
    -- FakeState's `usable = true`) — it is kept, not duplicated, and this comment now says so plainly
    -- instead of citing the retired "nothing engraved" framing it carried under the old rule.
    -- Where the retired `blues_no_runes` scenario's own reasoning still applies: the Judgement filler
    -- exists to fill the idle GCDs a thin rotation leaves (docs/research/exodin-filler-policy.md Q1);
    -- at THIS gear point, with the core fully known, there are no idle GCDs left in the top-3 for it to
    -- fill (Exorcism/Crusader Strike/Divine Storm already occupy all three slots) — the filler reaching
    -- a real top-3 slot is proven instead by `fully_geared_judgement_slot1_when_idle` and
    -- `low_mana_judgement_still_offered` below, once the ability that would otherwise win a slot is
    -- put on cooldown.
    -- Labels: no set bonuses at all, so DIVINE_STORM in slot 3 cannot be the "3 HP" entry (it needs
    -- bonus HOLY_POWER_CONSUME, which only the T3.5 4-set grants) — it is the unlabelled baseline.
    { name = "runes_only", sets = {}, seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" },
      expectLabels = { false, false, false } },

    -- Extra (not mandated by docs/04, kept for coverage): the "Seal expiring" Judgement gate.
    -- Note: Simulation's virtual state does not model Judgement consuming the seal aura (it only
    -- tracks cooldown/resource, per Core/Simulation.lua's newVirtualState) — see the report for why
    -- slot 2 is EXORCISM, not a re-triggered "Seal up", even though live gameplay would reseal here.
    -- `remaining` is an input, not an expectation: the sourced window tightened from 3s to 1.5s
    -- (wowsims uses 1-1.5s; the 3 was unsourced), so 2 no longer sits inside it. 1.0 keeps this
    -- scenario exercising the behaviour its name claims. The expected queue is unchanged.
    -- Labels: no T2 2-set, so slot 1's JUDGEMENT cannot be "Draconic 2p"; the seal has 1s remaining,
    -- inside the 1.5s window, so it must be the "Seal expiring" gate specifically.
    { name = "seal_expiring_no_t2", sets = {}, seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 1 } },
      expect = { "JUDGEMENT", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { "Seal expiring", false, false } },

    -- Boundary the 3s -> 1.5s tightening exists to protect: 2s used to sit INSIDE the old 3s window
    -- (promoting "Seal expiring" Judgement to slot 1) and now sits OUTSIDE the 1.5s one. If the
    -- window were ever widened back, this scenario is what would go red -- Judgement would jump back
    -- ahead of Exorcism. The bottom-of-list filler still makes Judgement reachable somewhere in the
    -- queue (seal is up throughout), but it must not outrank Exorcism/Crusader Strike/Divine Storm;
    -- see paladin_exodin_filler_spec.lua for the direct "not ahead of Exorcism" assertion.
    -- Labels: no set bonuses, so slot 3's DIVINE_STORM cannot be "3 HP" (no HOLY_POWER_CONSUME, no
    -- HOLY_POWER_BUFF stacks either) — it is the unlabelled baseline.
    { name = "seal_expiring_outside_window", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 2.0 } },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" },
      expectLabels = { false, false, false } },

    -- Radiant Judgement (T2) 2-set: Judgement no longer consumes the seal -> jumps to slot 1.
    -- Labels: the T2 2-set is exactly what grants JUDGEMENT_NO_CONSUME, so slot 1 must be "Draconic
    -- 2p" (not "Seal expiring": the seal has 25s remaining, well outside its 1.5s window).
    { name = "t2_2p", sets = { PALADIN_T2_JUDGEMENT = 2 }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "JUDGEMENT", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { "Draconic 2p", false, false } },

    -- Same bonus, the OTHER source: D.Bonuses.JUDGEMENT_NO_CONSUME's `from` list names two routes —
    -- the T2 Radiant Judgement 2-set (t2_2p above) and Soul of the Justicar (added today) — and ADR-0004
    -- says a build gates on the effect, never on which source granted it, so wearing the soul alone with
    -- ZERO set pieces must resolve to the byte-for-byte same queue as t2_2p. bonusExpected is what
    -- actually proves the soul path fired, since the queue shape alone can't tell "soul granted it" from
    -- "nothing granted it and Judgement just happened to look the same".
    -- Labels: same reasoning as t2_2p — the bonus is what unlocks "Draconic 2p", so slot 1 must be that
    -- entry regardless of which of the two sources supplied it.
    { name = "justicar_soul", sets = {}, souls = { "SOUL_OF_THE_JUSTICAR" }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      bonusExpected = { JUDGEMENT_NO_CONSUME = true },
      expect = { "JUDGEMENT", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { "Draconic 2p", false, false } },

    -- Inquisition (T3.5) 2-set only: the aura grants Holy Power, but nothing consumes it yet (that's
    -- the 4-set), so Divine Storm's "3 HP" entry never passes bonus("HOLY_POWER_CONSUME") and stays
    -- below Crusader Strike in priority.
    -- Labels: only 2 T3.5 pieces, so bonus("HOLY_POWER_CONSUME") is false even though the HOLY_POWER_BUFF
    -- stacks are present -- "3 HP"'s `when` needs both -- so slot 3's DIVINE_STORM is the baseline.
    { name = "t35_2p", sets = { PALADIN_T35_INQUISITION = 2 }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" }, -- HP never consumed -> DS stays below CS
      expectLabels = { false, false, false } },

    -- Inquisition (T3.5) 4-set: Divine Storm now consumes Holy Power -> jumps to slot 1 at 3 stacks.
    -- Labels: 4 T3.5 pieces satisfies HOLY_POWER_CONSUME and 3 HOLY_POWER_BUFF stacks satisfies the
    -- min-3 buff check, so slot 1 must be the "3 HP" entry itself, not the baseline it promotes past.
    { name = "t35_4p", sets = { PALADIN_T35_INQUISITION = 4 }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      expect = { "DIVINE_STORM", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { "3 HP", false, false } },

    -- Required by docs/04: full T3 (Redemption) 6-set + T3.5 (Inquisition) 2-set, against a
    -- non-Undead/Demon target with no Purifying Power rune. The T3 6-set satisfies the T3 4-set's
    -- HOLY_WRATH_INSTANT bonus threshold (6 >= 4), but Holy Wrath's `any` branch still requires
    -- Undead/Demon or the Purifying Power rune, so it stays gated out here — proving the 6p/2p
    -- combination does not accidentally unlock it against the wrong target, and (like t35_2p) that
    -- only 2 T3.5 pieces still leaves Divine Storm below Crusader Strike.
    -- Labels: only 2 T3.5 pieces here too (the T3 6p is irrelevant to HOLY_POWER_CONSUME), so slot 3's
    -- DIVINE_STORM is the baseline, same reasoning as t35_2p.
    { name = "naxx_t3_6p_t35_2p", sets = { PALADIN_T3_REDEMPTION = 6, PALADIN_T35_INQUISITION = 2 },
      targetType = "Humanoid", seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" },
      expectLabels = { false, false, false } },

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
    -- all on cooldown -- the idle-global case the filler exists for. Judgement must be slot 1, and now
    -- that gear_matrix_spec.lua supports expectLabels, this fixture can assert it directly rather than
    -- leaning entirely on paladin_exodin_filler_spec.lua: "Draconic 2p" doesn't apply (no T2 2-set),
    -- "Seal expiring" doesn't apply (the seal has 25s remaining, well outside the 1.5s window), so it
    -- must be the bottom-of-list filler. Slot 2's CONSECRATION is the unlabelled mana-gated baseline
    -- (both gated Consecration entries need Holy Power or 3+ enemies, neither present here).
    { name = "fully_geared_judgement_slot1_when_idle",
      sets = { PALADIN_T3_REDEMPTION = 4, PALADIN_T35_INQUISITION = 2 },
      runes = { RUNE_ART_OF_WAR = true, RUNE_CRUSADER_STRIKE = true, RUNE_DIVINE_STORM = true, RUNE_PURIFYING_POWER = true },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      cooldowns = { EXORCISM = 10, CRUSADER_STRIKE = 10, DIVINE_STORM = 10, HOLY_WRATH = 10 },
      expect = { "JUDGEMENT", "CONSECRATION" },
      expectLabels = { "Filler (nothing else ready)", false } },

    -- Contract point 5: mana below the plain Consecration filler's 40% floor, core abilities on
    -- cooldown. The plain filler drops out (gated on {"resource","MANA",minPct=40}); Judgement must
    -- still be offered. The queue legitimately truncates to 1: Judgement's own 10s cooldown (from
    -- Data/Spells.lua) takes it off the table for the rest of this simulated window too.
    -- Labels: no T2 2-set (not "Draconic 2p") and the seal has 25s remaining, outside the 1.5s window
    -- (not "Seal expiring"), so this must be the bottom-of-list filler.
    { name = "low_mana_judgement_still_offered", sets = {},
      usable = { CRUSADER_STRIKE = false, DIVINE_STORM = false, AVENGING_WRATH = false, AURA_MASTERY = false },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      power = { MANA = { 300, 1000 } }, cooldowns = { EXORCISM = 10 },
      expect = { "JUDGEMENT" },
      expectLabels = { "Filler (nothing else ready)" } },

    -- Required by docs/04: best-in-slot Scarlet Enclave -- full Inquisition (T3.5) 6-set plus the
    -- soul Data/Advice/Paladin.lua recommends for this build (Soul of the Exile). The soul only
    -- boosts Exorcism damage (EXORCISM_DAMAGE_SOUL) and no Exodin entry gates on that bonus, so the
    -- top-3 is identical in shape to t35_4p; bonusExpected below is what actually exercises the soul.
    -- Labels: same reasoning as t35_4p -- the T3.5 6-set clears the 4-set HOLY_POWER_CONSUME threshold
    -- and the HOLY_POWER_BUFF stacks satisfy the min-3 check, so slot 1 must be "3 HP".
    { name = "bis_se", sets = { PALADIN_T35_INQUISITION = 6 }, souls = { "SOUL_OF_THE_EXILE" },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME = true, EXORCISM_DAMAGE_SOUL = true },
      expect = { "DIVINE_STORM", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { "3 HP", false, false } },

    -- Soul case ADR-0006 cares about: the bonus is granted with zero set pieces equipped. No Exodin
    -- entry gates on CRUSADER_STRIKE_150 either, so the queue matches runes_only/soul-free shape;
    -- bonusExpected is what actually proves the soul path.
    -- Labels: no HOLY_POWER_CONSUME source here (0 T3.5 pieces, and the soul equipped grants an
    -- unrelated bonus), so slot 3's DIVINE_STORM is the baseline, same reasoning as runes_only.
    { name = "soul_grants_bonus_without_pieces", sets = { PALADIN_T25_AVENGERS = 0 }, souls = { "SOUL_OF_THE_RETRIBUTOR" },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      bonusExpected = { CRUSADER_STRIKE_150 = true }, expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- execute: HAMMER_OF_WRATH's slot (new line, 2026-09-03)
    -- The new entry sits below the baseline core (entry 11, after Exorcism/Crusader Strike/Divine
    -- Storm), so being inside its <=20% execute window does not make it preempt anything ranked above
    -- it. With the core fully available this scenario's top-3 is identical in shape to runes_only — the
    -- only difference is targetHp = 15 — proving the new line does not jump the queue.
    -- Labels: same reasoning as runes_only; nothing gated fires, so all three slots are the unlabelled
    -- baseline entries (7, 8, 10). HAMMER_OF_WRATH (11) never gets a turn here — see `execute_core_busy`
    -- immediately below for the scenario that actually reaches it.
    { name = "execute", sets = {}, seal = "SEAL_OF_MARTYRDOM", targetHp = 15,
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" },
      expectLabels = { false, false, false } },

    -- The core exhausted (Exorcism/Crusader Strike/Divine Storm all on cooldown; no T3 4-set means Holy
    -- Wrath's own bonus gate stays false regardless): HAMMER_OF_WRATH is now the first entry left
    -- standing at 15% target HP, one slot above the bottom-of-list Judgement filler — exactly "the
    -- position that follows from the list" once everything ranked above it is unavailable.
    -- Labels: slot 1 is entry 11 ("Execute"); slot 2 is entry 14 ("Filler (nothing else ready)") — the
    -- seal has 25s remaining, outside entry 5's 1.5s window, and no T2/soul bonus makes entry 4
    -- eligible. Slot 3's CONSECRATION is the unlabelled baseline filler (entry 12 needs Holy Power
    -- stacks this scenario never sets; entry 13 needs 3+ enemies).
    { name = "execute_core_busy", sets = {}, seal = "SEAL_OF_MARTYRDOM", targetHp = 15,
      cooldowns = { EXORCISM = 10, CRUSADER_STRIKE = 10, DIVINE_STORM = 10 },
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "HAMMER_OF_WRATH", "JUDGEMENT", "CONSECRATION" },
      expectLabels = { "Execute", "Filler (nothing else ready)", false } },

    -- Same exhausted core, target at 25% — outside HAMMER_OF_WRATH's <=20% window. The mutation this
    -- guards against: if the `{"target_hp", maxPct = 20}` clause were ever dropped from the entry, this
    -- scenario would start returning HAMMER_OF_WRATH in slot 1 too, indistinguishable from
    -- execute_core_busy above — the pair only proves the gate because execute_core_busy first shows the
    -- line IS reachable at this exact gear point.
    -- Labels: slot 1 is entry 14 ("Filler (nothing else ready)") — entry 11 fails its own gate at 25%
    -- HP, so it never gets a turn. Slot 2's CONSECRATION is the unlabelled baseline filler.
    { name = "execute_above_20", sets = {}, seal = "SEAL_OF_MARTYRDOM", targetHp = 25,
      cooldowns = { EXORCISM = 10, CRUSADER_STRIKE = 10, DIVINE_STORM = 10 },
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "JUDGEMENT", "CONSECRATION" },
      expectLabels = { "Filler (nothing else ready)", false } },

    -- The boundary itself. Schema's `target_hp maxPct` is inclusive (Core/Schema.lua inRange: v > max
    -- fails, v == max passes), so 20% is in execute range and 21% is not. The audit found
    -- `maxPct = 20` -> `19` survived with only the 15%/25% scenarios above; these two pin the edge.
        { name = "execute_at_20_inclusive", sets = {}, seal = "SEAL_OF_MARTYRDOM", targetHp = 20,
      cooldowns = { EXORCISM = 10, CRUSADER_STRIKE = 10, DIVINE_STORM = 10 },
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "HAMMER_OF_WRATH", "JUDGEMENT", "CONSECRATION" },
      expectLabels = { "Execute", "Filler (nothing else ready)", false } },
        { name = "execute_at_21_absent", sets = {}, seal = "SEAL_OF_MARTYRDOM", targetHp = 21,
      cooldowns = { EXORCISM = 10, CRUSADER_STRIKE = 10, DIVINE_STORM = 10 },
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "JUDGEMENT", "CONSECRATION" },
      expectLabels = { "Filler (nothing else ready)", false } },

    ---------------------------------------------------------------- survivor: CONSECRATION "AoE, 3 HP" (entry 12), isolated
    -- Previously unexercised by any scenario in this fixture — reported as a mutation survivor. T3.5
    -- 2-set only (grants the Holy Power aura but not HOLY_POWER_CONSUME, so Divine Storm's own "3 HP"
    -- entry stays gated out — same combination t35_2p above uses), Divine Storm and the single-target
    -- core forced onto cooldown so entry 12 is the first eligible line: HOLY_POWER_BUFF >= 3 AND
    -- cooldown_gt(DIVINE_STORM, 1) both pass.
    -- Labels: slot 1 is entry 12 ("AoE, 3 HP"), not entry 13 (needs enemies >= 3, unset here) or entry
    -- 15 (shares CONSECRATION's cooldown the instant entry 12 casts). Slot 2 is entry 14 ("Filler
    -- (nothing else ready)"; seal has 25s remaining, outside entry 5's window). The queue legitimately
    -- truncates to 2: Consecration and Judgement are both then on their own cooldowns and nothing else
    -- is eligible (no `items` entry here, so item_ready fails for both trinket slots).
    { name = "consecration_aoe_3hp", sets = { PALADIN_T35_INQUISITION = 2 }, seal = "SEAL_OF_MARTYRDOM",
      cooldowns = { EXORCISM = 10, CRUSADER_STRIKE = 10, DIVINE_STORM = 10 },
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      expect = { "CONSECRATION", "JUDGEMENT" },
      expectLabels = { "AoE, 3 HP", "Filler (nothing else ready)" } },

    ---------------------------------------------------------------- survivor: item 14 "Trinket" (entry 17), isolated
    -- Previously unexercised — also reported as a mutation survivor, alongside item 13. Same method as
    -- PALADIN_WRATHLIKE's `trinkets_only`: every rotation ability silenced so both trinket slots are the
    -- only candidates left (HOLY_WRATH and HAMMER_OF_WRATH need no separate silencing — their own bonus
    -- and target_hp gates already fail at this gear point's defaults). Item 13 (entry 16, earlier in the
    -- list) takes slot 1 and suppresses itself for the rest of the queue, leaving item 14 (entry 17) for
    -- slot 2. Both are `hold = true`, so neither advances Simulation's virtual clock, and with
    -- everything else silenced there is nothing left for slot 3 — the queue truncates at 2.
    { name = "trinkets_only", sets = {},
      usable = { AVENGING_WRATH = false, AURA_MASTERY = false, JUDGEMENT = false, CRUSADER_STRIKE = false,
                 EXORCISM = false, DIVINE_STORM = false, CONSECRATION = false },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      items = { [13] = { cooldown = 0 }, [14] = { cooldown = 0 } },
      expect = { "item:13", "item:14" },
      expectLabels = { "Trinket", "Trinket" } },

    -- Wrong-soul advisor case: Data/Advice/Paladin.lua always recommends Soul of the Exile for
    -- Exodin; wearing Sealbearer instead (nerfed, and meant for the Stack build) should surface as a
    -- mismatch. No `expect`: this scenario doesn't drive a queue.
    { name = "advisor_wrong_soul", souls = { "SOUL_OF_THE_SEALBEARER" }, build = "PALADIN_EXODIN",
      adviseExpected = { soul = "SOUL_OF_THE_EXILE" } },
  },

  -- ---------------------------------------------------------------------------------------------
  -- PALADIN_WRATHLIKE (ADR-0013). Gate list W1-W5, docs/research/paladin-p8-gather-ret.md
  -- "PALADIN_WRATHLIKE" section. Per ADR-0013 §4 the floor is now "dungeon blues with the build's
  -- runes engraved" -- there is no "blues_no_runes" scenario here; CRUSADER_STRIKE/DIVINE_STORM are
  -- rune-taught abilities and every scenario below leaves them at FakeState's default `usable = true`
  -- (nil usableSet), which is what "engraved" means in this fixture -- only the retired-baseline
  -- scenarios ever forced them to `false`.
  --
  -- Entries walked top-to-bottom against Elmira/Classes/Paladin.lua's PALADIN_WRATHLIKE (15 lines):
  --   1 SEAL_OF_MARTYRDOM "Seal up" (no_seal)
  --   2 AVENGING_WRATH "Burst" (buff VENGEANCE_BUFF, any(HOLY_POWER_BUFF>=3, not T3.5 2-set))
  --   3 AURA_MASTERY "with AW" (buff AVENGING_WRATH_BUFF)
  --   4 JUDGEMENT "Draconic 2p" -- W3 (bonus JUDGEMENT_NO_CONSUME)
  --   5 JUDGEMENT "Seal expiring" (seal + buff maxRemaining 1.5)
  --   6 DIVINE_STORM "3 HP" -- W4 (buff HOLY_POWER_BUFF>=3 + bonus HOLY_POWER_CONSUME)
  --   7 CONSECRATION "AoE, no T3.5" -- W5 (not T3.5 2-set, enemies>=3, mana>=40%)
  --   8 EXORCISM "Exile: Exorcism first" -- W1 (bonus EXORCISM_DAMAGE_SOUL)
  --   9 CRUSADER_STRIKE (baseline, unlabelled) -- W2
  --  10 EXORCISM (baseline, unlabelled) -- W2
  --  11 DIVINE_STORM (baseline, unlabelled)
  --  12 JUDGEMENT "Filler (then reseal)" (seal)
  --  13 CONSECRATION (baseline, unlabelled; mana>=40%)
  --  14 item 13 "Trinket" (item_ready 13)
  --  15 item 14 "Trinket" (item_ready 14)
  -- Ambiguous keys (more than one entry can produce them): JUDGEMENT x3, EXORCISM x2, DIVINE_STORM
  -- x2, CONSECRATION x2 -- every scenario below that touches one of those carries `expectLabels`.
  --
  -- AVENGING_WRATH and AURA_MASTERY carried no `cooldown` when this block was first written, so Simulation's
  -- fallback (`nominal <= 0 -> entry.cooldownSecs -> one time step`) gives them a synthetic ~1-GCD
  -- "cooldown" in the PREVIEW only -- the real adapter would supply their true (multi-minute)
  -- cooldown via state:baseCooldown()/GetSpellCooldown in game. AVENGING_WRATH's own gating buff
  -- (VENGEANCE_BUFF) is `proc = true`, so Schema's proc-suppression rule ("procs are unpredictable;
  -- absent in the future", Core/Schema.lua C.buff) keeps it from ever reappearing at a simulated
  -- t>0 regardless of that synthetic cooldown. AURA_MASTERY's gating buff (AVENGING_WRATH_BUFF) is
  -- NOT a proc, so it is NOT suppressed that way -- see `aura_mastery_only` below for how this
  -- fixture avoids relying on the exact-boundary coincidence that would otherwise make it reappear.
  -- That gap was shared with PALADIN_EXODIN's identical two entries and has since been closed:
  -- Data.Spells carries both cooldowns, pinned by data_sourcing_spec and `aura_mastery_then_core`.
  PALADIN_WRATHLIKE = {
    ---------------------------------------------------------------- W2: the baseline order
    -- Runes engraved (default `usable`), no sets, no soul, seal up with 25s remaining: nothing gated
    -- fires, so the list falls through to the W2 baseline: Crusader Strike, then Exorcism, then the
    -- plain Divine Storm line -- proving that last line IS reachable at this gear point (see the task
    -- report on whether it is reachable at any gear point at all).
    -- Labels: entry 8 (EXORCISM "Exile: Exorcism first") needs bonus EXORCISM_DAMAGE_SOUL, which no
    -- soul here grants, so slot 2's EXORCISM must be entry 10 (unlabelled). Entry 6 ("3 HP") needs a
    -- HOLY_POWER_BUFF stack this scenario never sets, so slot 3's DIVINE_STORM must be entry 11
    -- (unlabelled).
    { name = "runes_blues", sets = {}, seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "CRUSADER_STRIKE", "EXORCISM", "DIVINE_STORM" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- W1: soul flips the order
    -- Soul of the Exile only (no set): grants EXORCISM_DAMAGE_SOUL, which is exactly entry 8's gate,
    -- moving Exorcism above Crusader Strike -- "by effect, not by item" (the entry gates on the
    -- bonus, never on which soul is worn).
    -- Labels: slot 1 must be entry 8 ("Exile: Exorcism first"), not entry 10 -- entry 8 is earlier in
    -- the list and its bonus now passes. Slot 3's DIVINE_STORM has no HOLY_POWER_CONSUME source here
    -- (0 set pieces), so it is entry 11 (unlabelled), same reasoning as runes_blues.
    { name = "exile_soul", sets = {}, souls = { "SOUL_OF_THE_EXILE" },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      bonusExpected = { EXORCISM_DAMAGE_SOUL = true },
      expect = { "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM" },
      expectLabels = { "Exile: Exorcism first", false, false } },

    -- Soul of the Retributor grants CRUSADER_STRIKE_150, a bonus no PALADIN_WRATHLIKE entry gates on
    -- (unlike PALADIN_T25_AVENGERS' Excommunication path, nothing here reacts to it) -- the queue must
    -- be byte-for-byte the same shape as runes_blues, proving the soul is granted but inert for this
    -- build. bonusExpected pins down both halves: the soul's own bonus IS true, and the soul this
    -- build's W1 line actually cares about is NOT.
    { name = "retributor_soul", sets = {}, souls = { "SOUL_OF_THE_RETRIBUTOR" },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      bonusExpected = { CRUSADER_STRIKE_150 = true, EXORCISM_DAMAGE_SOUL = false },
      expect = { "CRUSADER_STRIKE", "EXORCISM", "DIVINE_STORM" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- W3: Draconic 2-set
    -- Radiant Judgement (T2) 2-set grants JUDGEMENT_NO_CONSUME -> Judgement jumps to slot 1 on
    -- cooldown, no reseal needed, exactly like Exodin's G1.
    -- Labels: slot 1 is entry 4 ("Draconic 2p") -- the seal has 25s remaining, well outside entry 5's
    -- 1.5s window, so it cannot be "Seal expiring". Slot 3's EXORCISM has no EXORCISM_DAMAGE_SOUL
    -- source (no soul), so it is entry 10 (unlabelled).
    { name = "t2_2p", sets = { PALADIN_T2_JUDGEMENT = 2 }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      bonusExpected = { JUDGEMENT_NO_CONSUME = true },
      expect = { "JUDGEMENT", "CRUSADER_STRIKE", "EXORCISM" },
      expectLabels = { "Draconic 2p", false, false } },

    ---------------------------------------------------------------- W4 threshold: 2-set grants, doesn't consume
    -- Inquisition (T3.5) 2-set only: the Holy Power aura exists (3 stacks, set here directly since the
    -- 2-set is what would apply it), but nothing consumes it -- that needs the 4-set -- so entry 6's
    -- "3 HP" line never passes bonus("HOLY_POWER_CONSUME") and Divine Storm stays the baseline, below
    -- Crusader Strike/Exorcism. Also demonstrates that Avenging Wrath's own gate now needs the 3-HP
    -- branch of its `any` (the "not T3.5 2-set" branch is false here) -- not separately exercised as
    -- a queue slot in this scenario (no VENGEANCE_BUFF set: entangling that with the Divine Storm
    -- claim this scenario exists for would prove the wrong thing, exactly as Exodin's own t35_2p
    -- avoids mixing HOLY_POWER_BUFF into an unrelated burst-cooldown check). See `avenging_wrath_burst`
    -- below for the "any" gate's other branch.
    -- Labels: same reasoning as runes_blues -- no bonus source fires anywhere gated, so every slot is
    -- the unlabelled baseline entry.
    { name = "t35_2p", sets = { PALADIN_T35_INQUISITION = 2 }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME = false },
      expect = { "CRUSADER_STRIKE", "EXORCISM", "DIVINE_STORM" }, -- HP never consumed -> DS stays baseline
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- W4: 4-set consumes Holy Power
    -- Inquisition (T3.5) 4-set + 3 Holy Power stacks: Divine Storm's "3 HP" entry now passes both
    -- halves of its gate and jumps to slot 1, exactly what W4 says is this build's single most
    -- important line.
    -- Labels: slot 1 is entry 6 ("3 HP"). Slot 3's EXORCISM has no soul bonus, so it is entry 10.
    { name = "t35_4p_3hp", sets = { PALADIN_T35_INQUISITION = 4 }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME = true },
      expect = { "DIVINE_STORM", "CRUSADER_STRIKE", "EXORCISM" },
      expectLabels = { "3 HP", false, false } },

    ---------------------------------------------------------------- Seal expiring outranks the core
    -- Seal at 1.0s remaining (inside entry 5's 1.5s window): the "Seal expiring" Judgement outranks
    -- Crusader Strike/Exorcism, same 1.0s boundary Exodin's seal_expiring_no_t2 scenario uses.
    -- Labels: slot 1 is entry 5, not entry 4 (no T2 2-set) and not entry 12 (entry 5 is earlier in the
    -- list and its own gate already passes). Slot 3's EXORCISM is entry 10 (no soul bonus).
    { name = "seal_expiring", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 1.0 } },
      expect = { "JUDGEMENT", "CRUSADER_STRIKE", "EXORCISM" },
      expectLabels = { "Seal expiring", false, false } },

    ---------------------------------------------------------------- Full BiS
    -- Inquisition (T3.5) 6-set (clears the 4-set HOLY_POWER_CONSUME threshold with room to spare) plus
    -- Soul of the Exile, deliberately exercising W1 and W4 together -- NOT what
    -- Data/Advice/Paladin.lua's PALADIN_WRATHLIKE.soul rule would recommend absent a T2.5 2-set (its
    -- fallback is Soul of the Retributor), chosen here because it is the combination that produces a
    -- shape distinct from every other scenario in this fixture (Exorcism promoted AND Divine Storm
    -- promoted), which is what a "does this build converge correctly at every gate at once" scenario
    -- needs to show.
    -- Labels: slot 1 is entry 6 ("3 HP", earlier in the list than entry 8). Slot 2 is entry 8 ("Exile:
    -- Exorcism first") -- Divine Storm's own cooldown blocks entry 6 again, and entry 8's bonus still
    -- passes. Slot 3's CRUSADER_STRIKE is unambiguous (entry 9, the only entry that can produce it).
    { name = "bis", sets = { PALADIN_T35_INQUISITION = 6 }, souls = { "SOUL_OF_THE_EXILE" },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME = true, EXORCISM_DAMAGE_SOUL = true },
      expect = { "DIVINE_STORM", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { "3 HP", "Exile: Exorcism first", false } },

    ---------------------------------------------------------------- W5: Consecration promoted, no T3.5
    -- tests/fake_state.lua's `enemies` field lets this fixture express "3+ enemies" directly (`t.enemies`
    -- feeds FakeState:enemies() -- see the `enemies` condition in Core/Schema.lua); M5a-i gave the REAL
    -- Adapters/Vanilla.lua the same reading, counted from nameplates -- so this scenario proves the
    -- BUILD's W5 line is wired correctly, and adapter_vanilla_spec.lua proves the count itself.
    -- No sets, no soul: not-T3.5-2-set passes, enemies=3 passes, mana defaults to 100% (>=40%).
    -- Labels: slot 1 is entry 7 ("AoE, no T3.5"), not entry 13 -- entry 7 is earlier and its own
    -- `enemies` gate now passes. Slot 3's EXORCISM is entry 10 (no soul bonus).
    { name = "no_t35_large_pull", sets = {}, enemies = 3, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "CONSECRATION", "CRUSADER_STRIKE", "EXORCISM" },
      expectLabels = { "AoE, no T3.5", false, false } },

    ---------------------------------------------------------------- extra: entry 1 itself (no scenario above ever drops the seal)
    -- Every scenario above keeps a seal active throughout (matching how the fixture's own comments say
    -- Simulation's virtual state never models a cast consuming the seal aura), which means entry 1
    -- ("Seal up") is never the first eligible entry anywhere above -- deleting it would change nothing
    -- any assertion checks. This scenario is the one that actually drops the seal (omits `seal`
    -- entirely, so state:seal() is nil) so entry 1 fires.
    -- Labels: slot 1 is entry 1 ("Seal up"). Casting a seal sets Simulation's virtual sealOverride
    -- (Core/Simulation.lua applyCast: `if entry.data.seal then v.sealOverride = entry.spell end`), so
    -- the seal reads as active for slots 2-3 even though nothing in `buffs` was ever set for it --
    -- entry 5 ("Seal expiring") correctly fails at every later slot because SEAL_OF_MARTYRDOM has no
    -- buff entry (C.buff.make treats an absent buff as `stacks == nil`, which fails before
    -- `maxRemaining` is even consulted). Slot 3's EXORCISM is entry 10 (no soul bonus).
    { name = "seal_down", sets = {},
      expect = { "SEAL_OF_MARTYRDOM", "CRUSADER_STRIKE", "EXORCISM" },
      expectLabels = { "Seal up", false, false } },

    ---------------------------------------------------------------- extra: entry 2 (Burst) and its `any` branch
    -- VENGEANCE_BUFF present, no T3.5 2-set (so the `any`'s "not T3.5 2-set" branch is what passes,
    -- the mirror of t35_2p's HP-branch note above). Avenging Wrath is `hold = true` (does not advance
    -- Simulation's virtual clock), so slot 2 is evaluated at the same t=0 as slot 1: entry 2 is
    -- already blocked by its own synthetic 1-GCD cooldown there, but VENGEANCE_BUFF's `proc = true`
    -- flag would have blocked it again at t>0 regardless (Core/Schema.lua C.buff: procs are suppressed
    -- for any simulated t>0), so it can never reappear in slot 3 either way -- unlike AURA_MASTERY,
    -- this entry needs no special handling to stay out of the later slots.
    -- Labels: slot 1 is entry 2 ("Burst"). Slot 3's EXORCISM is entry 10 (no soul bonus).
    { name = "avenging_wrath_burst", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, VENGEANCE_BUFF = { remaining = 20 } },
      expect = { "AVENGING_WRATH", "CRUSADER_STRIKE", "EXORCISM" },
      expectLabels = { "Burst", false, false } },

    ---------------------------------------------------------------- entry 2's OTHER branch: with the T3.5 2-set, Avenging Wrath waits for 3 Holy Power
    -- Wowhead's opener: "If you are using the Tier 3.5 Inquisition 2-set, resume your normal rotation
    -- until you build 3x Holy Power", THEN Avenging Wrath. The `any` gate's `not set` branch is false
    -- here (2 pieces), so the `HOLY_POWER_BUFF min = 3` branch is the only way in. Two Holy Power: held.
    -- The audit found `min = 3` -> `min = 99` survived the whole suite; this pair pins it.
    -- Labels: nothing gated fires (2 stacks, no 4-set), so every slot is an unlabelled baseline entry.
    { name = "t35_2p_burst_held", sets = { PALADIN_T35_INQUISITION = 2 }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, VENGEANCE_BUFF = { remaining = 20 }, HOLY_POWER_BUFF = { stacks = 2 } },
      expect = { "CRUSADER_STRIKE", "EXORCISM", "DIVINE_STORM" },
      expectLabels = { false, false, false } },
    -- Three Holy Power: the hold lifts and Avenging Wrath leads. Divine Storm's "3 HP" entry still
    -- needs the 4-set (bonus HOLY_POWER_CONSUME), so slots 2-3 stay the unlabelled baseline.
    { name = "t35_2p_burst_at_3hp", sets = { PALADIN_T35_INQUISITION = 2 }, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, VENGEANCE_BUFF = { remaining = 20 }, HOLY_POWER_BUFF = { stacks = 3 } },
      expect = { "AVENGING_WRATH", "CRUSADER_STRIKE", "EXORCISM" },
      expectLabels = { "Burst", false, false } },

    ---------------------------------------------------------------- W5's threshold: one T3.5 piece is still "no T3.5"
    -- The guard is `not set >= 2`. With exactly one piece it must still promote Consecration on a large
    -- pull; the audit found `min = 2` -> `min = 1` survived because no scenario wore exactly one piece.
    -- Labels: slot 1 is entry 7 ("AoE, no T3.5"); slots 2-3 are the baseline core.
    { name = "t35_1p_large_pull", sets = { PALADIN_T35_INQUISITION = 1 }, enemies = 3, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "CONSECRATION", "CRUSADER_STRIKE", "EXORCISM" },
      expectLabels = { "AoE, no T3.5", false, false } },
    -- And with two pieces the promotion is gone: Wowhead, "With Tier 3.5 Inquisition gear, Wrath-like
    -- makes zero changes for the AOE rotation". Slot 3 is the unlabelled baseline Divine Storm.
    { name = "t35_2p_large_pull", sets = { PALADIN_T35_INQUISITION = 2 }, enemies = 3, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "CRUSADER_STRIKE", "EXORCISM", "DIVINE_STORM" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- extra: entry 3 (with AW) in isolation
    -- AVENGING_WRATH_BUFF present (simulating "already popped Avenging Wrath") with no VENGEANCE_BUFF,
    -- so entry 2 never competes. Unlike VENGEANCE_BUFF, AVENGING_WRATH_BUFF carries no `proc = true`,
    -- so it is NOT suppressed at a simulated t>0. AURA_MASTERY now carries its 2-minute cooldown, so
    -- it would not read as "ready again" (the `aura_mastery_then_core` scenario proves that); this one
    -- still silences every other rotation entry (`usable = false`) to isolate entry 3, so nothing
    -- ever supplies that intervening non-`hold` cast: Engine.pick finds nothing after slot 1 and
    -- Simulation.queue truncates, the same legitimate shortening Exodin's
    -- low_mana_judgement_still_offered scenario exercises, rather than this fixture asserting a
    -- same-slot "AURA_MASTERY again" result that would only be true of the preview's synthetic
    -- cooldown and not of anything the build's data actually models.
    -- Labels: the single slot is entry 3 ("with AW"); AURA_MASTERY is not a key any other entry
    -- produces, so no ambiguity, but expectLabels is included anyway for the same reason the header
    -- comment gives -- filling every slot is free once the array exists at all.
    { name = "aura_mastery_only", sets = {},
      usable = { AVENGING_WRATH = false, JUDGEMENT = false, CRUSADER_STRIKE = false, EXORCISM = false,
                 DIVINE_STORM = false, CONSECRATION = false },
      seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, AVENGING_WRATH_BUFF = { remaining = 20 } },
      expect = { "AURA_MASTERY" },
      expectLabels = { "with AW" } },

    ---------------------------------------------------------------- entry 3 followed by the core: Aura Mastery's own cooldown
    -- Same start, nothing silenced but Avenging Wrath. Aura Mastery is `hold`, so it costs no time --
    -- which is exactly why its cooldown matters: without the 2-minute `cooldown` Data.Spells now carries
    -- it would be eligible again in slot 2 and the queue would read "Aura Mastery, Aura Mastery, ...".
    -- Labels: slot 1 is entry 3 ("with AW"); slots 2-3 are the baseline core (Crusader Strike, Exorcism).
    { name = "aura_mastery_then_core", sets = {}, usable = { AVENGING_WRATH = false },
      seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 }, AVENGING_WRATH_BUFF = { remaining = 20 } },
      expect = { "AURA_MASTERY", "CRUSADER_STRIKE", "EXORCISM" },
      expectLabels = { "with AW", false, false } },

    ---------------------------------------------------------------- extra: entry 12 (Filler) itself
    -- Mirrors Exodin's fully_geared_judgement_slot1_when_idle: Crusader Strike, Exorcism and Divine
    -- Storm all on cooldown, no set/soul bonuses, seal up but not expiring, no enemies for the AoE
    -- line -- everything above entry 12 in the list is ineligible, so the "cast Judgement and
    -- instantly refresh Seal of Martyrdom" filler becomes reachable. The plain Consecration baseline
    -- (mana >=40%, still true after Judgement's own cast) fills slot 2; both entries' cooldowns then
    -- block a slot 3, so the queue legitimately truncates at 2.
    -- Labels: slot 1 is entry 12 ("Filler (then reseal)"), not entry 4 (no T2 2-set) or entry 5 (seal
    -- has 25s remaining, outside the 1.5s window). Slot 2's CONSECRATION is entry 13 (unlabelled) --
    -- entry 7 needs enemies>=3, which this scenario never sets.
    { name = "judgement_filler_when_idle", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      cooldowns = { CRUSADER_STRIKE = 10, EXORCISM = 10, DIVINE_STORM = 10 },
      expect = { "JUDGEMENT", "CONSECRATION" },
      expectLabels = { "Filler (then reseal)", false } },

    ---------------------------------------------------------------- extra: entries 14-15 (trinkets)
    -- Every rotation ability silenced (`usable = false`) so both trinket slots are reachable; both
    -- items ready. Slot 1 is item 13 (entry 14, earlier in the list); casting it suppresses that slot
    -- for the rest of the queue (Simulation's QUEUE_HORIZON), so slot 2 is item 14 (entry 15). Both are
    -- `hold = true`, so neither advances Simulation's virtual clock, and with everything else silenced
    -- there is nothing left for slot 3 -- the queue truncates at 2.
    { name = "trinkets_only", sets = {},
      usable = { AVENGING_WRATH = false, AURA_MASTERY = false, JUDGEMENT = false, CRUSADER_STRIKE = false,
                 EXORCISM = false, DIVINE_STORM = false, CONSECRATION = false },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      items = { [13] = { cooldown = 0 }, [14] = { cooldown = 0 } },
      expect = { "item:13", "item:14" },
      expectLabels = { "Trinket", "Trinket" } },
  },

  -- ---------------------------------------------------------------------------------------------
  -- PALADIN_PROT (ADR-0013 sword & board tank). Gate list: docs/research/paladin-p8-gather-prot-shockadin.md
  -- lines 90-230; mechanism: docs/research/paladin-prot-how-tanking-works.md. Per ADR-0013 §4 the
  -- floor is "blues, the build's runes engraved" -- there is no "no runes" scenario here, and every
  -- scenario below leaves the six runes named in the build's `requires` at FakeState's default
  -- `usable = true` (nil usableSet) unless it deliberately silences one to test a skip path.
  --
  -- Entries walked top-to-bottom against Elmira/Classes/Paladin.lua's PALADIN_PROT (17 lines):
  --    1 RIGHTEOUS_FURY "Threat on" (no_buff RIGHTEOUS_FURY)
  --    2 SEAL_OF_MARTYRDOM "Seal up" (no_seal)
  --    3 HOLY_SHIELD "Keep up" (no_buff HOLY_SHIELD)
  --    4 AVENGING_WRATH "Threat burst", hold=true (in_combat)
  --    5 AVENGERS_SHIELD "AoE" (enemies>=3)
  --    6 CONSECRATION "AoE" (enemies>=3, resource MANA minPct=30)
  --    7 HAMMER_OF_THE_RIGHTEOUS (baseline, unlabelled, no gate)
  --    8 SHIELD_OF_RIGHTEOUSNESS (baseline, unlabelled, no gate)
  --    9 EXORCISM (baseline, unlabelled, no gate)
  --   10 AVENGERS_SHIELD (baseline, unlabelled, no gate)
  --   11 DIVINE_STORM "chest: Divine Storm" (enemies>=2)
  --   12 HOLY_WRATH "AoE" (enemies>=3, any(target_type Undead/Demon, rune RUNE_PURIFYING_POWER))
  --   13 JUDGEMENT "Seal expiring" (seal + buff maxRemaining 1.5)
  --   14 JUDGEMENT "Filler (then reseal)" (seal)
  --   15 CONSECRATION (baseline, unlabelled; resource MANA minPct=40)
  --   16 item 13 "Trinket" (item_ready 13)
  --   17 item 14 "Trinket" (item_ready 14)
  -- Ambiguous keys (more than one entry can produce them): JUDGEMENT x2 (13, 14), CONSECRATION x2
  -- (6, 15), AVENGERS_SHIELD x2 (5, 10) -- every scenario below that touches one of those carries
  -- `expectLabels`. No PALADIN_PROT entry gates on a `set` piece count at all (its one gear-conditional
  -- line is the soul-only HOLY_SHIELD_UNLIMITED bonus), so "each rotation-changing set/bonus threshold"
  -- collapses to `radiant_defender_soul` below -- there is no set-piece matrix to walk for this build.
  --
  -- IMPORTANT, verified empirically (not assumed) against Core/Simulation.lua and Core/Schema.lua
  -- before any scenario below was written, because both defeat the naive reading of several entries:
  --
  --  (a) tests/fake_state.lua's `inCombat()` was hardcoded `true` when this block was first written;
  --      it is now an option (`inCombat = false`), exercised by `out_of_combat_no_burst`. Scenarios that
  --      do not want AVENGING_WRATH to win still silence it (`usable = { AVENGING_WRATH = false }`),
  --      because it is `hold` and would otherwise take slot 1 of every in-combat scenario.
  --
  --  (b) AVENGING_WRATH carried no `cooldown` when this block was first written, so `pull_avenging_wrath`
  --      supplied an explicit `baseCooldown`. Data.Spells now carries the page's 3-minute cooldown and
  --      the stand-in is gone: this scenario is what pins that data line.
  --      AVENGERS_SHIELD had the same gap when this block was first written and showed three times
  --      in a row in `aoe_three`; it now carries `cooldown = 15` (its Wowhead page), which is why that
  --      scenario alternates into Consecration.
  --
  --  (c) RIGHTEOUS_FURY (entry 1) and HOLY_SHIELD (entry 3) gate on `no_buff` of THEMSELVES. When this
  --      block was first written the virtual state did not model a cast spell's own aura, and
  --      Righteous Fury won all three slots. Core/Simulation.lua now records a cast spell's own aura
  --      (`selfBuff`), so `righteous_fury_down` asserts the entry fires once and the core follows.
  PALADIN_PROT = {
    ---------------------------------------------------------------- baseline: single-target core, Wowhead's order
    -- Righteous Fury and Holy Shield already up, seal up with 25s remaining, one enemy (no AoE/cleave
    -- gate passes): entries 1-6 all fail their own gates, so the queue falls through to the
    -- unconditional core exactly in Wowhead's stated order -- Hammer of the Righteous, Shield of
    -- Righteousness, Exorcism. AVENGING_WRATH is silenced per finding (a) above, or it would win every
    -- slot (in_combat is hardcoded true in FakeState).
    -- Labels: all three slots are the unconditional baseline entries (7, 8, 9) -- none of them carry a
    -- label.
    { name = "runes_blues", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      usable = { AVENGING_WRATH = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS", "EXORCISM" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- entry 1: Righteous Fury down leads
    -- Righteous Fury's buff absent (Holy Shield and seal still up): "Threat on" must be slot 1. See
    -- finding (c) above for why slots 2-3 are ALSO RIGHTEOUS_FURY -- its own gate never falls once it
    -- fires in the preview, because Simulation's virtual state never marks a just-cast buff present and
    -- RIGHTEOUS_FURY carries no real cooldown to fall back on. This is asserted as the documented real
    -- behaviour, not an endorsement of it -- reported as a finding, not silently worked around.
    -- Slot 1 is entry 1 ("Threat on"). Casting Righteous Fury makes its own aura read as present for the
    -- rest of the preview (Core/Simulation.lua, selfBuff), so entry 1 is ineligible from slot 2 on and
    -- the core takes over: Hammer of the Righteous, then Shield of Righteousness. Before that change
    -- this scenario read "Righteous Fury" three times, which is the defect it now guards against.
    { name = "righteous_fury_down", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      usable = { AVENGING_WRATH = false },
      buffs = { HOLY_SHIELD = { remaining = 999 }, SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "RIGHTEOUS_FURY", "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS" },
      expectLabels = { "Threat on", false, false } },

    ---------------------------------------------------------------- entry 3: Holy Shield down leads
    -- Holy Shield's buff absent (Righteous Fury and seal up): "Keep up" is slot 1. Unlike Righteous
    -- Fury, Holy Shield carries a real `cooldown = 10` in Data.Spells, so its own re-cast is correctly
    -- blocked for the rest of this 3-slot preview and the queue falls through to the single-target
    -- core exactly like runes_blues.
    -- Labels: slot 1 is entry 3 ("Keep up"); slots 2-3 are the unconditional baseline (7, 8).
    { name = "holy_shield_down", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      usable = { AVENGING_WRATH = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "HOLY_SHIELD", "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS" },
      expectLabels = { "Keep up", false, false } },

    ---------------------------------------------------------------- entry 2: seal down leads
    -- No seal set at all (state:seal() is nil): "Seal up" is slot 1. Casting a seal sets Simulation's
    -- virtual `sealOverride` (Core/Simulation.lua applyCast), so `no_seal` correctly reads false for
    -- slots 2-3 even though nothing in `buffs` models it -- the seal condition, unlike a buff, IS
    -- specially modelled by Simulation. Righteous Fury and Holy Shield are up so entries 1 and 3 stay
    -- out of the way.
    -- Labels: slot 1 is entry 2 ("Seal up"); slots 2-3 are the unconditional baseline (7, 8).
    { name = "seal_down", sets = {},
      usable = { AVENGING_WRATH = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 } },
      expect = { "SEAL_OF_MARTYRDOM", "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS" },
      expectLabels = { "Seal up", false, false } },

    ---------------------------------------------------------------- entry 4: pull, Avenging Wrath ASAP
    -- Wowhead: "better to use this ASAP on a pull ... to facilitate a better threat curve" -- no
    -- Vengeance/Holy Power gate, just `in_combat` (hardcoded true in FakeState, finding (a) above).
    -- AVENGING_WRATH is left at its default `usable = true` here specifically to exercise the gate;
    -- Avenging Wrath's 3-minute `cooldown` now comes from Data.Spells, so no `baseCooldown` stand-in is
    -- needed and this scenario is what pins that data line: without it, AVENGING_WRATH's own synthetic
    -- ~1-GCD "cooldown" would make it win slot 3 again, which is not what a real player would ever see.
    -- Labels: slot 1 is entry 4 ("Threat burst"); slots 2-3 fall through to the single-target core (7, 8).
    { name = "pull_avenging_wrath", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "AVENGING_WRATH", "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS" },
      expectLabels = { "Threat burst", false, false } },

    -- The other side of that gate, now that the fake state can be out of combat: Avenging Wrath is
    -- usable and ready but must not be suggested before the pull. Labels: the plain core.
    { name = "out_of_combat_no_burst", sets = {}, seal = "SEAL_OF_MARTYRDOM", inCombat = false,
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 }, SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS", "EXORCISM" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- entry 5's threshold: two enemies is cleave, not AoE
    -- Wowhead's AoE list is for "3+ enemies". With two, Avenger's Shield's "AoE" copy must stay
    -- ineligible and the plain single-target order holds (its baseline copy is fourth, outside the top
    -- three). The audit found `min = 3` -> `min = 2` survived because every enemies = 2 scenario
    -- silenced Avenger's Shield to isolate the Divine Storm gate; this one leaves it live.
    { name = "cleave_two_no_aoe_avengers_shield", sets = {}, seal = "SEAL_OF_MARTYRDOM", enemies = 2,
      usable = { AVENGING_WRATH = false, DIVINE_STORM = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 }, SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS", "EXORCISM" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- entry 5: AoE promotes Avenger's Shield
    -- 3+ enemies: Wowhead's separate AoE list promotes Avenger's Shield ahead of the single-target
    -- core. This is the UNISOLATED scenario -- nothing above entry 5 is silenced beyond the usual
    -- AVENGING_WRATH -- and it reproduces finding (b) verbatim: because AVENGERS_SHIELD has no
    -- `cooldown` in Data.Spells, it wins all 3 slots instead of alternating with Consecration's own AoE
    -- line (entry 6), which per Wowhead should ALSO be promoted here. See `aoe_three_consecration`
    -- below for proof that entry 6's own gate is correctly wired once entry 5 is out of the way -- this
    -- scenario is deliberately left as the honest, unisolated reading and reported as a finding.
    -- Labels: entry 5 ("AoE") is earlier in the list than entry 10 (unlabelled) and remains eligible
    -- every slot, so it -- not entry 10 -- must be what produces all three.
    -- Slot 1: entry 5 (Avenger's Shield "AoE"). Avenger's Shield carries its 15s cooldown now, so slot 2
    -- falls to the next promoted AoE line, Consecration "AoE" (enemies 3, mana 100%); its 8s cooldown then
    -- leaves slot 3 to the first single-target core entry, Hammer of the Righteous (unlabelled).
    { name = "aoe_three", sets = {}, seal = "SEAL_OF_MARTYRDOM", enemies = 3,
      usable = { AVENGING_WRATH = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "AVENGERS_SHIELD", "CONSECRATION", "HAMMER_OF_THE_RIGHTEOUS" },
      expectLabels = { "AoE", "AoE", false } },

    ---------------------------------------------------------------- entry 6: Consecration's own AoE gate, isolated
    -- Same gear point as aoe_three, with Avenger's Shield additionally silenced so entry 6 gets a turn
    -- -- proving Consecration's "AoE" line (enemies>=3, mana>=30%) is correctly wired even though
    -- aoe_three above can never reach it unisolated (finding (b)). Mana defaults to 100%, well above
    -- the 30% floor.
    -- Labels: slot 1 is entry 6 ("AoE"); entry 6's own 8s cooldown (Data.Spells CONSECRATION.cooldown)
    -- blocks it for slots 2-3, which fall to the unconditional core (7, 8).
    { name = "aoe_three_consecration", sets = {}, seal = "SEAL_OF_MARTYRDOM", enemies = 3,
      usable = { AVENGING_WRATH = false, AVENGERS_SHIELD = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "CONSECRATION", "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS" },
      expectLabels = { "AoE", false, false } },

    ---------------------------------------------------------------- entry 6's mana floor: 30%, not entry 15's 40%
    -- Consecration's AoE line and its baseline filler (entry 15) use DIFFERENT mana floors (30% vs
    -- 40%) -- easy to conflate if one were ever copy-edited into the other. 32% sits strictly between
    -- them: above entry 6's 30% floor (so the AoE line still fires) but below entry 15's 40% (so this
    -- scenario is not accidentally passing because of the OTHER Consecration entry). Avenger's Shield
    -- silenced as in aoe_three_consecration.
    { name = "aoe_three_consecration_mana_floor", sets = {}, seal = "SEAL_OF_MARTYRDOM", enemies = 3,
      usable = { AVENGING_WRATH = false, AVENGERS_SHIELD = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      power = { MANA = { 320, 1000 } },
      expect = { "CONSECRATION", "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS" },
      expectLabels = { "AoE", false, false } },
    -- Below entry 6's 30% floor: the AoE line must NOT fire (falls straight to the single-target core;
    -- entry 15's own 40% floor is also failed at 20%, so nothing masks this).
    { name = "aoe_three_consecration_below_mana_floor", sets = {}, seal = "SEAL_OF_MARTYRDOM", enemies = 3,
      usable = { AVENGING_WRATH = false, AVENGERS_SHIELD = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      power = { MANA = { 200, 1000 } },
      expect = { "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS", "EXORCISM" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- entry 10: the unlabelled Avenger's Shield
    -- Single-target gear point (enemies=1, entry 5's AoE gate fails) with the rest of the core
    -- silenced: proves entry 10 (the plain, always-eligible Avenger's Shield later in Wowhead's
    -- single-target order) is itself reachable and correctly unlabelled.
    -- Slot 1 is the baseline Avenger's Shield (enemies = 1, so the "AoE" copy is ineligible; unlabelled).
    -- With the rest of the core silenced and Avenger's Shield on its 15s cooldown, slot 2 is the
    -- Judgement filler (seal up, not expiring) and slot 3 the unlabelled Consecration filler.
    { name = "avengers_shield_single_target", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      usable = { AVENGING_WRATH = false, HAMMER_OF_THE_RIGHTEOUS = false, SHIELD_OF_RIGHTEOUSNESS = false,
                 EXORCISM = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "AVENGERS_SHIELD", "JUDGEMENT", "CONSECRATION" },
      expectLabels = { false, "Filler (then reseal)", false } },

    ---------------------------------------------------------------- entry 12: Holy Wrath, Undead-only, isolated
    -- 3+ enemies against an Undead target, with everything that would otherwise outrank Holy Wrath
    -- silenced (entries 5, 6, 7, 8, 9, 11 -- the entire single-target core has no gate of its own and
    -- would win regardless of target type or enemy count, so Holy Wrath's own `target_type` gate can
    -- only be observed this way). This also proves the `any(target_type, rune)` branch's target-type
    -- half independently of RUNE_PURIFYING_POWER (not engraved here).
    -- Labels: slot 1 is entry 12 ("AoE"); slot 2 is entry 14 ("Filler (then reseal)") -- the seal has
    -- 25s remaining, well outside entry 13's 1.5s window.
    { name = "aoe_three_undead", sets = {}, seal = "SEAL_OF_MARTYRDOM", enemies = 3, targetType = "Undead",
      usable = { AVENGING_WRATH = false, AVENGERS_SHIELD = false, CONSECRATION = false,
                 HAMMER_OF_THE_RIGHTEOUS = false, SHIELD_OF_RIGHTEOUSNESS = false, EXORCISM = false,
                 DIVINE_STORM = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "HOLY_WRATH", "JUDGEMENT" },
      expectLabels = { "AoE", "Filler (then reseal)" } },

    ---------------------------------------------------------------- entry 11: the chest choice, Divine Storm known
    -- 2+ enemies with Divine Storm known (the character engraved the chest rune instead of the default
    -- Aegis): "chest: Divine Storm" is reachable. Isolated -- the single-target core (7, 8, 9) and the
    -- unlabelled Avenger's Shield (10) silenced -- because none of those four carry a gate of their own
    -- and would otherwise win every slot ahead of entry 11 regardless of enemy count.
    -- Labels: slot 1 is entry 11 ("chest: Divine Storm"); slot 2 is entry 14 ("Filler (then reseal)",
    -- seal has 25s remaining, outside entry 13's 1.5s window); slot 3's CONSECRATION is entry 15
    -- (unlabelled) -- entry 6 needs enemies>=3, which this scenario never sets (only 2).
    { name = "cleave_divine_storm_chest", sets = {}, seal = "SEAL_OF_MARTYRDOM", enemies = 2,
      usable = { AVENGING_WRATH = false, HAMMER_OF_THE_RIGHTEOUS = false, SHIELD_OF_RIGHTEOUSNESS = false,
                 EXORCISM = false, AVENGERS_SHIELD = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "DIVINE_STORM", "JUDGEMENT", "CONSECRATION" },
      expectLabels = { "chest: Divine Storm", "Filler (then reseal)", false } },

    -- Same gear point, Divine Storm NOT known (`usable = false` -- the P8 kit's default chest pick is
    -- Aegis, a passive with no ability, so this is the common case): entry 11 is silently skipped
    -- (ADR-0006 rule 5 / hard rule 8) and the queue falls to the Judgement/Consecration fillers with no
    -- error.
    -- Labels: slot 1 is entry 14 ("Filler (then reseal)"); slot 2's CONSECRATION is entry 15
    -- (unlabelled).
    { name = "cleave_no_divine_storm", sets = {}, seal = "SEAL_OF_MARTYRDOM", enemies = 2,
      usable = { AVENGING_WRATH = false, HAMMER_OF_THE_RIGHTEOUS = false, SHIELD_OF_RIGHTEOUSNESS = false,
                 EXORCISM = false, AVENGERS_SHIELD = false, DIVINE_STORM = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      expect = { "JUDGEMENT", "CONSECRATION" },
      expectLabels = { "Filler (then reseal)", false } },

    ---------------------------------------------------------------- entry 13: "Seal expiring" outranks the FILLER, not the core
    -- Seal at 1.0s remaining (inside entry 13's 1.5s window), single-target core silenced. Proves the
    -- `maxRemaining = 1.5` gate itself is correctly wired: with the core out of the way, "Seal expiring"
    -- (entry 13) fires ahead of the plain "Filler (then reseal)" (entry 14), which is the ordering
    -- point of having two Judgement entries at all.
    -- IMPORTANT: this does NOT show entry 13 outranking the single-target core -- see
    -- `seal_expiring_core_available` immediately below for why it can't, in this build, and why that is
    -- worth the build author's attention.
    -- Labels: slot 1 is entry 13 ("Seal expiring"), not entry 14 -- entry 13 is earlier in the list and
    -- its own gate passes first. Slot 2's CONSECRATION is entry 15 (unlabelled; enemies=1 fails entry 6).
    { name = "seal_expiring", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      usable = { AVENGING_WRATH = false, HAMMER_OF_THE_RIGHTEOUS = false, SHIELD_OF_RIGHTEOUSNESS = false,
                 EXORCISM = false, AVENGERS_SHIELD = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 1.0 } },
      expect = { "JUDGEMENT", "CONSECRATION" },
      expectLabels = { "Seal expiring", false } },

    -- FINDING, not a scenario the task asked for by name: same 1.0s-remaining seal as above, but
    -- nothing silenced beyond the usual AVENGING_WRATH. Unlike PALADIN_EXODIN/PALADIN_WRATHLIKE, where
    -- the equivalent "Seal expiring" Judgement entry sits ABOVE the baseline core specifically so it
    -- can promote ahead of it, PALADIN_PROT's entries 13-14 sit BELOW the entire single-target core (7,
    -- 8, 9, 10) and the Holy Wrath AoE line (12). Hammer of the Righteous/Shield of Righteousness/
    -- Exorcism carry no gate of their own, so at least one of them is essentially always eligible
    -- whenever it isn't literally on cooldown -- "Seal expiring" can only ever win a slot in the rare
    -- window where all four are simultaneously on cooldown. The queue here is therefore IDENTICAL in
    -- shape to runes_blues: the imminent seal drop never surfaces. Recorded here as a candidate
    -- authoring inconsistency (see the task report), not patched.
    -- "Seal expiring" now sits ABOVE the core (the build was reordered after this scenario showed the
    -- line could never fire while a core button was ready), so with the seal at 1.0s it leads even with
    -- everything else available. Judgement then sits on its cooldown, and the core follows.
    { name = "seal_expiring_core_available", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      usable = { AVENGING_WRATH = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 1.0 } },
      expect = { "JUDGEMENT", "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS" },
      expectLabels = { "Seal expiring", false, false } },

    ---------------------------------------------------------------- entry 14: the plain filler, isolated
    -- Everything that could otherwise fire is on cooldown or gated out (core forced onto cooldown,
    -- Consecration unusable -- see the next scenario for that half) and the seal is NOT expiring (25s
    -- remaining, outside entry 13's window): the plain "Filler (then reseal)" becomes reachable.
    -- Mirrors PALADIN_WRATHLIKE's judgement_filler_when_idle in method.
    -- Labels: slot 1 is entry 14 ("Filler (then reseal)"); entry 13 needs the seal inside 1.5s, which
    -- this scenario does not set.
    { name = "judgement_filler_when_idle", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      usable = { AVENGING_WRATH = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      cooldowns = { HAMMER_OF_THE_RIGHTEOUS = 10, SHIELD_OF_RIGHTEOUSNESS = 10, EXORCISM = 10, AVENGERS_SHIELD = 10 },
      expect = { "JUDGEMENT", "CONSECRATION" },
      expectLabels = { "Filler (then reseal)", false } },

    ---------------------------------------------------------------- entry 15: Consecration is a Holy talent the P8 build skips
    -- Wowhead: Consecration "does not generate enough damage or threat" for this build; when the
    -- character has not taken the talent it is an unknown/unusable spell, silently skipped (ADR-0006
    -- rule 5 / hard rule 8), and nothing errors. Same cooldown-forcing as judgement_filler_when_idle so
    -- Consecration's absence is actually observable within the top-3 window instead of being buried
    -- below the always-eligible core.
    -- The queue truncates to 1: Judgement's own 10s cooldown (Data.Spells JUDGEMENT.cooldown) takes it
    -- off the table too, and with Consecration unusable there is nothing left for a second slot.
    { name = "no_consecration_talent", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      usable = { AVENGING_WRATH = false, CONSECRATION = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      cooldowns = { HAMMER_OF_THE_RIGHTEOUS = 10, SHIELD_OF_RIGHTEOUSNESS = 10, EXORCISM = 10, AVENGERS_SHIELD = 10 },
      expect = { "JUDGEMENT" },
      expectLabels = { "Filler (then reseal)" } },

    ---------------------------------------------------------------- soul: Radiant Defender changes behaviour, not priority
    -- Data/Souls.lua / D.Advice.PALADIN_PROT: Wowhead frames Soul of the Radiant Defender as one of
    -- "our strongest damage dealing options, while also not editing our rotation" -- it changes how
    -- Holy Shield BEHAVES (unlimited charges, scales with block value) via HOLY_SHIELD_UNLIMITED, not
    -- when to press it. No PALADIN_PROT entry gates on that bonus, so the queue must be byte-for-byte
    -- the same shape as runes_blues; bonusExpected is what actually proves the soul is granted.
    { name = "radiant_defender_soul", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      usable = { AVENGING_WRATH = false },
      souls = { "SOUL_OF_THE_RADIANT_DEFENDER" },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      bonusExpected = { HOLY_SHIELD_UNLIMITED = true },
      expect = { "HAMMER_OF_THE_RIGHTEOUS", "SHIELD_OF_RIGHTEOUSNESS", "EXORCISM" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- wrong-soul advisor case
    -- D.Advice.PALADIN.PALADIN_PROT always recommends Soul of the Radiant Defender; wearing Soul of the
    -- Exile instead (Exodin's soul) should surface as a mismatch. No `expect`: this scenario doesn't
    -- drive a queue.
    { name = "advisor_wrong_soul", souls = { "SOUL_OF_THE_EXILE" }, build = "PALADIN_PROT",
      adviseExpected = { soul = "SOUL_OF_THE_RADIANT_DEFENDER" } },

    ---------------------------------------------------------------- entries 16-17: trinkets
    -- Every rotation ability silenced so both trinket slots are reachable; both items ready. Slot 1 is
    -- item 13 (entry 16); casting it suppresses that slot for the rest of the queue, so slot 2 is item
    -- 14 (entry 17). Both `hold = true`, so neither advances Simulation's virtual clock, and with
    -- everything else silenced there is nothing left for slot 3 -- the queue truncates at 2.
    { name = "trinkets", sets = {}, seal = "SEAL_OF_MARTYRDOM",
      usable = { AVENGING_WRATH = false, HAMMER_OF_THE_RIGHTEOUS = false, SHIELD_OF_RIGHTEOUSNESS = false,
                 EXORCISM = false, AVENGERS_SHIELD = false, DIVINE_STORM = false, HOLY_WRATH = false,
                 JUDGEMENT = false, CONSECRATION = false },
      buffs = { RIGHTEOUS_FURY = { remaining = 999 }, HOLY_SHIELD = { remaining = 999 },
                SEAL_OF_MARTYRDOM = { remaining = 25 } },
      items = { [13] = { cooldown = 0 }, [14] = { cooldown = 0 } },
      expect = { "item:13", "item:14" },
      expectLabels = { "Trinket", "Trinket" } },
  },

  -- ---------------------------------------------------------------------------------------------
  -- PALADIN_SHOCKADIN (ADR-0013 §6: THEORYCRAFT, not a guide's rotation -- no P8 Shockadin guide
  -- exists on Wowhead or Icy Veins, catalog ships it `experimental = true`). Gate list derived in
  -- docs/research/paladin-p8-gather-prot-shockadin.md lines 230-349, "Proposed theorycrafted Phase 8
  -- priority -- OURS, not a guide's". Per ADR-0013 §4 the floor is "blues, the build's runes engraved"
  -- -- Holy Shock (talent, not a rune) and Crusader Strike (rune) default to FakeState's `usable = true`
  -- below, which is what "known" means at this gear point.
  --
  -- Entries walked top-to-bottom against Elmira/Classes/Paladin.lua's PALADIN_SHOCKADIN (13 lines):
  --    1 SEAL_OF_RIGHTEOUSNESS "Seal up" (no_seal)
  --    2 AVENGING_WRATH "Burst", hold=true (in_combat, any(HOLY_POWER_BUFF>=3, not T3.5-HOLY 2-set))
  --    3 HOLY_SHOCK "3 HP" (buff HOLY_POWER_BUFF>=3 + bonus HOLY_POWER_CONSUME_HOLY)
  --    4 DIVINE_STORM "3 HP" (same gate as 3)
  --    5 HOLY_WRATH "3 HP" (same gate as 3, plus any(target_type Undead/Demon, rune RUNE_PURIFYING_POWER))
  --    6 HOLY_SHOCK (baseline, unlabelled) -- dossier item 1
  --    7 EXORCISM (baseline, unlabelled) -- dossier item 2
  --    8 JUDGEMENT "Seal expiring" (seal + buff maxRemaining 1.5) -- dossier item 3
  --    9 CRUSADER_STRIKE (baseline, unlabelled; rune) -- dossier item 4
  --   10 JUDGEMENT "Filler (then reseal)" (seal)
  --   11 CONSECRATION (baseline, unlabelled; resource MANA minPct=40)
  --   12 item 13 "Trinket" (item_ready 13)
  --   13 item 14 "Trinket" (item_ready 14)
  -- Ambiguous keys (more than one entry can produce them): HOLY_SHOCK x2 (3, 6), JUDGEMENT x2 (8, 10).
  -- DIVINE_STORM and HOLY_WRATH are each produced by exactly one entry here (unlike Exodin/Wrathlike,
  -- Shockadin has no unlabelled baseline copy of either), so they need no `expectLabels` to disambiguate
  -- on their own, but every scenario below labels every slot anyway per the shared fixture convention.
  --
  -- FINDING (placement of entry 8, "Seal expiring"): the dossier's own stated baseline order (lines
  -- 310-315) is Holy Shock, Exorcism, Judgement-when-seal-expiring, Crusader Strike -- and that is
  -- EXACTLY what entries 6-9 encode. This is the OPPOSITE of what happened to PALADIN_PROT's equivalent
  -- line (see that build's block above): Prot's "Seal expiring" had to be moved ABOVE its four-button
  -- core because Prot's core is wide enough that the line could otherwise never fire before the seal
  -- dropped. Shockadin's core is two buttons with real cooldowns (Holy Shock 30s, Exorcism 15s), so the
  -- gap the dossier's ordering leaves for it is real, not vestigial -- but nothing here VERIFIES the gap
  -- is wide enough at typical cast cadence; `seal_expiring` below only proves the WIRING (that "Seal
  -- expiring" is reachable once Holy Shock and Exorcism are both busy), the same way Prot's own
  -- `seal_expiring_core_available` scenario does for its build. Recorded as a finding, not a defect:
  -- the placement matches the source dossier verbatim, so it is authored intent, not an authoring slip.
  --
  -- FORMER FINDING, now closed (AVENGING_WRATH had no `cooldown` fallback data, same gap as every other
  -- Paladin build's copy): its own gate reads `HOLY_POWER_BUFF` and a `set` count, NEITHER of which
  -- Simulation's virtual state decays or overrides once the entry has been cast (Core/Simulation.lua's
  -- `v:buff` only intercepts a spell's OWN aura, and HOLY_POWER_BUFF is not AVENGING_WRATH's own aura).
  -- Combined with the synthetic ~1-GCD cooldown fallback (finding (b) in the PALADIN_PROT header above),
  -- any scenario that lets AVENGING_WRATH actually fire needs an explicit `baseCooldown` standing in for
  -- the real multi-minute cooldown, or it re-appears one non-`hold` cast later and silently displaces
  -- whatever this fixture is actually trying to isolate. `holy_t35_2p`, `burst_pull_no_set` and `bis`
  -- below carried `baseCooldown = { AVENGING_WRATH = 600 }` for exactly this reason until Data.Spells
  -- gained the page's 3-minute cooldown; the stand-ins are gone and these scenarios pin that line; every other
  -- scenario instead silences it (`usable = { AVENGING_WRATH = false }`), because with no Holy T3.5
  -- 2-set worn its `any` gate's `not set ... min = 2` branch is true unconditionally (0 < 2), so it
  -- would otherwise win slot 1 of every scenario below regardless of what that scenario is testing.
  PALADIN_SHOCKADIN = {
    ---------------------------------------------------------------- floor: blues, the build's runes engraved
    -- Holy Shock (talent) and Crusader Strike (rune) both known, no sets, no souls, seal up with 25s
    -- remaining (well outside entry 8's 1.5s window): entries 1-5 all fail their own gates, so the
    -- queue falls through to the dossier's stated baseline order -- Holy Shock, Exorcism, Crusader
    -- Strike, with "Seal expiring" correctly skipped over.
    -- Labels: all three slots are the unconditional baseline entries (6, 7, 9) -- none of them carry a
    -- label.
    { name = "runes_blues", sets = {}, seal = "SEAL_OF_RIGHTEOUSNESS",
      usable = { AVENGING_WRATH = false },
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 } },
      expect = { "HOLY_SHOCK", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- Crusader Strike not engraved
    -- `usable = { CRUSADER_STRIKE = false }` simulates the rune not being worn: entry 9 is silently
    -- skipped (ADR-0006 rule 5 / hard rule 8) and the queue falls through past it, with no error, to
    -- the bottom-of-list Judgement filler (entry 10) -- exactly as the equivalent skip does for every
    -- other Ret/Prot build's own Crusader Strike line.
    -- Labels: slots 1-2 are the same unlabelled baseline as runes_blues (6, 7); slot 3 is entry 10
    -- ("Filler (then reseal)") -- entry 8 still fails at 25s remaining, and entry 9 is skipped.
    { name = "no_crusader_strike_rune", sets = {}, seal = "SEAL_OF_RIGHTEOUSNESS",
      usable = { AVENGING_WRATH = false, CRUSADER_STRIKE = false },
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 } },
      expect = { "HOLY_SHOCK", "EXORCISM", "JUDGEMENT" },
      expectLabels = { false, false, "Filler (then reseal)" } },

    ---------------------------------------------------------------- entry 1: seal down leads
    -- No seal at all (state:seal() is nil): "Seal up" is slot 1. Casting a seal sets Simulation's
    -- virtual sealOverride (Core/Simulation.lua applyCast), so `no_seal` correctly reads false for the
    -- rest of this preview -- the seal condition, unlike a buff, IS specially modelled by Simulation.
    -- Labels: slot 1 is entry 1 ("Seal up"); slots 2-3 are the unconditional baseline (6, 7).
    { name = "seal_down", sets = {},
      usable = { AVENGING_WRATH = false },
      expect = { "SEAL_OF_RIGHTEOUSNESS", "HOLY_SHOCK", "EXORCISM" },
      expectLabels = { "Seal up", false, false } },

    ---------------------------------------------------------------- entry 8: where "Seal expiring" actually lands
    -- Seal at 1.0s remaining (inside entry 8's 1.5s window), Holy Shock and Exorcism BOTH still
    -- available: this is the scenario the header FINDING above describes. Entry 8's own gate passes
    -- throughout (Core/Simulation.lua never decays a real `buff()` value with virtual elapsed time, so
    -- 1.0s stays 1.0s at every slot) but entries 6 and 7 are earlier in the list, carry no gate of
    -- their own, and are not yet on cooldown at slots 1-2 -- so "Seal expiring" only reaches a slot
    -- once BOTH of them have been cast. It lands in slot 3, BELOW Holy Shock and Exorcism, exactly as
    -- entries 6-9's order says it should (see the header FINDING for why this differs from Prot).
    -- Labels: slot 1 is entry 6 (unlabelled Holy Shock); slot 2 is entry 7 (unlabelled Exorcism); slot
    -- 3 is entry 8 ("Seal expiring") -- not entry 9 (Crusader Strike), which sits below it in the list
    -- and never gets a turn once entry 8's own gate passes.
    { name = "seal_expiring", sets = {}, seal = "SEAL_OF_RIGHTEOUSNESS",
      usable = { AVENGING_WRATH = false },
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 1.0 } },
      expect = { "HOLY_SHOCK", "EXORCISM", "JUDGEMENT" },
      expectLabels = { false, false, "Seal expiring" } },

    ---------------------------------------------------------------- Holy T3.5 2-set: grants Holy Power, consumes nothing
    -- Inquisition Shockplate (T3.5 Holy) 2-set only, with 3 Holy Power stacks already up (as if Crusader
    -- Strike/Exorcism had just built them under Shock and Awe): the 4-set's HOLY_POWER_CONSUME_HOLY
    -- bonus needs 4 pieces, so entries 3-5 all stay gated out despite the stacks being present --
    -- bonusExpected pins that down directly. Entry 2's OWN gate is different: with 2 pieces its `not
    -- set ... min = 2` branch is now false, but the `buff HOLY_POWER_BUFF min = 3` branch is TRUE (we
    -- already have 3 stacks), so Avenging Wrath fires anyway -- "waits for 3 HP" and HAS it, rather than
    -- being held the way `burst_held_2p` below shows at 2 stacks. Its 3-minute `cooldown` from Data.Spells
    -- is why it does not reappear in slot 3.
    -- Labels: slot 1 is entry 2 ("Burst"); slots 2-3 are the unconditional baseline (6, 7) -- none of
    -- the "3 HP" entries can fire at this gear point.
    { name = "holy_t35_2p", sets = { PALADIN_T35_INQUISITION_HOLY = 2 }, seal = "SEAL_OF_RIGHTEOUSNESS",
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME_HOLY = false },
      expect = { "AVENGING_WRATH", "HOLY_SHOCK", "EXORCISM" },
      expectLabels = { "Burst", false, false } },

    ---------------------------------------------------------------- Holy T3.5 4-set: Holy Shock leads at 3 Holy Power
    -- 4 pieces satisfies HOLY_POWER_CONSUME_HOLY; 3 Holy Power stacks satisfy entry 3's own buff check;
    -- entry 3 is the FIRST of the three "3 HP" spenders in list order, so it wins slot 1. Divine Storm
    -- (the build's `usable` default leaves it known, matching "with the Holy T3.5 4-set, spend 3 Holy
    -- Power on Holy Shock or Divine Storm" from the build's own notes) is entry 4's own gate is
    -- identical and it is next in the list, so once Holy Shock's 30s cooldown takes slot 1's line off
    -- the table, Divine Storm's "3 HP" copy takes slot 2 -- the buff never decays in Simulation's
    -- virtual state, so it is still >= 3 there. Holy Wrath (entry 5) stays gated out throughout: no
    -- Undead/Demon target and no Purifying Power rune here. Avenging Wrath is silenced to isolate the
    -- spender ordering this scenario exists to prove (its own gate would otherwise fire it first, per
    -- the header FINDING -- see `bis` below for the scenario that deliberately lets both fire together).
    -- Labels: slot 1 is entry 3 ("3 HP", Holy Shock); slot 2 is entry 4 ("3 HP", Divine Storm); slot 3
    -- is entry 7 (unlabelled Exorcism) -- both spenders are now on their own cooldowns and entry 6
    -- shares Holy Shock's cooldown with entry 3, so it cannot re-fire either.
    { name = "holy_t35_4p_3hp", sets = { PALADIN_T35_INQUISITION_HOLY = 4 }, seal = "SEAL_OF_RIGHTEOUSNESS",
      usable = { AVENGING_WRATH = false },
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME_HOLY = true },
      expect = { "HOLY_SHOCK", "DIVINE_STORM", "EXORCISM" },
      expectLabels = { "3 HP", "3 HP", false } },

    ---------------------------------------------------------------- same 4-set, Holy Shock already on cooldown
    -- `cooldowns = { HOLY_SHOCK = 10 }` takes entry 3 (and entry 6, which shares the same spell key) off
    -- the table from t=0: Divine Storm's "3 HP" copy (entry 4, still known) is the next eligible spender
    -- and leads instead, exactly what the dossier's "promote whichever of the three is off cooldown"
    -- phrasing says should happen.
    -- Labels: slot 1 is entry 4 ("3 HP", Divine Storm); slot 2 is entry 7 (unlabelled Exorcism); slot 3
    -- is entry 9 (unlabelled Crusader Strike) -- entry 8 fails at 25s remaining.
    { name = "holy_t35_4p_3hp_holy_shock_on_cd", sets = { PALADIN_T35_INQUISITION_HOLY = 4 },
      seal = "SEAL_OF_RIGHTEOUSNESS", usable = { AVENGING_WRATH = false },
      cooldowns = { HOLY_SHOCK = 10 },
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME_HOLY = true },
      expect = { "DIVINE_STORM", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { "3 HP", false, false } },

    ---------------------------------------------------------------- Holy Shock AND Divine Storm both unavailable: Holy Wrath, Undead target
    -- Same 4-set/cooldown gear point, Divine Storm additionally unknown (`usable = false`) and the
    -- target is Undead: entry 5's `any(target_type, rune)` gate passes on its target-type half (no
    -- Purifying Power rune engraved here), so Holy Wrath becomes the last-standing "3 HP" spender.
    -- Labels: slot 1 is entry 5 ("3 HP", Holy Wrath); slots 2-3 are the unconditional baseline (7, 9).
    { name = "holy_t35_4p_3hp_holy_wrath_undead", sets = { PALADIN_T35_INQUISITION_HOLY = 4 },
      seal = "SEAL_OF_RIGHTEOUSNESS", targetType = "Undead",
      usable = { AVENGING_WRATH = false, DIVINE_STORM = false },
      cooldowns = { HOLY_SHOCK = 10 },
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME_HOLY = true },
      expect = { "HOLY_WRATH", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { "3 HP", false, false } },

    -- The `any` gate's OTHER branch: a non-Undead/Demon target (explicit "Humanoid", matching how
    -- PALADIN_EXODIN's own naxx_t3_6p_t35_2p proves the negative case), but RUNE_PURIFYING_POWER
    -- engraved -- Purifying Power lifts Holy Wrath's target restriction (Data/Spells.lua PURIFYING_POWER
    -- note), so entry 5 still fires via its rune half instead of its target-type half.
    -- Labels: same shape as the Undead scenario -- slot 1 is entry 5 ("3 HP", Holy Wrath).
    { name = "holy_t35_4p_3hp_holy_wrath_purifying_power", sets = { PALADIN_T35_INQUISITION_HOLY = 4 },
      seal = "SEAL_OF_RIGHTEOUSNESS", targetType = "Humanoid",
      runes = { RUNE_PURIFYING_POWER = true },
      usable = { AVENGING_WRATH = false, DIVINE_STORM = false },
      cooldowns = { HOLY_SHOCK = 10 },
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME_HOLY = true },
      expect = { "HOLY_WRATH", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { "3 HP", false, false } },

    ---------------------------------------------------------------- the RET T3.5 set does not count for Shockadin
    -- PALADIN_T35_INQUISITION (the RET Warplate, item-set 1940) is a DIFFERENT set from
    -- PALADIN_T35_INQUISITION_HOLY (item-set 1963, Sets.lua's own comment: "a different item-set from
    -- the Ret Warplate above ... with its own pieces and bonuses"). Wearing 4 pieces of the wrong set,
    -- with 3 Holy Power stacks manually up, must NOT satisfy HOLY_POWER_CONSUME_HOLY -- bonusExpected
    -- pins that down -- and none of entries 3-5 may fire; the queue must be byte-for-byte the shape of
    -- runes_blues.
    -- Labels: all three slots are the unlabelled baseline (6, 7, 9), same as runes_blues.
    { name = "ret_t35_does_not_count", sets = { PALADIN_T35_INQUISITION = 4 }, seal = "SEAL_OF_RIGHTEOUSNESS",
      usable = { AVENGING_WRATH = false },
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME_HOLY = false },
      expect = { "HOLY_SHOCK", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- entry 2's other branch: no Holy set, in combat
    -- Zero PALADIN_T35_INQUISITION_HOLY pieces: `not set ... min = 2` is unconditionally true (0 < 2),
    -- so Avenging Wrath's `any` passes on that branch alone regardless of Holy Power -- it fires on
    -- pull, exactly like the no-set case for every other Ret build's Vengeance-gated copy.
    -- Its 3-minute `cooldown` from Data.Spells keeps it out of slots 2-3.
    -- Labels: slot 1 is entry 2 ("Burst"); slots 2-3 are the unconditional baseline (6, 7).
    { name = "burst_pull_no_set", sets = {}, seal = "SEAL_OF_RIGHTEOUSNESS",
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 } },
      expect = { "AVENGING_WRATH", "HOLY_SHOCK", "EXORCISM" },
      expectLabels = { "Burst", false, false } },

    -- With the 2-set worn, the `not set` branch flips false, so only 3 Holy Power stacks can open the
    -- gate. Two stacks: held. The audit found `min = 3` -> `min = 99` survived a suite with no scenario
    -- pinning this exact boundary; this scenario needs no `usable` silencing at all, because entry 2's
    -- own gate correctly fails on its own -- if it did not, AVENGING_WRATH would appear in slot 1 here.
    -- Labels: no "3 HP" entry can fire either (bonus needs 4 pieces), so all three slots are the
    -- unlabelled baseline (6, 7, 9).
    { name = "burst_held_2p", sets = { PALADIN_T35_INQUISITION_HOLY = 2 }, seal = "SEAL_OF_RIGHTEOUSNESS",
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 2 } },
      expect = { "HOLY_SHOCK", "EXORCISM", "CRUSADER_STRIKE" },
      expectLabels = { false, false, false } },

    ---------------------------------------------------------------- full BiS: Holy T3.5 6-set, burst and spenders together
    -- Inquisition Shockplate 6-set (clears the 4-set HOLY_POWER_CONSUME_HOLY threshold with room to
    -- spare; the 6-set's own +8%/+18% spell-power bonus is a pure damage multiplier with no aura of its
    -- own to gate on, same shape as every other "passive bonus" set threshold in this pack, so it adds
    -- no new line to walk). Unlike every "*_3hp" scenario above, Avenging Wrath is left LIVE here on
    -- purpose: at 6 pieces (>= 2) its `not set` branch is false, but 3 Holy Power stacks satisfy the
    -- other half of its `any`, so it fires -- this is the gear point where a real character sees both
    -- the burst line AND a Holy Power spender in the same 3-slot window, which is what distinguishes
    -- this scenario's shape from every lower-gear scenario above.
    -- Labels: slot 1 is entry 2 ("Burst"); slot 2 is entry 3 ("3 HP", Holy Shock -- not yet on cooldown
    -- at the same t=0 Avenging Wrath's `hold = true` leaves behind); slot 3 is entry 4 ("3 HP", Divine
    -- Storm) -- Holy Shock is now on its own 30s cooldown and Avenging Wrath by its 3-minute one.
    { name = "bis", sets = { PALADIN_T35_INQUISITION_HOLY = 6 }, seal = "SEAL_OF_RIGHTEOUSNESS",
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 }, HOLY_POWER_BUFF = { stacks = 3 } },
      bonusExpected = { HOLY_POWER_CONSUME_HOLY = true },
      expect = { "AVENGING_WRATH", "HOLY_SHOCK", "DIVINE_STORM" },
      expectLabels = { "Burst", "3 HP", "3 HP" } },

    ---------------------------------------------------------------- entry 11: the plain Consecration filler, isolated
    -- Everything above entry 11 forced onto cooldown (Holy Shock, Exorcism, both Judgement entries via
    -- JUDGEMENT's own 10s cooldown, Crusader Strike) with no set/soul bonus to unlock any "3 HP"
    -- spender and the seal not expiring: the plain, unlabelled Consecration filler (mana >= 40%,
    -- default 100%) becomes the only entry left standing. Mirrors PALADIN_WRATHLIKE's own
    -- judgement_filler_when_idle in method, one level further down this build's own list.
    -- The queue legitimately truncates to 1: Consecration's own 8s cooldown takes it off the table too,
    -- and with everything else still on cooldown and no trinket data supplied there is nothing left for
    -- a second slot.
    { name = "consecration_filler_when_idle", sets = {}, seal = "SEAL_OF_RIGHTEOUSNESS",
      usable = { AVENGING_WRATH = false },
      cooldowns = { HOLY_SHOCK = 10, EXORCISM = 10, JUDGEMENT = 10, CRUSADER_STRIKE = 10 },
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 } },
      expect = { "CONSECRATION" },
      expectLabels = { false } },

    ---------------------------------------------------------------- entries 12-13: trinkets
    -- No `adviseExpected`/"wrong-soul advisor" scenario in this build's block: Data/Advice/Paladin.lua's
    -- own PALADIN_SHOCKADIN.soul is `{}` -- "no soul is sourced for a Holy caster DPS; none is guessed"
    -- (the build file's own comment) -- so Core/Advisor.lua's firstMatch() never has a rule to return
    -- and `rec.soul` stays nil for every soul a character could wear. gear_matrix_spec.lua's advisor
    -- assertion (`rec.soul.pick`) indexes that field unconditionally, so an `adviseExpected` scenario
    -- here would error, not fail cleanly -- there is no "wrong soul" for a build that recommends none.
    --
    -- Every rotation ability silenced so both trinket slots are reachable; both items ready. Slot 1 is
    -- item 13 (entry 12); casting it suppresses that slot for the rest of the queue, so slot 2 is item
    -- 14 (entry 13). Both `hold = true`, so neither advances Simulation's virtual clock, and with
    -- everything else silenced there is nothing left for slot 3 -- the queue truncates at 2.
    { name = "trinkets_only", sets = {}, seal = "SEAL_OF_RIGHTEOUSNESS",
      usable = { AVENGING_WRATH = false, HOLY_SHOCK = false, EXORCISM = false, JUDGEMENT = false,
                 CRUSADER_STRIKE = false, DIVINE_STORM = false, HOLY_WRATH = false, CONSECRATION = false },
      buffs = { SEAL_OF_RIGHTEOUSNESS = { remaining = 25 } },
      items = { [13] = { cooldown = 0 }, [14] = { cooldown = 0 } },
      expect = { "item:13", "item:14" },
      expectLabels = { "Trinket", "Trinket" } },
  },

  -- =================================================================================================
  -- MAGE_FIRE (MG1-D7). No cooldown numbers are shipped for any Mage spell (docs/research found no
  -- fetched page that quoted one), so Simulation's fallback (docs/02 "Simulation semantics": no
  -- state:baseCooldown, no Data `cooldown` -> one time step) governs every virtual slot: a spell with
  -- no rival, cast once, is back off cooldown by the very next slot and simply repeats. That is an
  -- honest consequence of the sourcing discipline (hard rule 2), not a bug — most scenarios below
  -- isolate ONE entry with `usable = false` on everything that could otherwise outrank it (the same
  -- technique paladin_exodin's own fixture uses for `trinkets_only` above) so the resulting 1-or-3-slot
  -- queue is unambiguous to hand-derive, rather than trying to predict a full, un-isolated cascade.
  MAGE_FIRE = {
    -- Natural, un-isolated cascade with the build's own 8 runes engraved and nothing else: entry 1
    -- (Hot Streak) fails (no buff), entry 2 (Overheat) is engraved and off-GCD so it wins slot 1
    -- without spending simulated time; slot 2 is still t=0, where entry 2 is now on its own 1-step
    -- virtual cooldown, so entry 3 (Scorch, absent debuff) wins; by slot 3 (t=1.5s) entry 2's virtual
    -- cooldown has already elapsed (1 step = 1.5s, the scenario's own gcd), so it is eligible again
    -- and outranks Scorch's now-also-reset cooldown by LIST POSITION alone.
    { name = "runes_engraved_baseline",
      runes = { RUNE_HOT_STREAK = true, RUNE_OVERHEAT = true, RUNE_ENLIGHTENMENT = true, RUNE_BALEFIRE_BOLT = true,
                RUNE_LIVING_BOMB = true, RUNE_FROSTFIRE_BOLT = true, RUNE_ICY_VEINS = true, RUNE_SPELL_POWER = true },
      expect = { "FIRE_BLAST", "SCORCH", "FIRE_BLAST" },
      expectLabels = { "Overheat", "Scorch to 5, refresh under 4s", "Overheat" } },

    -- Hot Streak is a proc (`proc = true` on HOT_STREAK_BUFF): Simulation suppresses it for every
    -- virtual slot past t=0, so it can only ever win slot 1 — exactly Paladin's VENGEANCE_BUFF shape.
    { name = "hot_streak_up_never_held",
      buffs = { HOT_STREAK_BUFF = { stacks = 1, remaining = 8 } },
      usable = { FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "PYROBLAST" } },

    -- Overheat NOT engraved: entry 2's rune gate fails, so the un-engraved baseline Fire Blast entry
    -- (no `when` at all, no `hold`) is what fires — and with nothing else usable and no sourced
    -- cooldown, it simply repeats every slot (the sourcing-gap behaviour the header above explains).
    { name = "overheat_not_engraved_uses_baseline_fire_blast",
      runes = {},
      usable = { PYROBLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "FIRE_BLAST", "FIRE_BLAST", "FIRE_BLAST" },
      expectLabels = { false, false, false } },

    -- Overheat engraved with Fire Blast the ONLY usable entry: `hold = true` never advances simulated
    -- time, so its own virtual cooldown (1 step) never clears and the queue truncates to 1 slot —
    -- proving the entry is reachable and off-GCD at once.
    { name = "overheat_engraved_isolated",
      runes = { RUNE_OVERHEAT = true },
      usable = { PYROBLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "FIRE_BLAST" },
      expectLabels = { "Overheat" } },

    -- Scorch at 0 stacks (debuff entirely absent): VL2-D7's single entry passes via its `max = 4`
    -- child, which also reads true on absence (VL2-D4).
    { name = "scorch_zero_stacks_applies",
      usable = { PYROBLAST = false, FIRE_BLAST = false, LIVING_BOMB = false, COMBUSTION = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "SCORCH", "SCORCH", "SCORCH" },
      expectLabels = { "Scorch to 5, refresh under 4s", "Scorch to 5, refresh under 4s",
                        "Scorch to 5, refresh under 4s" } },

    -- 4 stacks, 3s left: the entry's `max = 4` child alone already passes (4 <= 4, no remaining
    -- check on that branch) -- the `maxRemaining = 4` child would too, but only one entry exists now.
    { name = "scorch_four_stacks_refreshed",
      debuffs = { FIRE_VULNERABILITY = { stacks = 4, remaining = 3, mine = true } },
      usable = { PYROBLAST = false, FIRE_BLAST = false, LIVING_BOMB = false, COMBUSTION = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "SCORCH", "SCORCH", "SCORCH" },
      expectLabels = { "Scorch to 5, refresh under 4s", "Scorch to 5, refresh under 4s",
                        "Scorch to 5, refresh under 4s" } },

    -- 5 stacks, 20s left (nowhere near expiring): both `any` children fail (`max = 4`: 5 > 4;
    -- `maxRemaining = 4`: 20 > 4) — the queue correctly falls through to Living Bomb instead,
    -- proving the cap actually stops Scorch rather than merely relabelling it.
    { name = "scorch_five_stacks_skips_to_living_bomb",
      debuffs = { FIRE_VULNERABILITY = { stacks = 5, remaining = 20, mine = true } },
      usable = { PYROBLAST = false, FIRE_BLAST = false, COMBUSTION = false, ICY_VEINS = false, COLD_SNAP = false,
                 BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false, FLAMESTRIKE = false,
                 FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "LIVING_BOMB", "LIVING_BOMB", "LIVING_BOMB" } },

    -- 3 stacks, 20s left: the `max = 4` child passes (3 <= 4) even though `maxRemaining = 4` alone
    -- would not (20 > 4) — this is the scenario that actually needs the `max` half of the `any`
    -- rather than just the `maxRemaining` half.
    { name = "scorch_below_five_stacks_keeps_refreshing",
      debuffs = { FIRE_VULNERABILITY = { stacks = 3, remaining = 20, mine = true } },
      usable = { PYROBLAST = false, FIRE_BLAST = false, LIVING_BOMB = false, COMBUSTION = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "SCORCH", "SCORCH", "SCORCH" },
      expectLabels = { "Scorch to 5, refresh under 4s", "Scorch to 5, refresh under 4s",
                        "Scorch to 5, refresh under 4s" } },

    -- 5 stacks but only 2s left: the `maxRemaining = 4` child does not check stack count, so it
    -- fires regardless — refreshing even a maxed stack before it falls off.
    { name = "scorch_five_stacks_expiring_still_refreshed",
      debuffs = { FIRE_VULNERABILITY = { stacks = 5, remaining = 2, mine = true } },
      usable = { PYROBLAST = false, FIRE_BLAST = false, LIVING_BOMB = false, COMBUSTION = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "SCORCH", "SCORCH", "SCORCH" },
      expectLabels = { "Scorch to 5, refresh under 4s", "Scorch to 5, refresh under 4s",
                        "Scorch to 5, refresh under 4s" } },

    -- Living Bomb absent -> maintained; present -> the reapply line is skipped (falls through to a
    -- filler), proving `no_debuff` actually gates it rather than firing unconditionally.
    { name = "living_bomb_absent_is_applied",
      debuffs = {},
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, COMBUSTION = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "LIVING_BOMB", "LIVING_BOMB", "LIVING_BOMB" } },
    { name = "living_bomb_up_skips_reapply",
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, COMBUSTION = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false },
      expect = { "FROSTFIRE_BOLT", "FROSTFIRE_BOLT", "FROSTFIRE_BOLT" } },

    -- Both burst cooldowns are `hold = true` with no gate: each wins its own slot once, and since
    -- neither ever advances simulated time, both are permanently "just cast" (1-step virtual cooldown
    -- that elapsed can never clear) — the queue truncates to exactly 2 slots.
    { name = "combustion_then_icy_veins_both_off_gcd",
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COLD_SNAP = false,
                 BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false, FLAMESTRIKE = false,
                 FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "COMBUSTION", "ICY_VEINS" } },

    -- Trinkets: an item entry is suppressed for the rest of the queue once suggested (docs/02), so
    -- both fire once each and the queue truncates to 2 — mirrors paladin_exodin's `trinkets_only`.
    { name = "trinkets_only",
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false,
                 BLAST_WAVE = false, FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      items = { [13] = { cooldown = 0 }, [14] = { cooldown = 0 } },
      expect = { "item:13", "item:14" },
      expectLabels = { "Trinket", "Trinket" } },

    -- Icy Veins reads 45s remaining on the LIVE state; `cooldown_gt` still sees it well over 30 in
    -- the virtual overlay. MG1 fix pass item 3: `hold = true` now (matches the other cooldown lines,
    -- MG1-D4 item 5), so it never advances simulated time -- its own 1-step virtual cooldown never
    -- clears with nothing else usable, and the queue truncates to 1 slot.
    { name = "cold_snap_resets_icy_veins",
      cooldowns = { ICY_VEINS = 45 },
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 BALEFIRE_BOLT = false, LIVING_FLAME = false, BLAST_WAVE = false, FLAMESTRIKE = false,
                 FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "COLD_SNAP" } },

    -- Balefire Bolt's `max = 3` self-cap: at or under 3 stacks it fires; at 4 it is blocked and the
    -- queue falls through to a filler — MG1-D5(a)'s whole reason for existing.
    { name = "balefire_three_stacks_castable",
      buffs = { BALEFIRE_BOLT = { stacks = 3, remaining = 20 } },
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, LIVING_FLAME = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "BALEFIRE_BOLT", "BALEFIRE_BOLT", "BALEFIRE_BOLT" } },
    { name = "balefire_four_stacks_blocked_falls_through",
      buffs = { BALEFIRE_BOLT = { stacks = 4, remaining = 20 } },
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, LIVING_FLAME = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false, FIREBALL = false },
      expect = { "FROSTFIRE_BOLT", "FROSTFIRE_BOLT", "FROSTFIRE_BOLT" } },

    -- AoE promotion, one spell isolated at a time (all three share the identical `enemies >= 3` gate
    -- and would otherwise always shadow each other by list position).
    { name = "aoe_living_flame_at_three_enemies",
      enemies = 3,
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, BALEFIRE_BOLT = false, BLAST_WAVE = false,
                 FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "LIVING_FLAME", "LIVING_FLAME", "LIVING_FLAME" },
      expectLabels = { "AoE", "AoE", "AoE" } },
    { name = "aoe_blast_wave_at_three_enemies",
      enemies = 3,
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false,
                 FLAMESTRIKE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "BLAST_WAVE", "BLAST_WAVE", "BLAST_WAVE" },
      expectLabels = { "AoE", "AoE", "AoE" } },
    { name = "aoe_flamestrike_at_three_enemies",
      enemies = 3,
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false,
                 BLAST_WAVE = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "FLAMESTRIKE", "FLAMESTRIKE", "FLAMESTRIKE" },
      expectLabels = { "AoE", "AoE", "AoE" } },

    -- Rule-review finding (MG1 fix pass item 1): the three AoE lines' `{"enemies", min = 3}` gate
    -- had no scenario proving the FALSE branch — removing the `when` entirely, or loosening it to
    -- `min = 2`, left the suite green. Unlike the "at three enemies" scenarios above, the AoE spells
    -- are left USABLE here (only what sits ABOVE them in the list is silenced) so a wrongly-passing
    -- gate would win the slot instead of the filler below — mirrors Paladin's own
    -- `cleave_two_no_aoe_avengers_shield` (fixture ~709-716).
    { name = "aoe_enemies_one_no_promotion",
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, BALEFIRE_BOLT = false, FIREBALL = false },
      expect = { "FROSTFIRE_BOLT", "FROSTFIRE_BOLT", "FROSTFIRE_BOLT" } },
    { name = "aoe_enemies_two_no_promotion",
      enemies = 2,
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, BALEFIRE_BOLT = false, FIREBALL = false },
      expect = { "FROSTFIRE_BOLT", "FROSTFIRE_BOLT", "FROSTFIRE_BOLT" } },

    -- Baseline fillers, isolated.
    { name = "frostfire_bolt_filler_isolated",
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false,
                 BLAST_WAVE = false, FLAMESTRIKE = false, FIREBALL = false },
      expect = { "FROSTFIRE_BOLT", "FROSTFIRE_BOLT", "FROSTFIRE_BOLT" } },
    { name = "fireball_filler_isolated",
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false,
                 BLAST_WAVE = false, FLAMESTRIKE = false, FROSTFIRE_BOLT = false },
      expect = { "FIREBALL", "FIREBALL", "FIREBALL" } },

    -- Fireleaf Regalia 6pc (MG1-D3): all three thresholds are pure passive numeric interactions no
    -- build entry gates on (Wowhead describes a cooldown/tick-rate change, never a decision point),
    -- so this pins `state:bonus()` resolution directly rather than through a queue difference — the
    -- same `bonusExpected` mechanism gear_matrix_spec.lua already runs for every scenario that sets it.
    { name = "fireleaf_6pc_bonuses_resolve",
      sets = { MAGE_FIRELEAF_REGALIA = 6 },
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false,
                 BLAST_WAVE = false, FLAMESTRIKE = false, FIREBALL = false },
      expect = { "FROSTFIRE_BOLT", "FROSTFIRE_BOLT", "FROSTFIRE_BOLT" },
      bonusExpected = { LIVING_BOMB_FAST_TICK = true, PYROBLAST_CLEARS_BALEFIRE = true, FIRE_BLAST_REFRESHES_LB = true } },
    { name = "fireleaf_below_threshold_bonuses_absent",
      sets = { MAGE_FIRELEAF_REGALIA = 1 },
      usable = { PYROBLAST = false, FIRE_BLAST = false, SCORCH = false, LIVING_BOMB = false, COMBUSTION = false,
                 ICY_VEINS = false, COLD_SNAP = false, BALEFIRE_BOLT = false, LIVING_FLAME = false,
                 BLAST_WAVE = false, FLAMESTRIKE = false, FIREBALL = false },
      expect = { "FROSTFIRE_BOLT", "FROSTFIRE_BOLT", "FROSTFIRE_BOLT" },
      bonusExpected = { LIVING_BOMB_FAST_TICK = false, PYROBLAST_CLEARS_BALEFIRE = false, FIRE_BLAST_REFRESHES_LB = false } },
  },

  -- =================================================================================================
  -- MAGE_FROST_SPELLFROST (MG1-D7)
  MAGE_FROST_SPELLFROST = {
    -- Natural cascade with the 7 non-chest runes engraved: Molten Armor fails (default `inCombat`),
    -- Deep Freeze/Ice Lance fail (no Fingers of Frost), Frozen Orb has no gate and no sourced
    -- cooldown, so it wins every slot by list position over Living Bomb below it.
    { name = "runes_engraved_baseline",
      runes = { RUNE_DEEP_FREEZE = true, RUNE_FROZEN_ORB = true, RUNE_MOLTEN_ARMOR = true, RUNE_ICE_LANCE = true,
                RUNE_SPELLFROST_BOLT = true, RUNE_ICY_VEINS = true, RUNE_SPELL_POWER = true },
      expect = { "FROZEN_ORB", "FROZEN_ORB", "FROZEN_ORB" } },

    -- Molten Armor: out of combat and not already up -> applied once; casting it sets its own
    -- self-buff for the virtual slots after, so `no_buff` correctly stops re-suggesting it.
    { name = "molten_armor_precombat",
      inCombat = false,
      usable = { DEEP_FREEZE = false, ICE_LANCE = false, FROZEN_ORB = false, LIVING_BOMB = false, ICY_VEINS = false,
                 COLD_SNAP = false, LIVING_FLAME = false, BALEFIRE_BOLT = false, SPELLFROST_BOLT = false,
                 FROSTBOLT = false },
      expect = { "MOLTEN_ARMOR" } },

    -- Fingers of Frost up: Deep Freeze (listed first) wins the shatter combo's guaranteed-stun slot;
    -- FINGERS_OF_FROST_BUFF is `proc = true`, so the proc is suppressed for every slot past t=0 and
    -- the queue truncates to 1 with nothing else usable.
    { name = "fof_up_deep_freeze_wins",
      buffs = { FINGERS_OF_FROST_BUFF = { stacks = 1, remaining = 15 } },
      usable = { FROZEN_ORB = false, LIVING_BOMB = false, ICY_VEINS = false, COLD_SNAP = false, LIVING_FLAME = false,
                 BALEFIRE_BOLT = false, SPELLFROST_BOLT = false, FROSTBOLT = false },
      expect = { "DEEP_FREEZE" },
      expectLabels = { "FoF" } },
    -- Same proc, with Deep Freeze silenced so Ice Lance (the actual shatter nuke) surfaces instead.
    { name = "fof_up_ice_lance_when_deep_freeze_silenced",
      buffs = { FINGERS_OF_FROST_BUFF = { stacks = 1, remaining = 15 } },
      usable = { DEEP_FREEZE = false, FROZEN_ORB = false, LIVING_BOMB = false, ICY_VEINS = false, COLD_SNAP = false,
                 LIVING_FLAME = false, BALEFIRE_BOLT = false, SPELLFROST_BOLT = false, FROSTBOLT = false },
      expect = { "ICE_LANCE" },
      expectLabels = { "Shatter" } },

    -- Living Bomb maintenance, isolated.
    { name = "living_bomb_absent_is_applied",
      debuffs = {},
      usable = { DEEP_FREEZE = false, ICE_LANCE = false, FROZEN_ORB = false, ICY_VEINS = false, COLD_SNAP = false,
                 LIVING_FLAME = false, BALEFIRE_BOLT = false, SPELLFROST_BOLT = false, FROSTBOLT = false },
      expect = { "LIVING_BOMB", "LIVING_BOMB", "LIVING_BOMB" } },

    -- Icy Veins alone (`hold = true`, no gate): wins slot 1, then permanently "just cast" since
    -- nothing else is usable and simulated time never advances for it.
    { name = "icy_veins_isolated",
      usable = { DEEP_FREEZE = false, ICE_LANCE = false, FROZEN_ORB = false, LIVING_BOMB = false, COLD_SNAP = false,
                 LIVING_FLAME = false, BALEFIRE_BOLT = false, SPELLFROST_BOLT = false, FROSTBOLT = false },
      expect = { "ICY_VEINS" } },

    { name = "trinkets_only",
      usable = { DEEP_FREEZE = false, ICE_LANCE = false, FROZEN_ORB = false, LIVING_BOMB = false, ICY_VEINS = false,
                 COLD_SNAP = false, LIVING_FLAME = false, BALEFIRE_BOLT = false, SPELLFROST_BOLT = false,
                 FROSTBOLT = false },
      items = { [13] = { cooldown = 0 }, [14] = { cooldown = 0 } },
      expect = { "item:13", "item:14" },
      expectLabels = { "Trinket", "Trinket" } },

    -- MG1 fix pass item 3: `hold = true` now (matches the other cooldown lines, MG1-D4 item 5), so
    -- it never advances simulated time — its own 1-step virtual cooldown never clears with nothing
    -- else usable, and the queue truncates to 1 slot instead of repeating 3 times.
    { name = "cold_snap_resets_icy_veins",
      cooldowns = { ICY_VEINS = 45 },
      usable = { DEEP_FREEZE = false, ICE_LANCE = false, FROZEN_ORB = false, LIVING_BOMB = false,
                 LIVING_FLAME = false, BALEFIRE_BOLT = false, SPELLFROST_BOLT = false, FROSTBOLT = false },
      expect = { "COLD_SNAP" } },

    { name = "aoe_living_flame_at_three_enemies",
      enemies = 3,
      usable = { DEEP_FREEZE = false, ICE_LANCE = false, FROZEN_ORB = false, LIVING_BOMB = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, SPELLFROST_BOLT = false, FROSTBOLT = false },
      expect = { "LIVING_FLAME", "LIVING_FLAME", "LIVING_FLAME" },
      expectLabels = { "AoE", "AoE", "AoE" } },

    -- Rule-review finding (MG1 fix pass item 1), Frost's own copy of the gate: left USABLE (only
    -- what outranks it in the list is silenced), enemies unset/1 and enemies = 2 must both fall
    -- through to the Frostbolt filler rather than promoting Living Flame.
    { name = "aoe_enemies_one_no_promotion",
      usable = { DEEP_FREEZE = false, ICE_LANCE = false, FROZEN_ORB = false, LIVING_BOMB = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, SPELLFROST_BOLT = false },
      expect = { "FROSTBOLT", "FROSTBOLT", "FROSTBOLT" } },
    { name = "aoe_enemies_two_no_promotion",
      enemies = 2,
      usable = { DEEP_FREEZE = false, ICE_LANCE = false, FROZEN_ORB = false, LIVING_BOMB = false, ICY_VEINS = false,
                 COLD_SNAP = false, BALEFIRE_BOLT = false, SPELLFROST_BOLT = false },
      expect = { "FROSTBOLT", "FROSTBOLT", "FROSTBOLT" } },

    -- Balefire Bolt's self-cap, identical semantics to the Fire build's own entry line (a SEPARATE
    -- source line in THIS file, so it needs its own scenario for the mutation gate).
    { name = "balefire_three_stacks_castable",
      buffs = { BALEFIRE_BOLT = { stacks = 3, remaining = 20 } },
      usable = { DEEP_FREEZE = false, ICE_LANCE = false, FROZEN_ORB = false, LIVING_BOMB = false, ICY_VEINS = false,
                 COLD_SNAP = false, LIVING_FLAME = false, SPELLFROST_BOLT = false, FROSTBOLT = false },
      expect = { "BALEFIRE_BOLT", "BALEFIRE_BOLT", "BALEFIRE_BOLT" } },
    { name = "balefire_four_stacks_blocked_falls_through",
      buffs = { BALEFIRE_BOLT = { stacks = 4, remaining = 20 } },
      usable = { DEEP_FREEZE = false, ICE_LANCE = false, FROZEN_ORB = false, LIVING_BOMB = false, ICY_VEINS = false,
                 COLD_SNAP = false, LIVING_FLAME = false, FROSTBOLT = false },
      expect = { "SPELLFROST_BOLT", "SPELLFROST_BOLT", "SPELLFROST_BOLT" } },

    { name = "frostbolt_filler_isolated",
      usable = { DEEP_FREEZE = false, ICE_LANCE = false, FROZEN_ORB = false, LIVING_BOMB = false, ICY_VEINS = false,
                 COLD_SNAP = false, LIVING_FLAME = false, BALEFIRE_BOLT = false, SPELLFROST_BOLT = false },
      expect = { "FROSTBOLT", "FROSTBOLT", "FROSTBOLT" } },
  },

  -- =================================================================================================
  -- MAGE_FROST_LEVELING (MG1-D7)
  MAGE_FROST_LEVELING = {
    { name = "runes_engraved_baseline",
      runes = { RUNE_LIVING_BOMB = true, RUNE_LIVING_FLAME = true, RUNE_FROSTFIRE_BOLT = true,
                RUNE_DEEP_FREEZE = true, RUNE_FROZEN_ORB = true, RUNE_BRAIN_FREEZE = true },
      debuffs = {},
      expect = { "LIVING_BOMB", "LIVING_BOMB", "LIVING_BOMB" } },

    { name = "living_bomb_up_skips_reapply",
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { FIRE_BLAST = false, BLIZZARD = false, ARCANE_EXPLOSION = false, CONE_OF_COLD = false,
                 FROSTFIRE_BOLT = false, FROSTBOLT = false },
      expect = { "FROZEN_ORB", "FROZEN_ORB", "FROZEN_ORB" } },

    { name = "frozen_orb_isolated",
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { FIRE_BLAST = false, BLIZZARD = false, ARCANE_EXPLOSION = false, CONE_OF_COLD = false,
                 FROSTFIRE_BOLT = false, FROSTBOLT = false, FIREBALL = false },
      expect = { "FROZEN_ORB", "FROZEN_ORB", "FROZEN_ORB" } },

    { name = "fire_blast_isolated",
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { FROZEN_ORB = false, BLIZZARD = false, ARCANE_EXPLOSION = false, CONE_OF_COLD = false,
                 FROSTFIRE_BOLT = false, FROSTBOLT = false, FIREBALL = false },
      expect = { "FIRE_BLAST", "FIRE_BLAST", "FIRE_BLAST" } },

    { name = "aoe_blizzard_at_three_enemies",
      enemies = 3,
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { FROZEN_ORB = false, FIRE_BLAST = false, ARCANE_EXPLOSION = false, CONE_OF_COLD = false,
                 FROSTFIRE_BOLT = false, FROSTBOLT = false, FIREBALL = false },
      expect = { "BLIZZARD", "BLIZZARD", "BLIZZARD" },
      expectLabels = { "AoE", "AoE", "AoE" } },
    { name = "aoe_arcane_explosion_at_three_enemies",
      enemies = 3,
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { FROZEN_ORB = false, FIRE_BLAST = false, BLIZZARD = false, CONE_OF_COLD = false,
                 FROSTFIRE_BOLT = false, FROSTBOLT = false, FIREBALL = false },
      expect = { "ARCANE_EXPLOSION", "ARCANE_EXPLOSION", "ARCANE_EXPLOSION" },
      expectLabels = { "AoE", "AoE", "AoE" } },
    { name = "aoe_cone_of_cold_at_three_enemies",
      enemies = 3,
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { FROZEN_ORB = false, FIRE_BLAST = false, BLIZZARD = false, ARCANE_EXPLOSION = false,
                 FROSTFIRE_BOLT = false, FROSTBOLT = false, FIREBALL = false },
      expect = { "CONE_OF_COLD", "CONE_OF_COLD", "CONE_OF_COLD" },
      expectLabels = { "AoE", "AoE", "AoE" } },

    -- Rule-review finding (MG1 fix pass item 1), Leveling's three AoE lines: left USABLE, enemies
    -- unset/1 and enemies = 2 must both fall through to the Frostfire Bolt filler rather than
    -- promoting any of Blizzard/Arcane Explosion/Cone of Cold.
    { name = "aoe_enemies_one_no_promotion",
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { FROZEN_ORB = false, FIRE_BLAST = false },
      expect = { "FROSTFIRE_BOLT", "FROSTFIRE_BOLT", "FROSTFIRE_BOLT" } },
    { name = "aoe_enemies_two_no_promotion",
      enemies = 2,
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { FROZEN_ORB = false, FIRE_BLAST = false },
      expect = { "FROSTFIRE_BOLT", "FROSTFIRE_BOLT", "FROSTFIRE_BOLT" } },

    { name = "frostfire_bolt_filler_isolated",
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { FROZEN_ORB = false, FIRE_BLAST = false, BLIZZARD = false, ARCANE_EXPLOSION = false,
                 CONE_OF_COLD = false, FROSTBOLT = false, FIREBALL = false },
      expect = { "FROSTFIRE_BOLT", "FROSTFIRE_BOLT", "FROSTFIRE_BOLT" } },
    { name = "frostbolt_filler_isolated",
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { FROZEN_ORB = false, FIRE_BLAST = false, BLIZZARD = false, ARCANE_EXPLOSION = false,
                 CONE_OF_COLD = false, FROSTFIRE_BOLT = false, FIREBALL = false },
      expect = { "FROSTBOLT", "FROSTBOLT", "FROSTBOLT" } },
    { name = "fireball_filler_isolated",
      debuffs = { LIVING_BOMB = { stacks = 1, remaining = 10, mine = true } },
      usable = { FROZEN_ORB = false, FIRE_BLAST = false, BLIZZARD = false, ARCANE_EXPLOSION = false,
                 CONE_OF_COLD = false, FROSTFIRE_BOLT = false, FROSTBOLT = false },
      expect = { "FIREBALL", "FIREBALL", "FIREBALL" } },
  },

  -- =================================================================================================
  -- MAGE_ARCANE_HEALER (MG2-D5). Every scenario below silences whatever outranks the entry under
  -- test by SPELL (never by `when`) so the fixture proves the ENGINE, not the fixture's own gate --
  -- the same discipline MAGE_FIRE's scenarios use throughout this file. `ARCANE_BLAST` is produced by
  -- two entries (`Build stacks` and the unlabelled baseline), so any scenario whose `expect` touches
  -- it needs `expectLabels` (gear_matrix_spec.lua's ambiguity guard).
  MAGE_ARCANE_HEALER = {
    -- Reminder 1 (MASS_REGENERATION): held while off cooldown, isolated from everything else.
    { name = "mass_regeneration_reminder_appears_off_cooldown",
      usable = { REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false, EVOCATION = false,
                 ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false,
                 ARCANE_BLAST = false },
      expect = { "MASS_REGENERATION" },
      expectLabels = { "Beacons (reminder)" } },
    -- On cooldown: gone. Falls through everything else to the baseline stack-builder, the honest
    -- floor once every other entry is silenced too.
    { name = "mass_regeneration_reminder_gone_on_cooldown",
      cooldowns = { MASS_REGENERATION = 5 },
      usable = { REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false, EVOCATION = false,
                 ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false },
      expect = { "ARCANE_BLAST", "ARCANE_BLAST", "ARCANE_BLAST" },
      expectLabels = { "Build stacks", "Build stacks", "Build stacks" } },

    -- Reminder 2 (REWIND_TIME): same shape, a separate source line.
    { name = "rewind_time_reminder_appears_off_cooldown",
      usable = { MASS_REGENERATION = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false, EVOCATION = false,
                 ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false,
                 ARCANE_BLAST = false },
      expect = { "REWIND_TIME" },
      expectLabels = { "Rewind (reminder)" } },
    { name = "rewind_time_reminder_gone_on_cooldown",
      cooldowns = { REWIND_TIME = 10 },
      usable = { MASS_REGENERATION = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false, EVOCATION = false,
                 ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false },
      expect = { "ARCANE_BLAST", "ARCANE_BLAST", "ARCANE_BLAST" },
      expectLabels = { "Build stacks", "Build stacks", "Build stacks" } },

    -- Self-buff cooldowns, isolated.
    { name = "arcane_power_isolated",
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, PRESENCE_OF_MIND = false, EVOCATION = false,
                 ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false,
                 ARCANE_BLAST = false },
      expect = { "ARCANE_POWER" } },
    { name = "presence_of_mind_isolated",
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, EVOCATION = false,
                 ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false,
                 ARCANE_BLAST = false },
      expect = { "PRESENCE_OF_MIND" } },

    -- Trinkets: an item entry is suppressed for the rest of the queue once suggested (docs/02).
    { name = "trinkets_only",
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 EVOCATION = false, ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false,
                 BALEFIRE_BOLT = false, ARCANE_BLAST = false },
      items = { [13] = { cooldown = 0 }, [14] = { cooldown = 0 } },
      expect = { "item:13", "item:14" },
      expectLabels = { "Trinket", "Trinket" } },

    -- Evocation's mana gate: `maxPct` is inclusive (docs/02 `inRange`), so exactly 20% still passes;
    -- 21% must fall through.
    -- Evocation has no sourced `cooldown` field (no fetched page quoted one), so Simulation's virtual
    -- state falls back to a one-time-step estimate and the mana condition stays true throughout (the
    -- virtual overlay does not model mana regen/consumption for it) — it repeats every slot, the same
    -- sourcing-gap shape MAGE_FIRE's own "overheat_not_engraved_uses_baseline_fire_blast" documents.
    { name = "evocation_ready_at_twenty_percent_mana",
      power = { MANA = { 200, 1000 } },
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false,
                 ARCANE_BLAST = false },
      expect = { "EVOCATION", "EVOCATION", "EVOCATION" },
      expectLabels = { "Mana", "Mana", "Mana" } },
    { name = "evocation_not_ready_at_twenty_one_percent_mana",
      power = { MANA = { 210, 1000 } },
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false },
      expect = { "ARCANE_BLAST", "ARCANE_BLAST", "ARCANE_BLAST" },
      expectLabels = { "Build stacks", "Build stacks", "Build stacks" } },

    -- Missile Barrage proc: up wins its own slot; MISSILE_BARRAGE_BUFF is `proc = true` so the queue
    -- truncates to 1 with nothing else usable, matching HOT_STREAK_BUFF/FINGERS_OF_FROST_BUFF's shape
    -- elsewhere in this file. Absent falls through to the baseline stack-builder.
    { name = "missile_barrage_proc_up",
      buffs = { MISSILE_BARRAGE_BUFF = { stacks = 1, remaining = 15 } },
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 EVOCATION = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false,
                 ARCANE_BLAST = false },
      expect = { "ARCANE_MISSILES" },
      expectLabels = { "Missile Barrage" } },
    { name = "missile_barrage_absent_falls_through",
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 EVOCATION = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false },
      expect = { "ARCANE_BLAST", "ARCANE_BLAST", "ARCANE_BLAST" },
      expectLabels = { "Build stacks", "Build stacks", "Build stacks" } },

    -- Arcane Blast stack thresholds: 0/absent and 1 both read as "Build stacks" (`max = 1` passes on
    -- absence too, MG1-D5a); 2 stacks promotes Arcane Barrage instead, and Build stacks is no longer
    -- eligible at all -- the queue falls to the unlabelled baseline, proving the cap actually stops
    -- it rather than merely relabelling it.
    { name = "arcane_blast_one_stack_still_builds",
      buffs = { ARCANE_BLAST_BUFF = { stacks = 1, remaining = 6 } },
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 EVOCATION = false, ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false,
                 BALEFIRE_BOLT = false },
      expect = { "ARCANE_BLAST", "ARCANE_BLAST", "ARCANE_BLAST" },
      expectLabels = { "Build stacks", "Build stacks", "Build stacks" } },
    -- Rule-review finding: the scenario above silences ARCANE_BARRAGE outright, so a `min = 2` ->
    -- `min = 1` mutation on ITS OWN line is never exercised through a queue. Leaves Arcane Barrage
    -- LIVE at exactly 1 stack instead — unmutated code must still fall through to Build stacks.
    { name = "arcane_blast_one_stack_barrage_live_not_promoted",
      buffs = { ARCANE_BLAST_BUFF = { stacks = 1, remaining = 6 } },
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 BALEFIRE_BOLT = false },
      expect = { "ARCANE_BLAST", "ARCANE_BLAST", "ARCANE_BLAST" },
      expectLabels = { "Build stacks", "Build stacks", "Build stacks" } },
    -- (2 stacks at 1 enemy promoting Arcane Barrage, not Build stacks, is proven by the AoE block's
    -- own "one_enemy_two_stacks_barrage_wins_not_aoe" scenario below -- not duplicated here.)
    { name = "arcane_blast_two_stacks_build_stacks_not_eligible",
      buffs = { ARCANE_BLAST_BUFF = { stacks = 2, remaining = 6 } },
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 EVOCATION = false, ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false,
                 BALEFIRE_BOLT = false },
      expect = { "ARCANE_BLAST", "ARCANE_BLAST", "ARCANE_BLAST" },
      expectLabels = { false, false, false } },

    -- AoE promotion: 2 enemies + 2 Arcane Blast stacks promotes Arcane Explosion ahead of Arcane
    -- Barrage (both are eligible; Arcane Explosion is listed first). At 1 enemy (the default) the
    -- same stack count leaves Arcane Barrage the winner -- proves the `enemies` gate, not just the
    -- stack one, decides between them.
    -- Neither Arcane Explosion nor Arcane Barrage carries a sourced `cooldown`, and the virtual state
    -- does not model the Arcane Blast stack count changing, so both repeat every slot once they win —
    -- same sourcing-gap shape as Evocation above.
    { name = "aoe_two_enemies_two_stacks_promotes_arcane_explosion",
      enemies = 2,
      buffs = { ARCANE_BLAST_BUFF = { stacks = 2, remaining = 6 } },
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 EVOCATION = false, ARCANE_MISSILES = false },
      expect = { "ARCANE_EXPLOSION", "ARCANE_EXPLOSION", "ARCANE_EXPLOSION" },
      expectLabels = { "AoE", "AoE", "AoE" } },
    { name = "one_enemy_two_stacks_barrage_wins_not_aoe",
      buffs = { ARCANE_BLAST_BUFF = { stacks = 2, remaining = 6 } },
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 EVOCATION = false, ARCANE_MISSILES = false },
      expect = { "ARCANE_BARRAGE", "ARCANE_BARRAGE", "ARCANE_BARRAGE" },
      expectLabels = { "2 stacks", "2 stacks", "2 stacks" } },
    -- Rule-review finding: the AoE line was negative-tested only at 0 stacks elsewhere in this file, a
    -- boundary a `min = 2` -> `min = 1` mutation on its own line still correctly rejects (0 < 1 too).
    -- 2 enemies + EXACTLY 1 stack is the case that actually kills it — unmutated code must still fall
    -- through to Build stacks, not Arcane Explosion.
    { name = "two_enemies_one_stack_arcane_explosion_not_promoted",
      enemies = 2,
      buffs = { ARCANE_BLAST_BUFF = { stacks = 1, remaining = 6 } },
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 BALEFIRE_BOLT = false },
      expect = { "ARCANE_BLAST", "ARCANE_BLAST", "ARCANE_BLAST" },
      expectLabels = { "Build stacks", "Build stacks", "Build stacks" } },

    -- Balefire Bolt's `max = 3` self-cap, identical semantics to the Fire/Frost builds' own entries
    -- (a separate source line here, so it needs its own scenario for the mutation gate).
    { name = "balefire_three_stacks_castable",
      buffs = { BALEFIRE_BOLT = { stacks = 3, remaining = 20 } },
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 EVOCATION = false, ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false },
      expect = { "BALEFIRE_BOLT", "BALEFIRE_BOLT", "BALEFIRE_BOLT" } },
    { name = "balefire_four_stacks_blocked_falls_through",
      buffs = { BALEFIRE_BOLT = { stacks = 4, remaining = 20 } },
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 EVOCATION = false, ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false },
      expect = { "ARCANE_BLAST", "ARCANE_BLAST", "ARCANE_BLAST" },
      expectLabels = { "Build stacks", "Build stacks", "Build stacks" } },

    -- Baseline filler, isolated (no Arcane Blast stack, everything else silenced).
    { name = "arcane_blast_baseline_filler_isolated",
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 EVOCATION = false, ARCANE_MISSILES = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false,
                 BALEFIRE_BOLT = false },
      expect = { "ARCANE_BLAST", "ARCANE_BLAST", "ARCANE_BLAST" },
      expectLabels = { "Build stacks", "Build stacks", "Build stacks" } },

    -- MG2-D5's own floor: "with no runes at all the queue is ARCANE_BLAST only and nothing errors."
    -- Read literally against the shipped data this cannot mean an EMPTY rune set -- Arcane Blast
    -- itself is a hands-slot SoD rune ability (mage-healer-ids-verified-2026-09-14.md), so a
    -- genuinely bare character would not know it either and the queue would be empty, not
    -- ARCANE_BLAST-only (flagged during implementation). This scenario proves the honest floor
    -- the sentence actually describes: every OTHER build-specific ability made unpickable (`usable =
    -- false`, the same fixture mechanism this whole file uses to stand in for "unknown" -- an
    -- un-engraved rune's ability fails the engine's own `state:usable` check on the real adapter, not
    -- a separate `state:known` one; see Core/Engine.lua's `eligible`), Arcane Blast alone still
    -- produces a safe, non-erroring, single-spell queue -- never an engine error, never an empty pick.
    { name = "minimum_kit_falls_back_to_arcane_blast_only",
      usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                 EVOCATION = false, ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false },
      expect = { "ARCANE_BLAST", "ARCANE_BLAST", "ARCANE_BLAST" },
      expectLabels = { "Build stacks", "Build stacks", "Build stacks" } },
  },
}
