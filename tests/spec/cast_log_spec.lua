-- tests/spec/cast_log_spec.lua — the cast log (Contract C): ns.castRow (Core/Slash.lua),
-- Recorder.cast/casts/castCount/MAX_CASTS/payload/clear/reset (Core/Recorder.lua), and
-- ns.spellKeyByID's deterministic id-collision resolution (Core/Slash.lua).
--
-- Written from the contract text, not from the implementation: castRow is pure and returns one row
-- or nil; an unrecognised spellID still produces a row (unrecognised is data, not a reason to drop
-- it); the cast log is a ring exactly like marks, capped at MAX_CASTS, dropping the OLDEST on
-- overflow; and two keys sharing one spell id must resolve the same way no matter what order pairs()
-- happens to visit them in.
local helper = require("tests.helper")

describe("ns.castRow (Contract C)", function()
  local ns

  before_each(function()
    helper.reset()
    helper.load("Elmira/Core/Slash.lua")
    ns = helper.ns()
  end)

  it("is pure and returns nil when spellID is not a number", function()
    assert.is_nil(ns.castRow(10, "12345", {}, nil))
    assert.is_nil(ns.castRow(10, nil, {}, nil))
    assert.is_nil(ns.castRow(10, {}, {}, nil))
    assert.is_nil(ns.castRow(10, true, {}, nil))
  end)

  it("returns at/id/spell for a known spellID with no suggestion", function()
    local keyMap = { [12345] = "EXORCISM" }
    local row = ns.castRow(10, 12345, keyMap, nil)
    assert.equal(10, row.at)
    assert.equal(12345, row.id)
    assert.equal("EXORCISM", row.spell)
  end)

  it("leaves suggested and age absent (nil) when there is no suggestion", function()
    local row = ns.castRow(10, 12345, { [12345] = "EXORCISM" }, nil)
    assert.is_nil(row.suggested)
    assert.is_nil(row.age)
  end)

  it("still returns a row, with spell = nil, for a spellID the keyMap does not recognise", function()
    -- An unrecognised cast is data, not a reason to drop the row.
    local row = ns.castRow(10, 99999, { [12345] = "EXORCISM" }, nil)
    assert.is_not_nil(row)
    assert.equal(99999, row.id)
    assert.is_nil(row.spell)
  end)

  it("also returns a row with spell = nil when no keyMap is given at all", function()
    local row = ns.castRow(10, 99999, nil, nil)
    assert.is_not_nil(row)
    assert.is_nil(row.spell)
  end)

  it("adds `suggested` (the top pick) and `age` (staleness) when a suggestion is given", function()
    local suggestion = { at = 5, top = "EXORCISM" }
    local row = ns.castRow(7, 12345, { [12345] = "EXORCISM" }, suggestion)
    assert.equal("EXORCISM", row.suggested)
    assert.equal(2, row.age)
  end)

  it("rounds `age` to 2 decimals", function()
    local suggestion = { at = 1.111, top = "EXORCISM" }
    local row = ns.castRow(3.333, 12345, { [12345] = "EXORCISM" }, suggestion)
    assert.equal(2.22, row.age)
  end)

  it("rounds `at` to 2 decimals, e.g. 2.6900000000023 -> 2.69", function()
    local row = ns.castRow(2.6900000000023, 12345, {}, nil)
    assert.equal(2.69, row.at)
  end)
end)

