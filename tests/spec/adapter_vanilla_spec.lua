-- NOTE (reconciled 2026-09-01): this file was written with dot-style calls
-- (state.cooldown(key)). Core calls every accessor with COLON syntax (state:cooldown(key)) in both
-- Engine.lua and Schema.lua, and tests/fake_state.lua defines them that way, so colon is
-- authoritative — under dot-style the adapter would receive the state table as the spell key.
-- The 88 call sites were converted mechanically; not one assertion was changed. The root cause was
-- that docs/01 §2 never stated the convention, which is now fixed there.
-- tests/spec/adapter_vanilla_spec.lua — Elmira/Adapters/Vanilla.lua's gear/state provider, against
-- docs/01-ARCHITECTURE.md §2 (State contract), §4 (Vanilla.lua) and §5a (gear provider), and
-- docs/07-INGAME-VERIFICATION-BASELINE.md §9 (the M2 probe, which overrides any API doc when the
-- two disagree).
--
-- WRITTEN FROM THE DOCS, NOT THE IMPLEMENTATION. Vanilla.lua is an M0 stub while the real M2 work
-- lands in parallel; this file must not be shaped around whatever the stub currently does, because
-- that is exactly the failure mode that let three of four M1 bugs through — a spec that only
-- re-asserts what the code already does. Every assertion below is expected to fail red until M2
-- lands, and that is correct.
--
-- ASSUMPTION (constructor shape): neither doc names how a data pack (Spells/Sets/Souls) gets into
-- the adapter's State. The M0 stub only exposes a static `Vanilla.state`, seeded from
-- Interface.newNullState(), with no hook to inject class data at all. Every case here that needs to
-- resolve a symbolic key (rune/spell/set/soul) to a real id calls
--   Vanilla.newState(spells, sets, souls)
-- and asserts on the RETURNED table, because that is the most testable shape (no shared mutable
-- adapter state leaking between specs) and matches Engine.lua/Schema.lua's actual calling
-- convention: `state:cooldown(entry.spell)`, `state:usable(entry.spell)` etc. are called with the
-- BUILD'S SYMBOLIC KEY, not a raw spellID, despite docs/01 §2's `spellID` parameter name — see
-- Core/Schema.lua's `C.cooldown_ready`/`C.buff`/`C.seal` compilers and tests/fake_state.lua, which
-- key every table by symbolic name (`CRUSADER_STRIKE`, `EXORCISM`). If M2 instead wires data via a
-- module-level setter onto a singleton `Vanilla.state`, only the call sites in this file need
-- adjusting — every assertion still names the real behaviour to pin.
local helper = require("tests.helper")
local mock = require("tests.wow_mock")

-- Real ids from the docs/07 §9 probe. Using them (rather than synthetic ids, tests/fixtures/spells.lua's
-- convention for CORE specs) is deliberate here: the discriminating cases below — rune teach-vs-
-- ability, GetSpellCooldown vs GetSpellBaseCooldown, GetSpellPowerCost tracking a rune — only mean
-- anything when pinned to the exact numbers the bug shipped with (mirrors collector_spec.lua).
local function spellsFixture()
  return {
    EXORCISM                  = { id = 415073 },
    HOLY_WRATH                 = { id = 429146 },
    JUDGEMENT                  = { id = 20271 },
    CONSECRATION                = { id = 20924 },
    AVENGING_WRATH_BUFF         = { id = 407788 },
    SEAL_OF_MARTYRDOM           = { id = 407798, seal = true },
    -- Synthetic (900xxx): a second seal so "no matching seal aura" has something to not-match.
    SEAL_OF_RIGHTEOUSNESS       = { id = 900001, seal = true },
    -- docs/07 §9.12: the chest rune's data key held the TEACH id (425614); detection matches the
    -- ABILITY id (458287). Tests below start from the shipped bug and then fix it, per instructions.
    RUNE_HALLOWED_GROUND        = { id = 425614, rune = "chest" },
    -- Already correct at probe time — legs rune, ability id (docs/07 §9.12).
    RUNE_REBUKE                  = { id = 425609, rune = "legs" },
    -- Synthetic debuff ids for the mine-filter case.
    JUDGEMENT_OF_LIGHT_DEBUFF    = { id = 900301 },
    OTHER_TARGET_DEBUFF          = { id = 900302 },
  }
end

-- Synthetic set (900100s) — mirrors Data/<flavor>/Sets.lua SHAPE only (docs/01 §5), so this proves
-- the RESOLUTION MECHANISM (equipped item ids -> set membership -> threshold), not any real class
-- pack's numbers.
local function setsFixture()
  return {
    LAWBRINGER = {
      name = "Lawbringer (fixture)",
      items = { 900101, 900102, 900103, 900104 },
      bonuses = { [2] = { bonus = "AVENGERS_2P" }, [4] = { bonus = "AVENGERS_4P" } },
    },
  }
