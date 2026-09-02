-- tests/spec/capture_mark_spec.lua — ns.captureMark(pack) (Core/Slash.lua), Contract A.
--
-- Written from the contract text handed down for this recorder extension, not from reading
-- Core/Slash.lua's implementation first: a mark must additionally carry baseCooldowns (distinct from
-- cooldowns), gcd and gcdDuration (distinct from each other — conflating them has broken this project
-- once already), buffs (only the ones the pack's builds reference, only when present), seal, mana,
-- target, and every number rounded to 2 decimals.
local helper = require("tests.helper")
local FakeState = dofile("tests/fake_state.lua")

describe("ns.captureMark (Contract A)", function()
  local Slash, ns

  -- A pack whose one build references three buffs, one of them nested two levels deep inside
  -- any/not, so referencedBuffs (and therefore mark.buffs) has to walk nested conditions to find
  -- them all — a flat top-level-only walk would miss JUDGEMENT_BUFF and SEAL_BUFF.
  local function testPack(overrides)
    local pack = {
      spells = { A = { id = 1 }, B = { id = 2 } },
      sets = {},
      builds = {
        TEST_BUILD = {
          entries = {
            { spell = "A", when = {
              { "all",
                { "buff", "VENGEANCE_BUFF" },
                { "any", { "buff", "JUDGEMENT_BUFF" }, { "not", { "buff", "SEAL_BUFF" } } },
              },
            } },
          },
        },
      },
    }
    for k, v in pairs(overrides or {}) do pack[k] = v end
    return pack
  end

  before_each(function()
    helper.reset()
    Slash = helper.load("Elmira/Core/Slash.lua")
    ns = helper.ns()
  end)

  local function withState(state)
    ns.API = { GetState = function() return state end }
  end

  describe("baseCooldowns", function()
    it("is a different question from `cooldowns`: the learned duration, not time remaining", function()
      local pack = testPack{ spells = { A = { id = 1 }, B = { id = 2 } } }
      withState(FakeState.new{ cooldowns = { A = 3.5 }, baseCooldown = { A = 6 } })
      local mark = Slash and ns.captureMark(pack)
      assert.equal(3.5, mark.cooldowns.A, "cooldowns is time remaining")
      assert.equal(6, mark.baseCooldowns.A, "baseCooldowns is the learned duration")
      assert.is_not.equal(mark.cooldowns.A, mark.baseCooldowns.A)
    end)

    it("only records a base cooldown whose learned duration is > 0", function()
      local pack = testPack{ spells = { A = { id = 1 }, B = { id = 2 } } }
      withState(FakeState.new{ baseCooldown = { A = 6, B = 0 } })
      local mark = ns.captureMark(pack)
      assert.equal(6, mark.baseCooldowns.A)
      assert.is_nil(mark.baseCooldowns.B, "a base cooldown of exactly 0 carries no information")
    end)
  end)

  describe("gcd and gcdDuration", function()
    it("records both, separately: gcd is remaining, gcdDuration is the full length", function()
      local pack = testPack()
      withState(FakeState.new{ gcd = 0.42, gcdDuration = 1.5 })
      local mark = ns.captureMark(pack)
      assert.equal(0.42, mark.gcd)
      assert.equal(1.5, mark.gcdDuration)
      assert.is_not.equal(mark.gcd, mark.gcdDuration,
        "conflating gcd (remaining) with gcdDuration (full length) has broken this project once already")
    end)
  end)

  describe("buffs", function()
    it("captures exactly the buffs the pack's builds reference, only when present on the player", function()
      local pack = testPack()
      withState(FakeState.new{ buffs = {
        VENGEANCE_BUFF = { stacks = 2, remaining = 12.336 },
        UNREFERENCED_BUFF = { stacks = 1, remaining = 5 }, -- not asked about by any build
      } })
      local mark = ns.captureMark(pack)
      assert.same({ stacks = 2, remaining = 12.34 }, mark.buffs.VENGEANCE_BUFF)
      assert.is_nil(mark.buffs.UNREFERENCED_BUFF, "a buff no build's `when` reads must not be recorded")
      assert.is_nil(mark.buffs.JUDGEMENT_BUFF, "referenced (nested in any/not) but not present on the player")
      assert.is_nil(mark.buffs.SEAL_BUFF, "referenced (nested two levels deep) but not present")
    end)

    it("finds buffs referenced only inside nested all/any/not, not just top-level conditions", function()
      local pack = testPack()
      withState(FakeState.new{ buffs = { SEAL_BUFF = { stacks = 1, remaining = 4 } } })
      local mark = ns.captureMark(pack)
      assert.is_table(mark.buffs.SEAL_BUFF, "SEAL_BUFF is nested inside all>any>not in the fixture build")
    end)
  end)

  describe("seal", function()
    it("records the active seal key", function()
      local pack = testPack()
      withState(FakeState.new{ seal = "SEAL_OF_RIGHTEOUSNESS" })
      assert.equal("SEAL_OF_RIGHTEOUSNESS", ns.captureMark(pack).seal)
    end)

    it("records nil, not a stale value, when no seal is active", function()
      local pack = testPack()
      withState(FakeState.new{})
      assert.is_nil(ns.captureMark(pack).seal)
    end)
  end)

  describe("mana", function()
    it("records current mana, rounded to 2 decimals", function()
      local pack = testPack()
      withState(FakeState.new{ power = { MANA = { 22.33333, 100 } } })
      assert.equal(22.33, ns.captureMark(pack).mana)
    end)
  end)

  describe("target", function()
    it("records existence, creature type and hp percent", function()
      local pack = testPack()
      withState(FakeState.new{ targetType = "Undead" })
      local mark = ns.captureMark(pack)
      assert.is_true(mark.target.exists)
      assert.equal("Undead", mark.target.type)
      assert.equal(100, mark.target.hpPct)
    end)
  end)

  describe("rounding", function()
    -- Exact figures from the contract: a raw client value like 2.6900000000023 must be stored as
    -- 2.69, and 22.33333 as 22.33.
    it("rounds 2.6900000000023 to 2.69", function()
      local pack = testPack()
      withState(FakeState.new{ gcd = 2.6900000000023 })
      assert.equal(2.69, ns.captureMark(pack).gcd)
    end)

    it("rounds 22.33333 to 22.33", function()
      local pack = testPack()
      withState(FakeState.new{ power = { MANA = { 22.33333, 100 } } })
      assert.equal(22.33, ns.captureMark(pack).mana)
    end)
  end)
end)
