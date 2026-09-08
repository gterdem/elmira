-- tests/spec/schema_spec.lua — Elmira/Core/Schema.lua against docs/02-CONDITION-SCHEMA.md and
-- ADR-0002 (declarative conditions with a `custom` escape hatch). Written from the spec, not the
-- implementation: every assertion below traces to a line in docs/02 or the ADR, except where noted
-- as an implementation-detail safety net (argument `check` guards, which docs/02 doesn't spell out
-- but Schema.lua enforces).
local helper = require("tests.helper")

describe("Core.Schema (docs/02-CONDITION-SCHEMA.md, ADR-0002)", function()
  local Schema, FakeState, ns

  before_each(function()
    helper.reset()
    ns = helper.ns()
    -- Schema.lua's header claims "Pure Lua, no WoW globals: dofile-able headlessly", but
    -- Schema.compile() calls ns.log(...) unconditionally on validation failure with no guard
    -- (contrast Core/API.lua: `ns.log = ns.log or function() end`). Loading Schema.lua alone, as
    -- this spec must per docs/04 (Core tests never load WoW globals or unrelated modules), crashes
    -- on any failing Schema.compile() call without this stub. See the report for the real fix.
    ns.log = function() end
    Schema = helper.load("Elmira/Core/Schema.lua")
    FakeState = dofile("tests/fake_state.lua")
  end)

  -- Every symbolic key referenced anywhere below must appear here: docs/02 says a key absent from a
  -- data pack that WAS supplied is a validation error, and this is the pack most tests supply.
  local function ctx()
    return {
      spells = {
        TESTSPELL = {}, EXORCISM = {}, CRUSADER_STRIKE = {}, DIVINE_STORM = {}, JUDGEMENT = {},
        ART_OF_WAR_BUFF = { proc = true }, HOLY_POWER_BUFF = {}, SOME_DEBUFF = {},
        SEAL_OF_MARTYRDOM = {}, SEAL_OF_RIGHTEOUSNESS = {},
        RUNE_ART_OF_WAR = {}, RUNE_CRUSADER_STRIKE = {},
      },
      sets = { PALADIN_T3_REDEMPTION = true, PALADIN_TIER_TEST = true },
      bonuses = { TWOSET_BONUS = true },
    }
  end

  -- Compiles a one-entry build `{ spell = "TESTSPELL", when = when }` and returns the compiled
  -- predicate. Errors loudly rather than returning nil, so a test that expects a *passing* build
  -- never silently degrades into "predicate is nil" and reports the wrong kind of failure.
  local function pred(when, useCtx)
    local build = {
      schema = 1, key = "TEST", name = "Test", class = "PALADIN",
      entries = { { spell = "TESTSPELL", when = when } },
    }
    local compiled, errors = Schema.compile(build, useCtx or ctx())
    if not compiled then
      error("expected build to compile, got: " .. table.concat(Schema.errorLines(errors), "; "), 2)
    end
    return compiled.entries[1].test
  end

  it("has schema version 1", function()
    assert.equal(1, Schema.VERSION)
  end)

  -- ================================================================= a full, valid build
  describe("a valid build compiles end-to-end", function()
    it("compiles the docs/02 example shape with priority-ordered entries", function()
      local build = {
        schema = 1, key = "PALADIN_EXODIN", name = "Paladin — Exodin (fast 2H)", class = "PALADIN",
        flavor = "SoD",
        entries = {
          { spell = "EXORCISM", when = { { "buff", "ART_OF_WAR_BUFF" } }, label = "AoW proc" },
          { spell = "DIVINE_STORM", when = { { "buff", "HOLY_POWER_BUFF", min = 3 } } },
          { spell = "JUDGEMENT", when = { { "seal", "SEAL_OF_MARTYRDOM" } } },
          { spell = "EXORCISM" },
          { spell = "CRUSADER_STRIKE" },
        },
      }
      local compiled, errors = Schema.compile(build, ctx())
      assert.is_table(compiled)
      assert.same({}, errors)
      assert.equal(5, #compiled.entries)
      for i, e in ipairs(compiled.entries) do
        assert.equal(i, e.index)
        assert.is_function(e.test)
      end
      assert.is_true(compiled.compiled)
    end)

    it("surfaces data/cdVolatile/cost from the spells pack onto the compiled entry", function()
      local spells = { TESTSPELL = { cdVolatile = true, cost = { mana = 100 } } }
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = { { spell = "TESTSPELL" } },
      }
      local compiled = Schema.compile(build, { spells = spells })
      assert.equal(spells.TESTSPELL, compiled.entries[1].data)
      assert.is_true(compiled.entries[1].cdVolatile)
      -- Cost keys are upper-cased at compile time: docs/03 writes them lowercase (`{mana = N}`) but
      -- docs/02 addresses power kinds uppercase (`{"resource","MANA"}`), and the virtual state has to
      -- debit the same key the condition reads or the pool silently never drains.
      assert.same({ MANA = 100 }, compiled.entries[1].cost)
    end)

    it("upper-cases cost keys regardless of how the data pack wrote them", function()
      local spells = { A = { cost = { mana = 10 } }, B = { cost = { MANA = 20 } }, C = { cost = { Mana = 30 } } }
      local compiled = Schema.compile({ schema = 1, key = "T", name = "T", class = "PALADIN",
        entries = { { spell = "A" }, { spell = "B" }, { spell = "C" } } }, { spells = spells })
      assert.same({ MANA = 10 }, compiled.entries[1].cost)
      assert.same({ MANA = 20 }, compiled.entries[2].cost)
      assert.same({ MANA = 30 }, compiled.entries[3].cost)
    end)
  end)

  -- ================================================================= entries without a `when`
  describe("entries without a `when`", function()
    it("always pass (docs/02: an entry passes when all `when` conditions pass; none = vacuously true)", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = { { spell = "TESTSPELL" } },
      }
      local compiled = Schema.compile(build, ctx())
      assert.is_true(compiled.entries[1].test(FakeState.new{}, 0))
    end)

    it("an explicitly empty `when` list also always passes", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = { { spell = "TESTSPELL", when = {} } },
      }
      local compiled = Schema.compile(build, ctx())
      assert.is_true(compiled.entries[1].test(FakeState.new{}, 0))
    end)
  end)

  -- ================================================================= condition types (v1 table)
  describe("buff", function()
    it("passes when the aura is present with enough stacks", function()
      local test = pred({ { "buff", "HOLY_POWER_BUFF", min = 3 } })
      local s = FakeState.new{ buffs = { HOLY_POWER_BUFF = { stacks = 3, remaining = 5 } } }
      assert.is_true(test(s, 0))
    end)
    it("fails when the aura is absent", function()
      local test = pred({ { "buff", "HOLY_POWER_BUFF" } })
      assert.is_false(test(FakeState.new{}, 0))
    end)
    it("fails when stacks are below min", function()
      local test = pred({ { "buff", "HOLY_POWER_BUFF", min = 3 } })
      local s = FakeState.new{ buffs = { HOLY_POWER_BUFF = { stacks = 2 } } }
      assert.is_false(test(s, 0))
    end)
    it("honours minRemaining/maxRemaining windows", function()
      local test = pred({ { "buff", "HOLY_POWER_BUFF", minRemaining = 2, maxRemaining = 5 } })
      local inWindow = FakeState.new{ buffs = { HOLY_POWER_BUFF = { remaining = 3 } } }
      local tooLate = FakeState.new{ buffs = { HOLY_POWER_BUFF = { remaining = 6 } } }
      assert.is_true(test(inWindow, 0))
      assert.is_false(test(tooLate, 0))
    end)
  end)

  describe("no_buff", function()
    it("passes when the aura is absent", function()
      local test = pred({ { "no_buff", "HOLY_POWER_BUFF" } })
      assert.is_true(test(FakeState.new{}, 0))
    end)
    it("fails when the aura is present", function()
      local test = pred({ { "no_buff", "HOLY_POWER_BUFF" } })
      assert.is_false(test(FakeState.new{ buffs = { HOLY_POWER_BUFF = {} } }, 0))
    end)
  end)

  describe("debuff", function()
    it("passes when the player's debuff is on target (mine defaults true)", function()
      local test = pred({ { "debuff", "SOME_DEBUFF" } })
      local s = FakeState.new{ debuffs = { SOME_DEBUFF = { mine = true } } }
      assert.is_true(test(s, 0))
    end)
    it("fails when the debuff is absent", function()
      local test = pred({ { "debuff", "SOME_DEBUFF" } })
      assert.is_false(test(FakeState.new{}, 0))
    end)
    it("fails when present but not the player's, with the default mine=true", function()
      local test = pred({ { "debuff", "SOME_DEBUFF" } })
      local s = FakeState.new{ debuffs = { SOME_DEBUFF = { mine = false } } }
      assert.is_false(test(s, 0))
    end)
    it("respects minRemaining", function()
      local test = pred({ { "debuff", "SOME_DEBUFF", minRemaining = 4 } })
      local soonExpires = FakeState.new{ debuffs = { SOME_DEBUFF = { mine = true, remaining = 1 } } }
      local freshlyApplied = FakeState.new{ debuffs = { SOME_DEBUFF = { mine = true, remaining = 8 } } }
      assert.is_false(test(soonExpires, 0))
      assert.is_true(test(freshlyApplied, 0))
    end)
  end)

  describe("no_debuff", function()
    it("passes when the target lacks the debuff", function()
      local test = pred({ { "no_debuff", "SOME_DEBUFF" } })
      assert.is_true(test(FakeState.new{}, 0))
    end)
    it("fails when the target has the debuff", function()
      local test = pred({ { "no_debuff", "SOME_DEBUFF" } })
      assert.is_false(test(FakeState.new{ debuffs = { SOME_DEBUFF = { mine = true } } }, 0))
    end)
  end)

  describe("resource", function()
    it("passes when power is within min", function()
      local test = pred({ { "resource", "MANA", min = 500 } })
      assert.is_true(test(FakeState.new{ power = { MANA = { 800, 1000 } } }, 0))
    end)
    it("fails when power is below min", function()
      local test = pred({ { "resource", "MANA", min = 500 } })
      assert.is_false(test(FakeState.new{ power = { MANA = { 100, 1000 } } }, 0))
    end)
    it("supports percentage thresholds", function()
      local test = pred({ { "resource", "MANA", minPct = 50 } })
      assert.is_true(test(FakeState.new{ power = { MANA = { 600, 1000 } } }, 0))
      assert.is_false(test(FakeState.new{ power = { MANA = { 400, 1000 } } }, 0))
    end)
  end)

  describe("cooldown_ready", function()
    it("passes when the spell is off cooldown", function()
      local test = pred({ { "cooldown_ready", "EXORCISM" } })
      assert.is_true(test(FakeState.new{}, 0))
    end)
    it("fails when the spell is on cooldown", function()
      local test = pred({ { "cooldown_ready", "EXORCISM" } })
      assert.is_false(test(FakeState.new{ cooldowns = { EXORCISM = 3 } }, 0))
    end)
  end)

  describe("cooldown_gt", function()
    it("passes when remaining cooldown exceeds the threshold", function()
      local test = pred({ { "cooldown_gt", "EXORCISM", 2 } })
      assert.is_true(test(FakeState.new{ cooldowns = { EXORCISM = 5 } }, 0))
    end)
    it("fails when remaining cooldown is at or below the threshold", function()
      local test = pred({ { "cooldown_gt", "EXORCISM", 2 } })
      assert.is_false(test(FakeState.new{ cooldowns = { EXORCISM = 2 } }, 0))
    end)
  end)

  describe("target_type", function()
    it("passes when the target's creature type is in the list", function()
      local test = pred({ { "target_type", "Undead", "Demon" } })
      assert.is_true(test(FakeState.new{ targetType = "Undead" }, 0))
    end)
    it("fails when the target's creature type is not in the list", function()
      local test = pred({ { "target_type", "Undead", "Demon" } })
      assert.is_false(test(FakeState.new{ targetType = "Humanoid" }, 0))
    end)
  end)

  describe("target_hp", function()
    -- fake_state.lua hardcodes targetHPPct() to 100, so execute-range tests override the instance
    -- method directly (Lua __index only kicks in when the instance itself has no matching key).
    it("passes inside the configured percentage range", function()
      local test = pred({ { "target_hp", maxPct = 20 } })
      local s = FakeState.new{}
      s.targetHPPct = function() return 15 end
      assert.is_true(test(s, 0))
    end)
    it("fails outside the configured range", function()
      local test = pred({ { "target_hp", maxPct = 20 } })
      local s = FakeState.new{}
      s.targetHPPct = function() return 50 end
      assert.is_false(test(s, 0))
    end)
  end)

  describe("not_moving", function()
    it("passes when the player is stationary", function()
      local test = pred({ { "not_moving" } })
      assert.is_true(test(FakeState.new{ moving = false }, 0))
    end)
    it("fails when the player is moving", function()
      local test = pred({ { "not_moving" } })
      assert.is_false(test(FakeState.new{ moving = true }, 0))
    end)
  end)

  describe("in_combat / out_of_combat", function()
    -- fake_state.lua hardcodes inCombat() to true; the false side is exercised via an instance
    -- override (same technique as target_hp above).
    it("in_combat passes while in combat", function()
      local test = pred({ { "in_combat" } })
      assert.is_true(test(FakeState.new{}, 0))
    end)
    it("in_combat fails out of combat", function()
      local test = pred({ { "in_combat" } })
      local s = FakeState.new{}
      s.inCombat = function() return false end
      assert.is_false(test(s, 0))
    end)
    it("out_of_combat fails while in combat", function()
      local test = pred({ { "out_of_combat" } })
      assert.is_false(test(FakeState.new{}, 0))
    end)
    it("out_of_combat passes out of combat", function()
      local test = pred({ { "out_of_combat" } })
      local s = FakeState.new{}
      s.inCombat = function() return false end
      assert.is_true(test(s, 0))
    end)
  end)

  describe("set", function()
    it("passes when piece count meets min", function()
      local test = pred({ { "set", "PALADIN_T3_REDEMPTION", min = 2 } })
      assert.is_true(test(FakeState.new{ sets = { PALADIN_T3_REDEMPTION = 2 } }, 0))
    end)
    it("fails below min", function()
      local test = pred({ { "set", "PALADIN_T3_REDEMPTION", min = 2 } })
      assert.is_false(test(FakeState.new{ sets = { PALADIN_T3_REDEMPTION = 1 } }, 0))
    end)
  end)

  describe("bonus", function()
    it("passes when the resolved bonus flag is true", function()
      local test = pred({ { "bonus", "TWOSET_BONUS" } })
      assert.is_true(test(FakeState.new{ bonuses = { TWOSET_BONUS = true } }, 0))
    end)
    it("fails when the resolved bonus flag is false/absent", function()
      local test = pred({ { "bonus", "TWOSET_BONUS" } })
      assert.is_false(test(FakeState.new{}, 0))
    end)
    -- docs/02: "a shoulder soul grants it" — this is the whole reason `bonus` exists over raw `set`.
    it("passes when a shoulder soul grants the bonus without the set piece threshold", function()
      local test = pred({ { "bonus", "TWOSET_BONUS" } })
      local s = FakeState.new{
        souls = { "SOUL_OF_TEST" },
        bonusDefs = { TWOSET_BONUS = { from = { { set = "PALADIN_T3_REDEMPTION", pieces = 2 }, { soul = "SOUL_OF_TEST" } } } },
        sets = { PALADIN_T3_REDEMPTION = 0 },
      }
      assert.is_true(test(s, 0))
    end)
    it("fails for the wrong soul with too few set pieces", function()
      local test = pred({ { "bonus", "TWOSET_BONUS" } })
      local s = FakeState.new{
        souls = { "SOUL_OF_SOMETHING_ELSE" },
        bonusDefs = { TWOSET_BONUS = { from = { { set = "PALADIN_T3_REDEMPTION", pieces = 2 }, { soul = "SOUL_OF_TEST" } } } },
        sets = { PALADIN_T3_REDEMPTION = 0 },
      }
      assert.is_false(test(s, 0))
    end)
  end)

  describe("enchant", function()
    it("passes when the slot's enchant key matches", function()
      local test = pred({ { "enchant", 16, "SOUL_OF_THE_EXILE" } })
      assert.is_true(test(FakeState.new{ enchants = { [16] = "SOUL_OF_THE_EXILE" } }, 0))
    end)
    it("fails when the slot's enchant key differs or is absent", function()
      local test = pred({ { "enchant", 16, "SOUL_OF_THE_EXILE" } })
      assert.is_false(test(FakeState.new{}, 0))
      assert.is_false(test(FakeState.new{ enchants = { [16] = "SOMETHING_ELSE" } }, 0))
    end)
  end)

  describe("weapon", function()
    it("passes when the equipped weapon matches type and speed range", function()
      local test = pred({ { "weapon", "2H", maxSpeed = 3.0 } })
      assert.is_true(test(FakeState.new{ weapon = { [16] = { type = "2H", speed = 2.6 } } }, 0))
    end)
    it("fails on a mismatched type", function()
      local test = pred({ { "weapon", "2H" } })
      assert.is_false(test(FakeState.new{ weapon = { [16] = { type = "1H", speed = 1.8 } } }, 0))
    end)
    it("fails on a speed out of range", function()
      local test = pred({ { "weapon", "2H", maxSpeed = 3.0 } })
      assert.is_false(test(FakeState.new{ weapon = { [16] = { type = "2H", speed = 3.6 } } }, 0))
    end)
    it("checks the off-hand slot for Shield, not the main hand", function()
      local test = pred({ { "weapon", "Shield" } })
      assert.is_true(test(FakeState.new{ weapon = { [17] = { type = "Shield" } } }, 0))
      assert.is_false(test(FakeState.new{ weapon = { [16] = { type = "Shield" } } }, 0))
    end)
  end)

  describe("seal / no_seal", function()
    it("seal passes when the active seal matches", function()
      local test = pred({ { "seal", "SEAL_OF_MARTYRDOM" } })
      assert.is_true(test(FakeState.new{ seal = "SEAL_OF_MARTYRDOM" }, 0))
    end)
    it("seal fails when a different or no seal is active", function()
      local test = pred({ { "seal", "SEAL_OF_MARTYRDOM" } })
      assert.is_false(test(FakeState.new{ seal = "SEAL_OF_RIGHTEOUSNESS" }, 0))
      assert.is_false(test(FakeState.new{}, 0))
    end)
    it("no_seal passes with no active seal", function()
      local test = pred({ { "no_seal" } })
      assert.is_true(test(FakeState.new{}, 0))
    end)
    it("no_seal fails with an active seal", function()
      local test = pred({ { "no_seal" } })
      assert.is_false(test(FakeState.new{ seal = "SEAL_OF_MARTYRDOM" }, 0))
    end)
  end)

  describe("item_ready", function()
    it("passes when the item is present and off cooldown", function()
      local test = pred({ { "item_ready", 13 } })
      assert.is_true(test(FakeState.new{ items = { [13] = { cooldown = 0 } } }, 0))
    end)
    it("fails when the item is not equipped/usable", function()
      local test = pred({ { "item_ready", 13 } })
      assert.is_false(test(FakeState.new{}, 0))
    end)
    it("fails when the item is on cooldown", function()
      local test = pred({ { "item_ready", 13 } })
      assert.is_false(test(FakeState.new{ items = { [13] = { cooldown = 30 } } }, 0))
    end)
  end)

  describe("rune / no_rune", function()
    it("rune passes when engraved", function()
      local test = pred({ { "rune", "RUNE_ART_OF_WAR" } })
      assert.is_true(test(FakeState.new{ runes = { RUNE_ART_OF_WAR = true } }, 0))
    end)
    it("rune fails when not engraved", function()
      local test = pred({ { "rune", "RUNE_ART_OF_WAR" } })
      assert.is_false(test(FakeState.new{}, 0))
    end)
    it("no_rune passes when not engraved", function()
      local test = pred({ { "no_rune", "RUNE_ART_OF_WAR" } })
      assert.is_true(test(FakeState.new{}, 0))
    end)
    it("no_rune fails when engraved", function()
      local test = pred({ { "no_rune", "RUNE_ART_OF_WAR" } })
      assert.is_false(test(FakeState.new{ runes = { RUNE_ART_OF_WAR = true } }, 0))
    end)
  end)

  describe("level", function()
    it("passes within range", function()
      local test = pred({ { "level", min = 10, max = 20 } })
      assert.is_true(test(FakeState.new{ level = 15 }, 0))
    end)
    it("fails outside range", function()
      local test = pred({ { "level", min = 10, max = 20 } })
      assert.is_false(test(FakeState.new{ level = 25 }, 0))
    end)
  end)

  describe("ttd", function()
    it("passes within the estimated time-to-die window", function()
      local test = pred({ { "ttd", max = 10 } })
      assert.is_true(test(FakeState.new{ ttd = 5 }, 0))
    end)
    it("fails when ttd is unknown (nil never passes)", function()
      local test = pred({ { "ttd", max = 10 } })
      assert.is_false(test(FakeState.new{}, 0))
    end)
  end)

  describe("enemies", function()
    it("passes at or above min", function()
      local test = pred({ { "enemies", min = 3 } })
      assert.is_true(test(FakeState.new{ enemies = 3 }, 0))
    end)
    it("fails below min", function()
      local test = pred({ { "enemies", min = 3 } })
      assert.is_false(test(FakeState.new{ enemies = 1 }, 0))
    end)
  end)

  describe("mode", function()
    it("passes when it matches the current rotation mode", function()
      local test = pred({ { "mode", "Cleave" } })
      assert.is_true(test(FakeState.new{ mode = "Cleave" }, 0))
    end)
    it("fails on a different mode", function()
      local test = pred({ { "mode", "Cleave" } })
      assert.is_false(test(FakeState.new{ mode = "Single" }, 0))
    end)
  end)

  describe("swing", function()
    it("passes within the swing timer window", function()
      local test = pred({ { "swing", maxRemaining = 1.5 } })
      assert.is_true(test(FakeState.new{ swing = 1.0 }, 0))
    end)
    it("fails outside the window, including an unknown (nil) swing timer", function()
      local test = pred({ { "swing", maxRemaining = 1.5 } })
      assert.is_false(test(FakeState.new{ swing = 3.0 }, 0))
      assert.is_false(test(FakeState.new{}, 0))
    end)
  end)

  describe("seal_linger", function()
    it("passes while the replaced seal is still lingering", function()
      local test = pred({ { "seal_linger", "SEAL_OF_MARTYRDOM" } })
      assert.is_true(test(FakeState.new{ sealLinger = "SEAL_OF_MARTYRDOM" }, 0))
    end)
    it("fails when nothing lingers, or a different seal lingers", function()
      local test = pred({ { "seal_linger", "SEAL_OF_MARTYRDOM" } })
      assert.is_false(test(FakeState.new{}, 0))
      assert.is_false(test(FakeState.new{ sealLinger = "SEAL_OF_RIGHTEOUSNESS" }, 0))
    end)
  end)

  describe("custom", function()
    it("passes when the function returns true", function()
      local test = pred({ { "custom", function() return true end } })
      assert.is_true(test(FakeState.new{}, 0))
    end)
    it("fails when the function returns false or a non-true value", function()
      local test = pred({ { "custom", function() return false end } })
      assert.is_false(test(FakeState.new{}, 0))
      local test2 = pred({ { "custom", function() return nil end } })
      assert.is_false(test2(FakeState.new{}, 0))
    end)
    it("receives (state, t) so it can implement its own simulation-aware logic", function()
      local seenState, seenT
      local test = pred({ { "custom", function(state, t) seenState, seenT = state, t; return true end } })
      local s = FakeState.new{}
      test(s, 4.5)
      assert.equal(s, seenState)
      assert.equal(4.5, seenT)
    end)
  end)

  -- ================================================================= simulation semantics
  describe("proc suppression under simulation (docs/02 'Simulation semantics')", function()
    it("a proc-flagged buff is visible at t=0 (live state)", function()
      local test = pred({ { "buff", "ART_OF_WAR_BUFF" } })
      local s = FakeState.new{ buffs = { ART_OF_WAR_BUFF = {} } }
      assert.is_true(test(s, 0))
    end)
    it("a proc-flagged buff is suppressed for t>0 (unpredictable in the future)", function()
      local test = pred({ { "buff", "ART_OF_WAR_BUFF" } })
      local s = FakeState.new{ buffs = { ART_OF_WAR_BUFF = {} } }
      assert.is_false(test(s, 1.5))
    end)
    it("a non-proc buff is NOT suppressed for t>0", function()
      local test = pred({ { "buff", "HOLY_POWER_BUFF" } })
      local s = FakeState.new{ buffs = { HOLY_POWER_BUFF = {} } }
      assert.is_true(test(s, 1.5))
    end)
    it("cooldowns are read as-is and not further adjusted by t", function()
      -- docs/02: Simulation's virtual state already returns cooldown relative to t; the predicate
      -- must not double-count by also subtracting t.
      local test = pred({ { "cooldown_ready", "EXORCISM" } })
      local s = FakeState.new{ cooldowns = { EXORCISM = 5 } }
      assert.is_false(test(s, 10))
    end)
  end)

  -- ================================================================= all / any / not composition
  describe("all / any / not composition", function()
    it("implicit all: a bare `when` list requires every condition (top-level, no wrapper)", function()
      local test = pred({ { "buff", "HOLY_POWER_BUFF" }, { "set", "PALADIN_T3_REDEMPTION", min = 2 } })
      local both = FakeState.new{ buffs = { HOLY_POWER_BUFF = {} }, sets = { PALADIN_T3_REDEMPTION = 2 } }
      local onlyOne = FakeState.new{ buffs = { HOLY_POWER_BUFF = {} }, sets = { PALADIN_T3_REDEMPTION = 0 } }
      assert.is_true(test(both, 0))
      assert.is_false(test(onlyOne, 0))
    end)

    it("evaluates the nested {any {buff min} {not {set min}}} shape used in real builds", function()
      local when = { { "any", { "buff", "HOLY_POWER_BUFF", min = 3 }, { "not", { "set", "PALADIN_T3_REDEMPTION", min = 2 } } } }
      local test = pred(when)
      -- branch 1 true -> any true regardless of branch 2
      assert.is_true(test(FakeState.new{ buffs = { HOLY_POWER_BUFF = { stacks = 3 } }, sets = { PALADIN_T3_REDEMPTION = 2 } }, 0))
      -- branch 1 false; branch 2 = not(set>=2) = true because there are 0 pieces
      assert.is_true(test(FakeState.new{ sets = { PALADIN_T3_REDEMPTION = 0 } }, 0))
      -- branch 1 false; branch 2 = not(set>=2) = false because the threshold is met
      assert.is_false(test(FakeState.new{ sets = { PALADIN_T3_REDEMPTION = 2 } }, 0))
    end)

    it("explicit all requires every nested condition", function()
      local test = pred({ { "all", { "buff", "HOLY_POWER_BUFF" }, { "in_combat" } } })
      assert.is_true(test(FakeState.new{ buffs = { HOLY_POWER_BUFF = {} } }, 0))
      assert.is_false(test(FakeState.new{}, 0)) -- no buff -> all fails even though in_combat passes
    end)

    it("not negates its single nested condition", function()
      local test = pred({ { "not", { "buff", "HOLY_POWER_BUFF" } } })
      assert.is_true(test(FakeState.new{}, 0))
      assert.is_false(test(FakeState.new{ buffs = { HOLY_POWER_BUFF = {} } }, 0))
    end)
  end)

  -- ================================================================= malformed builds
  describe("Schema.validate rejects malformed builds without raising", function()
    local function baseBuild(overrides)
      local b = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = { { spell = "TESTSPELL" } },
      }
      for k, v in pairs(overrides or {}) do b[k] = v end
      return b
    end

    it("errors when schema is missing or wrong", function()
      local ok, errors = Schema.validate(baseBuild{ schema = 2 }, ctx())
      assert.is_false(ok)
      assert.is_true(#errors > 0)
      assert.matches("schema must be 1", errors[1].message)
      assert.is_nil(errors[1].entry)
    end)

    it("errors when key is missing", function()
      local b = baseBuild(); b.key = nil
      local ok, errors = Schema.validate(b, ctx())
      assert.is_false(ok)
      local found = false
      for _, e in ipairs(errors) do if e.message:match("^key ") then found = true end end
      assert.is_true(found)
    end)

    it("errors when name is missing", function()
      local b = baseBuild(); b.name = nil
      local ok = Schema.validate(b, ctx())
      assert.is_false(ok)
    end)

    it("errors when class is missing", function()
      local b = baseBuild(); b.class = nil
      local ok = Schema.validate(b, ctx())
      assert.is_false(ok)
    end)

    it("errors when entries is an empty list", function()
      local ok, errors = Schema.validate(baseBuild{ entries = {} }, ctx())
      assert.is_false(ok)
      assert.matches("entries must be a non%-empty list", errors[1].message)
    end)

    it("errors when entries is missing entirely", function()
      -- Not baseBuild{entries=nil}: a table constructor never stores a nil-valued key, so that
      -- would silently leave baseBuild()'s default (non-empty) entries list in place.
      local b = { schema = 1, key = "TEST", name = "Test", class = "PALADIN" }
      local ok = Schema.validate(b, ctx())
      assert.is_false(ok)
    end)

    it("errors when an entry has both spell and item", function()
      local ok, errors = Schema.validate(baseBuild{ entries = { { spell = "TESTSPELL", item = 13 } } }, ctx())
      assert.is_false(ok)
      assert.equal(1, errors[1].entry)
      assert.matches("both spell and item", errors[1].message)
    end)

    it("errors when an entry has neither spell nor item", function()
      local ok, errors = Schema.validate(baseBuild{ entries = { {} } }, ctx())
      assert.is_false(ok)
      assert.equal(1, errors[1].entry)
      assert.matches("either a spell key or an item slot", errors[1].message)
    end)

    it("errors on a raw numeric spell ID instead of a symbolic key", function()
      local ok, errors = Schema.validate(baseBuild{ entries = { { spell = 12345 } } }, ctx())
      assert.is_false(ok)
      local found = false
      for _, e in ipairs(errors) do
        if e.entry == 1 and e.message:match("symbolic key string, not a raw ID") then found = true end
      end
      assert.is_true(found)
    end)

    it("Schema.compile returns nil (never a half-compiled build) alongside the errors", function()
      local compiled, errors = Schema.compile(baseBuild{ schema = 2 }, ctx())
      assert.is_nil(compiled)
      assert.is_true(#errors > 0)
    end)

    -- D93/D94 (2026-09-07 in-game round): this is the developer diagnostic D26 deliberately kept as
    -- a plain print for real load-time pack failures -- it must keep logging exactly once, with the
    -- build's key and the problem count, and with no doubled "Elmira: " (ns.log/AceConsole's Printf
    -- already prefixes the addon name). The Options/Rotation preview no longer reaches this path for
    -- an in-progress draft (schema_spec pins Schema.compile itself; rotation_spec pins the preview).
    it("still logs once on validation failure, naming the key and the count, with no doubled prefix", function()
      local logged = {}
      ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
      local compiled, errors = Schema.compile(baseBuild{ schema = 2, key = "USER_TEST" }, ctx())
      assert.is_nil(compiled)
      assert.equal(1, #logged)
      assert.equal(string.format("build 'USER_TEST' failed validation (%d problem(s))", #errors), logged[1])
      assert.is_falsy(logged[1]:find("Elmira:", 1, true), "ns.log already prefixes the addon name")
    end)

    it("never raises even for a completely bogus build", function()
      assert.has_no.errors(function() Schema.validate(nil) end)
      assert.has_no.errors(function() Schema.validate("not a build") end)
      assert.has_no.errors(function() Schema.validate(42) end)
      local ok, errors = Schema.validate(nil)
      assert.is_false(ok)
      assert.is_true(#errors > 0)
    end)
  end)

  -- ================================================================= unknown condition type
  describe("unknown condition type", function()
    it("errors naming the entry index and the bad type", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = {
          { spell = "TESTSPELL" },
          { spell = "TESTSPELL" },
          { spell = "TESTSPELL", when = { { "not_a_real_condition_type" } } },
        },
      }
      local ok, errors = Schema.validate(build, ctx())
      assert.is_false(ok)
      local found
      for _, e in ipairs(errors) do
        if e.entry == 3 and e.message:match("not_a_real_condition_type") then found = e end
      end
      assert.is_truthy(found)
      assert.matches("unknown condition type", found.message)
    end)

    it("errorLines renders 'entry N: message' for entry-scoped errors", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = { { spell = "TESTSPELL", when = { { "bogus" } } } },
      }
      local _, errors = Schema.validate(build, ctx())
      local lines = Schema.errorLines(errors)
      assert.is_true(#lines >= 1)
      assert.matches("^entry 1: ", lines[1])
    end)

    it("errorLines renders bare messages for build-level (entry-less) errors", function()
      local build = {
        schema = 2, key = "T", name = "T", class = "PALADIN",
        entries = { { spell = "TESTSPELL" } },
      }
      local _, errors = Schema.validate(build, ctx())
      local lines = Schema.errorLines(errors)
      assert.is_nil(lines[1]:match("^entry"))
    end)

    -- Cross-check that the leaf condition set Schema.lua actually implements matches docs/02's
    -- table exactly (all/any/not are composition, not leaf conditions, and are tested separately
    -- above). A doc/code drift in either direction — a documented type Schema.lua forgot to wire
    -- up, or an implemented type docs/02 doesn't mention — fails here rather than silently.
    it("ns.__schemaConditions implements exactly the leaf types documented in docs/02", function()
      local docTypes = {
        "buff", "no_buff", "debuff", "no_debuff", "resource", "cooldown_ready", "cooldown_gt",
        "target_type", "target_hp", "not_moving", "in_combat", "out_of_combat", "set", "bonus",
        "enchant", "weapon", "seal", "no_seal", "item_ready", "rune", "no_rune", "level", "ttd",
        "enemies", "mode", "swing", "seal_linger", "custom",
      }
      local impl = ns.__schemaConditions
      assert.is_table(impl)
      for _, t in ipairs(docTypes) do
        assert.is_not_nil(impl[t], "docs/02 documents '" .. t .. "' but Schema.lua does not implement it")
      end
      local implCount = 0
      for _ in pairs(impl) do implCount = implCount + 1 end
      assert.equal(#docTypes, implCount)
    end)
  end)

  -- ================================================================= data-pack key checks
  describe("missing data pack keys (docs/02: 'a port to a new flavor fails loudly at load')", function()
    it("errors when entry.spell is absent from a SUPPLIED spells pack", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = { { spell = "GHOST_SPELL" } },
      }
      local ok, errors = Schema.validate(build, { spells = { TESTSPELL = {} } })
      assert.is_false(ok)
      local found = false
      for _, e in ipairs(errors) do if e.message:match("GHOST_SPELL") then found = true end end
      assert.is_true(found)
    end)

    it("does NOT error on entry.spell when no spells ctx table is supplied at all", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = { { spell = "GHOST_SPELL" } },
      }
      local ok, errors = Schema.validate(build, {})
      assert.is_true(ok, table.concat(Schema.errorLines(errors), "; "))
    end)

    it("errors when a condition's key is absent from a SUPPLIED spells pack", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = { { spell = "TESTSPELL", when = { { "buff", "GHOST_BUFF" } } } },
      }
      local ok, errors = Schema.validate(build, { spells = { TESTSPELL = {} } })
      assert.is_false(ok)
      local found = false
      for _, e in ipairs(errors) do
        if e.entry == 1 and e.message:match("GHOST_BUFF") and e.message:match("spells data pack") then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("does NOT error on that same condition when no spells ctx table is supplied at all", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = { { spell = "TESTSPELL", when = { { "buff", "GHOST_BUFF" } } } },
      }
      local ok, errors = Schema.validate(build, {})
      assert.is_true(ok, table.concat(Schema.errorLines(errors), "; "))
    end)

    it("errors for `set` keys absent from a SUPPLIED sets pack", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = { { spell = "TESTSPELL", when = { { "set", "GHOST_SET", min = 2 } } } },
      }
      local ok = Schema.validate(build, { spells = { TESTSPELL = {} }, sets = {} })
      assert.is_false(ok)
    end)

    it("errors for `bonus` keys absent from a SUPPLIED bonuses pack", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = { { spell = "TESTSPELL", when = { { "bonus", "GHOST_BONUS" } } } },
      }
      local ok = Schema.validate(build, { spells = { TESTSPELL = {} }, bonuses = {} })
      assert.is_false(ok)
    end)
  end)

  -- ================================================================= condition argument shape
  -- docs/02 doesn't spell out per-argument validation, but Schema.lua's `check` hooks are part of
  -- its documented public contract (validation errors "beyond generic key/type checks" per the
  -- module header) — worth guarding as a safety net against silent regressions.
  describe("condition argument validation (per-type `check` guards)", function()
    local cases = {
      { name = "resource missing a power kind", when = { { "resource" } } },
      { name = "cooldown_gt missing seconds", when = { { "cooldown_gt", "EXORCISM" } } },
      { name = "target_type missing any creature type", when = { { "target_type" } } },
      { name = "enchant missing an inventory slot number", when = { { "enchant", nil, "KEY" } } },
      { name = "enchant missing an enchant key", when = { { "enchant", 16 } } },
      { name = "weapon with an invalid kind", when = { { "weapon", "Wand" } } },
      { name = "item_ready missing an inventory slot number", when = { { "item_ready" } } },
      { name = "mode with an invalid value", when = { { "mode", "Solo" } } },
      { name = "custom with a non-function payload", when = { { "custom", "not a function" } } },
    }
    for _, case in ipairs(cases) do
      it(case.name .. " fails validation", function()
        local build = {
          schema = 1, key = "TEST", name = "Test", class = "PALADIN",
          entries = { { spell = "TESTSPELL", when = case.when } },
        }
        local ok = Schema.validate(build, ctx())
        assert.is_false(ok, case.name .. " should have failed validation")
      end)
    end
  end)

  -- ================================================================= export
  describe("Schema.exportable (docs/02 import/export: functions are never serialized)", function()
    local function sampleBuild()
      return {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = {
          { spell = "JUDGEMENT", when = { { "seal", "SEAL_OF_MARTYRDOM" } }, label = "Judge" },
          { spell = "EXORCISM", when = { { "custom", function(state) return state:seal() ~= nil end } } },
          { spell = "CRUSADER_STRIKE" },
        },
      }
    end

    it("strips `when` and marks disabled on the entry whose when directly contains `custom`", function()
      local out, stripped = Schema.exportable(sampleBuild())
      assert.equal(1, stripped)
      assert.is_nil(out.entries[2].when)
      assert.is_true(out.entries[2].disabled)
      -- unaffected entries keep their `when` and are not marked disabled
      assert.same({ { "seal", "SEAL_OF_MARTYRDOM" } }, out.entries[1].when)
      assert.is_nil(out.entries[1].disabled)
      assert.is_nil(out.entries[3].disabled)
    end)

    it("does not mutate the original build", function()
      local build = sampleBuild()
      Schema.exportable(build)
      assert.is_table(build.entries[2].when)
      assert.is_function(build.entries[2].when[1][2])
    end)

    it("strips compiled `test`/`data` artefacts and the `compiled` flag when exporting a compiled build", function()
      local compiled = Schema.compile(sampleBuild(), ctx())
      local out = Schema.exportable(compiled)
      assert.is_nil(out.compiled)
      for _, e in ipairs(out.entries) do
        assert.is_nil(e.test)
        assert.is_nil(e.data)
      end
    end)

    -- Regression: exportable() originally scanned only the direct items of `entry.when`, so a
    -- `custom` nested inside all/any/not exported with its Lua function still embedded. Functions
    -- cannot serialize, so that is a broken export string rather than a merely lost condition —
    -- docs/02 "Import/export string" and ADR-0002 both require it to be stripped.
    it("detects `custom` nested inside all/any/not", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = {
          { spell = "EXORCISM", when = { { "any", { "custom", function() return true end }, { "buff", "HOLY_POWER_BUFF" } } } },
        },
      }
      local out, stripped = Schema.exportable(build)
      assert.equal(1, stripped)
      assert.is_nil(out.entries[1].when)
      assert.is_true(out.entries[1].disabled)
    end)

    it("detects `custom` nested two levels deep, inside not-inside-any", function()
      local build = {
        schema = 1, key = "TEST", name = "Test", class = "PALADIN",
        entries = {
          { spell = "EXORCISM", when = { { "any", { "not", { "custom", function() return false end } } } } },
          { spell = "JUDGEMENT", when = { { "any", { "not", { "buff", "HOLY_POWER_BUFF" } } } } },
        },
      }
      local out, stripped = Schema.exportable(build)
      assert.equal(1, stripped)
      assert.is_true(out.entries[1].disabled)
      assert.is_nil(out.entries[2].disabled)      -- an identically shaped tree without custom survives
      assert.is_not_nil(out.entries[2].when)
    end)
  end)

  -- A percentage string ("6% of base mana") is what Wowhead gives for several paladin abilities, and
  -- Simulation's `spent[kind] + amount` turns it into a Lua error mid-queue rather than a load-time
  -- failure. ADR-0002's rule is that bad data fails at validation, so pin it here.
  it("rejects a non-numeric spell cost with a useful message", function()
    local build = { schema = 1, key = "TEST", name = "Test", class = "PALADIN",
                    entries = { { spell = "JUDGEMENT", when = {} } } }
    local c = ctx(); c.spells.JUDGEMENT = { id = 1, cost = { mana = "6% of base mana" } }
    local ok, errors = Schema.validate(build, c)
    assert.is_false(ok)
    local text = table.concat(Schema.errorLines(errors), "\n")
    assert.truthy(text:find("non%-numeric"), text)
    assert.truthy(text:find("mana"), text)
  end)

  it("accepts a numeric spell cost", function()
    local build = { schema = 1, key = "TEST", name = "Test", class = "PALADIN",
                    entries = { { spell = "EXORCISM", when = {} } } }
    local c = ctx(); c.spells.EXORCISM = { id = 1, cost = { mana = 345 } }
    assert.is_true((Schema.validate(build, c)))
  end)
end)
