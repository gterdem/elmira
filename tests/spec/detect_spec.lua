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

    -- ADR-0013 §2: a build is written for its runes, so a missing rune is a purchase, not a mismatch.
    describe("requires.runes as a shopping list", function()
      local REQ = { runes = { "RUNE_ART_OF_WAR" } }

      it("phrases a missing rune as something to engrave, naming the slot", function()
        local checks = Detect.check({ runes = { RUNE_ART_OF_WAR = false } }, REQ, PACK)
        assert.equal("Engrave Art of War (feet)", checks[1].text)
        assert.equal("rune", checks[1].kind)
        assert.equal("feet", checks[1].slot)
        assert.equal("Art of War (feet)", checks[1].engrave)
        assert.is_false(checks[1].ok)
      end)

      it("carries no `engrave` item when the rune is present or unreadable", function()
        assert.is_nil(Detect.check({ runes = { RUNE_ART_OF_WAR = true } }, REQ, PACK)[1].engrave)
        assert.is_nil(Detect.check({ runes = {} }, REQ, PACK)[1].engrave)
      end)

      it("reads 'engraved' when it is", function()
        local checks = Detect.check({ runes = { RUNE_ART_OF_WAR = true } }, REQ, PACK)
        assert.equal("Art of War engraved", checks[1].text)
        assert.is_true(checks[1].ok)
      end)

      -- The old wording rendered nil as "not engraved" -- the spellbook defect in a second place.
      it("says the runes could not be read rather than calling one not engraved", function()
        local checks = Detect.check({ runes = {} }, REQ, PACK)
        assert.is_nil(checks[1].ok)
        assert.truthy(checks[1].text:find("could not read", 1, true))
        assert.is_nil(checks[1].text:find("Engrave", 1, true))
      end)

      it("derives a readable name from the key when the pack record has none", function()
        local pack = { spells = { RUNE_HAND_OF_RECKONING = { id = 9, rune = "hands" } } }
        local checks = Detect.check({ runes = { RUNE_HAND_OF_RECKONING = false } },
          { runes = { "RUNE_HAND_OF_RECKONING" } }, pack)
        assert.equal("Engrave Hand Of Reckoning (hands)", checks[1].text)
        assert.equal("Art of War", Detect.readableName("RUNE_ART_OF_WAR", { name = "Art of War" }))
        assert.equal("Hand Of Reckoning", Detect.readableName("RUNE_HAND_OF_RECKONING", nil))
      end)

      it("leaves the slot off when the pack does not know it", function()
        local checks = Detect.check({ runes = { RUNE_MYSTERY = false } },
          { runes = { "RUNE_MYSTERY" } }, { spells = {} })
        assert.equal("Engrave Mystery", checks[1].text)
        assert.is_nil(checks[1].slot)
      end)
    end)

    -- PE1-D6: `readableName` asks the CLIENT first, through the adapter -- our prettifier cannot
    -- know "and" is a minor word, so it can only ever produce "Shock And Awe" where the spellbook
    -- says "Shock and Awe". Reached through `ns.Adapter`, never a WoW global (hard rule 3 forbids
    -- the direct call, not the adapter read), and gated on the same `spellNameLookup` capability
    -- the Abilities page's own id lookup uses.
    describe("readableName and the client's own spell names (PE1-D6)", function()
      local function installAdapter(caps, byID)
        helper.ns().Adapter = { capabilities = function() return caps end,
                                spellNameByID = byID }
      end

      it("prefers the client's name over both the record's own name and the prettifier", function()
        installAdapter({ spellNameLookup = true },
          function(id) return id == 7 and "Shock and Awe" or nil end)
        assert.equal("Shock and Awe",
          Detect.readableName("RUNE_SHOCK_AND_AWE", { id = 7, name = "Shock And Awe (data)" }))
      end)

      it("falls back to the record's name when the client has never seen the id", function()
        installAdapter({ spellNameLookup = true }, function() return nil end)
        assert.equal("Art of War", Detect.readableName("RUNE_ART_OF_WAR", { id = 7, name = "Art of War" }))
      end)

      it("does not ask the adapter at all on a client that cannot look a name up", function()
        local asked = false
        installAdapter({ spellNameLookup = false },
          function() asked = true; return "Shock and Awe" end)
        assert.equal("Shock And Awe", Detect.readableName("RUNE_SHOCK_AND_AWE", { id = 7 }))
        assert.is_false(asked, "the spellNameLookup capability is what guards this call")
      end)

      it("ignores an adapter that offers no name lookup at all", function()
        helper.ns().Adapter = { capabilities = function() return { spellNameLookup = true } end }
        assert.equal("Shock And Awe", Detect.readableName("RUNE_SHOCK_AND_AWE", { id = 7 }))
      end)

      -- A `sets` record carries a `name` and no `id`, so the client branch must never fire for one.
      it("skips the client lookup for a record with no id, such as a set", function()
        installAdapter({ spellNameLookup = true }, function() return "Wrong Name" end)
        assert.equal("Radiant Judgement",
          Detect.readableName("PALADIN_T2_JUDGEMENT", { name = "Radiant Judgement" }))
      end)

      -- The existing specs call this with no adapter loaded at all; that path must stay exactly as
      -- deterministic as it was.
      it("returns the prettified key with no adapter present", function()
        assert.is_nil(helper.ns().Adapter)
        assert.equal("Hand Of Reckoning", Detect.readableName("RUNE_HAND_OF_RECKONING", nil))
      end)
    end)

    it("counts set pieces against the threshold", function()
      local checks = Detect.check({ sets = { PALADIN_T2_JUDGEMENT = 2 } },
        { sets = { PALADIN_T2_JUDGEMENT = 4 } }, PACK)
      assert.is_false(checks[1].ok)
      assert.truthy(checks[1].text:find("2/4", 1, true))
    end)

    -- PE1-D6: the set row used to leak its raw key -- "T3_5_HOLY: 2/4 pieces".
    it("names the set readably rather than leaking its catalog key", function()
      local pack = { sets = { PALADIN_T2_JUDGEMENT = { name = "Radiant Judgement" } } }
      local checks = Detect.check({ sets = { PALADIN_T2_JUDGEMENT = 2 } },
        { sets = { PALADIN_T2_JUDGEMENT = 4 } }, pack)
      assert.equal("Radiant Judgement: 2/4 pieces", checks[1].text)
      assert.is_nil(checks[1].text:find("PALADIN_T2_JUDGEMENT", 1, true))
    end)

    it("prettifies a set key when the pack ships no name for it", function()
      local checks = Detect.check({ sets = { T3_5_HOLY = 2 } },
        { sets = { T3_5_HOLY = 4 } }, { sets = { T3_5_HOLY = {} } })
      assert.equal("T3 5 Holy: 2/4 pieces", checks[1].text)
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

      -- PE1-D6, the actual in-game defect: a SHIPPED spell record has no `name` field at all (the
      -- client owns names), so `pack.spells[key].name or key` fell through to the raw key and the
      -- panel read "HOLY_SHOCK known". All three states, because the bug was in all three.
      it("reads a shipped spell that carries no name readably, never as its raw key", function()
        local pack = { spells = { HOLY_SHOCK = { id = 20473 } } }
        local req = { spells = { "HOLY_SHOCK" } }
        assert.equal("Holy Shock known",
          Detect.check({ spells = { HOLY_SHOCK = true } }, req, pack)[1].text)
        assert.equal("Holy Shock NOT known",
          Detect.check({ spells = { HOLY_SHOCK = false } }, req, pack)[1].text)
        assert.equal("Holy Shock: could not read your spellbook",
          Detect.check({}, req, pack)[1].text)
      end)

      it("still prefers a name the pack does ship", function()
        local c = Detect.check({ spells = { EXORCISM = true } }, { spells = { "EXORCISM" } },
          { spells = { EXORCISM = { id = 3, name = "Exorcism" } } })[1]
        assert.equal("Exorcism known", c.text)
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
