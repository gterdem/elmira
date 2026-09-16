-- tests/spec/mage_builds_spec.lua — independent, hand-derived coverage of Elmira/Classes/Mage.lua's
-- three builds (MAGE_FIRE, MAGE_FROST_SPELLFROST, MAGE_FROST_LEVELING), written without reading
-- tests/spec/mage_pack_spec.lua's or tests/spec/mage_rune_gates_spec.lua's assertions or
-- tests/fixtures/gear_scenarios.lua's MAGE_* expected arrays. Every expectation below was derived by
-- reading Elmira/Classes/Mage.lua's `entries` top-down against Core/Engine.lua's `eligible`/`pick`
-- and Core/Schema.lua's condition implementations (`buff` "max passes on absence" for MG1-D5a,
-- `debuff` min/maxRemaining for MG1-D5b), never by running the engine first and copying its answer.
--
-- Uses the REAL shipped Elmira/Classes/Mage.lua data via helper.classPack (ADR-0011), the same
-- pattern tests/spec/paladin_exodin_filler_spec.lua uses against Paladin.lua.
--
-- Core test: FakeState only, no WoW globals, no tests/wow_mock.lua (docs/04-TESTING.md).
local helper = require("tests.helper")

describe("Elmira/Classes/Mage.lua — independent build-derivation coverage", function()
  local Schema, Engine, Simulation, FakeState, pack
  local fireBuild, frostBuild, levelBuild

  local function compile(build)
    local compiled, errors = Schema.compile(build, { spells = pack.spells, sets = pack.sets, bonuses = pack.bonuses })
    assert.is_not_nil(compiled, table.concat(Schema.errorLines(errors or {}), "; "))
    return compiled
  end

  -- Every scenario below only cares about Core's contract, so unset fields fall back to fake_state.lua's
  -- own defaults (gcdDuration 1.5, inCombat true, targetHp 100, etc.) exactly like every other Core spec.
  local function stateOf(opts)
    return FakeState.new(opts or {})
  end

  -- Finds a compiled entry by spell + label, the same technique paladin_exodin_filler_spec.lua uses to
  -- pin down WHICH of several same-spell entries fired (docs/02: several entries may share one `spell`).
  local function findEntry(build, spell, label)
    for _, entry in ipairs(build.entries) do
      if entry.spell == spell and entry.label == label then return entry end
    end
    error("no entry found for spell=" .. tostring(spell) .. " label=" .. tostring(label))
  end

  before_each(function()
    helper.reset()
    helper.load("Elmira/Adapters/Interface.lua")
    Schema = helper.load("Elmira/Core/Schema.lua")
    Engine = helper.load("Elmira/Core/Engine.lua")
    Simulation = helper.load("Elmira/Core/Simulation.lua")
    FakeState = dofile("tests/fake_state.lua")

    pack = helper.classPack("Mage")
    fireBuild = compile(pack.builds.MAGE_FIRE)
    frostBuild = compile(pack.builds.MAGE_FROST_SPELLFROST)
    levelBuild = compile(pack.builds.MAGE_FROST_LEVELING)
  end)

  -- ============================================================================================
  -- 1. Fire: Hot Streak proc always wins the live slot, and can never appear without it.
  -- ============================================================================================
  describe("MAGE_FIRE entry 1: Hot Streak Pyroblast", function()
    it("is slot 1 when Hot Streak is up, even though Overheat/Scorch/Living Bomb are also ready", function()
      local state = stateOf{
        buffs = { HOT_STREAK_BUFF = { stacks = 1, remaining = 8 } },
        runes = { RUNE_OVERHEAT = true },   -- entry 2 would also be eligible
        debuffs = {},                       -- entry 3 (Stack Scorch) and entry 6 (Living Bomb) would also be eligible
      }
      local first = Engine.pick(fireBuild, state, 0)
      assert.equal("PYROBLAST", first.spell)
      assert.equal("Hot Streak", first.label)
    end)

    it("never appears anywhere in the queue when Hot Streak is absent", function()
      -- A rich state so a long queue is actually reachable, not merely truncated to 1 slot.
      local state = stateOf{
        runes = { RUNE_HOT_STREAK = true, RUNE_OVERHEAT = true, RUNE_ENLIGHTENMENT = true, RUNE_BALEFIRE_BOLT = true,
                  RUNE_LIVING_BOMB = true, RUNE_FROSTFIRE_BOLT = true, RUNE_ICY_VEINS = true, RUNE_SPELL_POWER = true },
        buffs = {}, debuffs = {},
      }
      local queue = Simulation.queue(fireBuild, state, 8)
      assert.is_true(#queue > 0)
      for i, slot in ipairs(queue) do
        assert.is_not.equal("PYROBLAST", slot.spell, "slot " .. i .. " should never be Pyroblast without Hot Streak")
      end
    end)
  end)

  -- ============================================================================================
  -- 2. Fire: Overheat makes Fire Blast a held, off-GCD weave; unengraved it is a plain filler.
  -- ============================================================================================
  describe("MAGE_FIRE entry 2 vs the entry-16 baseline Fire Blast", function()
    it("Overheat engraved: Fire Blast is picked with hold=true and label 'Overheat'", function()
      local state = stateOf{ runes = { RUNE_OVERHEAT = true } }
      local queue = Simulation.queue(fireBuild, state, 1)
      assert.equal("FIRE_BLAST", queue[1].spell)
      assert.equal("Overheat", queue[1].label)
      assert.is_true(queue[1].hold)
    end)

    it("Overheat NOT engraved: the baseline Fire Blast line (entry 16, no `when`, no hold) fires instead", function()
      -- Disable every entry ranked between Hot Streak and the baseline Fire Blast so the pick is
      -- unambiguous: Scorch/Living Bomb/cooldowns/Balefire Bolt all outrank it in list order.
      local state = stateOf{
        runes = {},   -- Overheat entry's `rune` gate fails
        usable = { SCORCH = false, LIVING_BOMB = false, COMBUSTION = false, ICY_VEINS = false, BALEFIRE_BOLT = false },
      }
      local first = Engine.pick(fireBuild, state, 0)
      assert.equal("FIRE_BLAST", first.spell)
      assert.is_nil(first.label)   -- the baseline entry carries no label
      assert.is_falsy(first.hold)
      local queue = Simulation.queue(fireBuild, state, 1)
      assert.is_falsy(queue[1].hold)
    end)
  end)

  -- ============================================================================================
  -- 3. Fire: Fire Vulnerability / Scorch stack maintenance (VL2-D7: one SCORCH entry, an `any` of
  --    `max = 4` (absent or 1-4 stacks) and `maxRemaining = 4` (refresh at 5 stacks, 4s or less
  --    left) -- the same four states the old three-entry version covered, same outcomes.
  -- ============================================================================================
  describe("MAGE_FIRE Scorch stack maintenance (entry 3)", function()
    local SCORCH_LABEL = "Scorch to 5, refresh under 4s"
    -- Isolated to just the Scorch line: no Hot Streak, no Overheat, so entries 1-2 never preempt it.
    local ISOLATED = { runes = {}, buffs = {} }

    it("0 stacks (debuff absent): Scorch fires", function()
      local state = stateOf(ISOLATED)
      local first = Engine.pick(fireBuild, state, 0)
      assert.equal("SCORCH", first.spell)
      assert.equal(SCORCH_LABEL, first.label)
    end)

    it("5 stacks, 10s remaining: the Scorch entry is not eligible", function()
      local state = stateOf{ runes = {}, buffs = {},
                              debuffs = { FIRE_VULNERABILITY = { stacks = 5, remaining = 10, mine = true } } }
      assert.is_false(Engine.eligible(findEntry(fireBuild, "SCORCH", SCORCH_LABEL), state, 0))
      -- and the actual pick falls through past Scorch entirely, to Living Bomb maintenance.
      local first = Engine.pick(fireBuild, state, 0)
      assert.equal("LIVING_BOMB", first.spell)
    end)

    it("5 stacks, 3s remaining: Scorch fires (refresh before it falls off)", function()
      local state = stateOf{ runes = {}, buffs = {},
                              debuffs = { FIRE_VULNERABILITY = { stacks = 5, remaining = 3, mine = true } } }
      local first = Engine.pick(fireBuild, state, 0)
      assert.equal("SCORCH", first.spell)
      assert.equal(SCORCH_LABEL, first.label)
    end)

    it("4 stacks (comfortable remaining): Scorch fires (keep stacking to the cap)", function()
      local state = stateOf{ runes = {}, buffs = {},
                              debuffs = { FIRE_VULNERABILITY = { stacks = 4, remaining = 10, mine = true } } }
      local first = Engine.pick(fireBuild, state, 0)
      assert.equal("SCORCH", first.spell)
      assert.equal(SCORCH_LABEL, first.label)
    end)
  end)

  -- ============================================================================================
  -- 3b. VL2-D5: the `debuff` `max` op in isolation, through a synthetic one-entry build -- not the
  --     shipped Fire build's own combined `any` line (VL2-D7, which uses `max = 4`), so this is
  --     independent proof the op itself suggests Scorch through the cap and stops past it.
  -- ============================================================================================
  describe("debuff max op in isolation (VL2-D5)", function()
    local function stackBuild()
      return compile{ schema = 1, key = "VL2_D5_SCORCH_MAX", name = "VL2-D5 test", class = "MAGE",
        entries = { { spell = "SCORCH", when = { { "debuff", "FIRE_VULNERABILITY", max = 2 } } } } }
    end

    for _, stacks in ipairs({ 0, 1, 2 }) do
      it("suggests Scorch at " .. stacks .. " stacks", function()
        local debuffs = stacks > 0
          and { FIRE_VULNERABILITY = { stacks = stacks, remaining = 10, mine = true } } or nil
        local state = stateOf{ debuffs = debuffs }
        local first = Engine.pick(stackBuild(), state, 0)
        assert.is_not_nil(first, "expected Scorch to be suggested at " .. stacks .. " stacks")
        assert.equal("SCORCH", first.spell)
      end)
    end

    it("does not suggest Scorch at 3 stacks", function()
      local state = stateOf{ debuffs = { FIRE_VULNERABILITY = { stacks = 3, remaining = 10, mine = true } } }
      assert.is_nil(Engine.pick(stackBuild(), state, 0))
    end)
  end)

  -- ============================================================================================
  -- 4. Balefire Bolt's self-stack cap (MG1-D5a), Fire AND Frost (Spellfrost) share the same shape
  --    but are two separate source lines, so both need their own direct check.
  -- ============================================================================================
  for _, case in ipairs({ { name = "MAGE_FIRE", build = function() return fireBuild end },
                          { name = "MAGE_FROST_SPELLFROST", build = function() return frostBuild end } }) do
    describe(case.name .. ": Balefire Bolt filler ('3 or fewer stacks')", function()
      it("3 stacks: eligible", function()
        local entry = findEntry(case.build(), "BALEFIRE_BOLT", "3 or fewer stacks")
        local state = stateOf{ buffs = { BALEFIRE_BOLT = { stacks = 3, remaining = 20 } } }
        assert.is_true(Engine.eligible(entry, state, 0))
      end)

      it("4 stacks: NOT eligible (over the cap)", function()
        local entry = findEntry(case.build(), "BALEFIRE_BOLT", "3 or fewer stacks")
        local state = stateOf{ buffs = { BALEFIRE_BOLT = { stacks = 4, remaining = 20 } } }
        assert.is_false(Engine.eligible(entry, state, 0))
      end)

      it("absent: eligible (MG1-D5a: `max` passes on absence, reachable before the first stack lands)", function()
        local entry = findEntry(case.build(), "BALEFIRE_BOLT", "3 or fewer stacks")
        local state = stateOf{ buffs = {} }
        assert.is_true(Engine.eligible(entry, state, 0))
      end)
    end)
  end

  -- ============================================================================================
  -- 5. Frost: Fingers of Frost shatter combo ranks Deep Freeze, then Ice Lance, ahead of Frozen
  --    Orb; absent, neither reaches eligibility at all. Direct Engine.eligible/pick against the
  --    REAL (unsimulated) state, per docs/02's own `buff` semantics for a proc key (Simulation
  --    would suppress the SAME proc for every slot past t=0 in a queue, so this is deliberately not
  --    asserted as a two-slot Simulation.queue -- that would test proc suppression, not priority).
  -- ============================================================================================
  describe("MAGE_FROST_SPELLFROST Fingers of Frost shatter combo (entries 2-4)", function()
    it("FoF up: Deep Freeze is the live pick ('FoF')", function()
      local state = stateOf{ buffs = { FINGERS_OF_FROST_BUFF = { stacks = 1, remaining = 15 } } }
      local first = Engine.pick(frostBuild, state, 0)
      assert.equal("DEEP_FREEZE", first.spell)
      assert.equal("FoF", first.label)
    end)

    it("FoF up, Deep Freeze silenced: Ice Lance ('Shatter') is next, still ahead of Frozen Orb", function()
      local state = stateOf{ buffs = { FINGERS_OF_FROST_BUFF = { stacks = 1, remaining = 15 } },
                              usable = { DEEP_FREEZE = false } }
      local first = Engine.pick(frostBuild, state, 0)
      assert.equal("ICE_LANCE", first.spell)
      assert.equal("Shatter", first.label)
    end)

    it("FoF absent: neither Deep Freeze nor Ice Lance's shatter entry is eligible, and Frozen Orb wins", function()
      local state = stateOf{ buffs = {} }
      assert.is_false(Engine.eligible(findEntry(frostBuild, "DEEP_FREEZE", "FoF"), state, 0))
      assert.is_false(Engine.eligible(findEntry(frostBuild, "ICE_LANCE", "Shatter"), state, 0))
      local first = Engine.pick(frostBuild, state, 0)
      assert.equal("FROZEN_ORB", first.spell)
    end)
  end)

  -- ============================================================================================
  -- 6. Cold Snap is only reachable (gated on `cooldown_gt`,"ICY_VEINS",30) once Icy Veins' OWN
  --    remaining cooldown exceeds 30s -- checked at the boundary, for both builds that ship the line.
  -- ============================================================================================
  for _, case in ipairs({ { name = "MAGE_FIRE", build = function() return fireBuild end },
                          { name = "MAGE_FROST_SPELLFROST", build = function() return frostBuild end } }) do
    describe(case.name .. ": Cold Snap ('Reset Icy Veins')", function()
      local function entry() return findEntry(case.build(), "COLD_SNAP", "Reset Icy Veins") end

      it("Icy Veins off cooldown (0s remaining): not eligible", function()
        local state = stateOf{ cooldowns = { ICY_VEINS = 0 } }
        assert.is_false(Engine.eligible(entry(), state, 0))
      end)

      it("Icy Veins at exactly 30s remaining: not eligible (`cooldown_gt` is strict)", function()
        local state = stateOf{ cooldowns = { ICY_VEINS = 30 } }
        assert.is_false(Engine.eligible(entry(), state, 0))
      end)

      it("Icy Veins at 31s remaining: eligible", function()
        local state = stateOf{ cooldowns = { ICY_VEINS = 31 } }
        assert.is_true(Engine.eligible(entry(), state, 0))
      end)
    end)
  end

  -- ============================================================================================
  -- 7. Leveling: only Frostbolt and Fireball known/usable, no runes.
  --
  -- Hand-derivation note (reported, not asserted as a literal Simulation.queue alternation): Neither
  -- FROSTBOLT nor FIREBALL carries a `cooldown`/`baseCooldown` (docs/research found no sourced number
  -- for either), so Simulation's own fallback (docs/02 "one time step") makes FROSTBOLT read as
  -- off-cooldown again by the very next virtual slot -- exactly the mechanism
  -- tests/fixtures/gear_scenarios.lua's own MAGE_FIRE "overheat_not_engraved_uses_baseline_fire_blast"
  -- scenario already documents for Fire Blast. A plain `Simulation.queue(levelBuild, state, 2)` under
  -- this scenario therefore reads {FROSTBOLT, FROSTBOLT}, not {FROSTBOLT, FIREBALL} -- so FIREBALL's
  -- reachability is asserted here via Engine.pick with Frostbolt made unusable (silenced/out of
  -- range/out of mana), which is the honest way to prove the PRIORITY ORDER (Frostbolt outranks
  -- Fireball, Fireball is the true last-resort filler) without asserting a queue shape the cooldown
  -- model cannot produce.
  -- ============================================================================================
  describe("MAGE_FROST_LEVELING: only Frostbolt and Fireball known", function()
    local ONLY_FROSTBOLT_FIREBALL = {
      usable = { LIVING_BOMB = false, FROZEN_ORB = false, FIRE_BLAST = false, BLIZZARD = false,
                 ARCANE_EXPLOSION = false, CONE_OF_COLD = false, FROSTFIRE_BOLT = false },
    }

    it("Frostbolt is the live pick", function()
      local state = stateOf(ONLY_FROSTBOLT_FIREBALL)
      local first = Engine.pick(levelBuild, state, 0)
      assert.equal("FROSTBOLT", first.spell)
    end)

    it("with Frostbolt also unusable, Fireball (the last entry) is the live pick", function()
      local opts = { usable = {} }
      for k, v in pairs(ONLY_FROSTBOLT_FIREBALL.usable) do opts.usable[k] = v end
      opts.usable.FROSTBOLT = false
      local state = stateOf(opts)
      local first = Engine.pick(levelBuild, state, 0)
      assert.equal("FIREBALL", first.spell)
    end)

    it("Simulation.queue does not error and slot 1 is Frostbolt", function()
      local state = stateOf(ONLY_FROSTBOLT_FIREBALL)
      local ok, queue = pcall(Simulation.queue, levelBuild, state, 3)
      assert.is_true(ok, tostring(queue))
      assert.is_true(#queue > 0)
      assert.equal("FROSTBOLT", queue[1].spell)
    end)
  end)

  -- ============================================================================================
  -- 8. All three builds compile against the real pack with zero errors, and every `requires.runes`
  --    key each build's catalog/build entry names actually exists in the pack's own spells table.
  -- ============================================================================================
  describe("build compilation and requires.runes/spells integrity", function()
    local BUILDS = { "MAGE_FIRE", "MAGE_FROST_SPELLFROST", "MAGE_FROST_LEVELING" }

    for _, key in ipairs(BUILDS) do
      it(key .. " compiles against the real pack with zero validation errors", function()
        local ok, errors = Schema.validate(pack.builds[key],
          { spells = pack.spells, sets = pack.sets, bonuses = pack.bonuses })
        assert.is_true(ok, table.concat(Schema.errorLines(errors or {}), "; "))
        assert.same({}, errors)
      end)

      it(key .. ": every requires.runes key exists in pack.spells", function()
        local runes = pack.builds[key].requires and pack.builds[key].requires.runes
        assert.is_table(runes, key .. " has no requires.runes list")
        assert.is_true(#runes > 0)
        for _, runeKey in ipairs(runes) do
          assert.is_not_nil(pack.spells[runeKey], key .. ": requires.runes names '" .. runeKey .. "', missing from pack.spells")
        end
      end)
    end
  end)

  -- ============================================================================================
  -- 9. The self-aura fallback (`selfAura = "either"`, MG1-D5c): SKIPPED at the Core/FakeState level.
  --
  -- Adapters/Vanilla.lua's `S:buff()` is what implements the HELPFUL-then-HARMFUL fallback (see its
  -- own comment above the check `if spell and spell.selfAura == "either" then`), by scanning two
  -- DIFFERENT client aura-filter lists (`findAura(unit, key, "HELPFUL")` vs `"HARMFUL"`) and only the
  -- adapter's mock (tests/wow_mock.lua) can express "this id is filed under HARMFUL but not HELPFUL".
  -- tests/fake_state.lua's own `:buff(key)` reads a single flat `self.buffs[key]` table with no
  -- helpful/harmful distinction at all (see fake_state.lua's `buff`/`debuff` implementations) -- there
  -- is no second list to miss, so a FakeState scenario cannot fail to find Balefire Bolt via the
  -- normal path and therefore cannot exercise the fallback even in principle. This is a Core spec by
  -- this task's own instruction (fake_state.lua, no WoW globals), so this case is left to
  -- tests/spec/adapter_vanilla_spec.lua's existing `selfAura = "either"` describe block, which already
  -- covers exactly this mechanism against the real adapter.
  -- ============================================================================================
end)
