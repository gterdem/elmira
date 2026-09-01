local helper = require("tests.helper")

describe("Adapters.Interface (State contract)", function()
  local Interface, FakeState

  before_each(function()
    helper.reset()
    Interface = helper.load("Elmira/Adapters/Interface.lua")
    FakeState = dofile("tests/fake_state.lua")
  end)

  -- Literal, per docs/01-ARCHITECTURE.md §2 — a doc/code drift on this list fails here, not silently.
  it("matches the docs/01 §2 contract exactly", function()
    local expected = {
      "now", "gcd", "cooldown", "usable", "castTime", "buff", "debuff", "power",
      "targetType", "targetHPPct", "targetExists", "inCombat", "moving", "weapon", "setCount",
      "enchant", "bonus", "itemCooldown", "itemUsable", "seal", "swingRemaining", "ttd",
      "enemies", "mode", "latency",
    }
    assert.same(expected, Interface.CONTRACT)
  end)

  it("validates the existing tests/fake_state.lua as contract-complete", function()
    local state = FakeState.new{}
    local ok, missing = Interface.validate(state)
    assert.is_true(ok, table.concat(missing or {}, ", "))
  end)

  it("reports every member missing for an empty table", function()
    local ok, missing = Interface.validate({})
    assert.is_false(ok)
    assert.equal(#Interface.CONTRACT, #missing)
  end)

  it("reports every member missing for a non-table", function()
    local ok, missing = Interface.validate(nil)
    assert.is_false(ok)
    assert.equal(#Interface.CONTRACT, #missing)
  end)

  it("newNullState() validates as contract-complete", function()
    local ok, missing = Interface.validate(Interface.newNullState())
    assert.is_true(ok, table.concat(missing or {}, ", "))
  end)

  it("newNullState() returns documented safe zeros", function()
    local s = Interface.newNullState()
    assert.equal(0, s.now())
    assert.equal(0, s.gcd())
    assert.is_false(s.usable())
    assert.is_nil(s.buff())
    local cur, max = s.power()
    assert.equal(0, cur); assert.equal(0, max)
    assert.equal("Single", s.mode())
    assert.equal(1, s.enemies())
  end)
end)
