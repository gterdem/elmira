-- tests/spec/engine_spec.lua — Core/Engine.lua (docs/01-ARCHITECTURE.md §3, docs/02-CONDITION-SCHEMA.md,
-- ADR-0006). Headless: no WoW globals, tests/fake_state.lua stands in for the adapter.
--
-- Restored from the pre-M1 sketch, with its two documented
-- defects fixed:
--   1. `package.path` munging + `require("fake_state")` + a hand-set `_G.__ELM_NS` -> tests/helper.lua.
--   2. The proc test asserted on ART_OF_WAR_BUFF, which tests/fixtures/spells.lua does NOT flag
--      `proc = true` (only VENGEANCE_BUFF is). Swapped to VENGEANCE_BUFF, the fixture's actual proc aura.
local helper = require("tests.helper")

describe("Engine.pick / Engine.eligible", function()
  local Schema, Engine, FakeState, spellsCtx, setsCtx

  -- Fails loudly (with the Schema error list) instead of handing a later `it` a nil build to chase.
  local function compileBuild(raw, ctx)
    local build, errors = Schema.compile(raw, ctx)
    assert.is_not_nil(build, table.concat(Schema.errorLines(errors or {}), "; "))
    return build
  end

  before_each(function()
    helper.reset()
    helper.load("Elmira/Adapters/Interface.lua")
    Schema = helper.load("Elmira/Core/Schema.lua")
    Engine = helper.load("Elmira/Core/Engine.lua")
    FakeState = dofile("tests/fake_state.lua")
    spellsCtx = dofile("tests/fixtures/spells.lua")
    setsCtx = dofile("tests/fixtures/sets.lua")
  end)

  -- -------------------------------------------------------------- basic priority mechanics
  describe("basic priority mechanics (minimal build)", function()
    local build

    before_each(function()
      build = compileBuild({
        schema = 1, key = "MINI", name = "Mini priority build", class = "PALADIN", flavor = "SoD",
        entries = {
          { spell = "JUDGEMENT" },
          { spell = "CRUSADER_STRIKE" },
          { spell = "EXORCISM" },
        },
      }, { spells = spellsCtx })
    end)

    it("picks the first eligible entry in priority order", function()
      local entry, index = Engine.pick(build, FakeState.new{}, 0)
      assert.equals("JUDGEMENT", entry.spell)
      assert.equals(1, index)
    end)

    it("falls through to the next entry when the top one is on cooldown", function()
      local s = FakeState.new{ cooldowns = { JUDGEMENT = 4 } }
      local entry, index = Engine.pick(build, s, 0)
      assert.equals("CRUSADER_STRIKE", entry.spell)
      assert.equals(2, index)
    end)

    it("falls through past every entry that is on cooldown", function()
      local s = FakeState.new{ cooldowns = { JUDGEMENT = 4, CRUSADER_STRIKE = 2 } }
      local entry, index = Engine.pick(build, s, 0)
      assert.equals("EXORCISM", entry.spell)
      assert.equals(3, index)
    end)

    -- ADR-0006 rule 5: an ability the character has not learned is skipped SILENTLY, not treated as
    -- an error and not treated as "nothing left to scan".
    it("skips an unlearned (unusable) entry silently and keeps scanning", function()
      local s = FakeState.new{ usable = { JUDGEMENT = false } }
      local entry, index = Engine.pick(build, s, 0)
      assert.equals("CRUSADER_STRIKE", entry.spell)
      assert.equals(2, index)
    end)

    it("skips every unusable entry and still finds a usable one further down", function()
      local s = FakeState.new{ usable = { JUDGEMENT = false, CRUSADER_STRIKE = false } }
      local entry = Engine.pick(build, s, 0)
      assert.equals("EXORCISM", entry.spell)
    end)

    it("returns nil (and no index) when every entry is on cooldown", function()
      local s = FakeState.new{ cooldowns = { JUDGEMENT = 1, CRUSADER_STRIKE = 1, EXORCISM = 1 } }
      local entry, index = Engine.pick(build, s, 0)
      assert.is_nil(entry)
      assert.is_nil(index)
    end)

    it("returns nil when every entry is unusable, without erroring", function()
      local s = FakeState.new{ usable = { JUDGEMENT = false, CRUSADER_STRIKE = false, EXORCISM = false } }
      assert.is_nil(Engine.pick(build, s, 0))
    end)

    it("returns nil for a build with no entries table, without erroring", function()
      assert.is_nil(Engine.pick({ schema = 1 }, FakeState.new{}, 0))
    end)

    it("Engine.eligible agrees with Engine.pick's per-entry decision", function()
      local ready = FakeState.new{}
      local busy = FakeState.new{ cooldowns = { CRUSADER_STRIKE = 3 } }
      local crusaderStrike = build.entries[2]
      assert.is_true(Engine.eligible(crusaderStrike, ready, 0))
      assert.is_false(Engine.eligible(crusaderStrike, busy, 0))
    end)
  end)

  -- -------------------------------------------------------------- item entries
  describe("item entries gated by item_ready", function()
    local build

    before_each(function()
      build = compileBuild({
        schema = 1, key = "MINI_ITEM", name = "Mini item build", class = "PALADIN", flavor = "SoD",
        entries = {
          { item = 13, when = { {"item_ready", 13} }, label = "Trinket" },
          { spell = "JUDGEMENT" },
        },
      }, { spells = spellsCtx })
    end)

    it("falls through to the spell baseline when the item slot is empty", function()
      local entry = Engine.pick(build, FakeState.new{}, 0)
      assert.equals("JUDGEMENT", entry.spell)
    end)

    it("picks the item when it is usable and off cooldown", function()
      local s = FakeState.new{ items = { [13] = { cooldown = 0 } } }
      local entry, index = Engine.pick(build, s, 0)
      assert.equals(13, entry.item)
      assert.is_nil(entry.spell)
      assert.equals(1, index)
    end)

    it("falls through to the spell baseline while the item is on cooldown", function()
      local s = FakeState.new{ items = { [13] = { cooldown = 30 } } }
      local entry = Engine.pick(build, s, 0)
      assert.equals("JUDGEMENT", entry.spell)
    end)
  end)

  -- -------------------------------------------------------------- restored staged intentions
  describe("against the Exodin fixture (restored staged intentions)", function()
    local build

    before_each(function()
      build = compileBuild(dofile("tests/fixtures/paladin_exodin.lua"),
        { spells = spellsCtx, sets = setsCtx.sets, bonuses = setsCtx.bonuses })
    end)

    -- Locks in the reason ART_OF_WAR_BUFF was replaced: if the fixture ever grows an ART_OF_WAR_BUFF
    -- key, or VENGEANCE_BUFF stops being the proc aura, the test below would silently start testing
    -- the wrong thing without this guard.
    it("fixture sanity: VENGEANCE_BUFF is the proc aura, not ART_OF_WAR_BUFF", function()
      assert.is_true(spellsCtx.VENGEANCE_BUFF.proc)
      assert.is_nil(spellsCtx.ART_OF_WAR_BUFF)
    end)

    it("puts Exorcism first on a Vengeance proc", function()
      local s = FakeState.new{ buffs = { VENGEANCE_BUFF = { stacks = 1 } }, seal = "SEAL_OF_MARTYRDOM" }
      local entry = Engine.pick(build, s, 0)
      assert.equals("EXORCISM", entry.spell)
      assert.equals("Proc", entry.label)
    end)

    it("skips Judgement while it is on cooldown", function()
      local s = FakeState.new{ cooldowns = { JUDGEMENT = 4 }, seal = "SEAL_OF_MARTYRDOM" }
      local entry = Engine.pick(build, s, 0)
      assert.not_equals("JUDGEMENT", entry.spell)
      assert.equals("EXORCISM", entry.spell) -- falls to the baseline Exorcism entry (index 5)
    end)

    it("gates Holy Wrath to undead/demon targets", function()
      local s = FakeState.new{
        cooldowns = { JUDGEMENT = 5, EXORCISM = 5, CRUSADER_STRIKE = 5, DIVINE_STORM = 5 },
        targetType = "Humanoid", seal = "SEAL_OF_MARTYRDOM",
      }
      local entry = Engine.pick(build, s, 0)
      assert.not_equals("HOLY_WRATH", entry.spell)
      assert.equals("CONSECRATION", entry.spell) -- everything above it failed or was on cooldown
    end)

    it("Engine.pick itself demotes a proc entry once t advances past 0", function()
      local s = FakeState.new{ buffs = { VENGEANCE_BUFF = { stacks = 1 } }, seal = "SEAL_OF_MARTYRDOM" }
      local at0, idx0 = Engine.pick(build, s, 0)
      local at1, idx1 = Engine.pick(build, s, 1)
      assert.equals("EXORCISM", at0.spell); assert.equals("Proc", at0.label); assert.equals(2, idx0)
      assert.equals("EXORCISM", at1.spell); assert.is_nil(at1.label); assert.equals(5, idx1)
    end)

    it("Engine.eligible suppresses a proc-flagged buff condition for t>0 independent of cooldown", function()
      local entry = build.entries[2] -- gated Exorcism, `when = {{"buff","VENGEANCE_BUFF"}}`
      local s = FakeState.new{ buffs = { VENGEANCE_BUFF = { stacks = 1 } } } -- Exorcism stays off cooldown throughout
      assert.is_true(Engine.eligible(entry, s, 0))
      assert.is_false(Engine.eligible(entry, s, 0.01))
      assert.is_false(Engine.eligible(entry, s, 5))
    end)

    -- ADR-0006 shape: a gated entry sits above the ungated baseline duplicate it outranks, and only
    -- wins when its own gate passes -- otherwise the baseline underneath must still fire.
    describe("Divine Storm: gated entry above its ungated baseline duplicate", function()
      local function stateWith(buffs, bonuses)
        return FakeState.new{
          seal = "SEAL_OF_MARTYRDOM",
          cooldowns = { EXORCISM = 5, CRUSADER_STRIKE = 5 }, -- neutralize entries 1-6 so 7/8 decide
          buffs = buffs or {},
          bonuses = bonuses or {},
        }
      end

      it("baseline wins when neither the buff nor the bonus is present", function()
        local entry, index = Engine.pick(build, stateWith(), 0)
        assert.equals("DIVINE_STORM", entry.spell)
        assert.is_nil(entry.label)
        assert.equals(8, index)
      end)

      it("baseline still wins when only the buff half of the gate is present", function()
        local entry, index = Engine.pick(build, stateWith({ HOLY_POWER_BUFF = { stacks = 3 } }), 0)
        assert.equals("DIVINE_STORM", entry.spell)
        assert.is_nil(entry.label)
        assert.equals(8, index)
      end)

      it("baseline still wins when only the bonus half of the gate is present", function()
        local entry, index = Engine.pick(build, stateWith(nil, { HOLY_POWER_CONSUME = true }), 0)
        assert.equals("DIVINE_STORM", entry.spell)
        assert.is_nil(entry.label)
        assert.equals(8, index)
      end)

      it("the gated entry wins only once both halves of its gate pass", function()
        local entry, index = Engine.pick(build,
          stateWith({ HOLY_POWER_BUFF = { stacks = 3 } }, { HOLY_POWER_CONSUME = true }), 0)
        assert.equals("DIVINE_STORM", entry.spell)
        assert.equals("3 Holy Power", entry.label)
        assert.equals(7, index)
      end)
    end)

    -- A `bonus` condition must resolve through set thresholds via bonusDefs, exactly as the adapter
    -- will (docs/01 §5a: "bonus(key) = set threshold OR soul").
    it("reaches the gated Judgement only once its set-derived bonus threshold is met", function()
      local gatedState = FakeState.new{
        seal = "SEAL_OF_MARTYRDOM",
        sets = { PALADIN_T2_JUDGEMENT = 2 }, bonusDefs = setsCtx.bonuses,
      }
      local entry, index = Engine.pick(build, gatedState, 0)
      assert.equals("JUDGEMENT", entry.spell)
      assert.equals("Draconic 2p", entry.label)
      assert.equals(4, index)

      local ungatedState = FakeState.new{ seal = "SEAL_OF_MARTYRDOM", bonusDefs = setsCtx.bonuses }
      local fallback = Engine.pick(build, ungatedState, 0)
      assert.equals("EXORCISM", fallback.spell) -- baseline, index 5: the bonus gate failed with 0 pieces
    end)

    -- Nested `any`/`not` composition (AVENGING_WRATH's gate) resolved correctly.
    describe("Avenging Wrath: nested any/not gate", function()
      it("fires when Vengeance is up and the T35 2-piece is absent", function()
        local s = FakeState.new{
          seal = "SEAL_OF_MARTYRDOM",
          buffs = { VENGEANCE_BUFF = { stacks = 1 } },
          cooldowns = { EXORCISM = 5, CRUSADER_STRIKE = 5, DIVINE_STORM = 5 },
        }
        local entry, index = Engine.pick(build, s, 0)
        assert.equals("AVENGING_WRATH", entry.spell)
        assert.equals("Burst", entry.label)
        assert.is_true(entry.hold)
        assert.equals(10, index)
      end)

      it("does not fire when both the any-branches are false (T35 2-piece present, no Holy Power)", function()
        local s = FakeState.new{
          seal = "SEAL_OF_MARTYRDOM",
          buffs = { VENGEANCE_BUFF = { stacks = 1 } },
          cooldowns = { EXORCISM = 5, CRUSADER_STRIKE = 5, DIVINE_STORM = 5 },
          sets = { PALADIN_T35_INQUISITION = 2 },
        }
        local entry = Engine.pick(build, s, 0)
        assert.equals("CONSECRATION", entry.spell) -- Avenging Wrath's gate failed; falls through to it
      end)
    end)
  end)

  -- -------------------------------------------------------------- soul-granted bonus (ADR-0006 §3)
  describe("a soul can grant a bonus with zero set pieces equipped", function()
    local build

    before_each(function()
      build = compileBuild({
        schema = 1, key = "MINI_SOUL", name = "Mini soul build", class = "PALADIN", flavor = "SoD",
        entries = {
          { spell = "CRUSADER_STRIKE", when = { {"bonus", "CRUSADER_STRIKE_150"} }, label = "150%" },
          { spell = "JUDGEMENT", label = "Baseline" },
        },
      }, { spells = spellsCtx, sets = setsCtx.sets, bonuses = setsCtx.bonuses })
    end)

    it("wins the gate via the shoulder soul alone, with 0 set pieces equipped", function()
      local s = FakeState.new{ souls = { "SOUL_OF_THE_RETRIBUTOR" }, sets = {}, bonusDefs = setsCtx.bonuses }
      local entry = Engine.pick(build, s, 0)
      assert.equals("CRUSADER_STRIKE", entry.spell)
      assert.equals("150%", entry.label)
    end)

    it("falls back to baseline when the equipped soul does not grant the bonus (wrong-soul case)", function()
      local s = FakeState.new{ souls = { "SOUL_OF_THE_EXILE" }, sets = {}, bonusDefs = setsCtx.bonuses }
      local entry = Engine.pick(build, s, 0)
      assert.equals("JUDGEMENT", entry.spell)
      assert.equals("Baseline", entry.label)
    end)
  end)
end)
