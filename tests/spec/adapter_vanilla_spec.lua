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

  -- Provenance stamps (a fork's importedAt, ADR-0010) come from the client's `date`; Core never
  -- reads the clock. Absent `date` means no stamp, never a made-up one.
  describe("today()", function()
    it("formats the client's date, and is nil when the client has no date function", function()
      local saved = _G.date
      _G.date = function(fmt) assert.equal("%Y-%m-%d", fmt); return "2026-09-03" end
      assert.equal("2026-09-03", Vanilla.today())
      _G.date = nil
      assert.is_nil(Vanilla.today())
      _G.date = saved
    end)
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

    -- Season of Discovery engraves TEN slots; RUNE_SLOTS shipped with seven. Cloak and ring runes
    -- were therefore invisible, so `rune` gates on RUNE_RIGHTEOUS_VENGEANCE (all Ret builds),
    -- RUNE_SHIELD_OF_RIGHTEOUSNESS (Prot) and RUNE_SHOCK_AND_AWE (Shockadin) could never be true.
    -- Owner-confirmed slot list, client-swept 2026-09-03. Table-driven so that dropping any one slot
    -- from RUNE_SLOTS fails here and names the slot, rather than passing on the nine that remain.
    it("scans every slot Season of Discovery can engrave, cloak and rings included", function()
      for _, slot in ipairs({ 1, 5, 6, 7, 8, 9, 10, 11, 12, 15 }) do
        for engraved in pairs(mock.runes) do mock.runes[engraved] = nil end
        mock.runes[slot] = { name = "Rebuke", learnedAbilitySpellIDs = { 425609 } }
        local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
        assert.is_true(state:rune("RUNE_REBUKE"), "slot " .. slot .. " can hold a rune but is not scanned")
      end
    end)

    -- The client does not set `equipmentSlot` to the slot you asked about: live on 2026-09-03,
    -- querying 12 answered equipmentSlot=11 and querying 15 answered equipmentSlot=16. Reading it
    -- back would put a cloak rune in a slot that cannot hold one. The queried slot is the truth.
    it("trusts the slot it queried, not the equipmentSlot the client reports back", function()
      mock.runes[15] = { name = "Rebuke", equipmentSlot = 16, learnedAbilitySpellIDs = { 425609 } }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_true(state:rune("RUNE_REBUKE"))
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

    -- addonMemory follows the API's REAL presence, exactly like `swing` above (docs/07's lesson:
    -- a capability that cannot vary is not a capability).
    it("reports addonMemory from the library, not from a constant", function()
      assert.is_true(Vanilla.capabilities().addonMemory, "the mock provides UpdateAddOnMemoryUsage")
      -- Both forms have to go: the adapter falls back from the bare global to C_AddOns.*, so leaving
      -- either one in place would still read as "available" and prove nothing.
      local savedGlobal, savedCAddOns = _G.UpdateAddOnMemoryUsage, C_AddOns.UpdateAddOnMemoryUsage
      _G.UpdateAddOnMemoryUsage, C_AddOns.UpdateAddOnMemoryUsage = nil, nil
      assert.is_false(Vanilla.capabilities().addonMemory)
      _G.UpdateAddOnMemoryUsage, C_AddOns.UpdateAddOnMemoryUsage = savedGlobal, savedCAddOns
      assert.is_true(Vanilla.capabilities().addonMemory)
    end)
  end)

  -- ============================================================ 2a. addonMemoryKB()
  describe("addonMemoryKB() — Elmira's own memory, not the whole client's Lua heap (`/elm debug perf`)", function()
    it("sums only addons whose name starts with 'Elmira', ignoring every other addon", function()
      mock.addons[1] = { name = "Elmira", memory = 100 }
      mock.addons[2] = { name = "Elmira_ElvUI", memory = 50 }
      mock.addons[3] = { name = "Elmira_ItemRack", memory = 20 }
      mock.addons[4] = { name = "Recount", memory = 99999 }
      mock.addons[5] = { name = "ElvUI", memory = 5000 }
      assert.equal(170, Vanilla.addonMemoryKB())
    end)

    -- The prefix BOUNDARY, not just the concept. Narrowing the filter to "Elmir" survived the whole
    -- suite before this case existed: every name that should match started with "Elmira" and every
    -- name that should not was nowhere near it, so the exact length was never pinned.
    it("does not count an unrelated addon that merely shares the first five letters", function()
      mock.addons[1] = { name = "Elmira", memory = 100 }
      mock.addons[2] = { name = "Elmirror", memory = 7000 }
      assert.equal(100, Vanilla.addonMemoryKB())
    end)

    it("calls UpdateAddOnMemoryUsage BEFORE reading, so the figures are not stale", function()
      -- Left at the stale default (0) until UpdateAddOnMemoryUsage() copies pendingMemory in — if
      -- addonMemoryKB() summed without refreshing first, this would read back 0, not 250.
      mock.addons[1] = { name = "Elmira", memory = 0, pendingMemory = 250 }
      assert.equal(250, Vanilla.addonMemoryKB())
    end)

    it("returns nil, never 0, when the client cannot report per-addon usage (GetNumAddOns absent)", function()
      mock.addons[1] = { name = "Elmira", memory = 100 }
      local saved = C_AddOns.GetNumAddOns
      C_AddOns.GetNumAddOns = nil
      assert.is_nil(Vanilla.addonMemoryKB())
      C_AddOns.GetNumAddOns = saved
    end)

    it("returns nil, never 0, when GetAddOnMemoryUsage is absent in every form", function()
      mock.addons[1] = { name = "Elmira", memory = 100 }
      local savedGlobal, savedCAddOns = _G.GetAddOnMemoryUsage, C_AddOns.GetAddOnMemoryUsage
      _G.GetAddOnMemoryUsage, C_AddOns.GetAddOnMemoryUsage = nil, nil
      assert.is_nil(Vanilla.addonMemoryKB())
      _G.GetAddOnMemoryUsage, C_AddOns.GetAddOnMemoryUsage = savedGlobal, savedCAddOns
    end)

    it("works via the C_AddOns.* forms when the bare globals are absent", function()
      mock.addons[1] = { name = "Elmira", memory = 0, pendingMemory = 42 }
      local savedUpdate, savedUsage = _G.UpdateAddOnMemoryUsage, _G.GetAddOnMemoryUsage
      _G.UpdateAddOnMemoryUsage, _G.GetAddOnMemoryUsage = nil, nil
      assert.equal(42, Vanilla.addonMemoryKB())
      _G.UpdateAddOnMemoryUsage, _G.GetAddOnMemoryUsage = savedUpdate, savedUsage
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

    -- The cost is HELD between character changes (it costs a client-built table per ask, on the
    -- render loop), so the rune arriving is modelled the way it reaches the adapter in game: as the
    -- RUNE_UPDATED event Core/Init forwards to forgetSpellbook. Without that forward the old cost
    -- would stand, which is the second assertion -- the contract, stated, not an accident.
    it("tracks a rune-driven cost change (345 -> 69) once the rune event arrives", function()
      local spells = spellsFixture()
      mock.spell(spells.EXORCISM.id, { known = true, cost = 345 }) -- no Art of War
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      assert.equal(345, (state:powerCost("EXORCISM")))

      mock.powerCosts[spells.EXORCISM.id] = 69 -- Art of War engraved mid-session
      assert.equal(345, (state:powerCost("EXORCISM")), "held until the character changes")
      Vanilla.forgetSpellbook()                   -- what Core/Init does on RUNE_UPDATED
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
  -- Added at M5g for Core/Gates: "have you learned this at all" is a different question from
  -- `usable`, which is IsUsableSpell and answers false when you are merely out of mana.
  describe("known() — the spellbook, not IsUsableSpell", function()
    it("reports a spell the character has learned", function()
      mock.knownSpells = { [415073] = true }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_true(state:known("EXORCISM"))
    end)

    it("reports one they have not", function()
      mock.knownSpells = {}
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_false(state:known("EXORCISM"))
    end)

    -- RANKS. Classic gives every rank its own spell id and the pack ships one -- the max rank. A
    -- paladin with Exorcism at rank 5 has a different id from the pack's 415073, so IsPlayerSpell
    -- says no and the Builder greyed abilities the player had, as "not learned yet". Reported from
    -- a live client 2026-09-05. Display/BarGlow.lua had already learned this: names have no rank.
    --
    -- `knownSpells[id] = false` rather than nil is the mock's way of saying "a real spell you do
    -- not have": GetSpellInfo still resolves its NAME, exactly as the client does, while
    -- IsPlayerSpell answers false.
    local function withBook(book)
      mock.knownSpells = { [415073] = false }
      mock.spellNames = { [415073] = "Exorcism" }
      -- Answers ONLY for the right booktype. A stub that ignores its arguments cannot tell
      -- `"spell"` from `"pet"`, and the booktype is the one value in this fix that decides whether
      -- the whole spellbook fallback reads anything at all.
      _G.GetSpellBookItemName = function(i, booktype)
        if booktype ~= "spell" then return nil end
        return book[i]
      end
      Vanilla.forgetSpellbook()
      return Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
    end

    after_each(function()
      _G.GetSpellBookItemName, _G.GetSpellBookItemInfo = nil, nil
      Vanilla.forgetSpellbook()
    end)

    -- For `/elm debug alloc`: a book the client would not read whole is re-scanned for every
    -- unknown spell on every frame, and no other diagnostic can see that.
    it("reports whether the book is cached, how far a scan got, and how often it was forgotten", function()
      assert.matches("^spellbook: not read yet; character%-change forgets this session: %d+", Vanilla.spellbookStatus())
      local state = withBook({ "Exorcism", "Holy Wrath" })
      state:known("EXORCISM")
      assert.matches("^spellbook: cached, 2 entries read;", Vanilla.spellbookStatus())

      _G.GetSpellBookItemName = function(i) if i > 3 then error("index out of range") end return "Spell" .. i end
      Vanilla.forgetSpellbook()
      state:known("EXORCISM")
      assert.matches("NOT cached %-%- the client stopped answering at index 4, so every unknown spell re%-scans 3 entries",
        Vanilla.spellbookStatus())

      _G.GetSpellBookItemName = function() return nil end
      local before = tonumber(Vanilla.spellbookStatus():match("forgets this session: (%d+)"))
      Vanilla.forgetSpellbook()
      state:known("EXORCISM")
      assert.matches("NOT cached %-%- the client answered nothing", Vanilla.spellbookStatus())
      assert.equal(before + 1, tonumber(Vanilla.spellbookStatus():match("forgets this session: (%d+)")))
    end)

    it("finds a lower rank through the spellbook when the id is the max rank", function()
      assert.is_true(withBook({ "Exorcism", "Holy Wrath" }):known("EXORCISM"))
    end)

    it("still says no for a spell that is in neither", function()
      assert.is_false(withBook({ "Holy Wrath" }):known("EXORCISM"))
    end)

    -- An empty read is the client refusing to answer, not an empty spellbook: reporting false there
    -- would grey every row in the build at once.
    it("answers nil when the spellbook cannot be read at all", function()
      local realIs = _G.IsPlayerSpell
      _G.IsPlayerSpell = nil
      local state = withBook({})
      assert.is_nil(state:known("EXORCISM"))
      _G.IsPlayerSpell = realIs
    end)

    it("answers from the id alone on a client with no spellbook API", function()
      mock.knownSpells = { [415073] = true }
      _G.GetSpellBookItemName = nil
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_true(state:known("EXORCISM"))
      mock.knownSpells = { [415073] = false }
      -- The answer is cached per id now, and unlearning a spell is not something that happens to a
      -- live client without SPELLS_CHANGED firing -- which is precisely what Core/Init turns into
      -- this call. The invalidation itself is pinned by the two tests below; here it only has to
      -- stand in for the event, so that this test keeps testing what it is named after.
      Vanilla.forgetSpellbook()
      assert.is_false(state:known("EXORCISM"))
    end)

    -- 270 IsPlayerSpell calls per recompute, for about thirty distinct spells whose answers had not
    -- changed since login (measured on the live client, 2026-09-05: `simulate` was 80-91% of the
    -- addon's whole memory footprint at ~25 KB a recompute). The answer is now held until something
    -- the player did could have changed it.
    it("asks the client once per spell, not once per question", function()
      mock.knownSpells = { [415073] = true }
      local asked = 0
      local real = _G.IsPlayerSpell
      _G.IsPlayerSpell = function(id) asked = asked + 1; return real(id) end
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      state:known("EXORCISM")
      local afterFirst = asked
      for _ = 1, 20 do assert.is_true(state:known("EXORCISM")) end
      _G.IsPlayerSpell = real
      assert.equal(afterFirst, asked, "twenty more questions must cost the client nothing")
    end)

    -- The whole point of the cache is that it ENDS. Learning a rank, levelling and engraving a rune
    -- all reach this through Core/Init; a cache that survived them would answer "you do not know
    -- that" about an ability the player just engraved, for ever, with nothing to show why.
    it("forgets what it knew when the spellbook is invalidated", function()
      -- A book with something IN it, so the scan completes. An answer derived from a book that
      -- could not be read whole is deliberately not cached (see the partial-read test below), and
      -- an EMPTY book is indistinguishable from a client that would not answer -- `spellbookNames`
      -- returns nil for both -- so `withBook({})` would prove nothing about invalidation here.
      local state = withBook({ "Holy Wrath" })
      assert.is_false(state:known("EXORCISM"))
      mock.knownSpells = { [415073] = true }
      assert.is_false(state:known("EXORCISM"), "still cached until something says otherwise")
      Vanilla.forgetSpellbook()
      assert.is_true(state:known("EXORCISM"), "and the moment it is told, it re-reads")
    end)

    -- The rule the partial-read guard rests on, stated one level up: a derived answer must not
    -- outlive the truncated book it came from, or every spell past the failure reads "not known"
    -- until the next SPELLS_CHANGED. Caught by the existing partial-read test when this cache was
    -- first written, which is exactly what that test is for.
    it("does not cache an answer derived from a spellbook that failed partway", function()
      mock.knownSpells = { [415073] = false }
      mock.spellNames = { [415073] = "Exorcism" }
      _G.GetSpellBookItemName = function(i, booktype)
        if booktype ~= "spell" then return nil end
        if i == 1 then return "Holy Wrath" end
        error("the client gave up")
      end
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_false(state:known("EXORCISM"))
      -- The book becomes readable and now lists it. No event fires: nothing about the PLAYER
      -- changed, only the client's willingness to answer, so only the refusal to cache can save it.
      _G.GetSpellBookItemName = function(i, booktype)
        if booktype ~= "spell" then return nil end
        return ({ "Exorcism" })[i]
      end
      assert.is_true(state:known("EXORCISM"), "a truncated read must not be frozen in")
    end)

    -- Both sources silent: "cannot tell", never "you have learned nothing", which would grey the
    -- whole palette and every gated row at once.
    it("answers nil when neither the id nor the spellbook can be read", function()
      local realIs = _G.IsPlayerSpell
      mock.knownSpells = { [415073] = false }
      _G.IsPlayerSpell, _G.GetSpellBookItemName = nil, nil
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:known("EXORCISM"))
      _G.IsPlayerSpell = realIs
    end)

    it("answers nil when the spellbook reads but the id cannot be named", function()
      local realIs, realInfo = _G.IsPlayerSpell, _G.GetSpellInfo
      mock.knownSpells = { [415073] = false }
      _G.IsPlayerSpell = nil
      _G.GetSpellBookItemName = function(i) return ({ "Holy Wrath" })[i] end
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      _G.GetSpellInfo = nil
      assert.is_nil(state:known("EXORCISM"), "no way to name the id, so no way to search the book")
      _G.GetSpellInfo = function() return nil end
      assert.is_nil(state:known("EXORCISM"))
      _G.IsPlayerSpell, _G.GetSpellInfo = realIs, realInfo
    end)

    it("says no once the id has answered, even if it cannot be named", function()
      local realInfo = _G.GetSpellInfo
      mock.knownSpells = { [415073] = false }
      _G.GetSpellBookItemName = function(i) return ({ "Holy Wrath" })[i] end
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      _G.GetSpellInfo = nil
      assert.is_false(state:known("EXORCISM"))
      _G.GetSpellInfo = realInfo
    end)

    -- A client that answered a name for every index would hang the login without a bound.
    it("stops reading a spellbook that never ends", function()
      mock.knownSpells = { [415073] = false }
      mock.spellNames = { [415073] = "Exorcism" }
      local reads = 0
      _G.GetSpellBookItemName = function() reads = reads + 1; return "Endless" end
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_false(state:known("EXORCISM"))
      assert.is_true(reads <= 1024, "the scan did not stop: " .. reads .. " reads")
    end)

    -- A scan that DIED partway is not the whole spellbook. Caching a truncated read would report
    -- every spell past the failure as unlearned until the next SPELLS_CHANGED or a /reload.
    it("never caches a spellbook read that failed partway through", function()
      mock.knownSpells = { [415073] = false }
      mock.spellNames = { [415073] = "Exorcism" }
      local calls = 0
      _G.GetSpellBookItemName = function(i, booktype)
        if booktype ~= "spell" then return nil end
        calls = calls + 1
        if i == 1 then return "Holy Wrath" end
        error("the client gave up")
      end
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_false(state:known("EXORCISM"))
      local afterFirst = calls
      -- Asked again, it re-reads rather than trusting the truncated set it built.
      state:known("EXORCISM")
      assert.is_true(calls > afterFirst, "the partial read was cached")
    end)

    -- A rank the trainer will sell you is listed but not learnable. Counting it as known ungreys
    -- an ability you cannot cast -- the opposite failure to the one being fixed.
    it("does not count a spell that is listed but not learnable yet", function()
      mock.knownSpells = { [415073] = false }
      mock.spellNames = { [415073] = "Exorcism" }
      _G.GetSpellBookItemName = function(i, booktype)
        if booktype ~= "spell" then return nil end
        return ({ "Exorcism" })[i]
      end
      _G.GetSpellBookItemInfo = function(i, booktype)
        if booktype ~= "spell" then return nil end
        return "FUTURESPELL"
      end
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_false(state:known("EXORCISM"))
      _G.GetSpellBookItemInfo = nil
      Vanilla.forgetSpellbook()
      assert.is_true(state:known("EXORCISM"), "without the filter it is simply known")
    end)

    -- One answer to "do you know this", so the state contract, the requirement checks and the
    -- /elm debug dump cannot disagree. They did, and only the first had been fixed.
    it("answers the same for knownSpells() as for known()", function()
      mock.knownSpells = { [415073] = false }
      mock.spellNames = { [415073] = "Exorcism" }
      _G.GetSpellBookItemName = function(i, booktype)
        if booktype ~= "spell" then return nil end
        return ({ "Exorcism" })[i]
      end
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_true(state:known("EXORCISM"))
      assert.is_true(Vanilla.knownSpells({ EXORCISM = { id = 415073 } }).EXORCISM)
    end)

    -- The scan is cached, so learning a rank must drop it or the palette keeps saying "not learned"
    -- about the ability you just trained.
    it("forgets the spellbook on request, and re-reads it", function()
      -- Starts with a readable book, because a read that returned NOTHING is not cached: that is
      -- "the client would not answer", and caching it would make one bad moment permanent.
      local state = withBook({ "Holy Wrath" })
      assert.is_false(state:known("EXORCISM"))
      _G.GetSpellBookItemName = function(i) return ({ "Holy Wrath", "Exorcism" })[i] end
      assert.is_false(state:known("EXORCISM"), "the cache should still be in force")
      assert.is_true(Vanilla.forgetSpellbook())
      assert.is_true(state:known("EXORCISM"))
    end)

    -- nil, not false: Gates dims a row on false, and "this client will not answer" must not dim
    -- every row in the build.
    it("answers nil for a key the pack does not have", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:known("NOT_IN_THE_PACK"))
    end)

    it("answers nil on a client with no IsPlayerSpell at all", function()
      local real = _G.IsPlayerSpell
      _G.IsPlayerSpell = nil
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:known("EXORCISM"))
      _G.IsPlayerSpell = real
    end)

    it("answers nil rather than erroring when the call throws", function()
      local real = _G.IsPlayerSpell
      _G.IsPlayerSpell = function() error("no such spell") end
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:known("EXORCISM"))
      _G.IsPlayerSpell = real
    end)
  end)

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

  -- The queue looks five casts ahead across every entry, so the same handful of questions get asked
  -- of the client hundreds of times for one suggestion. Measured in game on 2026-09-05: 764 client
  -- calls per recompute, ~25 KB of garbage, 80-91% of the addon's entire memory footprint
  -- (`/elm debug memory`, phase `simulate`). None of those answers can change without a frame
  -- boundary, so none of them needs asking twice.
  describe("asking the client once per frame instead of once per question", function()
    local function counting(name)
      local calls, real = 0, _G[name]
      _G[name] = function(...) calls = calls + 1; return real(...) end
      return function() _G[name] = real; return calls end, function() calls = 0 end
    end

    -- "The client would not say" is a third answer, distinct from yes and no, and it has to be
    -- cacheable too: a client that is still starting up would otherwise be re-interrogated about
    -- every spell, several times a second, for as long as it stayed quiet.
    it("does not keep re-asking a client that will not answer", function()
      mock.knownSpells = {}
      -- Restored explicitly at the end: this spec's after_each puts GetSpellBookItemName back but
      -- nothing else, and a GetSpellInfo left stubbed to nil silently breaks castTime() forty tests
      -- later, where it reads as a bug in castTime.
      local realIs, realInfo = _G.IsPlayerSpell, _G.GetSpellInfo
      _G.IsPlayerSpell = nil
      _G.GetSpellBookItemName = function(i, booktype)
        if booktype ~= "spell" then return nil end
        return ({ "Holy Wrath" })[i]      -- a whole book, so the answer may be cached
      end
      _G.GetSpellInfo = function() return nil end        -- and no name for the id, so: no answer
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:known("EXORCISM"))
      -- Counting GetSpellInfo, not the spellbook read: the book has its OWN cache, so it answers
      -- from memory whether or not this one does, and counting it would pass either way.
      local looks = 0
      _G.GetSpellInfo = function() looks = looks + 1; return nil end
      for _ = 1, 10 do assert.is_nil(state:known("EXORCISM"), "still cannot tell") end
      _G.IsPlayerSpell, _G.GetSpellInfo = realIs, realInfo
      assert.equal(0, looks, "a silence is an answer, and it is remembered like one")
    end)

    -- A client that reports no cooldown returns nil, not 0. Left unnormalised, the frame cache
    -- cannot tell "asked and there is none" from "not asked yet", so every ready spell -- which out
    -- of combat is all of them -- would be re-read on every single question.
    it("remembers that a spell has no cooldown, rather than re-asking about it", function()
      mock.time = 100
      mock.cooldowns[415073] = nil
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(0, state:cooldown("EXORCISM"))
      local stop = counting("GetSpellCooldown")
      for _ = 1, 20 do assert.equal(0, state:cooldown("EXORCISM")) end
      assert.equal(0, stop(), "no cooldown is a fact worth remembering for the frame")
    end)

    -- A client that answers nil rather than 0,0. The mock always answers with numbers, so this
    -- stubs the global directly rather than teaching the mock a client behaviour nobody here has
    -- verified in game (docs/07). Left unnormalised, nil is indistinguishable from "not asked yet"
    -- in the frame cache, so every ready spell -- out of combat, all of them -- is re-read on every
    -- question, which is the whole defect this cache exists to remove.
    it("treats a nil answer as 'no cooldown' and caches that too", function()
      mock.time = 100
      local real = _G.GetSpellCooldown
      local asked = 0
      _G.GetSpellCooldown = function() asked = asked + 1; return nil, nil end
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(0, state:cooldown("EXORCISM"))
      assert.equal(0, state:baseCooldown("EXORCISM"))
      for _ = 1, 20 do assert.equal(0, state:cooldown("EXORCISM")) end
      _G.GetSpellCooldown = real
      assert.equal(1, asked, "one nil answer, remembered; not twenty-two questions")
    end)

    it("reads a spell's cooldown once however many times it is asked for", function()
      mock.time = 100
      mock.cooldowns[415073] = { 90, 30 }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      state:cooldown("EXORCISM")                       -- warm
      local stop = counting("GetSpellCooldown")
      for _ = 1, 20 do state:cooldown("EXORCISM") end
      assert.equal(0, stop(), "twenty more asks in the same frame must cost the client nothing")
    end)

    -- Two questions, one reading. `cooldown` wants what is LEFT and `baseCooldown` wants how long
    -- one LASTS; they were making a client call each, so every spell was read twice per evaluation.
    it("answers 'how much is left' and 'how long does it last' from one reading", function()
      mock.time = 100
      mock.cooldowns[415073] = { 90, 30 }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      local stop = counting("GetSpellCooldown")
      state:cooldown("EXORCISM")
      state:baseCooldown("EXORCISM")
      assert.equal(1, stop(), "the second question must reuse the first one's answer")
    end)

    -- A frozen cooldown is a rotation that never notices a spell coming off cooldown. GetTime is
    -- stamped once per frame by the client, so a new stamp is a new frame is a new reading.
    it("re-reads on the next frame, and reports the cooldown ticking down", function()
      mock.time = 100
      mock.cooldowns[415073] = { 90, 30 }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(20, state:cooldown("EXORCISM"))
      mock.time = 110
      local stop = counting("GetSpellCooldown")
      assert.equal(10, state:cooldown("EXORCISM"), "the next frame sees ten seconds less")
      assert.is_true(stop() > 0, "and it got there by asking the client again")
    end)

    it("reads usability once per spell per frame, and again on the next one", function()
      mock.time = 100
      mock.knownSpells[415073] = true
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      state:usable("EXORCISM")                          -- warm
      local stop = counting("IsUsableSpell")
      for _ = 1, 20 do assert.is_true(state:usable("EXORCISM")) end
      assert.equal(0, stop(), "twenty more asks in the same frame cost the client nothing")

      -- Mana and range move during a fight, so a cache that never expired would keep offering a
      -- spell the player can no longer afford.
      mock.time = 110
      mock.knownSpells[415073] = false
      assert.is_false(state:usable("EXORCISM"), "the next frame asks again")
    end)

    -- setCount walked all nineteen inventory slots ONCE PER SET. Six sets is 114 client calls for
    -- nineteen answers, and it rebuilt the set's item lookup table every time on top.
    it("reads the equipped slots once per frame, not once per set", function()
      mock.inventory[5] = 900101
      local sets = setsFixture()
      sets.SECOND = { name = "Second", items = { 900101 }, bonuses = {} }
      sets.THIRD  = { name = "Third",  items = { 900102 }, bonuses = {} }
      local state = Vanilla.newState(spellsFixture(), sets, soulsFixture())
      local stop = counting("GetInventoryItemID")
      assert.equal(1, state:setCount("LAWBRINGER"))
      assert.equal(1, state:setCount("SECOND"), "the same piece counts for the set that lists it")
      assert.equal(0, state:setCount("THIRD"))
      assert.equal(1, state:setCount("LAWBRINGER"))
      local total = stop()
      assert.is_true(total <= 19,
        "nineteen slots exist; four set questions must not read more than that: " .. total)
      assert.is_true(total > 0, "and it did read them, rather than answering from nothing")

      -- Gear cannot change mid-frame, but it very much changes between them.
      mock.time = mock.time + 0.1
      mock.inventory[5] = nil
      assert.equal(0, state:setCount("LAWBRINGER"), "the next frame sees the piece removed")
    end)

    -- The one nobody would guess, and the one that mattered most: `gcd`/`gcdDuration` walk the
    -- WHOLE spell table looking for something showing a global cooldown, and out of combat nothing
    -- is, so both ran to completion. Core/Simulation asks for them once per simulated slot, so a
    -- five-deep lookahead ran that scan ten times per recompute -- 264 of the 764 calls, before the
    -- rotation's own conditions had asked anything.
    it("scans for the global cooldown once a frame, not once per lookahead slot", function()
      mock.time = 100
      mock.knownSpells[415073] = true
      mock.knownSpells[20271] = true
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      state:gcd()
      local stop = counting("GetSpellCooldown")
      for _ = 1, 10 do state:gcd(); state:gcdDuration() end
      assert.equal(0, stop(), "twenty more asks in one frame must not walk the spell table again")
    end)

    -- The scan walks the spell table; `cooldownRead` caches underneath it, so counting client calls
    -- cannot see a second walk. Counting `knownById` -- which the scan asks about every spell -- can.
    local function countingScans()
      local calls, real = 0, Vanilla.knownById
      Vanilla.knownById = function(id) calls = calls + 1; return real(id) end
      return function() Vanilla.knownById = real; return calls end
    end

    it("holds the global cooldown answer for the frame instead of walking the table again", function()
      mock.time = 100
      mock.knownSpells[415073] = true
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      state:gcd()                                        -- warm
      local stop = countingScans()
      for _ = 1, 10 do state:gcd(); state:gcdDuration() end
      assert.equal(0, stop(), "twenty asks in one frame must not walk the spell table again")
    end)

    -- Core/Simulation asks per lookahead slot, so this is the difference between one pass and ten.
    it("stops at the first spell showing a global cooldown", function()
      mock.time = 100
      -- Every spell in the pack on a GCD-length cooldown, so whichever `pairs` reaches first is a
      -- match and the count is deterministic however the table happens to be ordered.
      for _, data in pairs(spellsFixture()) do
        mock.knownSpells[data.id] = true
        mock.cooldowns[data.id] = { 99.5, 1.5 }
      end
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      local stop = countingScans()
      state:gcd()
      assert.equal(1, stop(), "it had its answer after the first spell and kept going")
    end)

    it("still finds the global cooldown, and still falls back when nothing is on one", function()
      mock.time = 100
      mock.knownSpells[415073] = true
      -- 1.2s, not 1.5: the fallback IS 1.5, so a fixture using it cannot tell "read from the
      -- client" apart from "gave up and used the default" -- the assertion would pass either way.
      mock.cooldowns[415073] = { 99.8, 1.2 }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(1.2, state:gcdDuration(), "the reading, not the fallback")
      assert.equal(1, state:gcd(), "0.2s in, one second left")

      mock.cooldowns[415073] = nil
      mock.time = 200
      local idle = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(0, idle:gcd(), "nothing on a global cooldown")
      assert.equal(1.5, idle:gcdDuration(), "and the base duration is what a fresh one would last")
    end)

    -- They used to make separate passes and could pick different spells. One pass means the two
    -- halves of one answer always describe the same reading.
    it("rescans on the next frame", function()
      mock.time = 100
      mock.knownSpells[415073] = true
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(0, state:gcd())
      mock.cooldowns[415073] = { 109.5, 1.5 }
      mock.time = 110
      assert.equal(1, state:gcd(), "a new frame sees the global cooldown that just started")
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

  -- The addon's single largest cost, found from a client memory readout: Elmira topped the addon
  -- list at 73 MB and churned ~27 MB a minute standing still in a city (owner, 2026-09-05).
  --
  -- Each lookup walked 1..40 calling `UnitAura` TWICE per index -- the second only to read the
  -- spellID the first call already returns as its tenth value. A build with a dozen aura-gated
  -- lines, simulated across five slots, ran that hundreds of times per recompute. Measured on the
  -- shipped Exodin build: 275 UnitAura calls per recompute before, 13 after.
  describe("reading auras without rescanning for every one", function()
    local function countCalls(fn)
      local calls, real = 0, _G.UnitAura
      _G.UnitAura = function(...) calls = calls + 1; return real(...) end
      fn()
      _G.UnitAura = real
      return calls
    end

    before_each(function()
      mock.time = 100
      mock.auras.player = {}
      for i = 1, 12 do
        mock.auras.player[i] = { name = "Filler" .. i, spellID = 900000 + i, expires = 118 }
      end
      mock.auras.player[13] = { name = "Avenging Wrath", spellID = 407788, count = 1, expires = 118 }
    end)

    it("scans the list once however many auras are asked about", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      local once = countCalls(function() state:buff("AVENGING_WRATH_BUFF") end)
      local tenMore = countCalls(function()
        for _ = 1, 10 do state:buff("AVENGING_WRATH_BUFF") end
      end)
      assert.equal(0, tenMore, "ten more lookups in the same frame must cost nothing")
      assert.is_true(once <= 14, "one pass over the list, not one per lookup: " .. once)
    end)

    -- A frozen cache would answer with auras that expired minutes ago. GetTime() is stamped once
    -- per frame by the client, so a new stamp is a new frame and a new scan.
    it("reads again on the next frame", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      state:buff("AVENGING_WRATH_BUFF")
      mock.time = mock.time + 0.1
      assert.is_true(countCalls(function() state:buff("AVENGING_WRATH_BUFF") end) > 0,
        "the next frame must scan again")
    end)

    it("notices an aura that fell off between frames", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(1, state:buff("AVENGING_WRATH_BUFF"))
      mock.auras.player[13] = nil
      mock.time = mock.time + 0.1
      assert.is_nil(state:buff("AVENGING_WRATH_BUFF"))
    end)

    -- A key the pack does not carry cannot match anything, so it must not cost a scan either.
    -- Reading the map with a nil key would answer correctly and walk the whole list to do it.
    it("does not scan at all for a key the pack does not carry", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(0, countCalls(function() state:buff("NOT_IN_THE_PACK") end))
      assert.is_nil(state:buff("NOT_IN_THE_PACK"))
    end)

    it("answers nil for an aura that is not on the list at all", function()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:buff("EXORCISM"), "not present, so there is nothing to report")
      -- and the scan still answers correctly for one that IS there, from the same pass
      assert.equal(1, state:buff("AVENGING_WRATH_BUFF"))
    end)

    -- Stacks matter: T3.5's Holy Power buff is gated `min = 3`, so reporting every aura as one
    -- stack would hold that line back for ever.
    it("reports how many stacks an aura has, not just that it is there", function()
      mock.auras.player[13] = { name = "Avenging Wrath", spellID = 407788, count = 4, expires = 118 }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(4, state:buff("AVENGING_WRATH_BUFF"))
    end)

    -- Player and target are different lists, and helpful and harmful are different filters: one
    -- cache slot for all of them would answer a debuff question with a buff.
    it("keeps the units and filters apart", function()
      mock.auras.target = { { name = "Judgement", spellID = 20271, expires = 118,
                              source = "player" } }
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.equal(1, state:buff("AVENGING_WRATH_BUFF"))
      assert.is_nil(state:buff("JUDGEMENT"), "a target debuff is not a player buff")
      assert.equal(1, state:debuff("JUDGEMENT"))
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

  -- ============================================================ loadClassPack() (M4b, ADR-0011 §3)
  -- The scan for an EXTERNAL class pack -- a separate addon carrying `## X-Elmira-Class`. Shipped
  -- classes never take this path; this is the only-remaining-extension-point half of ADR-0011.
  -- Three distinct return shapes, and Init.lua's own logging depends on telling them apart (docs/07's
  -- "no pack for your class" / "pack disabled" / "pack failed to load" used to be one indistinguishable
  -- line) -- so this pins the THIRD return value (the addon name) as well as `loaded`/`reason`.
  describe("loadClassPack(class) — external X-Elmira-Class scan (ADR-0011 §3)", function()
    it("answers false, 'no-scan' when the client exposes no C_AddOns enumeration at all", function()
      -- `_G.` is load-bearing here, not decoration: busted runs each `it` under its own environment
      -- that shadows plain global writes, so a bare `C_AddOns = nil` would leave the real global
      -- Vanilla.lua actually reads untouched and this test would pass for the wrong reason (or, as
      -- discovered while writing it, fail for the wrong reason — silently comparing against 'no-pack').
      local saved = _G.C_AddOns
      _G.C_AddOns = nil
      local loaded, reason, name = Vanilla.loadClassPack("PALADIN")
      _G.C_AddOns = saved
      assert.is_false(loaded)
      assert.equal("no-scan", reason)
      assert.is_nil(name)
    end)

    it("answers false, 'no-scan' when GetNumAddOns specifically is missing", function()
      local saved = C_AddOns.GetNumAddOns
      C_AddOns.GetNumAddOns = nil
      local loaded, reason, name = Vanilla.loadClassPack("PALADIN")
      C_AddOns.GetNumAddOns = saved
      assert.is_false(loaded)
      assert.equal("no-scan", reason)
      assert.is_nil(name)
    end)

    it("answers false, 'no-pack' when no installed addon carries a matching X-Elmira-Class", function()
      mock.addons[1] = { name = "Elmira_ElvUI", metadata = { ["X-Elmira-Class"] = "MAGE" } }
      mock.addons[2] = { name = "SomeOtherAddon" }
      local loaded, reason, name = Vanilla.loadClassPack("PALADIN")
      assert.is_false(loaded)
      assert.equal("no-pack", reason)
      assert.is_nil(name)
    end)

    it("answers false, 'no-pack' when C_AddOns exists but nothing is installed at all", function()
      local loaded, reason, name = Vanilla.loadClassPack("PALADIN")
      assert.is_false(loaded)
      assert.equal("no-pack", reason)
      assert.is_nil(name)
    end)

    it("loads the matching addon and forwards LoadAddOn's own loaded/reason, plus the addon's name", function()
      mock.addons[1] = { name = "Elmira_Paladin", metadata = { ["X-Elmira-Class"] = "PALADIN" },
                          load = { true, nil } }
      local loaded, reason, name = Vanilla.loadClassPack("PALADIN")
      assert.is_true(loaded)
      assert.is_nil(reason)
      assert.equal("Elmira_Paladin", name)
    end)

    it("forwards LoadAddOn's failure reason and the claiming addon's name when the load fails", function()
      mock.addons[1] = { name = "Elmira_BrokenPaladin", metadata = { ["X-Elmira-Class"] = "PALADIN" },
                          load = { false, "DISABLED" } }
      local loaded, reason, name = Vanilla.loadClassPack("PALADIN")
      assert.is_false(loaded)
      assert.equal("DISABLED", reason)
      assert.equal("Elmira_BrokenPaladin", name)
    end)

    it("matches the FIRST addon carrying the class, ignoring addons for other classes", function()
      mock.addons[1] = { name = "Elmira_ElvUI", metadata = { ["X-Elmira-Class"] = "MAGE" } }
      mock.addons[2] = { name = "Elmira_Paladin", metadata = { ["X-Elmira-Class"] = "PALADIN" },
                          load = { true, nil } }
      local loaded, _, name = Vanilla.loadClassPack("PALADIN")
      assert.is_true(loaded)
      assert.equal("Elmira_Paladin", name)
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
  -- ============================================================ memory round 3: allocate nothing on a warm frame
  --
  -- The first per-frame cache allocated fresh tables on every new frame, the aura scan a table per
  -- aura per frame, and the client charged Elmira ~32 KB per recompute for it, four times a second,
  -- standing still. The headless benchmark had missed all of it because the mock clock never moved;
  -- every case here moves it. The memo is now stamped on permanent tables, and the answers that
  -- only a character change can move (a cost, a rune, a soul, a weapon) are held until
  -- forgetSpellbook -- which Core/Init calls on exactly those events.
  describe("allocating nothing on a warm frame, and holding what only the character can change", function()
    local function counting(name)
      local calls, real = 0, _G[name]
      _G[name] = function(...) calls = calls + 1; return real(...) end
      return function() _G[name] = real; return calls end
    end

    local allocatedKB = helper.allocatedKB

    -- A character with something to read in every table: known spells, cooldowns, sixteen buffs,
    -- nineteen equipped items, a soul on the shoulders, a two-hander, one rune.
    local function liveState()
      local spells = spellsFixture()
      spells.RUNE_REBUKE.id = 425609
      mock.spell(spells.EXORCISM.id, { known = true, cooldown = 15, cost = 345 })
      mock.spell(spells.JUDGEMENT.id, { known = true })
      mock.spell(spells.CONSECRATION.id, { known = true })
      for i = 1, 15 do mock.auras.player[i] = { name = "Buff" .. i, spellID = 900000 + i } end
      mock.auras.player[16] = { name = "Avenging Wrath", spellID = 407788, count = 1 }
      for slot = 1, 19 do mock.inventory[slot] = 900100 + slot end
      mock.inventory[16] = 900500
      mock.itemInfo[900500] = { name = "Big Sword", equipLoc = "INVTYPE_2HWEAPON" }
      mock.tooltipLines[3] = { "Shoulders", "Exile" }
      mock.tooltipLines[16] = { "Big Sword" }; mock.tooltipRight[16] = { "Speed 3.40" }
      mock.runes[7] = { name = "Rebuke", learnedAbilitySpellIDs = { 425609 } }
      return Vanilla.newState(spells, setsFixture(), soulsFixture())
    end

    local function askEverything(state)
      state:gcd(); state:gcdDuration()
      state:cooldown("EXORCISM"); state:baseCooldown("EXORCISM"); state:usable("EXORCISM")
      state:cooldown("JUDGEMENT"); state:usable("JUDGEMENT"); state:known("CONSECRATION")
      state:buff("AVENGING_WRATH_BUFF"); state:buff("EXORCISM"); state:debuff("EXORCISM", true)
      state:setCount("LAWBRINGER"); state:bonus("AVENGERS_2P"); state:enchant(3)
      state:weapon(16); state:rune("RUNE_REBUKE"); state:powerCost("EXORCISM")
      state:seal(); state:power("MANA"); state:itemCooldown(13); state:itemUsable(13)
    end

    it("asks every question again on a new frame without allocating", function()
      mock.time = 100
      local state = liveState()
      askEverything(state)                       -- frame 1: the memo fills
      mock.time = 100.1
      askEverything(state)                       -- frame 2: every slot now exists
      mock.time = 100.2
      local kb = allocatedKB(function() askEverything(state) end)
      assert.is_true(kb == nil or kb < 0.05, string.format("a warm frame allocated %.3f KB", kb or 0))
    end)

    it("still re-reads the per-frame facts on that new frame", function()
      mock.time = 100
      local state = liveState()
      askEverything(state)
      mock.time = 101
      local cooldowns, usable, auras, items = counting("GetSpellCooldown"), counting("IsUsableSpell"),
                                              counting("UnitAura"), counting("GetInventoryItemID")
      askEverything(state)
      assert.is_true(cooldowns() > 0, "cooldowns tick between frames")
      assert.is_true(usable() > 0, "mana and range move between frames")
      assert.is_true(auras() > 0, "auras come and go between frames")
      assert.is_true(items() > 0, "gear is re-read per frame")
    end)

    it("asks for a spell's cost once, and again only after the character changes", function()
      local state = liveState()
      local stop = counting("GetSpellPowerCost")
      for _ = 1, 10 do state:powerCost("EXORCISM") end
      assert.equal(1, stop())
      Vanilla.forgetSpellbook()
      stop = counting("GetSpellPowerCost")
      state:powerCost("EXORCISM")
      assert.equal(1, stop(), "forgotten, so asked again")
    end)

    it("remembers a spell with no cost, and one whose cost has no kind", function()
      local spells = spellsFixture()
      mock.spell(spells.JUDGEMENT.id, { known = true })       -- no cost at all
      local real = _G.GetSpellPowerCost
      local asked = 0
      _G.GetSpellPowerCost = function(id)
        asked = asked + 1
        if id == spells.JUDGEMENT.id then return {} end
        return { { cost = 90 } }                             -- a cost with no `name`
      end
      local state = Vanilla.newState(spells, setsFixture(), soulsFixture())
      for _ = 1, 3 do
        assert.equal(0, (state:powerCost("JUDGEMENT")))
        assert.is_nil(select(2, state:powerCost("JUDGEMENT")))
      end
      local amount, kind = state:powerCost("EXORCISM")
      assert.equal(90, amount)
      assert.equal("MANA", kind, "a cost with no kind is mana")
      state:powerCost("EXORCISM")
      _G.GetSpellPowerCost = real
      assert.equal(2, asked, "one ask per spell, whatever the answer")
    end)

    it("reads the rune slots once per rune, and again only after the character changes", function()
      local state = liveState()
      local reads, real = 0, C_Engraving.GetRuneForEquipmentSlot
      C_Engraving.GetRuneForEquipmentSlot = function(...) reads = reads + 1; return real(...) end
      assert.is_true(state:rune("RUNE_REBUKE"))
      assert.is_false(state:rune("RUNE_HALLOWED_GROUND"))
      local afterFirst = reads
      for _ = 1, 10 do state:rune("RUNE_REBUKE"); state:rune("RUNE_HALLOWED_GROUND") end
      assert.equal(afterFirst, reads, "a yes and a no are both held")
      mock.runes[7] = nil                                   -- un-engraved, and RUNE_UPDATED fires
      assert.is_true(state:rune("RUNE_REBUKE"), "held until the event arrives")
      Vanilla.forgetSpellbook()
      assert.is_false(state:rune("RUNE_REBUKE"))
      C_Engraving.GetRuneForEquipmentSlot = real
    end)

    it("scans the shoulder tooltip once for the soul, and again only after a gear change", function()
      local scans, realCreate = 0, _G.CreateFrame
      _G.CreateFrame = function(...)
        local frame = realCreate(...)
        local set = frame.SetInventoryItem
        frame.SetInventoryItem = function(...) scans = scans + 1; return set(...) end
        return frame
      end
      local state = liveState()
      for _ = 1, 10 do assert.equal("SOUL_OF_THE_EXILE", state:enchant(3)) end
      assert.equal(1, scans)
      mock.tooltipLines[3] = { "Shoulders" }               -- soul gone, PLAYER_EQUIPMENT_CHANGED fires
      assert.equal("SOUL_OF_THE_EXILE", state:enchant(3), "held until the event arrives")
      Vanilla.forgetSpellbook()
      assert.is_nil(state:enchant(3))
      for _ = 1, 10 do assert.is_nil(state:enchant(3)) end
      assert.equal(2, scans, "'no soul' is held too")
      _G.CreateFrame = realCreate
    end)

    it("reads the weapon once, refreshing only the hasted speed, until a gear change", function()
      local state = liveState()
      mock.attackSpeed = { 2.5, nil }
      local stop = counting("GetItemInfo")
      local w = state:weapon(16)
      assert.equal("2H", w.type)
      assert.equal(3.4, w.speed, "base speed from the tooltip")
      assert.equal(2.5, w.hastedSpeed)
      mock.attackSpeed = { 1.9, nil }                       -- a haste proc, no gear event
      assert.equal(1.9, state:weapon(16).hastedSpeed, "the live number stays live")
      assert.equal(3.4, state:weapon(16).speed)
      assert.equal(1, stop(), "one item read for three questions")
      mock.inventory[16] = 900501
      mock.itemInfo[900501] = { name = "Shield", equipLoc = "INVTYPE_SHIELD" }
      assert.equal("2H", state:weapon(16).type, "held until the event arrives")
      Vanilla.forgetSpellbook()
      assert.equal("Shield", state:weapon(16).type)
    end)

    it("holds 'no weapon' and 'no readable weapon' without re-reading either", function()
      local state = liveState()
      mock.inventory[17] = nil
      mock.inventory[18] = 900502
      mock.itemInfo[900502] = nil                           -- an item the client cannot describe
      local stop = counting("GetItemInfo")
      for _ = 1, 5 do
        assert.is_nil(state:weapon(17))
        assert.is_nil(state:weapon(18))
      end
      assert.equal(1, stop())
    end)

    it("falls back to the hasted speed when the tooltip has no base speed", function()
      local state = liveState()
      mock.tooltipRight[16] = {}
      mock.attackSpeed = { 2.2, nil }
      assert.equal(2.2, state:weapon(16).speed)
    end)

    it("answers nil for a soul line on anything but the shoulders, without holding it", function()
      local state = liveState()
      mock.tooltipLines[16] = { "Big Sword", "Exile" }        -- a weapon cannot carry a soul
      assert.is_nil(state:enchant(16))
      assert.equal("SOUL_OF_THE_EXILE", state:enchant(3))
    end)

    it("answers false for every rune on a client with no engraving API, rather than erroring", function()
      local state = liveState()
      local real = _G.C_Engraving
      _G.C_Engraving = nil
      assert.is_false(state:rune("RUNE_REBUKE"))
      _G.C_Engraving = { }                                     -- the namespace without the call
      assert.is_false(state:rune("RUNE_REBUKE"))
      _G.C_Engraving = real
      assert.is_true(state:rune("RUNE_REBUKE"), "and nothing was held from the silent client")
    end)

    it("forgets what a previous pack's state held when a new state is built", function()
      local state = liveState()
      assert.equal("SOUL_OF_THE_EXILE", state:enchant(3))
      local renamed = soulsFixture()
      renamed.SOUL_OF_THE_EXILE = nil
      renamed.SOUL_OF_THE_SEALBEARER = { itemID = 1, short = "Exile", grants = {} }
      local fresh = Vanilla.newState(spellsFixture(), setsFixture(), renamed)
      assert.equal("SOUL_OF_THE_SEALBEARER", fresh:enchant(3))
    end)

    it("an aura that dropped last frame is gone this frame, though its record is kept", function()
      mock.time = 100
      local state = liveState()
      assert.equal(1, (state:buff("AVENGING_WRATH_BUFF")))
      mock.time = 101
      mock.auras.player[16] = nil
      assert.is_nil(state:buff("AVENGING_WRATH_BUFF"))
      mock.time = 102
      mock.auras.player[16] = { name = "Avenging Wrath", spellID = 407788, count = 3 }
      assert.equal(3, (state:buff("AVENGING_WRATH_BUFF")), "back, with this frame's stacks")
    end)

    it("the first of two copies of an aura still wins on a reused record", function()
      mock.time = 100
      local state = liveState()
      mock.auras.player[1] = { name = "AW", spellID = 407788, count = 1 }
      mock.auras.player[2] = { name = "AW", spellID = 407788, count = 5 }
      assert.equal(1, (state:buff("AVENGING_WRATH_BUFF")))
      mock.time = 101
      mock.auras.player[1], mock.auras.player[2] = mock.auras.player[2], mock.auras.player[1]
      assert.equal(5, (state:buff("AVENGING_WRATH_BUFF")), "next frame, the other copy is first")
    end)

    -- An answer that cannot be cached is asked again on every render-loop tick, so the miss itself
    -- must be free: a client whose spellbook is unreadable used to cost a table and a closure per
    -- ask, for every spell it would not vouch for.
    it("asks a client that will not answer again on every frame, but allocates nothing doing it", function()
      -- Neither source answers: no IsPlayerSpell, no spellbook. That is the one case the adapter may
      -- not cache, so it is the one case that is re-asked on every tick.
      local realIs = _G.IsPlayerSpell
      _G.IsPlayerSpell, _G.GetSpellBookItemName = nil, nil
      Vanilla.forgetSpellbook()
      local state = Vanilla.newState(spellsFixture(), setsFixture(), soulsFixture())
      assert.is_nil(state:known("EXORCISM"))
      local answers = 0
      local kb = allocatedKB(function()
        for _ = 1, 20 do if state:known("EXORCISM") ~= nil then answers = answers + 1 end end
      end)
      _G.IsPlayerSpell = realIs
      assert.equal(0, answers, "still cannot tell")
      assert.is_true(kb == nil or kb < 0.05, string.format("twenty unanswerable asks allocated %.3f KB", kb or 0))
    end)

    it("bonus() walks sets without a bonus table and souls without grants, allocating nothing", function()
      local sets = setsFixture()
      sets.BARE = { name = "Bare", items = { 1, 2 } }
      local souls = soulsFixture()
      souls.SOUL_OF_THE_TEMPLAR = { itemID = 3, short = "Templar" }
      mock.time = 100
      local state = Vanilla.newState(spellsFixture(), sets, souls)
      assert.is_false(state:bonus("AVENGERS_4P"))
      mock.time = 101
      state:bonus("AVENGERS_4P")
      mock.time = 102
      local kb = allocatedKB(function() for _ = 1, 10 do state:bonus("AVENGERS_4P") end end)
      assert.is_true(kb == nil or kb < 0.05, string.format("ten bonus() calls allocated %.3f KB", kb or 0))
    end)
  end)

end)
