local helper = require("tests.helper")
local FakeState = dofile("tests/fake_state.lua")

-- Elmira/Setup/Detect.lua — the Detection record and requirement checks (docs/01 §5b, PRD F12/F14).
--
-- The property this file exists to protect: UNKNOWN IS NOT FALSE. Soul detection is a tooltip scan,
-- base weapon speed is a tooltip scan, talents are a heuristic, runes need the engraving API — every
-- one of them can legitimately come back empty on a working install. A wizard that renders "could
-- not read your shoulders" as "your soul is wrong" tells the user to fix something that is fine, and
-- a requirement check that BLOCKS on it would refuse a build the character can play.
--
-- Requirement checks warn and never gate: `requires` is advisory (hard rule 8, ADR-0006).
describe("Setup.Detect", function()
  local Detect

  local PACK = {
    spells = {
      RUNE_ART_OF_WAR = { id = 1, rune = "feet", name = "Art of War" },
      RUNE_DIVINE_STORM = { id = 2, rune = "hands", name = "Divine Storm" },
      EXORCISM = { id = 3 },
    },
    sets = { PALADIN_T2_JUDGEMENT = {}, PALADIN_T35_INQUISITION = {} },
  }

  before_each(function()
    helper.reset()
    helper.load("Elmira/Adapters/Interface.lua")
    Detect = helper.load("Elmira/Setup/Detect.lua")
  end)

  describe("gather()", function()
    local function adapter(talents)
      return { playerClass = function() return "PALADIN" end,
               talents = function() return talents end }
    end

    it("records class, level, weapon, soul, runes and set counts", function()
      local state = FakeState.new{
        level = 60,
        weapon = { [16] = { type = "2H", speed = 2.6 } },
        enchants = { [3] = "SOUL_OF_THE_EXILE" },
        runes = { RUNE_ART_OF_WAR = true },
        sets = { PALADIN_T2_JUDGEMENT = 4 },
      }
      local d = Detect.gather(state, adapter{ tabs = {}, total = 51, top = 1 }, PACK)
      assert.equal("PALADIN", d.class)
      assert.equal(60, d.level)
      assert.equal("2H", d.weapon.type)
      assert.equal("SOUL_OF_THE_EXILE", d.soul)
      assert.is_true(d.runes.RUNE_ART_OF_WAR)
      assert.is_false(d.runes.RUNE_DIVINE_STORM)
      assert.equal(4, d.sets.PALADIN_T2_JUDGEMENT)
    end)

    it("asks about runes the PACK knows, and only those", function()
      -- state:rune() answers per key and there is no enumerate-all, so a rune the pack has never
      -- heard of is invisible here — the limit that made docs/07 §9.5's three observed runes have
      -- to be added to Spells.lua before they could ever be reported.
      local d = Detect.gather(FakeState.new{}, adapter(nil), PACK)
      assert.is_not_nil(d.runes.RUNE_ART_OF_WAR)
      assert.is_nil(d.runes.EXORCISM)          -- not a rune
      assert.is_nil(d.runes.RUNE_OF_SOMETHING) -- not in the pack
    end)

    it("carries the spec heuristic from the adapter, and survives its absence", function()
      local d = Detect.gather(FakeState.new{}, adapter{ tabs = {}, total = 51, top = 2 }, PACK)
      assert.equal(2, d.specIndex)
      assert.equal(51, d.talentPoints)
      local none = Detect.gather(FakeState.new{}, adapter(nil), PACK)
      assert.is_nil(none.specIndex)
    end)

    -- The wizard shipped telling a level-60 paladin "SEAL_OF_MARTYRDOM not known" for an ability it
    -- has had since level 10, because `Detect.check` read `detection.spells` and `gather` never
    -- wrote it. A lookup against a table nobody populates: the same shape as the hover tooltip's
    -- `slot.index`, in the same milestone. This is the spec that would have caught it.
    it("populates the known-spell set that check() reads", function()
      local state = FakeState.new{}
      local known = { EXORCISM = true, SEAL_OF_MARTYRDOM = false }
      local a = { playerClass = function() return "PALADIN" end,
                  talents = function() return nil end,
                  knownSpells = function() return known end }
      local d = Detect.gather(state, a, PACK)
      assert.is_true(d.spells.EXORCISM)
      assert.is_false(d.spells.SEAL_OF_MARTYRDOM)
    end)

    it("leaves it nil when the adapter cannot answer, rather than an empty set", function()
      -- An empty set would read as "you know nothing", which is a claim; nil is the absence of one.
      local d = Detect.gather(FakeState.new{},
        { playerClass = function() return "PALADIN" end, talents = function() return nil end }, PACK)
      assert.is_nil(d.spells)
    end)

    it("returns a usable record with no state at all rather than erroring", function()
      local d = Detect.gather(nil, nil, nil)
      assert.same({}, d.runes)
      assert.same({}, d.sets)
    end)
  end)

  describe("check()", function()
    it("passes a matching weapon and fails a mismatched one", function()
      local ok = Detect.check({ weapon = { type = "2H", speed = 2.6 } }, { weapon = "2H" }, PACK)
      assert.is_true(ok[1].ok)
      local bad = Detect.check({ weapon = { type = "1H", speed = 2.6 } }, { weapon = "2H" }, PACK)
      assert.is_false(bad[1].ok)
    end)

    it("reports nil — not false — when the weapon could not be read", function()
      local checks = Detect.check({}, { weapon = "2H" }, PACK)
      assert.is_nil(checks[1].ok)
      assert.truthy(checks[1].text:find("could not read", 1, true))
    end)

    it("checks speed bounds, and treats an unreadable speed as unknown", function()
      assert.is_true(Detect.check({ weapon = { type = "2H", speed = 2.6 } },
        { maxSpeed = 3.0 }, PACK)[1].ok)
      assert.is_false(Detect.check({ weapon = { type = "2H", speed = 3.4 } },
        { maxSpeed = 3.0 }, PACK)[1].ok)
      assert.is_nil(Detect.check({ weapon = { type = "2H" } }, { maxSpeed = 3.0 }, PACK)[1].ok)
    end)

    it("names a rune by its readable name when the pack has one", function()
      local checks = Detect.check({ runes = { RUNE_ART_OF_WAR = false } },
        { runes = { "RUNE_ART_OF_WAR" } }, PACK)
      assert.is_false(checks[1].ok)
      assert.truthy(checks[1].text:find("Art of War", 1, true))
    end)

    it("counts set pieces against the threshold", function()
      local checks = Detect.check({ sets = { PALADIN_T2_JUDGEMENT = 2 } },
        { sets = { PALADIN_T2_JUDGEMENT = 4 } }, PACK)
      assert.is_false(checks[1].ok)
      assert.truthy(checks[1].text:find("2/4", 1, true))
    end)

    describe("requires.spells", function()
      local REQ = { spells = { "SEAL_OF_MARTYRDOM" } }

      it("passes a spell the character knows", function()
        local c = Detect.check({ spells = { SEAL_OF_MARTYRDOM = true } }, REQ, PACK)[1]
        assert.is_true(c.ok)
        assert.truthy(c.text:find("known", 1, true))
      end)

      it("fails one it genuinely does not know", function()
        local c = Detect.check({ spells = { SEAL_OF_MARTYRDOM = false } }, REQ, PACK)[1]
        assert.is_false(c.ok)
        assert.truthy(c.text:find("NOT known", 1, true))
      end)

      it("says it could not READ the spellbook rather than claiming the spell is missing", function()
        -- The marker and the text must agree. `?` next to "not known" tells the user a fact we do
        -- not have, and that is exactly what shipped.
        local c = Detect.check({}, REQ, PACK)[1]
        assert.is_nil(c.ok)
        assert.truthy(c.text:find("could not read", 1, true))
        assert.is_nil(c.text:find("NOT known", 1, true))
      end)
    end)

    it("returns nothing at all for a build with no requires", function()
      assert.same({}, Detect.check({}, nil, PACK))
    end)

    it("hasFailures ignores unknowns — it asks 'is there something to FIX'", function()
      assert.is_false(Detect.hasFailures({ { ok = nil }, { ok = true } }))
      assert.is_true(Detect.hasFailures({ { ok = nil }, { ok = false } }))
      assert.is_false(Detect.hasFailures(nil))
    end)
  end)
end)
