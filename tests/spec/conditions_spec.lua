local helper = require("tests.helper")

-- Elmira/Core/Conditions.lua — the Builder's model of the condition language (F30, ADR-0015 §2).
--
-- The fixture is the SHIPPED Paladin pack, not a hand-written one, and that is the point of this
-- file. A field table can look complete and still be unable to express the rows people actually
-- run: `no_buff` gates on Righteous Fury and `buff` gates on Seal of Martyrdom, both castable
-- abilities rather than aura records, so a key source filtered to "things flagged aura" would have
-- made those rows silently un-editable. The sweep over every shipped build is what catches that.
describe("Core.Conditions", function()
  local Conditions, Schema, ns, pack

  local function ctxOf()
    return { spells = pack.spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses }
  end

  before_each(function()
    ns = helper.reset()
    Schema = helper.load("Elmira/Core/Schema.lua")
    helper.load("Elmira/Core/Gates.lua")
    helper.load("Elmira/Core/Palette.lua")
    Conditions = helper.load("Elmira/Core/Conditions.lua")
    pack = helper.classPack("Paladin")
  end)

  -- Every top-level condition of every shipped build, so the sweeps below cannot pass by finding
  -- nothing. Composites are yielded whole: whether they are editable is exactly what is under test.
  local function shippedConditions()
    local out = {}
    for _, build in pairs(pack.builds) do
      for _, entry in ipairs(build.entries or {}) do
        for _, cond in ipairs(entry.when or {}) do out[#out + 1] = cond end
      end
    end
    return out
  end

  describe("the field table", function()
    it("covers every condition type Schema compiles, except the ones the editor must not draw",
      function()
        -- `custom` is a Lua function and `all`/`any`/`not` are the composition the pane models as
        -- match + negation, so neither is a field. Everything else must be drawable, or a shipped
        -- build carries a row nobody can edit.
        local undrawable = { custom = true, all = true, any = true, ["not"] = true }
        local missing = {}
        for kind in pairs(ns.__schemaConditions) do
          if not undrawable[kind] and not Conditions.field(kind) then missing[#missing + 1] = kind end
        end
        table.sort(missing)
        assert.same({}, missing)
      end)

    it("puts every field in exactly one category, in a fixed order", function()
      local seen = {}
      for _, cat in ipairs(Conditions.CATEGORIES) do
        for _, kind in ipairs(cat.fields) do
          assert.is_nil(seen[kind], kind .. " is in two categories")
          assert.is_truthy(Conditions.field(kind), kind .. " is in a category but has no field")
          seen[kind] = cat.id
          assert.equal(cat.id, Conditions.categoryOf(kind))
        end
      end
      for kind in pairs(Conditions.FIELDS) do
        assert.is_truthy(seen[kind], kind .. " is a field in no category, so nothing can reach it")
      end
      assert.is_nil(Conditions.categoryOf("no_such_field"))
    end)

    -- AceConfig round-trips a `select` value through the widget, and a numeric id comes back as a
    -- string: the two then compare unequal and the dropdown resets itself on every open.
    it("gives every operator a STRING id, and a valueless default first", function()
      for kind, field in pairs(Conditions.FIELDS) do
        assert.is_true(#field.ops > 0, kind .. " offers no operator")
        for _, op in ipairs(field.ops) do
          assert.equal("string", type(op.id), kind .. "." .. tostring(op.id))
          assert.equal("string", type(op.label))
        end
        assert.equal(field.ops[1], Conditions.op(field, field.ops[1].id))
      end
      assert.is_nil(Conditions.op(Conditions.field("buff"), "no_such_op"))
    end)

    -- Schema validates these three lists itself (C.mode, C.weapon), so an extra entry here would
    -- offer a value the compiler rejects the moment it is saved.
    it("offers only the vocabulary Schema accepts", function()
      for _, mode in ipairs(Conditions.MODES) do
        local _, errors = Schema.compileWhen({ { "mode", mode } }, ctxOf())
        assert.equal(0, #errors, mode)
      end
      for _, kind in ipairs(Conditions.WEAPON_KINDS) do
        local _, errors = Schema.compileWhen({ { "weapon", kind } }, ctxOf())
        assert.equal(0, #errors, kind)
      end
    end)
  end)

  -- Hardcoded, deliberately. Derived from `Conditions.FIELDS` this would agree with whatever the
  -- table happens to say, which is the shape of test that let a wrong rune id ship for eight days
  -- (tasks/lessons.md). Written out, adding or losing an operator is a decision someone has to make
  -- here as well as there -- and every one of them is exercised by the round trip below.
  local EXPECTED_OPS = {
    enemies = { "min", "max" },
    mode = { "present" },
    ttd = { "min", "max" },
    resource = { "minPct", "maxPct", "min", "max" },
    target_hp = { "maxPct", "minPct" },
    target_type = { "present" },
    buff = { "present", "min", "maxRemaining", "minRemaining" },
    no_buff = { "present" },
    debuff = { "present", "minRemaining" },
    no_debuff = { "present" },
    seal = { "present" },
    no_seal = { "present" },
    seal_linger = { "present" },
    cooldown_ready = { "present" },
    cooldown_gt = { "secs" },
    item_ready = { "present" },
    swing = { "maxRemaining", "minRemaining" },
    set = { "present", "min" },
    bonus = { "present" },
    rune = { "present" },
    no_rune = { "present" },
    weapon = { "present", "maxSpeed", "minSpeed" },
    enchant = { "present" },
    level = { "min", "max" },
    in_combat = { "present" },
    out_of_combat = { "present" },
    not_moving = { "present" },
  }

  describe("every operator of every field", function()
    it("offers exactly the operators it is meant to, in order", function()
      for kind, field in pairs(Conditions.FIELDS) do
        local ids = {}
        for _, op in ipairs(field.ops) do ids[#ids + 1] = op.id end
        assert.same(EXPECTED_OPS[kind], ids, kind)
      end
      for kind in pairs(EXPECTED_OPS) do
        assert.is_truthy(Conditions.field(kind), kind .. " is expected here but is not a field")
      end
    end)

    -- One row per operator, written by the editor and read back. This is what makes an operator
    -- that nobody has ever selected impossible to ship broken: a value written to the wrong
    -- qualifier compiles fine and simply tests something else.
    it("round-trips, compiles and describes a row built with each one", function()
      local samples = { key = { resource = "MANA", mode = "AoE", target_type = "Undead",
                                weapon = "2H", enchant = "EXORCISM_SOUL",
                                set = "PALADIN_T35_INQUISITION", bonus = "HOLY_POWER_CONSUME",
                                rune = "RUNE_PURIFYING_POWER", no_rune = "RUNE_PURIFYING_POWER",
                                seal = "SEAL_OF_MARTYRDOM", seal_linger = "SEAL_OF_MARTYRDOM",
                                cooldown_ready = "EXORCISM", cooldown_gt = "EXORCISM" } }
      local checked = 0
      for kind, field in pairs(Conditions.FIELDS) do
        for _, op in ipairs(field.ops) do
          local row = Conditions.blankRow(kind)
          assert.is_truthy(row, kind)
          row.op = op.id
          if field.keySource then
            row.key = samples.key[kind] or Conditions.keys(kind, pack)[1]
          end
          if field.slotAt then row.slot = 13 end
          if op.arg == "number" then row.value = 2 end

          local when = Conditions.fromRows("all", { row })
          local _, errors = Schema.compileWhen(when, ctxOf())
          assert.equal(0, #errors,
            kind .. "/" .. op.id .. ": " .. table.concat(Schema.errorLines(errors), "; "))

          local back = Conditions.toRows(when)
          assert.is_false(back.complex, kind .. "/" .. op.id)
          assert.equal(op.id, back.rows[1].op, kind .. "/" .. op.id)
          assert.equal(row.key, back.rows[1].key, kind .. "/" .. op.id)
          assert.equal(row.slot, back.rows[1].slot, kind .. "/" .. op.id)
          assert.equal(row.value, back.rows[1].value, kind .. "/" .. op.id)

          local text = Conditions.describe(when[1], { spells = pack.spells, sets = pack.sets,
                                                      souls = pack.souls, bonuses = pack.bonuses })
          assert.is_true(#text > 0, kind .. "/" .. op.id .. " describes as nothing")
          assert.is_nil(text:find("[\128-\255]"), text)
          checked = checked + 1
        end
      end
      assert.is_true(checked > 30, "only " .. checked .. " operators were exercised")
    end)

    -- The valueless form is what a row falls back to when a stored condition carries no qualifier
    -- at all, and it has to name the RIGHT operator or the dropdown opens on someone else's.
    it("reads a bare condition as its valueless operator", function()
      assert.equal("present", Conditions.toRows({ { "no_seal" } }).rows[1].op)
      assert.equal("present", Conditions.toRows({ { "set", "PALADIN_T35_INQUISITION" } }).rows[1].op)
      assert.equal("present", Conditions.toRows({ { "weapon", "2H" } }).rows[1].op)
    end)

    it("writes nothing for a row whose field it does not know", function()
      assert.same({}, Conditions.fromRows("all", { { kind = "no_such_field", op = "present" } }))
      assert.same({}, Conditions.fromRows("all", { {} }))
    end)
  end)

  describe("keys()", function()
    it("answers nil for a field that takes no key", function()
      assert.is_nil(Conditions.keys("in_combat", pack))
      assert.is_nil(Conditions.keys("enemies", pack))
      assert.is_nil(Conditions.keys("item_ready", pack))
      assert.is_nil(Conditions.keys("no_such_field", pack))
    end)

    it("offers the pack's own tables for the keys that come from data", function()
      assert.is_true(#Conditions.keys("set", pack) > 0)
      assert.is_true(#Conditions.keys("bonus", pack) > 0)
      assert.is_true(#Conditions.keys("buff", pack) > 0)
      assert.same(Conditions.keys("buff", pack), Conditions.keys("no_buff", pack))
    end)

    -- Two different readers, so both need the check: whole pack tables go one way and a filtered
    -- spell sweep goes another.
    it("sorts, because pairs() has no order and a palette that reshuffles is unreadable", function()
      for _, kind in ipairs({ "buff", "set", "bonus", "enchant",
                              "cooldown_ready", "seal", "rune" }) do
        local keys = Conditions.keys(kind, pack)
        assert.is_true(#keys > 1, kind .. " has too few keys to prove an order")
        for i = 2, #keys do
          assert.is_true(keys[i - 1] < keys[i], kind .. " is out of order at " .. i)
        end
      end
    end)

    it("offers seals for a seal gate and runes for a rune gate", function()
      for _, key in ipairs(Conditions.keys("seal", pack)) do
        assert.is_true(pack.spells[key].seal == true, key .. " is not a seal")
      end
      for _, key in ipairs(Conditions.keys("rune", pack)) do
        assert.is_truthy(pack.spells[key].rune, key .. " is not a rune")
      end
      assert.same(Conditions.keys("rune", pack), Conditions.keys("no_rune", pack))
      assert.same(Conditions.keys("seal", pack), Conditions.keys("seal_linger", pack))
    end)

    -- "Can you press this" is decided in the data and owned by Core/Palette; a second copy here
    -- would be the one nobody casts from.
    it("offers only castable spells for a cooldown gate", function()
      local keys = Conditions.keys("cooldown_ready", pack)
      assert.is_true(#keys > 0)
      for _, key in ipairs(keys) do
        assert.is_true(ns.Palette.castable(pack.spells[key]), key .. " cannot be pressed")
      end
      assert.same(keys, Conditions.keys("cooldown_gt", pack))
      -- Runes are records, not abilities: offering one as a cooldown gate is the "Test with"
      -- dropdown's shipped defect in a new place.
      for _, key in ipairs(keys) do assert.is_nil(pack.spells[key].rune, key) end
    end)

    -- The buff sources are deliberately UNfiltered. These two keys are the evidence: both are
    -- castable abilities that the shipped builds gate on as auras.
    it("offers the language's own vocabulary where a pack has none", function()
      assert.same({ "Single", "Cleave", "AoE" }, Conditions.keys("mode", pack))
      assert.same({ "2H", "1H", "Shield" }, Conditions.keys("weapon", pack))
      assert.same({ "MANA", "RAGE", "ENERGY" }, Conditions.keys("resource", pack))
      -- UnitCreatureType answers a localised string, so a build that ships one ships an English
      -- one (enUS only in v1).
      assert.same({ "Beast", "Critter", "Demon", "Dragonkin", "Elemental", "Giant", "Humanoid",
                    "Mechanical", "Undead" }, Conditions.keys("target_type", pack))
    end)

    it("reads each pack table from the pack, not from another one", function()
      local souls = Conditions.keys("enchant", pack)
      assert.is_true(#souls > 0)
      for _, key in ipairs(souls) do assert.is_truthy(pack.souls[key], key) end
      for _, key in ipairs(Conditions.keys("set", pack)) do assert.is_truthy(pack.sets[key], key) end
      for _, key in ipairs(Conditions.keys("bonus", pack)) do
        assert.is_truthy(pack.bonuses[key], key)
      end
      for _, key in ipairs(Conditions.keys("buff", pack)) do
        assert.is_truthy(pack.spells[key], key)
      end
      -- Each source is a different table, so a dispatch that fell through to the wrong one would
      -- offer set keys where soul keys belong.
      assert.are_not.same(Conditions.keys("set", pack), Conditions.keys("bonus", pack))
      assert.are_not.same(Conditions.keys("enchant", pack), Conditions.keys("buff", pack))
    end)

    it("answers an empty list, not an error, for a pack with no such table", function()
      assert.same({}, Conditions.keys("set", {}))
      assert.same({}, Conditions.keys("buff", nil))
    end)

    it("offers a castable ability as a buff key, because the shipped builds gate on two", function()
      local offered = {}
      for _, key in ipairs(Conditions.keys("buff", pack)) do offered[key] = true end
      assert.is_true(offered.SEAL_OF_MARTYRDOM, "Exodin's Judgement row gates on this buff")
      assert.is_true(offered.RIGHTEOUS_FURY, "Prot's first row gates on this no_buff")
    end)
  end)

  describe("toRows() / fromRows()", function()
    -- The round trip is the contract: whatever the pane reads it must be able to write back
    -- unchanged, or opening a row and saving it without touching anything would edit the rotation.
    local function roundTrip(when)
      local model = Conditions.toRows(when)
      assert.is_false(model.complex, "expected an editable shape")
      return Conditions.fromRows(model.match, model.rows), model
    end

    it("round-trips every shape the shipped builds use", function()
      local conds = shippedConditions()
      assert.is_true(#conds > 20, "the sweep found nothing to sweep")
      local editable = 0
      for _, cond in ipairs(conds) do
        local model = Conditions.toRows({ cond })
        if not model.complex then
          editable = editable + 1
          assert.same({ cond }, Conditions.fromRows(model.match, model.rows))
        end
      end
      assert.is_true(editable > 20, "only " .. editable .. " shipped conditions were editable")
    end)

    it("round-trips each shipped ENTRY's whole condition list", function()
      local entries, editable = 0, 0
      for _, build in pairs(pack.builds) do
        for _, entry in ipairs(build.entries or {}) do
          entries = entries + 1
          local model = Conditions.toRows(entry.when)
          if not model.complex then
            editable = editable + 1
            assert.same(entry.when or {}, Conditions.fromRows(model.match, model.rows))
          end
        end
      end
      assert.is_true(entries > 50)
      -- Most rows must be editable, or the pane is decoration. Named as a floor rather than an
      -- exact count so adding a build cannot fail this for the wrong reason.
      assert.is_true(editable > entries * 0.8,
        editable .. " of " .. entries .. " shipped entries are editable")
    end)

    it("round-trips one condition of every kind the editor draws, and each compiles clean",
      function()
        -- Built from the field table itself, so a field added without a working round trip fails
        -- here rather than shipping as a dropdown entry that saves nothing.
        local samples = {
          enemies = { "enemies", min = 3 },
          mode = { "mode", "AoE" },
          ttd = { "ttd", max = 8 },
          resource = { "resource", "MANA", minPct = 40 },
          target_hp = { "target_hp", maxPct = 20 },
          target_type = { "target_type", "Undead" },
          buff = { "buff", "HOLY_POWER_BUFF", min = 3 },
          no_buff = { "no_buff", "RIGHTEOUS_FURY" },
          debuff = { "debuff", "VINDICATION_DEBUFF", minRemaining = 2 },
          no_debuff = { "no_debuff", "VINDICATION_DEBUFF" },
          seal = { "seal", "SEAL_OF_MARTYRDOM" },
          no_seal = { "no_seal" },
          seal_linger = { "seal_linger", "SEAL_OF_MARTYRDOM" },
          cooldown_ready = { "cooldown_ready", "EXORCISM" },
          cooldown_gt = { "cooldown_gt", "DIVINE_STORM", 1 },
          item_ready = { "item_ready", 13 },
          swing = { "swing", maxRemaining = 0.5 },
          set = { "set", "PALADIN_T35_INQUISITION", min = 2 },
          bonus = { "bonus", "HOLY_POWER_CONSUME" },
          rune = { "rune", "RUNE_PURIFYING_POWER" },
          no_rune = { "no_rune", "RUNE_PURIFYING_POWER" },
          weapon = { "weapon", "2H", maxSpeed = 3 },
          enchant = { "enchant", 3, "EXORCISM_SOUL" },
          level = { "level", min = 40 },
          in_combat = { "in_combat" },
          out_of_combat = { "out_of_combat" },
          not_moving = { "not_moving" },
        }
        for kind in pairs(Conditions.FIELDS) do
          assert.is_truthy(samples[kind], kind .. " has a field but no round-trip sample here")
        end
        for kind, cond in pairs(samples) do
          local back = roundTrip({ cond })
          assert.same({ cond }, back, kind)
          local _, errors = Schema.compileWhen(back, ctxOf())
          assert.equal(0, #errors, kind .. ": " .. table.concat(Schema.errorLines(errors), "; "))
        end
      end)

    it("reads a list as an implicit all, and a lone any as match = any", function()
      local all = Conditions.toRows({ { "in_combat" }, { "not_moving" } })
      assert.equal("all", all.match)
      assert.equal(2, #all.rows)

      local any = Conditions.toRows({ { "any", { "in_combat" }, { "not_moving" } } })
      assert.equal("any", any.match)
      assert.equal(2, #any.rows)
      assert.same({ { "any", { "in_combat" }, { "not_moving" } } },
                  Conditions.fromRows("any", any.rows))
    end)

    it("carries `not` as a flag on the row rather than as a shape", function()
      local model = Conditions.toRows({ { "not", { "set", "PALADIN_T35_INQUISITION", min = 2 } } })
      assert.is_false(model.complex)
      assert.is_true(model.rows[1].negated)
      assert.equal("set", model.rows[1].kind)
      assert.equal("min", model.rows[1].op)
      assert.equal(2, model.rows[1].value)
      assert.same({ { "not", { "set", "PALADIN_T35_INQUISITION", min = 2 } } },
                  Conditions.fromRows("all", model.rows))
    end)

    it("reads the slot and the key of an enchant from the positions they are stored at", function()
      local model = Conditions.toRows({ { "enchant", 3, "EXORCISM_SOUL" } })
      assert.equal(3, model.rows[1].slot)
      assert.equal("EXORCISM_SOUL", model.rows[1].key)
    end)

    it("reads a positional value, and writes it back positionally", function()
      local model = Conditions.toRows({ { "cooldown_gt", "DIVINE_STORM", 1 } })
      assert.equal("secs", model.rows[1].op)
      assert.equal(1, model.rows[1].value)
      assert.same({ { "cooldown_gt", "DIVINE_STORM", 1 } }, Conditions.fromRows("all", model.rows))
    end)

    it("empties the rows when the list is empty, rather than inventing one", function()
      local model = Conditions.toRows(nil)
      assert.is_false(model.complex)
      assert.same({}, model.rows)
      assert.same({}, Conditions.fromRows("all", {}))
      -- An `any` of nothing is not a condition; it must not be written as one.
      assert.same({}, Conditions.fromRows("any", {}))
    end)

    it("edits a value without disturbing the rest of the row", function()
      local model = Conditions.toRows({ { "resource", "MANA", minPct = 40 } })
      model.rows[1].value = 90
      assert.same({ { "resource", "MANA", minPct = 90 } },
                  Conditions.fromRows(model.match, model.rows))
      -- Changing the operator moves the qualifier, rather than leaving both on the condition.
      model.rows[1].op = "maxPct"
      assert.same({ { "resource", "MANA", maxPct = 90 } },
                  Conditions.fromRows(model.match, model.rows))
    end)

    it("takes a value typed as text, because an AceConfig input hands back a string", function()
      local rows = { { kind = "enemies", op = "min", value = "3" } }
      assert.same({ { "enemies", min = 3 } }, Conditions.fromRows("all", rows))
    end)

    -- Same reason, and it matters more here: `Schema`'s `item_ready` check is
    -- `type(cond[2]) ~= "number"`, so a slot left as the string an AceConfig select hands back
    -- fails validation and the whole save is refused, with the dropdown showing the right slot.
    it("takes a slot typed as text too", function()
      local rows = { { kind = "item_ready", op = "present", slot = "13" } }
      local when = Conditions.fromRows("all", rows)
      assert.same({ { "item_ready", 13 } }, when)
      local _, errors = Schema.compileWhen(when, ctxOf())
      assert.equal(0, #errors)
    end)

    it("starts a new row on the field's valueless default", function()
      assert.same({ kind = "no_seal", op = "present" }, Conditions.blankRow("no_seal"))
      local row = Conditions.blankRow("enemies")
      assert.equal("min", row.op)
      assert.equal(0, row.value)
      assert.is_nil(Conditions.blankRow("no_such_field"))
    end)
  end)

  describe("complex shapes are read-only, and carry no rows", function()
    -- Handing back the rows that DID convert would invite a caller to save those and lose the rest,
    -- which is the silent partial write this whole file exists to make impossible.
    local function assertComplex(when, why)
      local model = Conditions.toRows(when)
      assert.is_true(model.complex, why)
      assert.same({}, model.rows, why .. ": complex answers must carry no rows")
    end

    it("refuses a composite nested inside the list", function()
      assertComplex({ { "bonus", "HOLY_WRATH_INSTANT" },
                      { "any", { "target_type", "Undead" }, { "rune", "RUNE_PURIFYING_POWER" } } },
                    "an any beside another condition is two levels")
    end)

    it("refuses a composite inside a `not`", function()
      assertComplex({ { "not", { "any", { "in_combat" }, { "not_moving" } } } }, "not(any(...))")
    end)

    it("refuses a `custom` function, which cannot be drawn or serialized", function()
      assertComplex({ { "custom", function() return true end } }, "custom")
    end)

    it("refuses a variadic value, rather than narrowing it to its first argument", function()
      -- {"target_type","Undead","Demon"} narrowed to Undead is a DIFFERENT test from the one that
      -- shipped, and saving it would quietly change the rotation.
      assertComplex({ { "target_type", "Undead", "Demon" } }, "two creature types")
    end)

    it("refuses two qualifiers on one condition", function()
      assertComplex({ { "buff", "HOLY_POWER_BUFF", min = 3, maxRemaining = 2 } }, "two qualifiers")
    end)

    it("refuses a qualifier the field does not offer", function()
      assertComplex({ { "enemies", range = 8 } }, "enemies range")
      assertComplex({ { "debuff", "VINDICATION_DEBUFF", mine = false } }, "debuff mine")
    end)

    it("refuses a condition that is not a table, and an unknown kind", function()
      assertComplex({ "in_combat" }, "a bare string in the list")
      assertComplex({ { "no_such_kind" } }, "unknown kind")
    end)

    it("refuses a value stored where the field expects it positionally", function()
      assertComplex({ { "cooldown_gt", "DIVINE_STORM", secs = 1 } }, "secs as a qualifier")
    end)

    it("refuses an incomplete condition whose field has no valueless form", function()
      assertComplex({ { "enemies" } }, "enemies with no bound")
      assertComplex({ { "swing" } }, "swing with no bound")
    end)

    it("refuses a `not` with more than one child", function()
      assertComplex({ { "not", { "in_combat" }, { "not_moving" } } }, "not takes one child")
    end)

    -- The shipped builds must still be MOSTLY editable, or "read-only" stops being an edge case.
    it("finds the shipped nested rows and nothing else", function()
      local complex = 0
      for _, cond in ipairs(shippedConditions()) do
        if Conditions.toRows({ cond }).complex then
          complex = complex + 1
          assert.equal("any", cond[1], "the only complex shape shipped is a nested any")
        end
      end
      assert.is_true(complex > 0, "the sweep found no complex shape, so it proved nothing")
    end)
  end)

  describe("describe()", function()
    local ctx

    before_each(function()
      ctx = ctxOf()
      -- Options passes Rotation.spellLabel, which asks the client. Headless, a readable stand-in
      -- proves the name goes through the hook rather than being printed as the raw key.
      ctx.name = function(key) return (key:gsub("_", " "):lower()) end
    end)

    it("writes each dynamic kind in words a player can read", function()
      local cases = {
        { { "resource", "MANA", minPct = 50 }, "mana at least 50%" },
        { { "resource", "MANA", maxPct = 50 }, "mana at most 50%" },
        { { "resource", "RAGE", min = 20 }, "rage at least 20" },
        { { "resource", "ENERGY", max = 80 }, "energy at most 80" },
        { { "target_hp", maxPct = 20 }, "target HP at most 20%" },
        { { "target_hp", minPct = 80 }, "target HP at least 80%" },
        { { "enemies", min = 3 }, "at least 3 enemies nearby" },
        { { "enemies", max = 1 }, "at most 1 enemies nearby" },
        { { "mode", "AoE" }, "mode is AoE" },
        { { "ttd", max = 8 }, "target dies within 8s" },
        { { "ttd", min = 30 }, "target lives at least 30s" },
        { { "target_type", "Undead" }, "target is Undead" },
        { { "target_type", "Undead", "Demon" }, "target is Undead or Demon" },
        { { "buff", "HOLY_POWER_BUFF", min = 3 }, "holy power buff at 3 stacks or more" },
        { { "buff", "AVENGING_WRATH_BUFF" }, "avenging wrath buff is up" },
        { { "buff", "SEAL_OF_MARTYRDOM", maxRemaining = 1.5 },
          "seal of martyrdom with 1.5s left or less" },
        { { "buff", "SEAL_OF_MARTYRDOM", minRemaining = 4 },
          "seal of martyrdom with 4s left or more" },
        { { "no_buff", "RIGHTEOUS_FURY" }, "righteous fury is not up" },
        { { "debuff", "VINDICATION_DEBUFF" }, "vindication debuff is on the target" },
        { { "debuff", "VINDICATION_DEBUFF", minRemaining = 2 },
          "vindication debuff on the target with 2s left or more" },
        { { "no_debuff", "VINDICATION_DEBUFF" }, "vindication debuff is not on the target" },
        { { "seal", "SEAL_OF_MARTYRDOM" }, "seal of martyrdom is the active seal" },
        { { "no_seal" }, "no seal is up" },
        { { "seal_linger", "SEAL_OF_COMMAND" }, "seal of command is still lingering" },
        { { "cooldown_ready", "EXORCISM" }, "exorcism is off cooldown" },
        { { "cooldown_gt", "DIVINE_STORM", 1 }, "divine storm has more than 1s of cooldown left" },
        { { "item_ready", 13 }, "the item in slot 13 is ready" },
        { { "swing", maxRemaining = 0.5 }, "next swing within 0.5s" },
        { { "swing", minRemaining = 1 }, "next swing at least 1s away" },
        { { "in_combat" }, "in combat" },
        { { "out_of_combat" }, "out of combat" },
        { { "not_moving" }, "standing still" },
      }
      for _, case in ipairs(cases) do
        assert.equal(case[2], Conditions.describe(case[1], ctx), case[1][1])
      end
    end)

    -- One phrasing per requirement. Core/Gates already words a static gate in the voice of it being
    -- MET, because the equipment announcement says "X: Divine Storm is now active" -- and a second
    -- phrasing here would be the one that reads wrong in that sentence.
    it("hands every static gate to Gates.describe rather than wording it twice", function()
      for kind in pairs(ns.Gates.STATIC) do
        local cond = ({
          set = { "set", "PALADIN_T35_INQUISITION", min = 2 },
          bonus = { "bonus", "HOLY_POWER_CONSUME" },
          rune = { "rune", "RUNE_PURIFYING_POWER" },
          no_rune = { "no_rune", "RUNE_PURIFYING_POWER" },
          level = { "level", min = 40 },
          weapon = { "weapon", "2H" },
          enchant = { "enchant", 3, "EXORCISM_SOUL" },
        })[kind]
        assert.is_truthy(cond, kind .. " is static but this test has no sample for it")
        assert.equal(ns.Gates.describe(cond, ctx), Conditions.describe(cond, ctx), kind)
      end
      assert.equal("Purifying Power engraved",
                   Conditions.describe({ "rune", "RUNE_PURIFYING_POWER" }, ctx))
    end)

    it("writes a composite as a sentence, mixing static and dynamic children", function()
      assert.equal("at least 3 enemies nearby or mode is AoE",
        Conditions.describe({ "any", { "enemies", min = 3 }, { "mode", "AoE" } }, ctx))
      assert.equal("target is Undead or Purifying Power engraved",
        Conditions.describe({ "any", { "target_type", "Undead" },
                              { "rune", "RUNE_PURIFYING_POWER" } }, ctx))
      assert.equal("in combat and standing still",
        Conditions.describe({ "all", { "in_combat" }, { "not_moving" } }, ctx))
      assert.equal("in combat, standing still and mode is AoE",
        Conditions.describe({ "all", { "in_combat" }, { "not_moving" }, { "mode", "AoE" } }, ctx))
      assert.equal("in combat", Conditions.describe({ "all", { "in_combat" } }, ctx))
      assert.equal("nothing", Conditions.describe({ "all" }, ctx))
    end)

    it("negates in words", function()
      assert.equal("not in combat", Conditions.describe({ "not", { "in_combat" } }, ctx))
      -- Gates words `set` as the requirement; `not` in front of it must still read.
      assert.is_truthy(Conditions.describe(
        { "not", { "set", "PALADIN_T35_INQUISITION", min = 2 } }, ctx):find("^not "))
    end)

    it("falls back to the key when no name resolver was handed in", function()
      assert.equal("EXORCISM is off cooldown",
                   Conditions.describe({ "cooldown_ready", "EXORCISM" }, ctxOf()))
      assert.equal("EXORCISM is off cooldown",
                   Conditions.describe({ "cooldown_ready", "EXORCISM" }, nil))
      -- A resolver that answers nil is a client that could not resolve the id, not a blank row.
      local blind = ctxOf(); blind.name = function() return nil end
      assert.equal("EXORCISM is off cooldown",
                   Conditions.describe({ "cooldown_ready", "EXORCISM" }, blind))
    end)

    -- A build is data a person may have hand-written or imported, so a qualifier can arrive as a
    -- string. It must still read as words rather than as "table: 0x...".
    it("prints a value that is not a number without erroring", function()
      assert.equal("at least 3 enemies nearby",
                   Conditions.describe({ "enemies", min = "3" }, ctx))
      -- "%g" coerces a numeric STRING, so only a value that is not a number at all proves the
      -- guard: without it this raises rather than reading oddly.
      assert.equal("at least many enemies nearby",
                   Conditions.describe({ "enemies", min = "many" }, ctx))
    end)

    it("says something for a shape it cannot read, rather than erroring", function()
      assert.equal("an unreadable condition", Conditions.describe("in_combat", ctx))
      assert.equal("an unreadable condition", Conditions.describe(nil, ctx))
      assert.equal("custom", Conditions.describe({ "custom", function() end }, ctx))
    end)

    -- The client's font draws U+2265 and friends as empty boxes, which is how a status column once
    -- shipped as a row of identical squares. Every sentence this file writes must be ASCII.
    it("writes ASCII only, for every condition the shipped builds carry", function()
      for _, cond in ipairs(shippedConditions()) do
        local text = Conditions.describe(cond, ctx)
        assert.is_nil(text:find("[\128-\255]"),
          "non-ASCII in: " .. text .. " (from " .. tostring(cond[1]) .. ")")
      end
    end)

    it("puts every user-facing string through the localiser", function()
      local asked = {}
      local ctxL = ctxOf()
      ctxL.L = setmetatable({}, { __index = function(_, k) asked[k] = true; return k end })
      Conditions.describe({ "resource", "MANA", minPct = 40 }, ctxL)
      Conditions.describe({ "no_seal" }, ctxL)
      assert.is_true(asked["%s at least %s%%"])
      assert.is_true(asked["no seal is up"])
    end)
  end)

  describe("summary()", function()
    local ctx
    before_each(function()
      ctx = ctxOf()
      ctx.name = function(key) return (key:gsub("_", " "):lower()) end
    end)

    it("says a line with no conditions fires always", function()
      assert.equal("always", Conditions.summary(nil, ctx))
      assert.equal("always", Conditions.summary({}, ctx))
    end)

    it("names the conditions rather than counting them", function()
      assert.equal("no seal is up", Conditions.summary({ { "no_seal" } }, ctx))
      assert.equal("in combat, standing still",
        Conditions.summary({ { "in_combat" }, { "not_moving" } }, ctx))
    end)

    -- The list column is 1.6 widths across; a row that wraps to four lines stops being a list.
    it("shows two and counts the rest", function()
      local text = Conditions.summary({ { "in_combat" }, { "not_moving" }, { "no_seal" },
                                        { "mode", "AoE" } }, ctx)
      assert.equal("in combat, standing still +2 more", text)
    end)
  end)
end)
