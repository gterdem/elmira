local helper = require("tests.helper")

-- Elmira/Core/Diagnostics.lua — "what did my edit do?" (F36, F35).
--
-- The property every test here is really defending is SOUNDNESS. A diagnostic that says "this line
-- can never fire" is telling someone to delete working code, so it must be right every time; a
-- diagnostic that stays quiet about a line that is in fact dead has cost nothing. So the sweeps
-- below check both directions, and the shipped builds are used as the negative case: not one of the
-- four playstyles may be reported as carrying an unreachable line.
describe("Core.Diagnostics", function()
  local Diagnostics, pack

  local function ctxOf()
    return { spells = pack.spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses }
  end

  before_each(function()
    helper.reset()
    helper.load("Elmira/Core/Schema.lua")
    Diagnostics = helper.load("Elmira/Core/Diagnostics.lua")
    pack = helper.classPack("Paladin")
  end)

  local function build(entries)
    return { schema = 1, key = "K", name = "K", class = "PALADIN", entries = entries }
  end

  describe("shadowed()", function()
    -- The commonest editing mistake there is: add an unconditional line, then add a conditional one
    -- for the same spell below it and wonder why the condition never does anything.
    it("flags a line an earlier unconditional line for the same spell kills", function()
      local found = Diagnostics.shadowed(build{
        { spell = "EXORCISM" },
        { spell = "CRUSADER_STRIKE" },
        { spell = "EXORCISM", when = { { "target_hp", maxPct = 20 } } },
      })
      assert.equal(1, #found)
      assert.equal(3, found[1].index)
      assert.equal(1, found[1].by)
      assert.equal("spell:EXORCISM", found[1].action)
      assert.is_true(found[1].alwaysOn, "nothing gates the line that kills it")
    end)

    -- Soundness, the subset rule: A passes whenever B does, so B is unreachable.
    it("flags a line whose gates are a superset of an earlier line's", function()
      local found = Diagnostics.shadowed(build{
        { spell = "EXORCISM", when = { { "in_combat" } } },
        { spell = "EXORCISM", when = { { "in_combat" }, { "not_moving" } } },
      })
      assert.equal(1, #found)
      assert.equal(2, found[1].index)
      assert.is_false(found[1].alwaysOn, "the killer has a gate of its own")
    end)

    -- An item line binds to a SLOT and shadows exactly as a spell line does; without the item arm
    -- of the action test, two identical trinket lines would both read as "no action" and neither
    -- would ever be checked.
    it("flags a duplicated item line", function()
      local found = Diagnostics.shadowed(build{
        { item = 13 },
        { item = 13, when = { { "item_ready", 13 } } },
      })
      assert.equal(1, #found)
      assert.equal(2, found[1].index)
      assert.equal("item:13", found[1].action)
    end)

    it("flags an exact duplicate", function()
      local when = { { "resource", "MANA", minPct = 40 } }
      local found = Diagnostics.shadowed(build{
        { spell = "CONSECRATION", when = when },
        { spell = "CONSECRATION", when = { { "resource", "MANA", minPct = 40 } } },
      })
      assert.equal(1, #found)
      assert.equal(2, found[1].index)
    end)

    -- Under-reporting is the safe direction. Each of these IS reachable, and a diagnostic that
    -- named it would be telling someone to delete a line that works.
    it("stays quiet when the later line can still win", function()
      local cases = {
        { "a different spell entirely",
          { { spell = "EXORCISM" }, { spell = "CRUSADER_STRIKE" } } },
        { "a spell against an item slot",
          { { spell = "EXORCISM" }, { item = 13 } } },
        { "two different item slots",
          { { item = 13 }, { item = 14 } } },
        { "the later line is the LESS gated one",
          { { spell = "EXORCISM", when = { { "in_combat" }, { "not_moving" } } },
            { spell = "EXORCISM", when = { { "in_combat" } } } } },
        { "the gates merely overlap",
          { { spell = "EXORCISM", when = { { "in_combat" } } },
            { spell = "EXORCISM", when = { { "not_moving" } } } } },
        { "the same kind with a different value",
          { { spell = "CONSECRATION", when = { { "resource", "MANA", minPct = 60 } } },
            { spell = "CONSECRATION", when = { { "resource", "MANA", minPct = 40 } } } } },
        { "the same kind with a different key",
          { { spell = "JUDGEMENT", when = { { "seal", "SEAL_OF_MARTYRDOM" } } },
            { spell = "JUDGEMENT", when = { { "seal", "SEAL_OF_COMMAND" } } } } },
        -- The earlier gate has a qualifier the later one does not carry, and vice versa: a
        -- comparison that only walked one of the two tables would call these the same condition.
        -- `buff X` really is implied by `buff X min=2`, so this is a MISSED warning -- and missing
        -- one costs nothing, while inventing one tells someone to delete a line that works.
        { "the earlier gate is a prefix of the later one's qualifiers",
          { { spell = "DIVINE_STORM", when = { { "buff", "HOLY_POWER_BUFF" } } },
            { spell = "DIVINE_STORM", when = { { "buff", "HOLY_POWER_BUFF", min = 2 } } } } },
        { "and the other way round",
          { { spell = "DIVINE_STORM", when = { { "buff", "HOLY_POWER_BUFF", min = 2 } } },
            { spell = "DIVINE_STORM", when = { { "buff", "HOLY_POWER_BUFF" } } } } },
      }
      for _, case in ipairs(cases) do
        assert.same({}, Diagnostics.shadowed(build(case[2])), case[1])
      end
    end)

    -- A `custom` condition is a closure. Two closures doing the same thing are not equal, and
    -- claiming a line is dead because of a function nobody can read is the worst possible version
    -- of this warning.
    it("never reasons about a custom condition it cannot read", function()
      local fn = function() return true end
      assert.same({}, Diagnostics.shadowed(build{
        { spell = "EXORCISM", when = { { "custom", function() return true end } } },
        { spell = "EXORCISM", when = { { "custom", function() return true end } } },
      }), "two different closures are not the same gate")
      -- The SAME closure is the same gate, and then the rule applies as normal.
      assert.equal(1, #Diagnostics.shadowed(build{
        { spell = "EXORCISM", when = { { "custom", fn } } },
        { spell = "EXORCISM", when = { { "custom", fn }, { "in_combat" } } },
      }))
    end)

    -- A switched-off line is not in the rotation at all (Schema.compile skips it), so it can
    -- neither kill a line below it nor be worth reporting itself.
    it("ignores switched-off lines in both directions", function()
      assert.same({}, Diagnostics.shadowed(build{
        { spell = "EXORCISM", disabled = true },
        { spell = "EXORCISM", when = { { "in_combat" } } },
      }), "a disabled line kills nothing")
      assert.same({}, Diagnostics.shadowed(build{
        { spell = "EXORCISM" },
        { spell = "EXORCISM", when = { { "in_combat" } }, disabled = true },
      }), "a disabled line is not worth reporting")
    end)

    it("names the FIRST line that kills it, not every one of them", function()
      local found = Diagnostics.shadowed(build{
        { spell = "EXORCISM" },
        { spell = "EXORCISM" },
        { spell = "EXORCISM" },
      })
      assert.equal(2, #found)
      assert.equal(1, found[1].by)
      assert.equal(1, found[2].by, "line 3 is killed by line 1, which is the news")
    end)

    it("says nothing about an empty or malformed rotation", function()
      assert.same({}, Diagnostics.shadowed(build{}))
      assert.same({}, Diagnostics.shadowed(nil))
      assert.same({}, Diagnostics.shadowed(build{ { spell = "EXORCISM" }, "not an entry" }))
      -- An entry that produces nothing at all cannot shadow and cannot be shadowed.
      assert.same({}, Diagnostics.shadowed(build{ { label = "nothing" }, { label = "nothing" } }))
    end)

    -- The negative case that matters most: none of the four shipped playstyles may be reported.
    -- A false positive here would tell every user that a line of the rotation they installed is
    -- dead, on the very first screen they open.
    it("reports nothing against any shipped build", function()
      local checked = 0
      for key, shipped in pairs(pack.builds) do
        checked = checked + 1
        assert.same({}, Diagnostics.shadowed(shipped), key .. " was reported as having a dead line")
      end
      assert.is_true(checked >= 4, "only " .. checked .. " builds were swept")
    end)
  end)

  describe("unknown()", function()
    it("names the line and the key the class data no longer has", function()
      local found = Diagnostics.unknown(build{
        { spell = "EXORCISM" },
        { spell = "SPELL_THAT_WENT_AWAY" },
      }, ctxOf())
      assert.equal(1, #found)
      assert.equal(2, found[1].index)
      assert.equal("spell", found[1].kind)
      assert.equal("SPELL_THAT_WENT_AWAY", found[1].key)
      assert.equal("spells", found[1].source)
    end)

    it("checks the keys inside conditions, against the table each one belongs to", function()
      local found = Diagnostics.unknown(build{
        { spell = "EXORCISM", when = {
          { "buff", "AURA_THAT_WENT_AWAY" },
          { "set", "SET_THAT_WENT_AWAY", min = 2 },
          { "bonus", "BONUS_THAT_WENT_AWAY" },
        } },
      }, ctxOf())
      assert.equal(3, #found)
      local bySource = {}
      for _, row in ipairs(found) do bySource[row.source] = row.key end
      assert.equal("AURA_THAT_WENT_AWAY", bySource.spells)
      assert.equal("SET_THAT_WENT_AWAY", bySource.sets)
      assert.equal("BONUS_THAT_WENT_AWAY", bySource.bonuses)
    end)

    -- Schema recurses into all/any/not when it validates, so a check that only looked at the top
    -- level would pass a build Schema then refuses -- the panel would say "everything is fine" and
    -- the rotation would not compile.
    it("looks inside all, any and not", function()
      local found = Diagnostics.unknown(build{
        { spell = "EXORCISM", when = {
          { "any", { "buff", "GONE_A" }, { "not", { "rune", "GONE_B" } } },
        } },
      }, ctxOf())
      assert.equal(2, #found)
    end)

    it("stays quiet about every key the shipped builds actually use", function()
      for key, shipped in pairs(pack.builds) do
        assert.same({}, Diagnostics.unknown(shipped, ctxOf()), key)
      end
    end)

    -- Exactly how Schema treats a ctx table that was not supplied: not checked. Reporting every set
    -- as missing because the caller only handed over `spells` would be wrong.
    it("does not check a pack table it was not given", function()
      assert.same({}, Diagnostics.unknown(build{
        { spell = "EXORCISM", when = { { "set", "ANYTHING", min = 2 } } },
      }, { spells = pack.spells }))
      assert.same({}, Diagnostics.unknown(build{ { spell = "EXORCISM" } }, {}))
      assert.same({}, Diagnostics.unknown(build{ { spell = "EXORCISM" } }, nil))
    end)

    it("says nothing about an empty or malformed rotation", function()
      assert.same({}, Diagnostics.unknown(nil, ctxOf()))
      assert.same({}, Diagnostics.unknown(build{ "not an entry" }, ctxOf()))
      assert.same({}, Diagnostics.unknown(build{ { item = 13 } }, ctxOf()))
    end)
  end)

  -- R3 (D87): "a condition on a seal after the line that cast it was changed" -- the owner's own
  -- worked example of the editor's RED state. Nothing else in the addon's model puts a seal on the
  -- character, so a `seal`/`seal_linger` condition naming one no enabled line casts can never
  -- become true as the build stands, however the character or the moment changes.
  describe("deadSeal()", function()
    it("names a seal condition no line of the build casts", function()
      local found = Diagnostics.deadSeal(build{
        { spell = "JUDGEMENT" },
        { spell = "EXORCISM", when = { { "seal", "SEAL_OF_RIGHTEOUSNESS" } } },
      })
      assert.equal(1, #found)
      assert.equal(2, found[1].index)
      assert.equal("SEAL_OF_RIGHTEOUSNESS", found[1].key)
    end)

    it("says nothing once a line actually casts that seal", function()
      assert.same({}, Diagnostics.deadSeal(build{
        { spell = "SEAL_OF_RIGHTEOUSNESS" },
        { spell = "EXORCISM", when = { { "seal", "SEAL_OF_RIGHTEOUSNESS" } } },
      }))
    end)

    it("checks seal_linger the same way as seal", function()
      local found = Diagnostics.deadSeal(build{
        { spell = "EXORCISM", when = { { "seal_linger", "SEAL_OF_RIGHTEOUSNESS" } } },
      })
      assert.equal(1, #found)
    end)

    -- Schema recurses into all/any/not when it validates; a check that only looked at the top
    -- level would miss exactly the nested shape the shipped builds actually use.
    it("looks inside all, any and not", function()
      local found = Diagnostics.deadSeal(build{
        { spell = "EXORCISM", when = {
          { "any", { "seal", "GONE_A" }, { "not", { "seal_linger", "GONE_B" } } },
        } },
      })
      local keys = {}
      for _, row in ipairs(found) do keys[row.key] = true end
      assert.is_true(keys.GONE_A)
      assert.is_true(keys.GONE_B)
    end)

    -- A disabled line neither casts a seal for real play nor is itself checked: Schema.compile
    -- skips it, so it is not in the rotation at all.
    it("does not count a disabled line's cast, and does not check a disabled line's own condition", function()
      local found = Diagnostics.deadSeal(build{
        { spell = "SEAL_OF_RIGHTEOUSNESS", disabled = true },
        { spell = "EXORCISM", when = { { "seal", "SEAL_OF_RIGHTEOUSNESS" } } },
        { spell = "JUDGEMENT", disabled = true, when = { { "seal", "GONE" } } },
      })
      assert.equal(1, #found)
      assert.equal(2, found[1].index)
    end)

    it("stays quiet about every seal condition the shipped builds actually use", function()
      for key, shipped in pairs(pack.builds) do
        assert.same({}, Diagnostics.deadSeal(shipped), key)
      end
    end)

    it("says nothing about an empty or malformed rotation", function()
      assert.same({}, Diagnostics.deadSeal(nil))
      assert.same({}, Diagnostics.deadSeal(build{ "not an entry" }))
      assert.same({}, Diagnostics.deadSeal(build{ { item = 13 } }))
    end)
  end)

  describe("compare()", function()
    local MINE, THEIRS

    -- A local rather than a `Diagnostics.identical` helper: nothing in the addon needs the boolean,
    -- and a function only a spec calls is a bug report (the definition of done).
    local function unchanged(result)
      return #result.onlyMine == 0 and #result.onlyTheirs == 0
         and #result.changed == 0 and #result.moved == 0
    end

    before_each(function()
      THEIRS = build{
        { spell = "EXORCISM", when = { { "in_combat" } } },
        { spell = "CRUSADER_STRIKE" },
        { spell = "CONSECRATION", label = "AoE", when = { { "enemies", min = 3 } } },
      }
      MINE = build{
        { spell = "EXORCISM", when = { { "in_combat" } } },
        { spell = "CRUSADER_STRIKE" },
        { spell = "CONSECRATION", label = "AoE", when = { { "enemies", min = 3 } } },
      }
    end)

    it("finds nothing between two identical rotations", function()
      local result = Diagnostics.compare(MINE, THEIRS)
      assert.is_true(unchanged(result))
      assert.same({}, result.onlyMine)
      assert.same({}, result.onlyTheirs)
      assert.same({}, result.changed)
      assert.same({}, result.moved)
    end)

    it("names a row only you have, and one only the template has", function()
      MINE.entries[4] = { spell = "JUDGEMENT" }
      THEIRS.entries[4] = { spell = "HOLY_WRATH" }
      local result = Diagnostics.compare(MINE, THEIRS)
      assert.is_false(unchanged(result))
      assert.equal(1, #result.onlyMine)
      assert.equal("JUDGEMENT", result.onlyMine[1].spell)
      assert.equal(4, result.onlyMine[1].index)
      assert.equal(1, #result.onlyTheirs)
      assert.equal("HOLY_WRATH", result.onlyTheirs[1].spell)
    end)

    it("names a row whose conditions differ, and carries both positions", function()
      MINE.entries[3].when = { { "enemies", min = 2 } }
      local result = Diagnostics.compare(MINE, THEIRS)
      assert.equal(1, #result.changed)
      assert.equal(3, result.changed[1].index)
      assert.equal(3, result.changed[1].theirIndex)
      assert.equal("AoE", result.changed[1].label)
      assert.same({}, result.moved)
    end)

    -- Position IS the rotation (F1: the first line that passes is the answer), so a row that only
    -- moved is a real difference, and it can be the only thing a release changed.
    it("names a row that only moved", function()
      MINE.entries[1], MINE.entries[2] = MINE.entries[2], MINE.entries[1]
      local result = Diagnostics.compare(MINE, THEIRS)
      assert.equal(2, #result.moved)
      assert.same({}, result.changed)
      assert.same({}, result.onlyMine)
      assert.same({}, result.onlyTheirs)
      local at = {}
      for _, row in ipairs(result.moved) do at[row.spell] = { row.index, row.theirIndex } end
      assert.same({ 1, 2 }, at.CRUSADER_STRIKE)
      assert.same({ 2, 1 }, at.EXORCISM)
    end)

    -- Exodin carries three Judgements. Matching on the action alone would pair the wrong two and
    -- then report both as changed, which is a diff that invents differences.
    it("pairs repeated actions by the author's label, in order", function()
      THEIRS = build{
        { spell = "JUDGEMENT", label = "Draconic 2p", when = { { "bonus", "A" } } },
        { spell = "JUDGEMENT", label = "Seal expiring", when = { { "buff", "S", maxRemaining = 1.5 } } },
        { spell = "JUDGEMENT" },
      }
      MINE = build{
        { spell = "JUDGEMENT", label = "Draconic 2p", when = { { "bonus", "A" } } },
        { spell = "JUDGEMENT", label = "Seal expiring", when = { { "buff", "S", maxRemaining = 1.5 } } },
        { spell = "JUDGEMENT" },
      }
      assert.is_true(unchanged(Diagnostics.compare(MINE, THEIRS)))
      MINE.entries[2].when = { { "buff", "S", maxRemaining = 3 } }
      local result = Diagnostics.compare(MINE, THEIRS)
      assert.equal(1, #result.changed)
      assert.equal("Seal expiring", result.changed[1].label,
                   "the wrong pairing would have reported the unlabelled one too")
    end)

    -- An item line has no spell, and a caller naming it needs the SLOT rather than a string it has
    -- to parse back apart.
    it("carries the entry's own fields, so a caller never parses an identity string", function()
      MINE.entries[4] = { item = 13 }
      local only = Diagnostics.compare(MINE, THEIRS).onlyMine[1]
      assert.equal(13, only.item)
      assert.is_nil(only.spell)
      assert.is_nil(only.action, "the action string is this file's own business")
    end)

    it("survives a missing or malformed rotation on either side", function()
      assert.is_true(unchanged(Diagnostics.compare(nil, nil)))
      assert.equal(3, #Diagnostics.compare(MINE, nil).onlyMine)
      assert.equal(3, #Diagnostics.compare(nil, THEIRS).onlyTheirs)
      assert.is_true(unchanged(Diagnostics.compare(build{ "junk" }, build{ "junk" })))
    end)

    -- A fork of a shipped template, before anything is edited, must read as identical -- otherwise
    -- the stale-parent banner would announce differences on a fork nobody has touched.
    it("finds nothing between a shipped build and a deep copy of it", function()
      local UserBuilds = helper.load("Elmira/Core/UserBuilds.lua")
      for key, shipped in pairs(pack.builds) do
        local copy = UserBuilds.copy(shipped)
        assert.is_true(unchanged(Diagnostics.compare(copy, shipped)), key)
      end
    end)
  end)
end)
