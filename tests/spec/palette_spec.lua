local helper = require("tests.helper")

-- Elmira/Core/Palette.lua — what the Builder offers you (F30, ADR-0015 §2). Pure: the client-shaped
-- parts (`label`, `known`, `filled`) arrive through opts, so the whole thing runs headlessly.
--
-- The two failures pinned hardest here were both learned by Options.lua's "Test with" dropdown in a
-- live client: passive rune records are not castable and must never be offered, and two records can
-- resolve to ONE spell name, which reads as a duplicate however different the keys are. In this
-- pack they are the same defect — RUNE_DIVINE_STORM and DIVINE_STORM carry the same spell id.
describe("Core/Palette", function()
  local Palette

  -- Shaped like Classes/Paladin.lua: rune records carry `rune`, and the ability a rune teaches
  -- shares its id (both 407778 there, which is what makes the "engrave X" link derivable at all).
  local PACK = {
    class = "PALADIN",
    spells = {
      EXORCISM          = { id = 415073, cooldown = 15 },
      DIVINE_STORM      = { id = 407778, cooldown = 10 },
      CRUSADER_STRIKE   = { id = 407676, cooldown = 6 },
      RUNE_DIVINE_STORM = { id = 407778, rune = "chest" },
      RUNE_ART_OF_WAR   = { id = 426157, rune = "feet" },
    },
  }

  local NAMES = {
    EXORCISM = "Exorcism", DIVINE_STORM = "Divine Storm", CRUSADER_STRIKE = "Crusader Strike",
    RUNE_DIVINE_STORM = "Divine Storm", RUNE_ART_OF_WAR = "The Art of War",
  }
  local function label(key) return NAMES[key] or key end

  local function keysOf(rows)
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r.key end
    return out
  end

  local function rowFor(rows, key)
    for _, r in ipairs(rows) do if r.key == key then return r end end
    return nil
  end

  before_each(function()
    helper.reset()
    Palette = helper.load("Elmira/Core/Palette.lua")
  end)

  describe("spells()", function()
    it("is empty, not an error, without a pack", function()
      assert.same({}, Palette.spells(nil, { label = label }))
      assert.same({}, Palette.spells({}, { label = label }))
    end)

    -- Public, so it is called with whatever a caller has. A nil or a string must answer "no",
    -- not error: it is the guard every other entry point here leans on.
    it("castable() answers for anything, not just a record", function()
      assert.is_false(Palette.castable(nil))
      assert.is_false(Palette.castable("EXORCISM"))
      assert.is_false(Palette.castable(42))
      assert.is_true(Palette.castable({ id = 1 }))
      assert.is_false(Palette.castable({ id = 1, aura = true }))
      assert.is_false(Palette.castable({ id = 1, passive = true }))
      assert.is_false(Palette.castable({ id = 1, rune = "chest" }))
      assert.is_false(Palette.castable({ id = 1, proc = true }))
      assert.is_false(Palette.castable({ id = 1, triggered = true }))
    end)

    it("skips a record that is not a table at all", function()
      local rows = Palette.spells({ spells = { GOOD = { id = 1 }, JUNK = "oops" } }, {})
      assert.equal(1, #rows)
      assert.equal("GOOD", rows[1].key)
    end)

    it("works when handed no options at all", function()
      local rows = Palette.spells(PACK)
      assert.equal(3, #rows)
      assert.equal("CRUSADER_STRIKE", rows[1].key)
    end)

    -- A rune record is the engraving, not an ability: it can never sit on a bar and never be
    -- pressed. Offering them is what made the "Test with" dropdown list "The Art of War".
    it("never offers a rune record, only the abilities", function()
      local rows = Palette.spells(PACK, { label = label })
      assert.is_nil(rowFor(rows, "RUNE_ART_OF_WAR"))
      assert.is_nil(rowFor(rows, "RUNE_DIVINE_STORM"))
      assert.is_truthy(rowFor(rows, "DIVINE_STORM"))
      assert.equal(3, #rows)
    end)

    it("sorts by the name the reader sees, not by the key", function()
      -- The two orders must DISAGREE, or sorting by key passes this test just as well.
      local pack = { spells = { ZZZ = { id = 1 }, AAA = { id = 2 } } }
      local names = { ZZZ = "Avenging Wrath", AAA = "Zealotry" }
      local rows = Palette.spells(pack, { label = function(k) return names[k] end })
      assert.same({ "ZZZ", "AAA" }, keysOf(rows))
      assert.same({ "Avenging Wrath", "Zealotry" }, { rows[1].label, rows[2].label })
    end)

    -- pairs() has no order, so without an explicit sort the palette reshuffles between opens.
    it("gives the same order every time", function()
      local first = keysOf(Palette.spells(PACK, { label = label }))
      for _ = 1, 5 do
        assert.same(first, keysOf(Palette.spells(PACK, { label = label })))
      end
    end)

    it("de-duplicates on the displayed name, not the key", function()
      local pack = { spells = { A = { id = 1 }, B = { id = 2 } } }
      local rows = Palette.spells(pack, { label = function() return "Judgement" end })
      assert.equal(1, #rows)
    end)

    -- The row the character actually has wins, so the palette never explains how to acquire
    -- something they are already holding.
    it("keeps the known row when two names collide", function()
      local pack = { spells = { A = { id = 1 }, B = { id = 2 } } }
      local rows = Palette.spells(pack, {
        label = function() return "Judgement" end,
        known = function(key) return key == "B" end,
      })
      assert.equal(1, #rows)
      assert.equal("B", rows[1].key)
      assert.is_true(rows[1].known)
    end)

    -- Three records on one name: the known one must win however many unknown ones it meets, which
    -- only works if the swap updates the index it is checked against.
    it("keeps the known row out of three colliding names", function()
      local pack = { spells = { A = { id = 1 }, B = { id = 2 }, C = { id = 3 } } }
      for _, winner in ipairs({ "A", "B", "C" }) do
        local rows = Palette.spells(pack, {
          label = function() return "Judgement" end,
          known = function(key) return key == winner end,
        })
        assert.equal(1, #rows, "collapsed to one row")
        assert.equal(winner, rows[1].key, "the known row should win from position " .. winner)
      end
    end)

    it("keeps the known row whichever order it is met in", function()
      local pack = { spells = { A = { id = 1 }, B = { id = 2 } } }
      local rows = Palette.spells(pack, {
        label = function() return "Judgement" end,
        known = function(key) return key == "A" end,
      })
      assert.equal(1, #rows)
      assert.equal("A", rows[1].key)
    end)

    -- A TOKEN, not a sentence: Core says why, Options says it in words and through AceLocale.
    it("marks what you have not learned", function()
      local rows = Palette.spells(PACK, { label = label, known = function() return false end })
      assert.is_false(rowFor(rows, "EXORCISM").known)
      assert.equal("unlearned", rowFor(rows, "EXORCISM").reason)
      assert.is_nil(rowFor(rows, "EXORCISM").reasonKey)
    end)

    -- The actionable half of the owner's "greyed with a reason" decision. A rune-granted ability is
    -- missing for exactly one reason, and naming the rune is the thing you can act on.
    it("names the rune to engrave for an ability a rune grants", function()
      local rows = Palette.spells(PACK, { label = label, known = function() return false end })
      assert.equal("rune", rowFor(rows, "DIVINE_STORM").reason)
      assert.equal("RUNE_DIVINE_STORM", rowFor(rows, "DIVINE_STORM").reasonKey)
    end)

    it("says only 'unlearned' when no rune grants it", function()
      local rows = Palette.spells(PACK, { label = label, known = function() return false end })
      assert.equal("unlearned", rowFor(rows, "CRUSADER_STRIKE").reason)
      assert.is_nil(rowFor(rows, "CRUSADER_STRIKE").reasonKey)
    end)

    it("gives a known spell no reason to explain away", function()
      local rows = Palette.spells(PACK, { label = label, known = function() return true end })
      assert.is_true(rowFor(rows, "DIVINE_STORM").known)
      assert.is_nil(rowFor(rows, "DIVINE_STORM").reason)
    end)

    -- `known` is tri-state and carries the adapter's meaning exactly: nil is "this client cannot
    -- tell", which must never render as "you do not have it" (Adapters/Interface.lua says so).
    it("leaves a row alone when the client cannot tell", function()
      local rows = Palette.spells(PACK, { label = label, known = function() return nil end })
      assert.is_nil(rowFor(rows, "DIVINE_STORM").known)
      assert.is_nil(rowFor(rows, "DIVINE_STORM").reason)
    end)

    it("works with no known lookup at all", function()
      local rows = Palette.spells(PACK, { label = label })
      assert.is_nil(rowFor(rows, "EXORCISM").known)
    end)

    it("falls back to the key when nothing can name it", function()
      local rows = Palette.spells(PACK, {})
      assert.equal("CRUSADER_STRIKE", rowFor(rows, "CRUSADER_STRIKE").label)
    end)
  end)

  -- The fixture above is convenient by construction, and that is exactly how the first version of
  -- this file passed while the shipped palette listed "Templar Buff (not learned yet)" and
  -- "The Art of War (engrave The Art of War)". These run against the REAL Elmira/Classes/Paladin.lua
  -- through helper.classPack, so a record added there without a classification breaks the suite
  -- rather than the panel.
  describe("against the shipped Paladin pack", function()
    local pack
    before_each(function() pack = helper.classPack("Paladin") end)

    -- `pack.spells` is every spell the class data must NAME: the auras conditions test, the debuffs
    -- Judgement applies, the passives runes grant, and the rune records. Only a fraction are things
    -- a person can press, and only those may be offered.
    local CASTABLE = {
      "AURA_MASTERY", "AVENGERS_SHIELD", "AVENGING_WRATH", "CONSECRATION", "CRUSADER_STRIKE",
      "DIVINE_STORM", "EXORCISM", "HAMMER_OF_THE_RIGHTEOUS", "HAMMER_OF_WRATH", "HOLY_SHIELD",
      "HOLY_SHOCK", "HOLY_WRATH", "HORN_OF_LORDAERON", "JUDGEMENT", "REBUKE", "RIGHTEOUS_FURY",
      "SEAL_OF_COMMAND", "SEAL_OF_MARTYRDOM", "SEAL_OF_RIGHTEOUSNESS", "SHIELD_OF_RIGHTEOUSNESS",
    }

    it("offers exactly the abilities a paladin can press", function()
      local got = keysOf(Palette.spells(pack, {}))
      table.sort(got)
      local want = {}
      for _, k in ipairs(CASTABLE) do want[#want + 1] = k end
      table.sort(want)
      assert.same(want, got)
    end)

    -- Named individually because each was a row the shipped palette actually rendered, and the
    -- count assertion above would go on passing if one were swapped for another.
    it("offers no aura, debuff, passive, proc, triggered record or rune", function()
      local offered = {}
      for _, row in ipairs(Palette.spells(pack, {})) do offered[row.key] = true end
      for _, key in ipairs({ "THE_ART_OF_WAR", "PURIFYING_POWER", "SEAL_OF_MARTYRDOM_HIT",
                             "VENGEANCE_BUFF", "SWIFT_JUDGEMENT_BUFF", "EXCOMMUNICATION_BUFF",
                             "TEMPLAR_BUFF", "HOLY_POWER_BUFF", "AVENGING_WRATH_BUFF",
                             "VINDICATION_DEBUFF", "JUDGEMENT_OF_WISDOM", "JUDGEMENT_OF_LIGHT",
                             "JUDGEMENT_OF_COMMAND", "JUDGEMENT_OF_THE_CRUSADER",
                             "RUNE_ART_OF_WAR", "RUNE_DIVINE_STORM" }) do
        -- Assert it EXISTS as well as that it is not offered. Without the first half, deleting the
        -- record outright satisfies the second and the conditions that name it break instead.
        assert.is_truthy(pack.spells[key], key .. " is gone from the pack; conditions name it")
        assert.is_nil(offered[key], key .. " can never be pressed, so it must not be offered")
      end
    end)

    -- Every record the pack ships must be classified one way or the other. A new spell added
    -- without a marker lands in the palette silently, which is how this defect shipped.
    it("classifies every record the pack ships", function()
      local unclassified = {}
      local castable = {}
      for _, k in ipairs(CASTABLE) do castable[k] = true end
      for key, data in pairs(pack.spells) do
        if Palette.castable(data) and not castable[key] then
          unclassified[#unclassified + 1] = key
        end
      end
      table.sort(unclassified)
      assert.same({}, unclassified,
        "unclassified record(s): mark aura/passive/proc/triggered, or add to CASTABLE")
    end)

    -- Deliberate, not an oversight: a taunt is pressed in answer to what a mob is doing, not in a
    -- priority order, so it does not belong in a rotation (owner, 2026-09-05). It exists only as a
    -- rune record, so the filter already hides it; this pins the decision so it is not "fixed".
    it("does not offer Hand of Reckoning, because a taunt is not rotational", function()
      for _, row in ipairs(Palette.spells(pack, {})) do
        assert.is_nil(row.key:find("RECKONING", 1, true), "a taunt must not be offered")
      end
    end)

    -- The reason a real un-known ability carries, on real data.
    it("tells a paladin which rune grants Divine Storm", function()
      local rows = Palette.spells(pack, { known = function() return false end })
      for _, row in ipairs(rows) do
        if row.key == "DIVINE_STORM" then
          assert.equal("rune", row.reason)
          assert.equal("RUNE_DIVINE_STORM", row.reasonKey)
          return
        end
      end
      error("Divine Storm was not offered at all")
    end)
  end)

  describe("items()", function()
    local function slotsOf(rows)
      local out = {}
      for _, r in ipairs(rows) do out[#out + 1] = r.slot end
      return out
    end

    it("offers the two trinkets by default", function()
      assert.same({ 13, 14 }, slotsOf(Palette.items{}))
      assert.same({ 13, 14 }, slotsOf(Palette.items()))
    end)

    it("offers every on-use-capable slot when asked", function()
      local slots = slotsOf(Palette.items{ allSlots = true })
      assert.is_true(#slots > 2)
      for _, wanted in ipairs({ 1, 10, 13, 14, 15 }) do
        local found = false
        for _, s in ipairs(slots) do if s == wanted then found = true end end
        assert.is_true(found, "slot " .. wanted .. " should be offered")
      end
    end)

    -- Shirt and tabard can never carry an on-use effect, so listing them would be offering
    -- something that can never fire.
    it("never offers the shirt or the tabard", function()
      for _, s in ipairs(slotsOf(Palette.items{ allSlots = true })) do
        assert.is_true(s ~= 4 and s ~= 19, "slot " .. s .. " can never have an on-use effect")
      end
    end)

    -- Named individually: an assertion that only counts slots lets any one of them be dropped.
    it("offers every weapon and armour slot that can carry an on-use effect", function()
      local offered = {}
      for _, row in ipairs(Palette.items{ allSlots = true }) do offered[row.slot] = true end
      for slot = 1, 18 do
        if slot ~= 4 then
          assert.is_true(offered[slot] == true, "slot " .. slot .. " should be offered")
        end
      end
    end)

    it("says which slots have something in them", function()
      local rows = Palette.items{ filled = function(slot) return slot == 13 end }
      assert.is_true(rows[1].filled)
      assert.is_false(rows[2].filled)
    end)

    -- An empty slot is still listed: a rotation may name a slot you have not filled yet, exactly as
    -- it may name a rune you have not engraved, and `item_ready` gates it at runtime either way.
    it("lists an empty slot rather than hiding it", function()
      local rows = Palette.items{ filled = function() return false end }
      assert.equal(2, #rows)
    end)

    it("reports every slot unfilled when nothing can answer", function()
      for _, row in ipairs(Palette.items{}) do assert.is_false(row.filled) end
    end)
  end)
end)
