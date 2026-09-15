-- tests/spec/mage_healer_spec.lua — independent, hand-derived coverage of MAGE_ARCANE_HEALER
-- (MG2-D5), written without reading tests/fixtures/gear_scenarios.lua's MAGE_ARCANE_HEALER expected
-- arrays or tests/spec/mage_pack_spec.lua's assertions. Every expectation below was derived by
-- reading Elmira/Classes/Mage.lua's `entries` for MAGE_ARCANE_HEALER top-down against
-- Core/Engine.lua's `eligible`/`pick` and Core/Schema.lua's condition implementations, the same
-- discipline tests/spec/mage_builds_spec.lua uses for the DPS builds.
--
-- Core test: FakeState only, no WoW globals, no tests/wow_mock.lua (docs/04-TESTING.md).
local helper = require("tests.helper")

describe("Elmira/Classes/Mage.lua — MAGE_ARCANE_HEALER independent coverage (MG2-D5)", function()
  local Schema, Engine, FakeState, pack, build

  local function stateOf(opts) return FakeState.new(opts or {}) end

  local function findEntry(spell, label)
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
    FakeState = dofile("tests/fake_state.lua")

    pack = helper.classPack("Mage")
    local compiled, errors = Schema.compile(pack.builds.MAGE_ARCANE_HEALER, { spells = pack.spells })
    assert.is_not_nil(compiled, table.concat(Schema.errorLines(errors or {}), "; "))
    build = compiled
  end)

  -- ============================================================================================
  -- 1. The two reminders are held while off cooldown and gone once on cooldown — the mechanism the
  --    entries actually rely on (no explicit `when`; Engine.eligible's own cooldown check gates them).
  -- ============================================================================================
  describe("reminder lines follow the spell's own cooldown, not a `when` clause", function()
    it("Mass Regeneration reminder wins slot 1 when off cooldown", function()
      local state = stateOf{}
      local first = Engine.pick(build, state, 0)
      assert.equal("MASS_REGENERATION", first.spell)
      assert.equal("Beacons (reminder)", first.label)
      assert.is_true(first.hold)
    end)

    it("Mass Regeneration reminder never appears anywhere while on cooldown", function()
      local state = stateOf{ cooldowns = { MASS_REGENERATION = 5 } }
      assert.is_false(Engine.eligible(findEntry("MASS_REGENERATION", "Beacons (reminder)"), state, 0))
    end)

    it("Rewind Time reminder wins its own isolated slot", function()
      local state = stateOf{ cooldowns = { MASS_REGENERATION = 5 } }
      local first = Engine.pick(build, state, 0)
      assert.equal("REWIND_TIME", first.spell)
      assert.equal("Rewind (reminder)", first.label)
    end)

    it("Rewind Time reminder never appears anywhere while on cooldown", function()
      local state = stateOf{ cooldowns = { REWIND_TIME = 10 } }
      assert.is_false(Engine.eligible(findEntry("REWIND_TIME", "Rewind (reminder)"), state, 0))
    end)

    -- No Chronostatic Preservation reminder line ships at all (MG2-D3): the entry list has nothing
    -- with that spell+label to find.
    it("ships no reminder entry for Chronostatic Preservation", function()
      for _, entry in ipairs(build.entries) do
        assert.is_not.equal("CHRONOSTATIC_PRESERVATION", entry.spell)
      end
    end)
  end)

  -- ============================================================================================
  -- 2. Missile Barrage proc always outranks both Arcane Blast stack lines, whether or not it is up.
  -- ============================================================================================
  describe("Missile Barrage proc window", function()
    it("wins the live slot over Build stacks when up, even with both cooldowns on cooldown", function()
      local state = stateOf{
        cooldowns = { MASS_REGENERATION = 5, REWIND_TIME = 5, ARCANE_POWER = 5, PRESENCE_OF_MIND = 5 },
        buffs = { MISSILE_BARRAGE_BUFF = { stacks = 1, remaining = 15 } },
      }
      local first = Engine.pick(build, state, 0)
      assert.equal("ARCANE_MISSILES", first.spell)
      assert.equal("Missile Barrage", first.label)
    end)

    it("Arcane Missiles is not eligible at all when the proc is absent", function()
      local state = stateOf{}
      assert.is_false(Engine.eligible(findEntry("ARCANE_MISSILES", "Missile Barrage"), state, 0))
    end)
  end)

  -- ============================================================================================
  -- 3. AoE vs single-target: Arcane Explosion only outranks Arcane Barrage when BOTH gates pass
  --    (2+ enemies AND 2+ stacks); either alone leaves Arcane Barrage the winner.
  -- ============================================================================================
  describe("AoE promotion needs enemies AND stacks together", function()
    local SILENCE_ABOVE = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false,
                             PRESENCE_OF_MIND = false, EVOCATION = false, ARCANE_MISSILES = false }

    it("2 enemies + 2 stacks: Arcane Explosion wins, not Arcane Barrage", function()
      local state = stateOf{ enemies = 2, buffs = { ARCANE_BLAST_BUFF = { stacks = 2, remaining = 6 } },
                              usable = SILENCE_ABOVE }
      local first = Engine.pick(build, state, 0)
      assert.equal("ARCANE_EXPLOSION", first.spell)
      assert.equal("AoE", first.label)
    end)

    it("2 enemies but only 1 stack: Arcane Explosion is not eligible (its own `min = 2` on the buff)", function()
      local state = stateOf{ enemies = 2, buffs = {}, usable = SILENCE_ABOVE }
      assert.is_false(Engine.eligible(findEntry("ARCANE_EXPLOSION", "AoE"), state, 0))
    end)

    -- Rule-review finding: the scenario above only proves the gate rejects 0/absent stacks, which a
    -- `min = 2` -> `min = 1` mutation on this exact line would STILL correctly reject (0 < 1 too) —
    -- a scratch copy with that mutation left `make test` green. This is the boundary case that
    -- actually kills it: at exactly 1 stack, unmutated code must still say no.
    it("2 enemies, EXACTLY 1 stack: Arcane Explosion is not eligible (kills a min=2->1 mutation on its own line)", function()
      local state = stateOf{ enemies = 2, buffs = { ARCANE_BLAST_BUFF = { stacks = 1, remaining = 6 } }, usable = SILENCE_ABOVE }
      assert.is_false(Engine.eligible(findEntry("ARCANE_EXPLOSION", "AoE"), state, 0))
    end)

    it("2 stacks but only 1 enemy: Arcane Barrage wins instead", function()
      local state = stateOf{ buffs = { ARCANE_BLAST_BUFF = { stacks = 2, remaining = 6 } }, usable = SILENCE_ABOVE }
      local first = Engine.pick(build, state, 0)
      assert.equal("ARCANE_BARRAGE", first.spell)
      assert.equal("2 stacks", first.label)
    end)
  end)

  -- ============================================================================================
  -- 4. Arcane Blast's own stack cap (`max = 1`, MG1-D5a semantics reused): 0/absent and 1 both build,
  --    2 does not, and the baseline (no `when`) is what keeps the strip from ever going empty.
  -- ============================================================================================
  describe("Arcane Blast stack management (0/1/2)", function()
    local ONLY_ARCANE_BLAST = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false,
                                 PRESENCE_OF_MIND = false, EVOCATION = false, ARCANE_MISSILES = false,
                                 ARCANE_EXPLOSION = false, ARCANE_BARRAGE = false, BALEFIRE_BOLT = false }

    it("0 stacks (buff absent): 'Build stacks' fires", function()
      local state = stateOf{ usable = ONLY_ARCANE_BLAST }
      local first = Engine.pick(build, state, 0)
      assert.equal("ARCANE_BLAST", first.spell)
      assert.equal("Build stacks", first.label)
    end)

    it("1 stack: 'Build stacks' still fires", function()
      local state = stateOf{ buffs = { ARCANE_BLAST_BUFF = { stacks = 1, remaining = 6 } }, usable = ONLY_ARCANE_BLAST }
      local first = Engine.pick(build, state, 0)
      assert.equal("ARCANE_BLAST", first.spell)
      assert.equal("Build stacks", first.label)
    end)

    -- Rule-review finding: every scenario above silences ARCANE_BARRAGE outright (`usable = false`),
    -- so a `min = 2` -> `min = 1` mutation on Arcane Barrage's OWN line is never exercised — a scratch
    -- copy with that mutation left `make test` green. This leaves Arcane Barrage LIVE at exactly 1
    -- stack: unmutated code must still say no, and the pick must still land on Build stacks.
    it("1 stack, Arcane Barrage LIVE: Arcane Barrage is not eligible (kills a min=2->1 mutation on its own line)", function()
      local state = stateOf{ buffs = { ARCANE_BLAST_BUFF = { stacks = 1, remaining = 6 } },
        usable = { MASS_REGENERATION = false, REWIND_TIME = false, ARCANE_POWER = false, PRESENCE_OF_MIND = false,
                   BALEFIRE_BOLT = false } }
      assert.is_false(Engine.eligible(findEntry("ARCANE_BARRAGE", "2 stacks"), state, 0))
      local first = Engine.pick(build, state, 0)
      assert.equal("ARCANE_BLAST", first.spell)
      assert.equal("Build stacks", first.label)
    end)

    it("2 stacks: 'Build stacks' is no longer eligible, the unlabelled baseline fires instead", function()
      local state = stateOf{ buffs = { ARCANE_BLAST_BUFF = { stacks = 2, remaining = 6 } }, usable = ONLY_ARCANE_BLAST }
      assert.is_false(Engine.eligible(findEntry("ARCANE_BLAST", "Build stacks"), state, 0))
      local first = Engine.pick(build, state, 0)
      assert.equal("ARCANE_BLAST", first.spell)
      assert.is_nil(first.label)
    end)
  end)

  -- ============================================================================================
  -- 5. Balefire Bolt's self-stack cap, this build's own copy of the same MG1-D5a shape.
  -- ============================================================================================
  describe("Balefire Bolt filler ('3 or fewer stacks')", function()
    it("3 stacks: eligible", function()
      local state = stateOf{ buffs = { BALEFIRE_BOLT = { stacks = 3, remaining = 20 } } }
      assert.is_true(Engine.eligible(findEntry("BALEFIRE_BOLT", "3 or fewer stacks"), state, 0))
    end)

    it("4 stacks: not eligible", function()
      local state = stateOf{ buffs = { BALEFIRE_BOLT = { stacks = 4, remaining = 20 } } }
      assert.is_false(Engine.eligible(findEntry("BALEFIRE_BOLT", "3 or fewer stacks"), state, 0))
    end)

    it("absent: eligible (reachable before the first stack ever lands)", function()
      local state = stateOf{ buffs = {} }
      assert.is_true(Engine.eligible(findEntry("BALEFIRE_BOLT", "3 or fewer stacks"), state, 0))
    end)
  end)

  -- ============================================================================================
  -- 6. Evocation's mana gate (`maxPct = 20`, inclusive bound) and the build's compile/requires
  --    integrity against the real pack.
  -- ============================================================================================
  describe("Evocation mana gate and build integrity", function()
    it("ready at exactly 20% mana", function()
      local state = stateOf{ power = { MANA = { 200, 1000 } } }
      assert.is_true(Engine.eligible(findEntry("EVOCATION", "Mana"), state, 0))
    end)

    it("not ready at 21% mana", function()
      local state = stateOf{ power = { MANA = { 210, 1000 } } }
      assert.is_false(Engine.eligible(findEntry("EVOCATION", "Mana"), state, 0))
    end)

    it("compiles against the real pack with zero validation errors", function()
      local ok, errors = Schema.validate(pack.builds.MAGE_ARCANE_HEALER,
        { spells = pack.spells, sets = pack.sets, bonuses = pack.bonuses })
      assert.is_true(ok, table.concat(Schema.errorLines(errors or {}), "; "))
      assert.same({}, errors)
    end)

    it("every requires.runes and requires.spells key exists in pack.spells", function()
      local requires = pack.builds.MAGE_ARCANE_HEALER.requires
      for _, runeKey in ipairs(requires.runes) do
        assert.is_not_nil(pack.spells[runeKey], "requires.runes names '" .. runeKey .. "', missing from pack.spells")
      end
      for _, spellKey in ipairs(requires.spells) do
        assert.is_not_nil(pack.spells[spellKey], "requires.spells names '" .. spellKey .. "', missing from pack.spells")
      end
    end)
  end)
end)
