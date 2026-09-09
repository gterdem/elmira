local helper = require("tests.helper")

-- Elmira/Core/Spells.lua — the Spells registry (R2, D53-D56). PURE: every function here takes
-- already-resolved data, never a WoW global, so the whole registry runs headlessly.
describe("Core/Spells (the registry)", function()
  local Spells, ns

  before_each(function()
    ns = helper.reset()
    helper.load("Elmira/Core/Conditions.lua")
    Spells = helper.load("Elmira/Core/Spells.lua")
  end)

  describe("store()", function()
    it("reads db.char.spells when AceDB has handed one over", function()
      ns.db = { char = { spells = { EXORCISM = { key = "EXORCISM" } } } }
      assert.equal(ns.db.char.spells, Spells.store())
    end)

    it("answers nil rather than erroring with no db, no char scope, or no spells table", function()
      ns.db = nil
      assert.is_nil(Spells.store())
      ns.db = {}
      assert.is_nil(Spells.store())
      ns.db = { char = {} }
      assert.is_nil(Spells.store())
    end)
  end)

  -- R2b (D75/D76): the one merge every compile/validate ctx builder shares (Core/UserBuilds.ctxFor,
  -- Display.packContext, Adapters/Vanilla.attachPack, Core/Slash's diagnostic commands) -- see the
  -- function's own comment for why it is a shared, live, per-pack table rather than a fresh copy.
  describe("merged() -- the ctx.spells every consumer compiles/validates against", function()
    before_each(function() ns.db = { char = { spells = {} } } end)

    it("merges this character's registry entries UNDER the pack's own spells", function()
      ns.db.char.spells = { SLICE = { key = "SLICE", id = 900, name = "Slice and Dice" } }
      local pack = { spells = { EXORCISM = { id = 415073, name = "Exorcism" } } }
      local merged = Spells.merged(pack)
      assert.equal(415073, merged.EXORCISM.id)
      assert.equal(900, merged.SLICE.id)
    end)

    -- D75's collision policy: shipped data is the authority, always.
    it("the pack's own entry wins a key collision, never the registry's", function()
      ns.db.char.spells = { EXORCISM = { key = "EXORCISM", id = 1, name = "Mine", source = "id" } }
      local pack = { spells = { EXORCISM = { id = 415073, name = "Exorcism" } } }
      assert.equal(415073, Spells.merged(pack).EXORCISM.id)
    end)

    it("answers an empty table for a pack with nothing in either source, never an error", function()
      ns.db = nil
      assert.same({}, Spells.merged(nil))
      ns.db = { char = { spells = {} } }
      assert.same({}, Spells.merged({}))
    end)

    -- Identity-keyed compile caches (Core/Slash.compileBuild, Display.packContext) decide "is this
    -- still the ctx I compiled against" by comparing `ctx.spells` for IDENTITY -- a fresh table on
    -- every call would make every one of them miss on every tick.
    it("returns the SAME table across calls for one pack, so identity-keyed caches still hit", function()
      local pack = { spells = { EXORCISM = { id = 415073 } } }
      assert.equal(Spells.merged(pack), Spells.merged(pack))
    end)

    -- Keyed by PACK, not a single shared slot: a class switch (or two specs sharing a process)
    -- must never see one pack's merge bleed into another's.
    it("keeps a separate table per pack, never one shared across every pack", function()
      local packA = { spells = { A = { id = 1 } } }
      local packB = { spells = { B = { id = 2 } } }
      local mergedA = Spells.merged(packA)
      local mergedB = Spells.merged(packB)
      assert.are_not.equal(mergedA, mergedB)
      assert.is_nil(mergedA.B)
      assert.is_nil(mergedB.A)
    end)

    -- Mutated, not merely added-to: a spell removed from the registry (or a pack whose own table
    -- shrank) must stop appearing on the next call, not linger from the previous one.
    it("drops on the next call an entry no longer present in either source", function()
      ns.db.char.spells = { SLICE = { key = "SLICE", id = 900 } }
      local pack = { spells = {} }
      assert.is_not_nil(Spells.merged(pack).SLICE)
      ns.db.char.spells.SLICE = nil
      assert.is_nil(Spells.merged(pack).SLICE)
    end)

    -- Stays LIVE rather than a snapshot taken once: a spell registered after the first call must be
    -- visible on the next one with no re-attach, since `Vanilla.attachPack` only ever asks once.
    it("picks up a registry entry added after the first call", function()
      local pack = { spells = {} }
      assert.is_nil(Spells.merged(pack).SLICE)
      ns.db.char.spells.SLICE = { key = "SLICE", id = 900, name = "Slice and Dice" }
      assert.equal(900, Spells.merged(pack).SLICE.id)
    end)
  end)

  describe("registerPack()", function()
    it("writes a new pack entry under the pack's OWN key, not a slug", function()
      local s = {}
      local key = Spells.registerPack(s, "EXORCISM", 415073, "Exorcism")
      assert.equal("EXORCISM", key)
      assert.same({ key = "EXORCISM", id = 415073, name = "Exorcism", source = "pack" }, s.EXORCISM)
    end)

    it("is idempotent: calling it again with the same key changes nothing", function()
      local s = {}
      Spells.registerPack(s, "EXORCISM", 415073, "Exorcism")
      local same = s.EXORCISM
      Spells.registerPack(s, "EXORCISM", 999, "Different Name")
      assert.equal(same, s.EXORCISM)
      assert.equal(415073, s.EXORCISM.id)
    end)

    it("never overwrites an entry that already exists under this key, manual or not", function()
      local s = { EXORCISM = { key = "EXORCISM", id = 1, name = "Mine", source = "id" } }
      Spells.registerPack(s, "EXORCISM", 415073, "Exorcism")
      assert.equal("id", s.EXORCISM.source, "a manual entry must not be relabelled automatic")
    end)

    it("refuses a nil store or a non-string key without erroring", function()
      assert.is_nil(Spells.registerPack(nil, "EXORCISM", 1, "Exorcism"))
      assert.is_nil(Spells.registerPack({}, nil, 1, "Exorcism"))
      assert.is_nil(Spells.registerPack({}, "", 1, "Exorcism"))
    end)
  end)

  describe("add()", function()
    it("slugs the resolved name into a key and stores the given source", function()
      local s = {}
      local key = Spells.add(s, { id = 900, name = "Slice and Dice", source = "spellbook" })
      assert.equal("SLICE_AND_DICE", key)
      assert.same({ key = "SLICE_AND_DICE", id = 900, name = "Slice and Dice", source = "spellbook" },
                  s.SLICE_AND_DICE)
    end)

    -- D54: "adding it again selects its page" -- the SAME id from a second row must return the
    -- SAME key, not a duplicate entry.
    it("dedupes by id: adding the same spell twice returns the same key both times", function()
      local s = {}
      local first = Spells.add(s, { id = 900, name = "Slice and Dice", source = "spellbook" })
      local second = Spells.add(s, { id = 900, name = "Slice and Dice", source = "id" })
      assert.equal(first, second)
      local count = 0
      for _ in pairs(s) do count = count + 1 end
      assert.equal(1, count)
      assert.equal("spellbook", s[first].source, "the first add's source wins, not the second's")
    end)

    it("finds an existing PACK entry by id too, rather than creating a second one", function()
      local s = {}
      Spells.registerPack(s, "EXORCISM", 415073, "Exorcism")
      local key = Spells.add(s, { id = 415073, name = "Exorcism", source = "id" })
      assert.equal("EXORCISM", key)
    end)

    it("collision-guards the slug when two different spells would slug to the same key", function()
      local s = {}
      local a = Spells.add(s, { id = 1, name = "Judgement!", source = "id" })
      local b = Spells.add(s, { id = 2, name = "Judgement?", source = "id" })
      assert.equal("JUDGEMENT", a)
      assert.equal("JUDGEMENT_2", b)
    end)

    -- Three-way, so the collision LOOP actually has to iterate more than once to find a free slot --
    -- a two-way collision alone cannot tell a `while` from a single `if`.
    it("keeps counting past _2 when that slug is already taken too", function()
      local s = {}
      local a = Spells.add(s, { id = 1, name = "Judgement!", source = "id" })
      local b = Spells.add(s, { id = 2, name = "Judgement?", source = "id" })
      local c = Spells.add(s, { id = 3, name = "Judgement.", source = "id" })
      assert.same({ "JUDGEMENT", "JUDGEMENT_2", "JUDGEMENT_3" }, { a, b, c })
    end)

    it("falls back to SPELL when a name has no alphanumeric characters at all", function()
      local s = {}
      local key = Spells.add(s, { id = 1, name = "!!!", source = "id" })
      assert.equal("SPELL", key)
    end)

    it("truncates a slug longer than 32 characters", function()
      local s = {}
      local key = Spells.add(s, { id = 1, name = string.rep("A", 40), source = "id" })
      assert.equal(32, #key)
      assert.equal(string.rep("A", 32), key)
    end)

    it("refuses an id-less or name-less resolution, and stores nothing", function()
      local s = {}
      local key, reason = Spells.add(s, { id = nil, name = "Exorcism" })
      assert.is_nil(key)
      assert.equal("not found", reason)
      assert.same({}, s)
      key, reason = Spells.add(s, { id = 1, name = "" })
      assert.is_nil(key)
      assert.equal("not found", reason)
      assert.same({}, s)
    end)

    it("refuses with no store at all, and never errors", function()
      local key, reason = Spells.add(nil, { id = 1, name = "Exorcism" })
      assert.is_nil(key)
      assert.equal("no character data yet", reason)
    end)
  end)

  describe("list()", function()
    -- Keys deliberately ANTI-correlated with names (key "Z" carries name "Aaa" and so on): sorting
    -- by key instead of by name would produce a DIFFERENT order, which is what actually catches a
    -- mutation that swaps which field the comparator reads.
    it("sorts by name, not by key and not by pairs() order", function()
      local s = {
        Z = { key = "Z", name = "Aaa" }, A = { key = "A", name = "Mmm" },
        M = { key = "M", name = "Zzz" },
      }
      local rows = Spells.list(s)
      assert.same({ "Z", "A", "M" }, { rows[1].key, rows[2].key, rows[3].key })
    end)

    -- Three tied names, so an actual sort has to run (not just "leave two elements as found") --
    -- and keys chosen so key order and insertion order disagree.
    it("breaks a name tie by key, so the order never depends on table iteration", function()
      local s = { C = { key = "C", name = "Same" }, A = { key = "A", name = "Same" },
                  B = { key = "B", name = "Same" } }
      local rows = Spells.list(s)
      assert.same({ "A", "B", "C" }, { rows[1].key, rows[2].key, rows[3].key })
    end)

    it("answers an empty list for nil, never an error", function()
      assert.same({}, Spells.list(nil))
    end)
  end)

  describe("referencedKeys()", function()
    it("counts a direct cast", function()
      local build = { entries = { { spell = "EXORCISM" }, { item = 13 } } }
      assert.same({ EXORCISM = true }, Spells.referencedKeys(build))
    end)

    it("counts a spell key named inside a plain condition", function()
      local build = { entries = { { spell = "JUDGEMENT",
                                     when = { { "buff", "SEAL_OF_MARTYRDOM" } } } } }
      local keys = Spells.referencedKeys(build)
      assert.is_true(keys.JUDGEMENT)
      assert.is_true(keys.SEAL_OF_MARTYRDOM)
    end)

    it("walks all/any/not composites for nested spell keys", function()
      local build = { entries = { { spell = "HOLY_WRATH", when = {
        { "all", { "not", { "buff", "INNER_ONE" } },
                  { "any", { "debuff", "INNER_TWO" }, { "cooldown_ready", "INNER_THREE" } } },
      } } } }
      local keys = Spells.referencedKeys(build)
      assert.is_true(keys.INNER_ONE)
      assert.is_true(keys.INNER_TWO)
      assert.is_true(keys.INNER_THREE)
    end)

    it("ignores a condition field whose keySource is not a spell (mode, weapon, power, ...)", function()
      local build = { entries = { { spell = "X", when = { { "resource", "MANA", min = 10 },
                                                            { "mode", "AoE" } } } } }
      local keys = Spells.referencedKeys(build)
      assert.same({ X = true }, keys)
    end)

    it("answers an empty table for a build with no entries, never an error", function()
      assert.same({}, Spells.referencedKeys(nil))
      assert.same({}, Spells.referencedKeys({}))
    end)

    -- A NUMBER (unlike a string) has no __index metatable in Lua, so `when[1]` on one throws
    -- outright without the type guard -- this is what actually proves the guard runs, rather than
    -- merely that a malformed build produces no keys.
    it("skips a malformed condition that is not a table, rather than erroring", function()
      local build = { entries = { { spell = "X", when = { 42 } } } }
      local keys
      assert.has_no.errors(function() keys = Spells.referencedKeys(build) end)
      assert.same({ X = true }, keys)
    end)
  end)

  describe("usedBy()", function()
    it("lists, sorted, only the rotations whose keyset contains the key", function()
      local rotations = {
        { name = "Zed", keys = { EXORCISM = true } },
        { name = "Aardvark", keys = { EXORCISM = true } },
        { name = "Neither", keys = { JUDGEMENT = true } },
      }
      assert.same({ "Aardvark", "Zed" }, Spells.usedBy(rotations, "EXORCISM"))
    end)

    it("answers an empty list when nothing references the key", function()
      assert.same({}, Spells.usedBy({ { name = "X", keys = {} } }, "EXORCISM"))
      assert.same({}, Spells.usedBy(nil, "EXORCISM"))
    end)
  end)

  describe("remove() — D56's guard", function()
    it("refuses an entry still referenced, and names every rotation that holds it", function()
      local s = { SLICE = { key = "SLICE", id = 1, name = "Slice", source = "id" } }
      local rotations = { { name = "My Rogue Build", keys = { SLICE = true } } }
      local ok, names = Spells.remove(s, "SLICE", rotations)
      assert.is_false(ok)
      assert.same({ "My Rogue Build" }, names)
      assert.is_not_nil(s.SLICE, "a refused removal must leave the registry unchanged")
    end)

    -- The literal rule: only a MANUAL entry with no reference is removable. A pack entry is
    -- derived, so it stays refused even with zero current references.
    it("refuses a pack-sourced entry even when nothing currently references it", function()
      local s = { EXORCISM = { key = "EXORCISM", id = 415073, name = "Exorcism", source = "pack" } }
      local ok = Spells.remove(s, "EXORCISM", {})
      assert.is_false(ok)
      assert.is_not_nil(s.EXORCISM)
    end)

    it("removes a manually added entry with nothing referencing it", function()
      local s = { SLICE = { key = "SLICE", id = 1, name = "Slice", source = "id" } }
      local ok = Spells.remove(s, "SLICE", {})
      assert.is_true(ok)
      assert.is_nil(s.SLICE)
    end)

    it("refuses an unknown key, leaving the store untouched", function()
      local s = { SLICE = { key = "SLICE", id = 1, name = "Slice", source = "id" } }
      local ok = Spells.remove(s, "NOPE", {})
      assert.is_false(ok)
      assert.is_not_nil(s.SLICE)
    end)
  end)

  -- AB2-D5's import path. Not `add`: `add` slugs a fresh key out of the name, and settings that
  -- arrived under "EXORCISM" attached to an entry called "EXORCISM_2" would configure nothing.
  describe("adopt() -- the import path", function()
    it("registers under the key it was given, marked as an import", function()
      local s = {}
      assert.equal("EXORCISM", Spells.adopt(s, "EXORCISM", 415073, "Exorcism"))
      assert.same({ key = "EXORCISM", id = 415073, name = "Exorcism", source = "import" }, s.EXORCISM)
    end)

    it("never overwrites an entry that is already there", function()
      local s = { EXORCISM = { key = "EXORCISM", id = 1, name = "Mine", source = "spellbook" } }
      assert.equal("EXORCISM", Spells.adopt(s, "EXORCISM", 415073, "Exorcism"))
      assert.equal("Mine", s.EXORCISM.name)
      assert.equal("spellbook", s.EXORCISM.source)
    end)

    it("refuses anything it cannot make a real entry out of", function()
      local s = {}
      assert.is_nil(Spells.adopt(nil, "EXORCISM", 1, "Exorcism"))
      assert.is_nil(Spells.adopt(s, "", 1, "Exorcism"))
      assert.is_nil(Spells.adopt(s, 7, 1, "Exorcism"))
      assert.is_nil(Spells.adopt(s, "EXORCISM", nil, "Exorcism"))
      assert.is_nil(Spells.adopt(s, "EXORCISM", 0, "Exorcism"))
      assert.is_nil(Spells.adopt(s, "EXORCISM", 1, ""))
      assert.is_nil(Spells.adopt(s, "EXORCISM", 1, nil))
      assert.same({}, s)
    end)
  end)

end)
