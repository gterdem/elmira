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
      "level", "rune", "sealLinger",
      "gcdDuration",
      "baseCooldown", "powerCost",
      "known",
      -- PE9-D6. Appended rather than slotted next to `targetExists`: this list is chronological by
      -- the block comments in Adapters/Interface.lua, and the two are genuinely different readings.
      "targetAttackable",
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
    assert.equal(0, s.level())
    assert.is_false(s.rune())
    -- nil, NOT false: Core/Gates dims a row on false, so a state that cannot answer whether a
    -- spell is known would dim every row in the build before a pack has even loaded.
    assert.is_nil(s.known())
    assert.is_nil(s.sealLinger())
    assert.equal(0, s.gcdDuration())
    assert.equal(0, s.baseCooldown())
    local amount, kind = s.powerCost()
    assert.equal(0, amount); assert.is_nil(kind)
  end)

  -- The three M1 additions exist so a docs/02 condition has something to read. Guard the fixture
  -- defects that made two older members untestable: castTime was pinned to 0, and enchant() read a
  -- table new() never created.
  it("lets fake_state carry cast times, enchants, runes, level and seal linger", function()
    local s = FakeState.new{ castTime = { CONSECRATION = 2.5 }, enchants = { [16] = "SOUL_OF_THE_EXILE" },
                             runes = { RUNE_ART_OF_WAR = true }, level = 42, sealLinger = "SEAL_OF_MARTYRDOM" }
    assert.equal(2.5, s:castTime("CONSECRATION"))
    assert.equal(0, s:castTime("JUDGEMENT"))
    assert.equal("SOUL_OF_THE_EXILE", s:enchant(16))
    assert.is_true(s:rune("RUNE_ART_OF_WAR"))
    assert.is_false(s:rune("RUNE_CRUSADER_STRIKE"))
    assert.equal(42, s:level())
    assert.equal("SEAL_OF_MARTYRDOM", s:sealLinger())
  end)

  it("lets fake_state carry base cooldowns and power costs", function()
    local s = FakeState.new{ baseCooldown = { EXORCISM = 15 },
                             powerCost = { EXORCISM = 180, HOLY_WRATH = { 400, "MANA" } } }
    assert.equal(15, s:baseCooldown("EXORCISM"))
    assert.equal(0, s:baseCooldown("JUDGEMENT"))
    local amount, kind = s:powerCost("EXORCISM")
    assert.equal(180, amount); assert.equal("MANA", kind)
    local a2, k2 = s:powerCost("HOLY_WRATH")
    assert.equal(400, a2); assert.equal("MANA", k2)
    assert.equal(0, (s:powerCost("JUDGEMENT")))
  end)

  it("defaults level to 60 and leaves seal linger empty", function()
    local s = FakeState.new{}
    assert.equal(60, s:level())
    assert.is_nil(s:sealLinger())
  end)

  -- AB4 review. Every AURA reading in Adapters/Vanilla.lua goes through one `findAura`, which
  -- returns THREE values: stacks, seconds LEFT, and how long the aura lasts in total.
  -- tests/fake_state.lua returned two for both `buff` and `debuff`, so anything reading the third
  -- saw nil in every headless test and a real number in game -- Display's "Divine Protection used
  -- -- 10s" and AB4-D1's buff-remaining texture fill are both that reading. An arity difference is
  -- invisible to every other test in the suite, because Lua silently drops the extra value.
  --
  -- Walked against Interface.CONTRACT rather than a bare list, so a member that leaves the contract
  -- makes this fail instead of quietly comparing nothing.
  it("returns the same number of values from fake_state and the live adapter, per aura member", function()
    local mock = require("tests.wow_mock")
    mock.reset()
    local Vanilla = helper.load("Elmira/Adapters/Vanilla.lua")
    mock.auras.player = { { name = "Test Aura", spellID = 900, count = 2, duration = 20,
                            expires = mock.time + 5 } }
    mock.auras.target = mock.auras.player
    local live = Vanilla.newState({ AURA = { id = 900 } }, {}, {})
    local fake = FakeState.new{ buffs = { AURA = { stacks = 2, remaining = 5, duration = 20 } },
                                debuffs = { AURA = { stacks = 2, remaining = 5, duration = 20 } } }

    local onContract = {}
    for _, name in ipairs(Interface.CONTRACT) do onContract[name] = true end
    for _, member in ipairs({ "buff", "debuff" }) do
      assert.is_true(onContract[member], member .. " is not on the State contract any more")
      local fromAdapter = select("#", live[member](live, "AURA"))
      assert.equal(3, fromAdapter, member .. ": the adapter stopped answering with three values")
      assert.equal(fromAdapter, select("#", fake[member](fake, "AURA")),
        member .. ": tests/fake_state.lua and Adapters/Vanilla.lua disagree about how many values "
        .. "an aura reading has, so the third one is untestable")
    end

    -- ...and the third value really is the DURATION, not a repeat of what is left: reading one for
    -- the other is exactly the mistake the arity check cannot catch on its own.
    local _, remaining, duration = fake:buff("AURA")
    assert.equal(5, remaining)
    assert.equal(20, duration)
    local _, liveRemaining, liveDuration = live:buff("AURA")
    assert.equal(5, liveRemaining)
    assert.equal(20, liveDuration)
  end)

  -- A capability the contract declares but no adapter answers reads as nil, which is
  -- indistinguishable from "not supported" — the guard silently disables a feature instead of
  -- erroring. Pin both directions so adding to one list and not the other fails here.
  it("has every declared capability answered by the Vanilla adapter", function()
    local Vanilla = helper.load("Elmira/Adapters/Vanilla.lua")
    local caps = Vanilla.capabilities()
    for _, name in ipairs(Interface.CAPABILITIES) do
      assert.equal("boolean", type(caps[name]), "capability not declared by adapter: " .. name)
    end
    for name in pairs(caps) do
      local known = false
      for _, declared in ipairs(Interface.CAPABILITIES) do
        if declared == name then known = true; break end
      end
      assert.is_true(known, "adapter declares a capability the contract does not list: " .. name)
    end
  end)
end)
