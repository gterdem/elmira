local helper = require("tests.helper")
local FakeState = dofile("tests/fake_state.lua")

-- Elmira/Core/Advisor.lua — soul / rune / weapon recommendations (PRD F21, docs/01 §5a).
--
-- Two properties matter more than any individual recommendation.
--
-- First, ADVICE IS NOT A GATE. `requires` is advisory and never changes evaluation (hard rule 8);
-- so is this. Nothing here may make the rotation behave differently, and a character who ignores
-- every word must still get a correct queue.
--
-- Second, THREE STATES, NOT TWO. "your soul is wrong" and "I could not read your shoulders" must
-- not render the same. Soul detection is a tooltip scan that can legitimately come back empty
-- (docs/07 §9.11), and base weapon speed likewise — so `ok` is true, false, or nil, and nil never
-- produces a complaint.
describe("Core.Advisor", function()
  local Advisor

  local CTX = { sets = { PALADIN_T25_AVENGERS = {} }, souls = {}, spells = {}, bonuses = {} }

  before_each(function()
    helper.reset()
    helper.load("Elmira/Adapters/Interface.lua")
    helper.load("Elmira/Core/Schema.lua")
    Advisor = helper.load("Elmira/Core/Advisor.lua")
  end)

  describe("soul", function()
    local RULES = {
      soul = {
        { when = { { "set", "PALADIN_T25_AVENGERS", min = 2 } }, pick = "SOUL_OF_THE_EXILE",
          reason = "Exile with Avenger's 2-set" },
        { pick = "SOUL_OF_THE_RETRIBUTOR", reason = "Retributor otherwise" },
      },
    }

    it("takes the first rule whose condition passes", function()
      local state = FakeState.new{ sets = { PALADIN_T25_AVENGERS = 2 } }
      local rec = Advisor.recommend(RULES, state, CTX, {})
      assert.equal("SOUL_OF_THE_EXILE", rec.soul.pick)
      assert.equal("Exile with Avenger's 2-set", rec.soul.reason)
    end)

    it("falls through to the unconditional rule when it does not", function()
      local state = FakeState.new{ sets = {} }
      local rec = Advisor.recommend(RULES, state, CTX, {})
      assert.equal("SOUL_OF_THE_RETRIBUTOR", rec.soul.pick)
    end)

    -- The stand-in this replaces (gear_matrix_spec) could not evaluate `when` at all and said so in
    -- its own comment, so a gear-conditional soul rule was never actually exercised anywhere.
    it("evaluates `when` through the SAME compiler builds use, not a second one", function()
      local state = FakeState.new{ sets = { PALADIN_T25_AVENGERS = 1 } }   -- one piece, needs two
      assert.equal("SOUL_OF_THE_RETRIBUTOR", Advisor.recommend(RULES, state, CTX, {}).soul.pick)
      state = FakeState.new{ sets = { PALADIN_T25_AVENGERS = 2 } }
      assert.equal("SOUL_OF_THE_EXILE", Advisor.recommend(RULES, state, CTX, {}).soul.pick)
    end)

    it("says ok=true when it is already worn, false when it is not", function()
      local state = FakeState.new{ sets = {} }
      assert.is_true(Advisor.recommend(RULES, state, CTX,
        { soul = "SOUL_OF_THE_RETRIBUTOR" }).soul.ok)
      local wrong = Advisor.recommend(RULES, state, CTX, { soul = "SOUL_OF_THE_SEALBEARER" })
      assert.is_false(wrong.soul.ok)
      assert.equal("SOUL_OF_THE_SEALBEARER", wrong.soul.have)
    end)

    it("says nil — never false — when the soul could not be read at all", function()
      local rec = Advisor.recommend(RULES, FakeState.new{}, CTX, {})
      assert.is_nil(rec.soul.ok)
      assert.is_nil(rec.soul.have)
    end)
  end)

  describe("weapon", function()
    local RULES = { weapon = { type = "2H", maxSpeed = 3.0, reason = "Fast 2H" } }

    it("passes a matching weapon", function()
      local rec = Advisor.recommend(RULES, FakeState.new{}, CTX, { weapon = { type = "2H", speed = 2.6 } })
      assert.is_true(rec.weapon.ok)
    end)

    it("fails the wrong type", function()
      local rec = Advisor.recommend(RULES, FakeState.new{}, CTX, { weapon = { type = "1H", speed = 2.6 } })
      assert.is_false(rec.weapon.ok)
    end)

    it("fails a weapon outside the speed bound", function()
      local rec = Advisor.recommend(RULES, FakeState.new{}, CTX, { weapon = { type = "2H", speed = 3.4 } })
      assert.is_false(rec.weapon.ok)
    end)

    it("does not fail a weapon whose speed could not be read — unknown is not wrong", function()
      -- Base speed comes from a tooltip scan that can come back empty. Treating that as a violation
      -- would tell someone to replace a weapon that is fine.
      local rec = Advisor.recommend(RULES, FakeState.new{}, CTX, { weapon = { type = "2H" } })
      assert.is_true(rec.weapon.ok)
    end)

    it("is nil when no weapon was detected at all", function()
      local rec = Advisor.recommend(RULES, FakeState.new{}, CTX, {})
      assert.is_nil(rec.weapon.ok)
    end)
  end)

  describe("runes", function()
    local RULES = { runes = { "RUNE_ART_OF_WAR", "RUNE_DIVINE_STORM" },
                    ringRunes = { human = { "HOLY_SPECIALIZATION" }, default = { "WEAPON_SPEC" } } }

    it("reports each rune as engraved or not", function()
      local state = FakeState.new{ runes = { RUNE_ART_OF_WAR = true } }
      local rec = Advisor.recommend(RULES, state, CTX, {})
      assert.is_true(rec.runes[1].have)
      assert.is_false(rec.runes[2].have)
    end)

    it("picks ring runes by race, defaulting when the race is unknown", function()
      local rec = Advisor.recommend(RULES, FakeState.new{}, CTX, {})
      assert.equal("WEAPON_SPEC", rec.runes[#rec.runes].key)
      rec = Advisor.recommend(RULES, FakeState.new{}, CTX, { race = "human" })
      assert.equal("HOLY_SPECIALIZATION", rec.runes[#rec.runes].key)
    end)
  end)

  describe("output", function()
    it("lists only the runes you are MISSING, not a wall of green", function()
      local state = FakeState.new{ runes = { RUNE_ART_OF_WAR = true } }
      local rec = Advisor.recommend({ runes = { "RUNE_ART_OF_WAR", "RUNE_DIVINE_STORM" } }, state, CTX, {})
      local text = table.concat(Advisor.lines(rec), "\n")
      assert.truthy(text:find("RUNE_DIVINE_STORM", 1, true))
      assert.is_nil(text:find("RUNE_ART_OF_WAR", 1, true))
    end)

    it("returns an empty recommendation for a build with no advice, and never errors", function()
      assert.same({ soul = nil, runes = {}, weapon = nil, notes = {} },
        Advisor.recommend(nil, FakeState.new{}, CTX, {}))
      assert.same({}, Advisor.lines(nil))
    end)
  end)
end)