end

-- Souls.lua shape (docs/01 §5): {itemID=, grants={"BONUS_KEY"}, src=}. ASSUMPTION: the "matchable
-- name" field docs/01 §5a says Souls.lua needs is called `short` here — neither doc names the field,
-- so this is a guess at the schema, not the detection logic.
local function soulsFixture()
  return {
    -- 226588 is the verified shoulder item from docs/07 §9.10 wearing this soul.
    SOUL_OF_THE_EXILE      = { itemID = 226588, short = "Exile", grants = { "EXORCISM_FAST" } },
    SOUL_OF_THE_RETRIBUTOR = { itemID = 900201, short = "Retributor", grants = { "AVENGERS_2P" } },
  }
end

describe("Adapters.Vanilla (State provider, docs/01 §2/§4/§5a, docs/07 §9)", function()
  local Vanilla, Interface

  before_each(function()
    mock.reset()
    helper.reset()
    Interface = helper.load("Elmira/Adapters/Interface.lua")
    Vanilla = helper.load("Elmira/Adapters/Vanilla.lua")
  end)

  -- ============================================================ 1. baseCooldown / GCD filtering
  -- The headline finding (docs/07 §9.1, §9.10): GetSpellBaseCooldown is a dead end (15000 ms in
  -- every gear state); the real value comes from observing GetSpellCooldown when the spell is
  -- ACTUALLY on cooldown, and a GCD reading must never be cached as that observation.
  describe("baseCooldown() — observe GetSpellCooldown, never GetSpellBaseCooldown, never cache the GCD", function()
    it("does not cache a GCD reading as the spell's cooldown", function()
      local spells = spellsFixture()
      mock.spell(spells.EXORCISM.id, { known = true }) -- no real cooldown queued
      mock.gcdActive = true                            -- GetSpellCooldown now reports 1.5 for ANY id

      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      state:baseCooldown("EXORCISM") -- an observation attempt taken during the GCD

      -- Must still read as unknown (0), not 1.5 — the exact poisoning docs/07 §9.10 warns about.
      assert.equal(0, state:baseCooldown("EXORCISM"))
    end)

    it("caches a real observation once the spell is genuinely on cooldown", function()
      local spells = spellsFixture()
      mock.spell(spells.EXORCISM.id, { known = true, cooldown = 6 }) -- the live 6.0 s from docs/07 §9.1

      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.equal(6, state:baseCooldown("EXORCISM"))
    end)

    it("reports unknown (0) for a spell never observed on cooldown — no shipped fallback", function()
      local spells = spellsFixture()
      mock.spell(spells.EXORCISM.id, { known = true }) -- known, but never actually went on cooldown

      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.equal(0, state:baseCooldown("EXORCISM"))
    end)

    it("never touches GetSpellBaseCooldown at all", function()
      local called = false
      _G.GetSpellBaseCooldown = function() called = true; return 15000 end -- the dead-end API

      local spells = spellsFixture()
      mock.spell(spells.EXORCISM.id, { known = true, cooldown = 6 })
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      state:baseCooldown("EXORCISM")

      _G.GetSpellBaseCooldown = nil
      assert.is_false(called, "baseCooldown() must never call GetSpellBaseCooldown (docs/07 §9.1)")
    end)

    it("reports 0 for a key the data pack does not define", function()
      local state = Vanilla.newState({}, {}, {})
      assert.equal(0, state:baseCooldown("NOT_A_REAL_KEY"))
    end)
  end)

  -- ============================================================ 2. rune() — ability ids, not teach ids
  describe("rune() — matches ABILITY ids from learnedAbilitySpellIDs (docs/07 §9.5, §9.12)", function()
    it("does NOT match when the data key holds the teach id (the bug that shipped)", function()
      mock.runes[5] = { name = "Hallowed Ground", learnedAbilitySpellIDs = { 458287 } }
      local spells = spellsFixture() -- RUNE_HALLOWED_GROUND.id == 425614, the teach spell
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.is_false(state:rune("RUNE_HALLOWED_GROUND"))
    end)

    it("matches once the data key holds the ability id", function()
      mock.runes[5] = { name = "Hallowed Ground", learnedAbilitySpellIDs = { 458287 } }
      local spells = spellsFixture()
      spells.RUNE_HALLOWED_GROUND.id = 458287
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.is_true(state:rune("RUNE_HALLOWED_GROUND"))
    end)

    it("matches a rune already stored with the correct ability id, in any slot", function()
      mock.runes[7] = { name = "Rebuke", learnedAbilitySpellIDs = { 425609 } }
      local spells = spellsFixture() -- RUNE_REBUKE.id == 425609 already
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.is_true(state:rune("RUNE_REBUKE"))
    end)

    it("does not match against an unrelated slot's rune", function()
      mock.runes[7] = { name = "Rebuke", learnedAbilitySpellIDs = { 425609 } }
      local spells = spellsFixture() -- RUNE_HALLOWED_GROUND wants slot 5's rune, not slot 7's
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.is_false(state:rune("RUNE_HALLOWED_GROUND"))
    end)

    it("reports false for a key the data pack does not define", function()
      local state = Vanilla.newState({}, {}, {})
      assert.is_false(state:rune("RUNE_NOT_DEFINED"))
    end)

    it("reports false when no rune is engraved in any slot", function()
      local spells = spellsFixture()
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.is_false(state:rune("RUNE_HALLOWED_GROUND"))
      assert.is_false(state:rune("RUNE_REBUKE"))
    end)
  end)

  -- ============================================================ Capability flags
  describe("capabilities() — engraving vs runes must not be the same expression (docs/07 §9.5)", function()
    it("reports engraving disabled via IsEngravingEnabled() even though C_Engraving still exists", function()
      mock.engravingEnabled = false
      local caps = Vanilla.capabilities()
      assert.is_not_nil(_G.C_Engraving, "the mock keeps C_Engraving present for this case")
      assert.is_false(caps.engraving, "engraving must read IsEngravingEnabled(), not C_Engraving ~= nil")
    end)

    it("lets runes and engraving disagree in the same state", function()
      mock.engravingEnabled = false
      local caps = Vanilla.capabilities()
      -- A `C_Engraving ~= nil` implementation would make both flags identical to each other in every
      -- state, which is exactly what docs/07 §9.5 flags as wrong. Pin that they CAN differ.
      assert.is_not.equal(caps.runes, caps.engraving)
    end)

    it("reports engraving enabled when the client says so", function()
      mock.engravingEnabled = true
      assert.is_true(Vanilla.capabilities().engraving)
    end)
  end)

  -- ============================================================ 3. powerCost()
  describe("powerCost() — GetSpellPowerCost's LIST, cost[1].cost (docs/07 §9.3)", function()
    it("reads costs[1].cost and costs[1].name, not a bare number", function()
      local spells = spellsFixture()
      mock.spell(spells.EXORCISM.id, { known = true, cost = 69 }) -- Art of War engraved, docs/07 §9.2
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      local amount, kind = state:powerCost("EXORCISM")
      assert.equal(69, amount)
      assert.equal("MANA", kind)
    end)

    it("tracks a rune-driven cost change (345 -> 69), so no static table is consulted", function()
      local spells = spellsFixture()
      mock.spell(spells.EXORCISM.id, { known = true, cost = 345 }) -- no Art of War
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.equal(345, (state:powerCost("EXORCISM")))

      mock.powerCosts[spells.EXORCISM.id] = 69 -- Art of War engraved mid-session
      assert.equal(69, (state:powerCost("EXORCISM")))
    end)

    it("returns the safe zero for a spell with no cost table entry", function()
      local spells = spellsFixture()
      mock.spell(spells.JUDGEMENT.id, { known = true }) -- no cost registered
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      local amount, kind = state:powerCost("JUDGEMENT")
      assert.equal(0, amount)
      assert.is_nil(kind)
    end)

    it("returns the safe zero for a key the data pack does not define", function()
      local state = Vanilla.newState({}, {}, {})
      local amount, kind = state:powerCost("NOT_A_REAL_KEY")
      assert.equal(0, amount)
      assert.is_nil(kind)
    end)
  end)

  -- ============================================================ 4. enchant() / souls from tooltip
  describe("enchant() — shoulder souls come from the TOOLTIP, not the item link (docs/07 §9.10)", function()
    it("finds the soul by its short tooltip name even with no item link at all", function()
      mock.tooltipLines[3] = {
        "Truthbearer Pauldrons", "Soulbound", "Shoulder", "562 Armor",
        "+12 Stamina", "Exile", "+15 Intellect", "Durability 100 / 100",
      }
      -- mock.itemLinks[3] deliberately left unset: docs/07 §9.10 found the link's enchant field
      -- empty (`|Hitem:226588::::::::60::::::::::|`), so an empty/absent link must not block detection.
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal("SOUL_OF_THE_EXILE", state:enchant(3))
    end)

    it("still finds the soul when the link is present but carries an empty enchant field", function()
      mock.tooltipLines[3] = { "Truthbearer Pauldrons", "Exile" }
      mock.itemLinks[3] = "|Hitem:226588::::::::60::::::::::|" -- verbatim from docs/07 §9.10
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal("SOUL_OF_THE_EXILE", state:enchant(3))
    end)

    it("returns nil rather than guessing when no line matches a known soul", function()
      mock.tooltipLines[3] = { "Truthbearer Pauldrons", "Soulbound", "Shoulder", "+12 Stamina" }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:enchant(3))
    end)

    it("returns nil for an empty shoulder slot", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:enchant(3))
    end)
  end)

  -- ============================================================ 5. bonus() — set threshold OR soul
  describe("bonus() — resolved as set threshold reached OR a soul that grants it (docs/01 §5a)", function()
    it("is granted by enough set pieces alone, with no soul", function()
      mock.inventory[1] = 900101
      mock.inventory[5] = 900102 -- 2 of 4 LAWBRINGER pieces: meets the [2] threshold
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_true(state:bonus("AVENGERS_2P"))
    end)

    it("is granted by the soul alone, with zero set pieces equipped", function()
      mock.tooltipLines[3] = { "Some Pauldrons", "Retributor" }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(0, state:setCount("LAWBRINGER"))
      assert.is_true(state:bonus("AVENGERS_2P"))
    end)

    it("is granted when both the set threshold and the soul are present", function()
      mock.inventory[1] = 900101
      mock.inventory[5] = 900102
      mock.tooltipLines[3] = { "Some Pauldrons", "Retributor" }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_true(state:bonus("AVENGERS_2P"))
    end)

    it("is granted by neither: below threshold and the wrong soul", function()
      mock.inventory[1] = 900101 -- only 1 of 4 pieces
      mock.tooltipLines[3] = { "Some Pauldrons", "Exile" } -- grants a different bonus key
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_false(state:bonus("AVENGERS_2P"))
    end)

    it("reports false for a bonus key nothing defines", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_false(state:bonus("NOT_A_REAL_BONUS"))
    end)
  end)

  -- ============================================================ 6. setCount()
  describe("setCount() — equipped pieces matched against Sets.lua item ids", function()
    it("counts equipped items belonging to the set", function()
      mock.inventory[1] = 900101
      mock.inventory[5] = 900102
      mock.inventory[6] = 900103
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(3, state:setCount("LAWBRINGER"))
    end)

    it("does not count an item from a different set", function()
      mock.inventory[1] = 900101
      mock.inventory[7] = 999999 -- not in LAWBRINGER
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(1, state:setCount("LAWBRINGER"))
    end)

    it("returns 0 for an unknown set key", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(0, state:setCount("NOT_A_REAL_SET"))
    end)
  end)

  -- Two recordings reported combat=false on every mark, including ones taken at combat start.
  -- InCombatLockdown answers a different question and is not set when PLAYER_REGEN_DISABLED fires.
  describe("inCombat() — the player's combat state, not UI lockdown", function()
    it("reports combat from UnitAffectingCombat", function()
      mock.affectingCombat = true
      mock.inCombat = false -- lockdown not yet set, as at the instant combat begins
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_true(state:inCombat(),
        "must read UnitAffectingCombat; lockdown lags the start of combat")
    end)

    it("reports out of combat when the player is not fighting", function()
      mock.affectingCombat = false
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_false(state:inCombat())
    end)
  end)

  -- ============================================================ 7. weapon() — base/item speed only
  describe("weapon() — the base/item speed used for build selection (docs/01 §2, §4)", function()
    it("reports a 2H weapon's item speed and id from the main-hand slot (16)", function()
      mock.inventory[16] = 900401
      mock.itemInfo[900401] = { name = "Fixture Greatsword", equipLoc = "INVTYPE_2HWEAPON" }
      mock.attackSpeed = { 3.6, nil }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      local w = state:weapon(16)
      assert.equal("2H", w.type)
      assert.equal(900401, w.itemID)
      assert.equal(3.6, w.speed)
    end)

    it("reports a 1H weapon", function()
      mock.inventory[16] = 900402
      mock.itemInfo[900402] = { name = "Fixture Blade", equipLoc = "INVTYPE_WEAPONMAINHAND" }
      mock.attackSpeed = { 2.6, nil }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal("1H", state:weapon(16).type)
    end)

    it("reports a shield from the off-hand slot (17), matching Schema.lua's C.weapon slot choice", function()
      mock.inventory[17] = 900403
      mock.itemInfo[900403] = { name = "Fixture Shield", equipLoc = "INVTYPE_SHIELD" }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal("Shield", state:weapon(17).type)
    end)

    it("returns nil for an empty weapon slot, the documented safe zero", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:weapon(16))
    end)

    -- Demonstrated in game on Truthbearer (229749): a 2.10 speed two-hander whose chance-on-hit
    -- grants +30% attack speed for 8s. UnitAttackSpeed reads ~1.6 while that proc is up, so a build
    -- gating on a speed range would flip its answer mid-fight. Base speed must come from the tooltip.
    it("reports the BASE item speed from the tooltip, not the hasted attack speed", function()
      mock.inventory[16] = 229749
      mock.itemInfo[229749] = { name = "Truthbearer", equipLoc = "INVTYPE_2HWEAPON" }
      mock.tooltipLines[16] = { "Truthbearer", "Two-Hand", "132 - 199 Damage", "Speed 2.10" }
      mock.attackSpeed = { 1.61, nil } -- as if Crusader's Zeal were up
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      local w = state:weapon(16)
      assert.equal(2.10, w.speed, "speed must be the item's, unaffected by a haste proc")
      assert.equal(1.61, w.hastedSpeed, "the hasted value stays available, under its own name")
    end)

    -- The recording proved the first fix did nothing in game: the client puts "Speed 2.10" in the
    -- tooltip's RIGHT column, on the same line as the damage range, and the scan read only the left.
    -- The mock modelled only the left too, so a broken parse passed. Both are fixed; this pins it.
    it("finds the speed in the tooltip's RIGHT column, where the client actually puts it", function()
      mock.inventory[16] = 229749
      mock.itemInfo[229749] = { name = "Truthbearer", equipLoc = "INVTYPE_2HWEAPON" }
      mock.tooltipLines[16] = { "Truthbearer", "Two-Hand", "132 - 199 Damage" }
      mock.tooltipRight[16] = { nil, "Sword", "Speed 2.10" }
      mock.attackSpeed = { 1.902, nil } -- what the live recording actually reported
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(2.10, state:weapon(16).speed,
        "base speed lives in the right column; a left-only scan silently falls back to hasted")
    end)

    it("falls back to the hasted value only when the tooltip has no speed line", function()
      mock.inventory[16] = 900401
      mock.itemInfo[900401] = { name = "Fixture Greatsword", equipLoc = "INVTYPE_2HWEAPON" }
      mock.attackSpeed = { 3.6, nil }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(3.6, state:weapon(16).speed)
    end)

    -- The distinction the task calls out: weapon() must answer with the ITEM's speed, and must not
    -- be the same accessor swingRemaining() (M3b, haste-aware "time to next swing") will use.
    it("does not fold in the M3b swing-timer concern: swingRemaining stays the null-state safe value", function()
      mock.inventory[16] = 900401
      mock.itemInfo[900401] = { name = "Fixture Greatsword", equipLoc = "INVTYPE_2HWEAPON" }
      mock.attackSpeed = { 3.6, nil }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(3.6, state:weapon(16).speed)
      assert.is_nil(state:swingRemaining(), "swingRemaining is M3b (LibClassicSwingTimerAPI); M2 must not wire it")
    end)
  end)

  -- ============================================================ Straightforward contract members
  describe("now/gcd", function()
    it("now() forwards GetTime()", function()
      mock.time = 12345
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(12345, state:now())
    end)

    it("gcd() is 0 when the GCD is not running", function()
      local spells = spellsFixture()
      for _, s in pairs(spells) do mock.spell(s.id, { known = true }) end
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.equal(0, state:gcd())
    end)

    -- docs/07 §9.10: gcd()'s only viable source is GetSpellCooldown on a KNOWN, off-cooldown spell
    -- while the GCD is running — every fixture spell is marked known and cooldown-free here so the
    -- assertion holds regardless of which spell the adapter probes with.
    it("gcd() reports the running global cooldown", function()
      local spells = spellsFixture()
      for _, s in pairs(spells) do mock.spell(s.id, { known = true }) end
      mock.gcdActive = true
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.equal(1.5, state:gcd())
    end)
  end)

  describe("cooldown()", function()
    it("reports the remaining seconds on a spell mid-cooldown", function()
      local spells = spellsFixture()
      mock.time = 10
      mock.spell(spells.EXORCISM.id, { known = true, cooldown = 6, start = 8 }) -- cast at t=8, 6s CD
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.equal(4, state:cooldown("EXORCISM")) -- 8 + 6 - 10
    end)

    it("reports 0 once the cooldown has fully elapsed, never negative", function()
      local spells = spellsFixture()
      mock.time = 20
      mock.spell(spells.EXORCISM.id, { known = true, cooldown = 6, start = 8 })
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.equal(0, state:cooldown("EXORCISM"))
    end)

    it("reports 0 for a key the data pack does not define", function()
      local state = Vanilla.newState({}, {}, {})
      assert.equal(0, state:cooldown("NOT_A_REAL_KEY"))
    end)
  end)

  describe("usable()", function()
    it("is true for a known spell", function()
      local spells = spellsFixture()
      mock.spell(spells.JUDGEMENT.id, { known = true })
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.is_true(state:usable("JUDGEMENT"))
    end)

    it("is false for an unknown spell (e.g. an un-engraved or under-level ability)", function()
      local spells = spellsFixture()
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.is_false(state:usable("JUDGEMENT")) -- never registered known in the mock
    end)

    it("is false for a key the data pack does not define", function()
      local state = Vanilla.newState({}, {}, {})
      assert.is_false(state:usable("NOT_A_REAL_KEY"))
    end)
  end)

  describe("castTime()", function()
    it("converts GetSpellInfo's milliseconds to seconds (docs/07 §9.6: 1941 ms, haste-modified)", function()
      local spells = spellsFixture()
      mock.spell(spells.HOLY_WRATH.id, { known = true, castTime = 1941 })
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.equal(1.941, state:castTime("HOLY_WRATH"))
    end)

    it("is 0 for an instant", function()
      local spells = spellsFixture()
      mock.spell(spells.EXORCISM.id, { known = true }) -- no castTime registered = instant
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.equal(0, state:castTime("EXORCISM"))
    end)
  end)

  describe("buff()", function()
    it("returns stacks and remaining seconds for a present player aura", function()
      mock.time = 100
      mock.auras.player[1] = { name = "Avenging Wrath", spellID = 407788, count = 1, expires = 118 }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      local stacks, remaining = state:buff("AVENGING_WRATH_BUFF")
      assert.equal(1, stacks)
      assert.equal(18, remaining)
    end)

    it("returns nil when the aura is absent — the Art of War case (docs/07 §9.4: no aura exists at all)", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:buff("AVENGING_WRATH_BUFF"))
    end)

    it("returns nil for a key the data pack does not define, rather than erroring", function()
      local state = Vanilla.newState({}, {}, {})
      assert.is_nil(state:buff("NOT_A_REAL_KEY"))
    end)
  end)

  describe("debuff() — mine filters by aura source (docs/01 §2)", function()
    it("finds a player-sourced debuff on the target when mine=true", function()
      mock.time = 50
      mock.auras.target[1] = { name = "Judgement of Light", spellID = 900301, count = 1, expires = 62, source = "player" }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      local stacks, remaining = state:debuff("JUDGEMENT_OF_LIGHT_DEBUFF", true)
      assert.equal(1, stacks)
      assert.equal(12, remaining)
    end)

    it("filters out a debuff not sourced from the player when mine=true", function()
      mock.auras.target[1] = { name = "Something Else", spellID = 900302, source = "npc" }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:debuff("OTHER_TARGET_DEBUFF", true))
    end)

    it("includes a non-player debuff when mine=false", function()
      mock.auras.target[1] = { name = "Something Else", spellID = 900302, count = 1, source = "npc" }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_not_nil(state:debuff("OTHER_TARGET_DEBUFF", false))
    end)
  end)

  describe("power()", function()
    it("reads MANA via Enum.PowerType.Mana", function()
      mock.power[0] = { 450, 1000 }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      local cur, max = state:power("MANA")
      assert.equal(450, cur)
      assert.equal(1000, max)
    end)

    it("reads RAGE via Enum.PowerType.Rage, a different index than MANA", function()
      mock.power[1] = { 30, 100 }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      local cur, max = state:power("RAGE")
      assert.equal(30, cur)
      assert.equal(100, max)
    end)
  end)

  describe("targetType() / targetHPPct() / targetExists()", function()
    it("reports the target's creature type", function()
      mock.creatureType = "Undead"
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal("Undead", state:targetType())
    end)

    it("reports nil when the client returns no creature type (humanoid, or no target)", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:targetType())
    end)

    it("reports target HP as a percentage", function()
      mock.health = { 50, 200 }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(25, state:targetHPPct())
    end)

    -- ASSUMPTION: wow_mock.lua gained a `targetExists` toggle after this was written, so
    -- this harness cannot exercise "no target selected". Only the true branch is pinned here; the
    -- false branch needs either a mock enhancement or an in-game check.
    it("reports true when a target exists (harness limitation: cannot simulate no-target)", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_true(state:targetExists())
    end)
  end)

  describe("inCombat() / moving()", function()
    -- Was "forwards InCombatLockdown()", written from docs/01 §2 back when it named no API. Two live
    -- recordings then reported combat=false at combat start, because lockdown answers a different
    -- question. docs/01 now names UnitAffectingCombat explicitly.
    it("forwards UnitAffectingCombat(player)", function()
      mock.affectingCombat = true
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_true(state:inCombat())
      mock.affectingCombat = false
      assert.is_false(Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture()):inCombat())
    end)

    it("is moving when GetUnitSpeed(player) is above zero", function()
      mock.speed = 7
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_true(state:moving())
    end)

    it("is not moving at zero speed", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_false(state:moving())
    end)
  end)

  describe("seal() — paladin-specific, resolved from spells flagged seal=true (docs/01 §2)", function()
    it("returns the symbolic key of the active seal aura", function()
      mock.auras.player[1] = { name = "Seal of Martyrdom", spellID = 407798 }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal("SEAL_OF_MARTYRDOM", state:seal())
    end)

    it("returns nil when no seal aura is active", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:seal())
    end)
  end)

  describe("level()", function()
    it("forwards UnitLevel(player)", function()
      mock.level = 47
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(47, state:level())
    end)
  end)

  describe("itemCooldown() / itemUsable()", function()
    it("itemUsable is false for an empty slot even though the mock's IsUsableItem is unconditionally true", function()
      -- wow_mock.lua's IsUsableItem(id) always returns true regardless of id, including nil — the
      -- adapter must gate on GetInventoryItemID first, not trust IsUsableItem alone.
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_false(state:itemUsable(13))
    end)

    it("itemUsable is true once an item occupies the slot", function()
      mock.inventory[13] = 900501
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_true(state:itemUsable(13))
    end)

    -- ASSUMPTION / harness limitation: wow_mock.lua's GetInventoryItemCooldown is hardcoded to
    -- (0, 0) with no configurable state, so a genuine "on cooldown" reading cannot be exercised
    -- here. This only pins the ready case; a nonzero-cooldown case needs an in-game check or a mock
    -- enhancement (out of scope for this file per the no-edits-to-shared-infra instruction).
    it("itemCooldown is 0 when the trinket is ready", function()
      mock.inventory[13] = 900501
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(0, state:itemCooldown(13))
    end)
  end)

  -- ============================================================ 8. Null-safety / contract completeness
  describe("null-safety — every member returns its documented safe zero, never errors", function()
    it("Interface.validate passes on a freshly constructed adapter state", function()
      local state = Vanilla.newState({}, {}, {})
      local ok, missing = Interface.validate(state)
      assert.is_true(ok, table.concat(missing or {}, ", "))
    end)

    it("returns every documented safe zero with no data pack and no gear", function()
      local state = Vanilla.newState({}, {}, {})

      assert.equal(0, state:cooldown("X"))
      assert.is_false(state:usable("X"))
      assert.equal(0, state:castTime("X"))
      assert.is_nil(state:buff("X"))
      assert.is_nil(state:debuff("X", true))
      local cur, max = state:power("MANA")
      assert.is_number(cur); assert.is_number(max)
      assert.is_nil(state:targetType())
      assert.is_nil(state:weapon(16))
      assert.equal(0, state:setCount("X"))
      assert.is_nil(state:enchant(3))
      assert.is_false(state:bonus("X"))
      assert.equal(0, state:itemCooldown(13))
      assert.is_false(state:itemUsable(13))
      assert.is_nil(state:seal())
      assert.is_nil(state:swingRemaining())
      -- level() is NOT asserted here: it legitimately reads UnitLevel("player") regardless of the
      -- data pack (mock.level defaults to 60), so 0 would not be its safe zero in this scenario —
      -- see the dedicated level() describe block above for its real contract.
      assert.is_false(state:rune("X"))
      assert.is_nil(state:sealLinger())
      assert.equal(0, state:baseCooldown("X"))
      local amount, kind = state:powerCost("X")
      assert.equal(0, amount); assert.is_nil(kind)
    end)
  end)

  -- M3b. `swingRemaining` and `sealLinger` were `return nil` stubs from M1 to M3 while Schema
  -- happily compiled conditions against them — correct code reading a dead accessor, which is this
  -- codebase's signature defect. These pin the wiring AND, more importantly, the cases that must
  -- keep answering nil.
  describe("swing timing (M3b)", function()
    local function withSwing(remaining)
      helper.ns().Swing = {
        available = function() return true end,
        remaining = function(_, latency) return remaining, latency end,
      }
    end

    it("delegates swingRemaining to the swing adapter", function()
      withSwing(1.25)
      local state = Vanilla.newState(spellsFixture())
      assert.equal(1.25, state:swingRemaining())
    end)

    it("answers nil when no swing adapter is loaded at all", function()
      helper.ns().Swing = nil
      local state = Vanilla.newState(spellsFixture())
      assert.is_nil(state:swingRemaining())
    end)

    it("reports the swing capability from the library, not from a constant", function()
      helper.ns().Swing = { available = function() return true end }
      assert.is_true(Vanilla.capabilities().swing)
      helper.ns().Swing = { available = function() return false end }
      assert.is_false(Vanilla.capabilities().swing)
      helper.ns().Swing = nil
      assert.is_false(Vanilla.capabilities().swing)
    end)

    it("reads world latency, never home latency", function()
      mock.latency = 120
      local state = Vanilla.newState(spellsFixture())
      assert.equal(120, state:latency())
    end)
  end)

  describe("seal linger (M3b)", function()
    local SEALS = {
      SEAL_OF_MARTYRDOM = { id = 407798, seal = true },
      SEAL_OF_RIGHTEOUSNESS = { id = 21084, seal = true },
    }

    local function sealUp(name)
      mock.auras.player = name and { { name = name, spellID = name == "SoM" and 407798 or 21084 } } or {}
    end

    -- The adapter matches auras by the pack's spell name, so give the mock matching names.
    local function stateWithWindow(window)
      mock.spellNames[407798] = "SoM"
      mock.spellNames[21084] = "SoR"
      mock.knownSpells[407798], mock.knownSpells[21084] = true, true
      return Vanilla.newState(SEALS, nil, nil, nil, window)
    end

    it("answers nil when the data pack ships no sourced window", function()
      -- Deliberate: a guessed timing constant would mis-time every twist silently. No source, no
      -- window, no linger — and the condition simply reads false.
      local state = stateWithWindow(nil)
      mock.time = 10
      sealUp("SoM")
      state:seal()
      mock.time = 11
      sealUp("SoR")
      assert.is_nil(state:sealLinger())
    end)

    it("names the OUTGOING seal while the window is open", function()
      local state = stateWithWindow(0.4)
      mock.time = 10
      sealUp("SoM")
      assert.equal("SEAL_OF_MARTYRDOM", state:seal())
      mock.time = 10.1
      sealUp("SoR")
      assert.equal("SEAL_OF_RIGHTEOUSNESS", state:seal())
      assert.equal("SEAL_OF_MARTYRDOM", state:sealLinger())
    end)

    it("forgets it once the window closes", function()
      local state = stateWithWindow(0.4)
      mock.time = 10
      sealUp("SoM")
      state:seal()
      mock.time = 10.1
      sealUp("SoR")
      state:seal()
      mock.time = 10.6
      assert.is_nil(state:sealLinger())
    end)

    it("an expiry is not a twist: a seal falling off with nothing replacing it never lingers", function()
      local state = stateWithWindow(0.4)
      mock.time = 10
      sealUp("SoM")
      state:seal()
      mock.time = 10.1
      sealUp(nil)
      assert.is_nil(state:seal())
      assert.is_nil(state:sealLinger())
    end)

    it("the first seal of a fight does not linger, because nothing was replaced", function()
      local state = stateWithWindow(0.4)
      mock.time = 10
      sealUp("SoM")
      assert.equal("SEAL_OF_MARTYRDOM", state:seal())
      assert.is_nil(state:sealLinger())
    end)
  end)

  -- M4. This function exists BECAUSE the call shape is counter-intuitive, so leaving it untested
  -- would be leaving the one thing that can go wrong unguarded. docs/07 §9.8: GetTalentTabInfo does
  -- NOT return the name first — position 1 is a numeric tab id (382 Holy / 383 Prot / 381 Ret) and
  -- points spent are at position 5. Collector.lua got this wrong once already.
  describe("talents() (M4 adapter extra)", function()
    it("reads points from position 5 and the tab id from position 1", function()
      -- The mock carries Arthorion's real 31/0/20 spread (docs/07 §9.7).
      local t = Vanilla.talents()
      assert.equal(382, t.tabs[1].id)
      assert.equal(31, t.tabs[1].points)
      assert.equal(383, t.tabs[2].id)
      assert.equal(0, t.tabs[2].points)
      assert.equal(381, t.tabs[3].id)
      assert.equal(20, t.tabs[3].points)
    end)

    it("names the tree with the most points, and totals them", function()
      local t = Vanilla.talents()
      assert.equal(51, t.total)     -- correct for level 60
      assert.equal(1, t.top)        -- Holy, for a 31/0/20 hybrid
      assert.equal(31, t.topPoints)
    end)

    it("follows the points, not the tab order", function()
      mock.talentTabs = { { 382, 5 }, { 383, 0 }, { 381, 46 } }
      local t = Vanilla.talents()
      assert.equal(3, t.top)
      assert.equal(46, t.topPoints)
    end)

    it("answers nil rather than a fake spread when the client cannot say", function()
      mock.talentTabs = {}
      assert.is_nil(Vanilla.talents())
    end)
  end)
end)
