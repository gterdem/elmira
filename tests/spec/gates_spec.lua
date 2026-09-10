local helper = require("tests.helper")
local FakeState = dofile("tests/fake_state.lua")

-- Elmira/Core/Gates.lua — which rows of a build are live for THIS character (ADR-0015).
--
-- The question the owner asked that produced this file: a template is one static list shipped to
-- everybody, so how does a player know their gear changed what it does? The answer only works if
-- the STATIC gates are told apart from the dynamic ones. A row blocked by a set bonus stays blocked
-- until the player loots a piece; a row blocked by target health unblocks in four seconds. Report
-- the second as "not active for you" and the strip becomes a thing that flickers and lies.
describe("Core.Gates", function()
  local Gates

  local ctx = {
    spells = { DIVINE_STORM = { id = 1 }, EXORCISM = { id = 2 } },
    sets = { PALADIN_T35 = { name = "Inquisition (T3.5, SoD)" } },
    bonuses = { HOLY_POWER_CONSUME = { note = "Divine Storm consumes Holy Power" } },
  }

  local function build(...)
    local entries = {}
    for i, entry in ipairs({ ... }) do
      entry.index = i
      entries[i] = entry
    end
    return { entries = entries }
  end

  before_each(function()
    helper.reset()
    helper.load("Elmira/Core/Schema.lua")
    Gates = helper.load("Elmira/Core/Gates.lua")
  end)

  describe("which gates count as static", function()
    -- Each row is the decision, so each row is asserted rather than counted.
    it("counts gear, runes, enchants, weapons and level", function()
      assert.is_true(Gates.STATIC.set)
      assert.is_true(Gates.STATIC.bonus)
      assert.is_true(Gates.STATIC.enchant)
      assert.is_true(Gates.STATIC.weapon)
      assert.is_true(Gates.STATIC.rune)
      assert.is_true(Gates.STATIC.no_rune)
      assert.is_true(Gates.STATIC.level)
    end)

    -- It looks static -- the trinket is equipped or it is not -- but half of it is a cooldown, so
    -- reporting it would make a row blink in and out every twenty seconds.
    it("does not count item_ready, whose other half is a cooldown", function()
      assert.is_nil(Gates.STATIC.item_ready)
    end)

    -- Read from Schema's own table rather than a list written out here: a condition type added
    -- later would otherwise be classified by omission, and the omission is invisible.
    it("classifies every condition type Schema has, and counts nothing else as static", function()
      local all = helper.ns().__schemaConditions
      assert.is_table(all)
      local dynamic = 0
      for kind in pairs(all) do
        if not Gates.STATIC[kind] then dynamic = dynamic + 1 end
      end
      assert.is_true(dynamic > 10, "Schema's condition table did not load")
      for kind in pairs(Gates.STATIC) do
        assert.is_not_nil(all[kind], kind .. " is called static but Schema has no such condition")
      end
      -- Spot-check the ones whose misclassification would be worst: a row blinking in and out
      -- every few seconds because something momentary was reported as a property of the character.
      for _, kind in ipairs({ "buff", "no_buff", "debuff", "no_debuff", "resource",
                              "cooldown_ready", "cooldown_gt", "target_hp", "target_type",
                              "enemies", "mode", "seal", "no_seal", "seal_linger", "in_combat",
                              "out_of_combat", "ttd", "not_moving", "swing", "custom" }) do
        assert.is_nil(Gates.STATIC[kind], kind .. " must not be static")
      end
    end)
  end)

  describe("verdict", function()
    local function state(t) return FakeState.new(t or {}) end

    it("answers for each static gate on its own", function()
      local s = state{ sets = { PALADIN_T35 = 4 }, runes = { RUNE_PURIFYING_POWER = true },
                       level = 60, bonuses = { HOLY_POWER_CONSUME = true } }
      assert.is_true(Gates.verdict({ "set", "PALADIN_T35", min = 4 }, s))
      assert.is_false(Gates.verdict({ "set", "PALADIN_T35", min = 6 }, s))
      assert.is_true(Gates.verdict({ "bonus", "HOLY_POWER_CONSUME" }, s))
      assert.is_false(Gates.verdict({ "bonus", "NOT_HELD" }, s))
      assert.is_true(Gates.verdict({ "rune", "RUNE_PURIFYING_POWER" }, s))
      assert.is_false(Gates.verdict({ "rune", "RUNE_WRATH" }, s))
      assert.is_true(Gates.verdict({ "no_rune", "RUNE_WRATH" }, s))
      assert.is_true(Gates.verdict({ "level", min = 40 }, s))
      assert.is_false(Gates.verdict({ "level", min = 61 }, s))
    end)

    it("weapon and enchant answer from the character too", function()
      local s = state{ weapon = { [16] = { type = "2H", speed = 3.6 } },
                       enchants = { [3] = "SOUL_OF_THE_EXILE" } }
      assert.is_true(Gates.verdict({ "weapon", "2H" }, s))
      assert.is_false(Gates.verdict({ "weapon", "1H" }, s))
      assert.is_true(Gates.verdict({ "enchant", 3, "SOUL_OF_THE_EXILE" }, s))
      assert.is_false(Gates.verdict({ "enchant", 3, "SOUL_OF_THE_JUSTICAR" }, s))
    end)

    it("refuses to answer for a dynamic gate", function()
      local s = state{}
      assert.is_nil(Gates.verdict({ "buff", "ART_OF_WAR" }, s))
      assert.is_nil(Gates.verdict({ "enemies", min = 3 }, s))
      assert.is_nil(Gates.verdict({ "item_ready", 13 }, s))
      assert.is_nil(Gates.verdict({ "not_a_condition_type" }, s))
      assert.is_nil(Gates.verdict("not even a table", s))
      -- Indexing a number errors where indexing a string quietly answers nil, so this is the shape
      -- that proves the guard rather than coinciding with it.
      assert.is_nil(Gates.verdict(42, s))
    end)

    -- Schema owns what a condition means; a type it cannot build, or one that throws on this
    -- state, must read as "cannot say" rather than take the display down with it.
    it("cannot say when Schema refuses to build or run the test", function()
      local C = helper.ns().__schemaConditions
      C.exploding_gate = { make = function() error("cannot build") end }
      C.throwing_gate = { make = function() return function() error("boom") end end }
      C.not_a_maker = { make = "not a function" }
      C.builds_nothing = { make = function() return nil end }
      for _, kind in ipairs({ "exploding_gate", "throwing_gate", "not_a_maker", "builds_nothing" }) do
        Gates.STATIC[kind] = true
        assert.is_nil(Gates.verdict({ kind }, state{}), kind .. " should be unanswerable")
      end
      -- A type Schema has never heard of at all: the one shape that errors rather than returning.
      Gates.STATIC.ghost_gate = true
      assert.is_nil(Gates.verdict({ "ghost_gate" }, state{}))
    end)

    -- A flavour without engraving answers `false` for every rune (the engine wants a boolean), so
    -- without the capability every rune row would be reported dead for a reason that is not true.
    describe("a client that cannot read runes", function()
      it("cannot say, rather than saying not engraved", function()
        local s = state{ runes = {} }
        assert.is_false(Gates.verdict({ "rune", "RUNE_WRATH" }, s, { runes = true }))
        assert.is_nil(Gates.verdict({ "rune", "RUNE_WRATH" }, s, { runes = false }))
        assert.is_nil(Gates.verdict({ "no_rune", "RUNE_WRATH" }, s, { runes = false }))
      end)

      it("still answers every other gate", function()
        local s = state{ level = 60 }
        assert.is_true(Gates.verdict({ "level", min = 40 }, s, { runes = false }))
      end)

      it("assumes readable when the client has not been asked", function()
        assert.is_false(Gates.verdict({ "rune", "RUNE_WRATH" }, state{ runes = {} }, nil))
      end)

      it("carries the capability down through a composite", function()
        local s = state{ runes = {} }
        assert.is_nil(Gates.verdict(
          { "all", { "rune", "RUNE_WRATH" }, { "level", min = 40 } }, s, { runes = false }))
        assert.is_nil(Gates.verdict({ "not", { "rune", "RUNE_WRATH" } }, s, { runes = false }))
      end)

      it("reaches evaluate through the pack context", function()
        local rows = Gates.evaluate(build({ spell = "X", when = { { "rune", "RUNE_WRATH" } } }),
                                    state{ runes = {} }, { capabilities = { runes = false } })
        assert.is_true(rows[1].active)
        rows = Gates.evaluate(build({ spell = "X", when = { { "rune", "RUNE_WRATH" } } }),
                              state{ runes = {} }, { capabilities = { runes = true } })
        assert.is_false(rows[1].active)
      end)
    end)

    describe("nested", function()
      local s
      before_each(function() s = state{ sets = { PALADIN_T35 = 2 }, level = 60 } end)

      it("fails an `all` on one failing static gate, whatever the dynamic ones do", function()
        assert.is_false(Gates.verdict(
          { "all", { "set", "PALADIN_T35", min = 4 }, { "buff", "ART_OF_WAR" } }, s))
      end)

      it("cannot decide an `all` whose static parts all pass", function()
        assert.is_nil(Gates.verdict(
          { "all", { "set", "PALADIN_T35", min = 2 }, { "buff", "ART_OF_WAR" } }, s))
      end)

      it("passes an `all` that is static all the way down", function()
        assert.is_true(Gates.verdict(
          { "all", { "set", "PALADIN_T35", min = 2 }, { "level", min = 40 } }, s))
      end)

      -- The rule that keeps it honest: one branch that might fire tonight means the row is not
      -- dead, and calling it dead is a claim the player cannot check.
      it("cannot decide an `any` with one undecidable branch", function()
        assert.is_nil(Gates.verdict(
          { "any", { "set", "PALADIN_T35", min = 4 }, { "buff", "ART_OF_WAR" } }, s))
      end)

      it("fails an `any` only when every branch is static and every one fails", function()
        assert.is_false(Gates.verdict(
          { "any", { "set", "PALADIN_T35", min = 4 }, { "level", min = 61 } }, s))
      end)

      it("passes an `any` as soon as one static branch passes", function()
        assert.is_true(Gates.verdict(
          { "any", { "set", "PALADIN_T35", min = 4 }, { "level", min = 40 } }, s))
      end)

      it("inverts a `not` and refuses when its child is undecidable", function()
        assert.is_false(Gates.verdict({ "not", { "level", min = 40 } }, s))
        assert.is_true(Gates.verdict({ "not", { "level", min = 61 } }, s))
        assert.is_nil(Gates.verdict({ "not", { "buff", "ART_OF_WAR" } }, s))
      end)
    end)
  end)

  describe("evaluate", function()
    local function state(t) return FakeState.new(t or {}) end

    it("marks a row live when its static gates are met", function()
      local rows = Gates.evaluate(
        build({ spell = "DIVINE_STORM", when = { { "bonus", "HOLY_POWER_CONSUME" } } }),
        state{ bonuses = { HOLY_POWER_CONSUME = true } }, ctx)
      assert.equal(1, #rows)
      assert.is_true(rows[1].active)
      assert.equal(0, #rows[1].reasons)
      assert.equal("DIVINE_STORM", rows[1].spell)
      assert.equal(1, rows[1].index)
    end)

    it("marks it not live, and says what is missing", function()
      local rows = Gates.evaluate(
        build({ spell = "DIVINE_STORM", when = { { "bonus", "HOLY_POWER_CONSUME" } } }),
        state{}, ctx)
      assert.is_false(rows[1].active)
      assert.same({ "Divine Storm consumes Holy Power" }, rows[1].reasons)
    end)

    it("collects every missing gate, not only the first", function()
      local rows = Gates.evaluate(
        build({ spell = "DIVINE_STORM",
                when = { { "bonus", "HOLY_POWER_CONSUME" }, { "level", min = 60 } } }),
        state{ level = 40 }, ctx)
      assert.equal(2, #rows[1].reasons)
    end)

    -- A dynamic gate is the rotation doing its job. Reporting it would make the Builder's rows
    -- flicker mid-fight and teach that the rotation is unstable.
    it("says nothing about a row held back by a dynamic gate", function()
      local rows = Gates.evaluate(
        build({ spell = "DIVINE_STORM", when = { { "enemies", min = 3 } } }), state{}, ctx)
      assert.is_true(rows[1].active)
    end)

    it("keeps every entry, in priority order", function()
      local rows = Gates.evaluate(
        build({ spell = "EXORCISM" }, { spell = "DIVINE_STORM" }, { item = 13 }), state{}, ctx)
      assert.equal(3, #rows)
      assert.equal("EXORCISM", rows[1].spell)
      assert.equal(13, rows[3].item)
    end)

    -- Core/Engine skips an unlearned ability silently and correctly (ADR-0006 rule 5). That is the
    -- right thing for the rotation and useless for explaining it.
    it("reports a spell the character has not learned", function()
      local rows = Gates.evaluate(build({ spell = "DIVINE_STORM" }),
                                  state{ known = { DIVINE_STORM = false } }, ctx)
      assert.is_false(rows[1].active)
      -- Named as the REQUIREMENT, not as the complaint: the same phrase has to read correctly in
      -- "Divine Storm learned: Divine Storm is now active" as well as in the missing-things list.
      assert.same({ "Divine Storm learned" }, rows[1].reasons)
    end)

    -- "This client will not tell me" is not "you have not learned it", and treating them alike
    -- would dim every row in the build.
    --
    -- PE15: the row stays live AND says so -- `certain` false is how Display/Driver knows this
    -- verdict is a guess, so that it is neither announced nor remembered. Without the flag the
    -- guess is stored as if it were a reading, and the next real answer looks like the character
    -- gained or lost the ability.
    it("says nothing when the client cannot answer whether a spell is known", function()
      local s = state{}
      s.known = function() return nil end
      local row = Gates.evaluate(build({ spell = "DIVINE_STORM" }), s, ctx)[1]
      assert.is_true(row.active)
      assert.is_false(row.certain)
    end)

    -- The ordinary case must stay certain, or nothing is ever announced again.
    it("is certain about every verdict the character actually answered", function()
      local live = Gates.evaluate(
        build({ spell = "DIVINE_STORM", when = { { "bonus", "HOLY_POWER_CONSUME" } } }),
        state{ known = { DIVINE_STORM = true }, bonuses = { HOLY_POWER_CONSUME = true } }, ctx)
      assert.is_true(live[1].certain)
      -- A dynamic gate is undecidable BY DESIGN and is not doubt about the client. Treating the
      -- two alike would mark most of the build uncertain and silence the announcements entirely.
      local dynamic = Gates.evaluate(
        build({ spell = "DIVINE_STORM", when = { { "enemies", min = 3 } } }),
        state{ known = { DIVINE_STORM = true } }, ctx)
      assert.is_true(dynamic[1].certain)
    end)

    -- One gate the client stated plainly settles the row: "this cannot fire, and here is the
    -- requirement" is a fact, whatever went unread beside it.
    it("is certain about a row something definitely blocks, whatever else went unread", function()
      local s = state{ level = 40 }
      s.known = function() return nil end
      local row = Gates.evaluate(
        build({ spell = "DIVINE_STORM", when = { { "level", min = 60 } } }), s, ctx)[1]
      assert.is_false(row.active)
      assert.is_true(row.certain)
    end)

    -- The other reading the client can refuse: a static gate nothing could read. A flavour with no
    -- engraving leaves every rune row live, and that row is a guess for the same reason.
    it("is uncertain about a static gate the client cannot read", function()
      local row = Gates.evaluate(build({ spell = "X", when = { { "rune", "RUNE_WRATH" } } }),
                                 state{ runes = {}, known = { X = true } },
                                 { capabilities = { runes = false } })[1]
      assert.is_true(row.active)
      assert.is_false(row.certain)
    end)

    -- The same unreadable gate one level down, inside a composite. `all` and `any` each have to
    -- carry a child's "nothing could read this" up with the nil verdict; a composite that answers
    -- nil WITHOUT the flag reports the row certain, and PE15's whole suppression rests on the flag.
    -- Authored gates are composites far more often than bare leaves, so this is the ordinary case.
    it("carries an unreadable gate up out of all()", function()
      local row = Gates.evaluate(
        build({ spell = "X", when = { { "all", { "rune", "RUNE_WRATH" }, { "level", min = 1 } } } }),
        state{ runes = {}, level = 60, known = { X = true } },
        { capabilities = { runes = false } })[1]
      assert.is_true(row.active)
      assert.is_false(row.certain)
    end)

    it("carries an unreadable gate up out of any()", function()
      local row = Gates.evaluate(
        build({ spell = "X", when = { { "any", { "rune", "RUNE_WRATH" }, { "level", min = 60 } } } }),
        state{ runes = {}, level = 40, known = { X = true } },
        { capabilities = { runes = false } })[1]
      assert.is_true(row.active)
      assert.is_false(row.certain)
    end)

    -- ...and a composite whose children the client DID answer stays certain, or the two flags
    -- above could be hard-wired to true and every announcement would go silent.
    it("stays certain about a composite the client answered", function()
      local row = Gates.evaluate(
        build({ spell = "X", when = { { "all", { "rune", "RUNE_WRATH" }, { "level", min = 1 } } } }),
        state{ runes = { RUNE_WRATH = true }, level = 60, known = { X = true } }, ctx)[1]
      assert.is_true(row.active)
      assert.is_true(row.certain)
    end)

    it("answers empty rather than erroring with nothing to evaluate", function()
      assert.same({}, Gates.evaluate(nil, state{}, ctx))
      assert.same({}, Gates.evaluate(build({ spell = "X" }), nil, ctx))
    end)

    -- Called before a pack has loaded: there is a build and a character but no set names yet.
    it("evaluates with no pack context at all", function()
      local rows = Gates.evaluate(
        build({ spell = "DIVINE_STORM", when = { { "level", min = 60 } } }), state{ level = 40 })
      assert.is_false(rows[1].active)
      assert.same({ "level 60 or above" }, rows[1].reasons)
    end)
  end)

  describe("describe", function()
    it("uses the pack's own words for a set and a bonus", function()
      assert.equal("Inquisition (T3.5, SoD) (4 pieces)",
                   Gates.describe({ "set", "PALADIN_T35", min = 4 }, ctx))
      assert.equal("Divine Storm consumes Holy Power",
                   Gates.describe({ "bonus", "HOLY_POWER_CONSUME" }, ctx))
    end)

    it("falls back to the key when the pack has no words for it", function()
      assert.equal("Some Set (2 pieces)", Gates.describe({ "set", "SOME_SET", min = 2 }, ctx))
      assert.equal("Mystery Bonus", Gates.describe({ "bonus", "MYSTERY_BONUS" }, ctx))
    end)

    -- The requirement in the voice of it being MET. The negative voice made the activation
    -- sentence say the opposite of what had happened: "Art Of War not engraved: Exorcism is now
    -- active in Exodin."
    it("names a rune the way a player would say it, as the requirement", function()
      assert.equal("Purifying Power engraved",
                   Gates.describe({ "rune", "RUNE_PURIFYING_POWER" }, ctx))
      assert.equal("Purifying Power not engraved",
                   Gates.describe({ "no_rune", "RUNE_PURIFYING_POWER" }, ctx))
    end)

    it("phrases a level bound each way round", function()
      assert.equal("level 40 or above", Gates.describe({ "level", min = 40 }, ctx))
      assert.equal("level 50 or below", Gates.describe({ "level", max = 50 }, ctx))
      assert.equal("level 20 to 40", Gates.describe({ "level", min = 20, max = 40 }, ctx))
    end)

    it("names a weapon and an enchant", function()
      assert.equal("a 2H equipped", Gates.describe({ "weapon", "2H" }, ctx))
      assert.equal("Soul Of The Exile on slot 3",
                   Gates.describe({ "enchant", 3, "SOUL_OF_THE_EXILE" }, ctx))
    end)

    -- Schema's label grammar ("any(rune:RUNE_WRATH,level)") is right for a debug dump and wrong in
    -- a sentence a player reads.
    it("puts a composite into words", function()
      assert.equal("Wrath engraved or level 60 or above",
        Gates.describe({ "any", { "rune", "RUNE_WRATH" }, { "level", min = 60 } }, ctx))
      assert.equal("Wrath engraved and level 60 or above",
        Gates.describe({ "all", { "rune", "RUNE_WRATH" }, { "level", min = 60 } }, ctx))
      assert.equal("Wrath engraved, level 60 or above and a 2H equipped",
        Gates.describe({ "all", { "rune", "RUNE_WRATH" }, { "level", min = 60 },
                         { "weapon", "2H" } }, ctx))
      assert.equal("not Wrath engraved", Gates.describe({ "not", { "rune", "RUNE_WRATH" } }, ctx))
      assert.equal("Wrath engraved", Gates.describe({ "any", { "rune", "RUNE_WRATH" } }, ctx))
      assert.equal("nothing", Gates.describe({ "all" }, ctx))
    end)

    it("says something for a type it has no words for", function()
      assert.equal("mystery_gate", Gates.describe({ "mystery_gate", "X" }, ctx))
    end)

    it("says something for a condition it cannot read at all", function()
      assert.is_string(Gates.describe(nil, ctx))
      assert.is_string(Gates.describe(42, ctx))
    end)

    -- Called before a pack is loaded, or for a build whose pack has no set table.
    it("still phrases a gear gate with no pack tables at all", function()
      assert.equal("Some Set (2 pieces)", Gates.describe({ "set", "SOME_SET", min = 2 }))
      assert.equal("Mystery Bonus", Gates.describe({ "bonus", "MYSTERY_BONUS" }))
    end)

    it("names a key that is not a string without erroring", function()
      assert.equal("13", Gates.describe({ "rune", 13 }, ctx):match("^%S+"))
    end)
  end)

  describe("snapshot and diff", function()
    local function rows(t) return t end

    it("keeps the first verdict when a later entry of the same spell agrees", function()
      local snap = Gates.snapshot(rows{
        { spell = "JUDGEMENT", active = false, reasons = { "first reason" } },
        { spell = "JUDGEMENT", active = false, reasons = { "second reason" } },
      })
      assert.is_false(snap.JUDGEMENT.active)
      assert.equal("first reason", snap.JUDGEMENT.reason)
    end)

    it("collapses two entries of one spell into one verdict", function()
      local snap = Gates.snapshot(rows{
        { spell = "JUDGEMENT", active = false, reasons = { "no set" } },
        { spell = "JUDGEMENT", active = true, reasons = {} },
      })
      -- Live as soon as EITHER entry can fire: that is what the player sees on the strip.
      assert.is_true(snap.JUDGEMENT.active)
    end)

    it("keeps the reason a blocked spell is blocked", function()
      local snap = Gates.snapshot(rows{
        { spell = "DIVINE_STORM", active = false, reasons = { "needs the 4-set" } },
      })
      assert.equal("needs the 4-set", snap.DIVINE_STORM.reason)
    end)

    -- PE15: the flag has to survive the collapse to one verdict per spell, or Display/Driver can
    -- never see it. Between two rows that agree, the reading the client GAVE wins -- a spell whose
    -- second entry is certainly available is certainly available.
    it("carries whether the verdict could be read at all", function()
      local snap = Gates.snapshot(rows{ { spell = "DIVINE_STORM", active = true, certain = false,
                                          reasons = {} } })
      assert.is_false(snap.DIVINE_STORM.certain)
      snap = Gates.snapshot(rows{ { spell = "DIVINE_STORM", active = true, certain = false, reasons = {} },
                                  { spell = "DIVINE_STORM", active = true, certain = true, reasons = {} } })
      assert.is_true(snap.DIVINE_STORM.certain)
    end)

    it("keys an item row by its slot", function()
      local snap = Gates.snapshot(rows{ { item = 13, active = true, reasons = {} } })
      assert.is_true(snap["item:13"].active)
    end)

    it("reports what became live and what stopped being live", function()
      local before = { DIVINE_STORM = { active = false, reason = "needs the 4-set" },
                       EXORCISM = { active = true } }
      local after = { DIVINE_STORM = { active = true },
                      EXORCISM = { active = false, reason = "Art of War not engraved" } }
      local diff = Gates.diff(before, after)
      assert.equal(1, #diff.activated)
      assert.equal("DIVINE_STORM", diff.activated[1].spell)
      -- The reason it USED to be blocked is the news: "you now have the 4-set".
      assert.equal("needs the 4-set", diff.activated[1].reason)
      assert.equal(1, #diff.deactivated)
      assert.equal("EXORCISM", diff.deactivated[1].spell)
      assert.equal("Art of War not engraved", diff.deactivated[1].reason)
    end)

    it("reports nothing when nothing changed", function()
      local same = { DIVINE_STORM = { active = true } }
      local diff = Gates.diff(same, same)
      assert.equal(0, #diff.activated)
      assert.equal(0, #diff.deactivated)
    end)

    it("says nothing about a spell that was not there before", function()
      local diff = Gates.diff({}, { DIVINE_STORM = { active = true } })
      assert.equal(0, #diff.activated)
    end)

    -- PE15. "I could not tell" is not a state the character was ever in, so a change into or out
    -- of it is not a change. Both directions, because suppressing only one of them still announces
    -- half of every wobble -- and a snapshot with no flag at all (an older or hand-built one) is
    -- treated as certain, since a diff that quietly says nothing is the worse failure.
    it("says nothing when either side of the change is a reading the client could not give", function()
      local guess = Gates.diff({ DIVINE_STORM = { active = false, certain = true } },
                               { DIVINE_STORM = { active = true, certain = false } })
      assert.equal(0, #guess.activated)
      local recovered = Gates.diff({ DIVINE_STORM = { active = true, certain = false } },
                                   { DIVINE_STORM = { active = false, certain = true } })
      assert.equal(0, #recovered.deactivated)
      local plain = Gates.diff({ DIVINE_STORM = { active = false, certain = true } },
                               { DIVINE_STORM = { active = true, certain = true } })
      assert.equal(1, #plain.activated)
    end)

    -- An unordered list names the same two spells in a different order every time and reads like
    -- two different messages.
    it("sorts, so the same change reads the same way twice", function()
      local before, after = {}, {}
      for _, key in ipairs({ "ZEAL", "AVENGER", "MARTYR", "BLESSING", "CRUSADE" }) do
        before[key] = { active = false }
        after[key] = { active = true }
      end
      local diff = Gates.diff(before, after)
      assert.equal(5, #diff.activated)
      for i = 2, #diff.activated do
        assert.is_true(diff.activated[i - 1].spell < diff.activated[i].spell,
                       "activated is not in a stable order")
      end
    end)

    it("sorts what dropped out too", function()
      local before, after = {}, {}
      for _, key in ipairs({ "ZEAL", "AVENGER", "MARTYR", "BLESSING", "CRUSADE" }) do
        before[key] = { active = true }
        after[key] = { active = false }
      end
      local diff = Gates.diff(before, after)
      assert.equal(5, #diff.deactivated)
      for i = 2, #diff.deactivated do
        assert.is_true(diff.deactivated[i - 1].spell < diff.deactivated[i].spell,
                       "deactivated is not in a stable order")
      end
    end)
  end)

  describe("announcement", function()
    it("says what changed, which spell and which rotation", function()
      local diff = { activated = { { spell = "DIVINE_STORM", reason = "Inquisition (T3.5, SoD) (4 pieces)" } },
                     deactivated = {} }
      assert.equal("Inquisition (T3.5, SoD) (4 pieces): Divine Storm is now active in Exodin.",
                   Gates.announcement(diff, "Exodin"))
    end)

    it("says the reverse when something drops out", function()
      local diff = { activated = {},
                     deactivated = { { spell = "DIVINE_STORM", reason = "the 4-set" } } }
      assert.equal("Divine Storm is no longer active in Exodin — needs the 4-set.",
                   Gates.announcement(diff, "Exodin"))
    end)

    it("says both in one sentence when both happened", function()
      local diff = { activated = { { spell = "A", reason = "r1" } },
                     deactivated = { { spell = "B", reason = "r2" } } }
      local text = Gates.announcement(diff, "Exodin")
      assert.is_truthy(text:find("A is now active"))
      assert.is_truthy(text:find("B is no longer active"))
    end)

    it("says nothing at all when nothing changed", function()
      assert.is_nil(Gates.announcement({ activated = {}, deactivated = {} }, "Exodin"))
      assert.is_nil(Gates.announcement(nil, "Exodin"))
    end)

    it("still reads without a build name or a reason", function()
      local text = Gates.announcement({ activated = { { spell = "DIVINE_STORM" } }, deactivated = {} })
      assert.is_truthy(text:find("Divine Storm is now active."))
    end)
  end)
end)