describe("Recorder cast log (Contract C)", function()
  local Recorder

  before_each(function()
    helper.reset()
    Recorder = helper.load("Elmira/Core/Recorder.lua")
    Recorder.reset()
  end)

  it("MAX_MARKS is 120", function()
    assert.equal(120, Recorder.MAX_MARKS)
  end)

  it("Recorder.cast returns false when not recording", function()
    assert.is_false(Recorder.cast({ id = 1 }))
    assert.equal(0, Recorder.castCount())
  end)

  it("Recorder.cast returns false for a non-table row", function()
    Recorder.start(0)
    assert.is_false(Recorder.cast("not a table"))
    assert.is_false(Recorder.cast(nil))
    assert.is_false(Recorder.cast(42))
    assert.equal(0, Recorder.castCount())
  end)

  it("appends accepted rows and returns them in order via Recorder.casts()", function()
    Recorder.start(0)
    assert.is_true(Recorder.cast({ id = 1, spell = "A" }))
    assert.is_true(Recorder.cast({ id = 2, spell = "B" }))
    assert.is_true(Recorder.cast({ id = 3, spell = "C" }))
    local casts = Recorder.casts()
    assert.same({ "A", "B", "C" }, { casts[1].spell, casts[2].spell, casts[3].spell })
  end)

  it("Recorder.castCount() matches the number of accepted rows", function()
    Recorder.start(0)
    Recorder.cast({ id = 1 })
    Recorder.cast({ id = 2 })
    assert.equal(2, Recorder.castCount())
  end)

  it("caps the cast log at MAX_CASTS, dropping the OLDEST on overflow", function()
    Recorder.start(0)
    for i = 1, Recorder.MAX_CASTS + 3 do Recorder.cast({ tag = "c" .. i }) end
    assert.equal(Recorder.MAX_CASTS, Recorder.castCount())
    assert.equal("c4", Recorder.casts()[1].tag, "the first 3 pushed out the oldest 3")
    assert.equal(3, Recorder.payload().castsDropped)
  end)

  it("Recorder.payload() includes casts and castsDropped", function()
    Recorder.start(0)
    Recorder.cast({ id = 1 })
    local payload = Recorder.payload()
    assert.is_table(payload.casts)
    assert.equal(1, #payload.casts)
    assert.equal(0, payload.castsDropped)
  end)

  it("Recorder.clear() empties the cast log", function()
    Recorder.start(0)
    Recorder.cast({ id = 1 })
    Recorder.clear()
    assert.equal(0, Recorder.castCount())
    assert.same({}, Recorder.casts())
  end)

  it("Recorder.reset() empties the cast log", function()
    Recorder.start(0)
    Recorder.cast({ id = 1 })
    Recorder.reset()
    assert.equal(0, Recorder.castCount())
    assert.is_false(Recorder.isRecording())
  end)
end)

describe("ns.spellKeyByID (Contract C)", function()
  local ns

  before_each(function()
    helper.reset()
    helper.load("Elmira/Core/Slash.lua")
    ns = helper.ns()
  end)

  -- Three deliberate collisions, each exercising a different branch of the tie-break rule:
  --   id 100: a RUNE_-prefixed key vs a plain key -> the plain (non-RUNE_) key must win.
  --   id 200: two plain keys -> the lexicographically smaller wins.
  --   id 300: two RUNE_-prefixed keys -> the lexicographically smaller wins.
  local function collidingPack()
    return {
      spells = {
        RUNE_FOO = { id = 100 },
        BAR = { id = 100 },
        BETA = { id = 200 },
        ALPHA = { id = 200 },
        RUNE_BETA = { id = 300 },
        RUNE_ALPHA = { id = 300 },
        SOLO = { id = 400 }, -- no collision, sanity check
      },
    }
  end

  it("a non-RUNE_ key beats a RUNE_-prefixed key sharing the same id", function()
    local map = ns.spellKeyByID(collidingPack())
    assert.equal("BAR", map[100])
  end)

  it("between two non-RUNE_ keys, the lexicographically smaller wins", function()
    local map = ns.spellKeyByID(collidingPack())
    assert.equal("ALPHA", map[200])
  end)

  it("between two RUNE_-prefixed keys, the lexicographically smaller wins", function()
    local map = ns.spellKeyByID(collidingPack())
    assert.equal("RUNE_ALPHA", map[300])
  end)

  it("leaves a non-colliding id mapped to its one key", function()
    local map = ns.spellKeyByID(collidingPack())
    assert.equal("SOLO", map[400])
  end)

  -- Repeated construction: two structurally-independent pack tables carrying the same collisions
  -- (built via separate literals, not the same table object) must resolve identically. If resolution
  -- depended on pairs() traversal order rather than the key names themselves, two independently-built
  -- tables would have no guarantee of agreeing.
  it("is stable across repeated, independent construction", function()
    local mapA = ns.spellKeyByID(collidingPack())
    local mapB = ns.spellKeyByID(collidingPack())
    assert.same(mapA, mapB)
    assert.equal("BAR", mapA[100])
    assert.equal("BAR", mapB[100])
  end)

  it("is stable across repeated calls on the very same pack table", function()
    local pack = collidingPack()
    local mapA = ns.spellKeyByID(pack)
    local mapB = ns.spellKeyByID(pack)
    assert.same(mapA, mapB)
  end)
end)
