-- tests/spec/paladin_exodin_filler_spec.lua — the 2026-09-02 Exodin change set, for the assertions
-- tests/fixtures/gear_scenarios.lua's exact-top-3-spell-array shape cannot express:
--   * absence ("must NOT be in the top 3", "must not be slot 1 ahead of X") -- an exact-array match
--     against a queue that legitimately omits the spell already proves absence, but the task calls
--     out point 2 specifically as "the one most likely to be wrong", so it gets a direct assertion
--     here too, not just an inference from a fixture array;
--   * WHICH entry fired, via `label` -- Simulation.queue's slot carries the compiled entry's label,
--     but gear_matrix_spec.lua's queueToNames() only reads `spell`. Two different entries can suggest
--     the same spell key (three of PALADIN_EXODIN's sixteen entries are all JUDGEMENT), so a spell-only
--     comparison cannot tell "the bottom-of-list filler fired" apart from "the Seal-expiring gate
--     fired" apart from "nothing fired and the filler just happens to share a name with what did".
--     That gap matters here specifically: with the filler present, JUDGEMENT is reachable from nearly
--     any seal-up state, so a spell-only check stops being able to tell a working "Seal expiring" gate
--     from a broken one it silently duplicates through position 13 (point 8's "wrote the window in the
--     wrong direction" is exactly this shape);
--   * a direct Engine.eligible/Engine.pick check against the REAL (unsimulated) state -- point 4's
--     "the filler must not fire" is about the live decision, not about what a later, re-sealed virtual
--     slot may legitimately reach (Simulation's virtual state models a cast seal as up again once it
--     is the entry actually chosen -- see Core/Simulation.lua's `v:seal()` -- so Judgement DOES
--     legitimately reappear a couple of slots after "Seal up" in a full queue; that is correct
--     re-seal behaviour, not the thing point 4 is worried about);
--   * an equality diff between the real build and the same build with one entry stripped, which is
--     the most direct way to prove a promotion is an inert no-op rather than trusting a hand-derived
--     array to have gotten the same non-effect right by coincidence.
--
-- Uses the REAL shipped Elmira/Classes/Paladin.lua data via helper.classPack, which calls the
-- registered thunk and returns the pack exactly as Core/Init.lua receives it (ADR-0011).
local helper = require("tests.helper")

describe("PALADIN_EXODIN: 2026-09-02 filler/promotion contract", function()
  local Schema, Engine, Simulation, FakeState, pack, build

  local FULL_GEAR = { PALADIN_T3_REDEMPTION = 4, PALADIN_T35_INQUISITION = 2 }
  local FULL_RUNES = { RUNE_ART_OF_WAR = true, RUNE_CRUSADER_STRIKE = true, RUNE_DIVINE_STORM = true, RUNE_PURIFYING_POWER = true }

  local function stateOf(opts)
    opts.bonusDefs = opts.bonusDefs or pack.bonuses
    opts.gcd = opts.gcd or 1.5
    return FakeState.new(opts)
  end

  local function names(queue)
    local out = {}
    for i, slot in ipairs(queue) do out[i] = slot.spell or ("item:" .. tostring(slot.item)) end
    return out
  end

  before_each(function()
    helper.reset()
    helper.load("Elmira/Adapters/Interface.lua")
    Schema = helper.load("Elmira/Core/Schema.lua")
    Engine = helper.load("Elmira/Core/Engine.lua")
    Simulation = helper.load("Elmira/Core/Simulation.lua")
    FakeState = dofile("tests/fake_state.lua")

    pack = helper.classPack("Paladin")
    local compiled, errors = Schema.compile(pack.builds.PALADIN_EXODIN,
      { spells = pack.spells, sets = pack.sets, bonuses = pack.bonuses })
    assert.is_not_nil(compiled, table.concat(Schema.errorLines(errors or {}), "; "))
    build = compiled
  end)

  -- ---------------------------------------------------------------- point 2: self-throttling
  it("point 2: does not put Judgement in the top 3 when fully geared and nothing is on cooldown", function()
    local state = stateOf{ sets = FULL_GEAR, runes = FULL_RUNES,
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } } }
    local queue = Simulation.queue(build, state, 3)
    for i, slot in ipairs(queue) do
      assert.is_not.equal("JUDGEMENT", slot.spell, "slot " .. i .. " should not be Judgement")
    end
    -- The four abilities the contract says outrank it: needs depth 5 to actually see all four ahead
    -- of Judgement (top-3 alone only shows the first three of them).
    local deep = Simulation.queue(build, state, 5)
    assert.same({ "EXORCISM", "CRUSADER_STRIKE", "HOLY_WRATH", "DIVINE_STORM", "JUDGEMENT" }, names(deep))
  end)

  -- ---------------------------------------------------------------- point 3: idle-global promotion
  it("point 3: promotes Judgement to slot 1, via the bottom-of-list filler specifically, when the core buttons are all on cooldown", function()
    local state = stateOf{ sets = FULL_GEAR, runes = FULL_RUNES,
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      cooldowns = { EXORCISM = 10, CRUSADER_STRIKE = 10, DIVINE_STORM = 10, HOLY_WRATH = 10 } }
    local queue = Simulation.queue(build, state, 3)
    assert.equal("JUDGEMENT", queue[1].spell)
    assert.equal("Filler (nothing else ready)", queue[1].label)
  end)

  -- ---------------------------------------------------------------- point 4: seal down
  it("point 4: the filler does not fire while the seal is down, and Seal of Martyrdom leads instead", function()
    local state = stateOf{ sets = {},
      usable = { CRUSADER_STRIKE = false, DIVINE_STORM = false, AVENGING_WRATH = false, AURA_MASTERY = false },
      seal = nil }

    -- Direct: the filler entry itself must be ineligible against the live (unsimulated) state.
    local filler
    for _, entry in ipairs(build.entries) do
      if entry.spell == "JUDGEMENT" and entry.label == "Filler (nothing else ready)" then filler = entry end
    end
    assert.is_not_nil(filler, "no Judgement filler entry found in PALADIN_EXODIN")
    assert.is_false(Engine.eligible(filler, state, 0))

    -- And the live pick (and slot 1 of the queue) is the reseal, not Judgement.
    local first = Engine.pick(build, state, 0)
    assert.equal("SEAL_OF_MARTYRDOM", first.spell)
    local queue = Simulation.queue(build, state, 1)
    assert.equal("SEAL_OF_MARTYRDOM", queue[1].spell)
  end)

  -- ---------------------------------------------------------------- point 6: AoE promotion reachable
  it("point 6: Consecration is reachable via the AoE (3+ targets) promotion once enemies>=3 and mana>=40%", function()
    local state = stateOf{ sets = {},
      usable = { CRUSADER_STRIKE = false, DIVINE_STORM = false, AVENGING_WRATH = false, AURA_MASTERY = false },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      enemies = 3, power = { MANA = { 1000, 1000 } }, cooldowns = { EXORCISM = 10 } }
    local queue = Simulation.queue(build, state, 3)
    assert.equal("CONSECRATION", queue[1].spell)
    assert.equal("AoE (3+ targets)", queue[1].label)
  end)

  -- ---------------------------------------------------------------- point 7: single-target no-op
  it("point 7: the AoE (3+ targets) promotion is a no-op at 1 enemy (protects existing single-target users)", function()
    local opts = { sets = {},
      usable = { CRUSADER_STRIKE = false, DIVINE_STORM = false, AVENGING_WRATH = false, AURA_MASTERY = false },
      seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 25 } },
      power = { MANA = { 1000, 1000 } }, cooldowns = { EXORCISM = 10 } }

    local strippedEntries = {}
    for _, entry in ipairs(build.entries) do
      if not (entry.spell == "CONSECRATION" and entry.label == "AoE (3+ targets)") then
        strippedEntries[#strippedEntries + 1] = entry
      end
    end
    assert.equal(#build.entries - 1, #strippedEntries)
    local strippedBuild = { entries = strippedEntries }

    -- enemies defaults to 1 in fake_state.lua when not given -- the live client's own hardcoded case.
    local withPromotion = Simulation.queue(build, stateOf(opts), 6)
    local withoutPromotion = Simulation.queue(strippedBuild, stateOf(opts), 6)
    assert.same(names(withoutPromotion), names(withPromotion))
  end)

  -- ---------------------------------------------------------------- point 8: window still promotes
  it("point 8: Seal expiring still promotes Judgement to slot 1 (via that entry specifically) at 1.0s remaining", function()
    local state = stateOf{ sets = {}, seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 1.0 } } }
    local queue = Simulation.queue(build, state, 1)
    assert.equal("JUDGEMENT", queue[1].spell)
    assert.equal("Seal expiring", queue[1].label)
  end)

  -- ---------------------------------------------------------------- point 9: window boundary
  it("point 9: at 2.0s remaining (outside the 1.5s window) Judgement is not slot 1 ahead of Exorcism", function()
    local state = stateOf{ sets = {}, seal = "SEAL_OF_MARTYRDOM", buffs = { SEAL_OF_MARTYRDOM = { remaining = 2.0 } } }
    local queue = Simulation.queue(build, state, 3)
    assert.equal("EXORCISM", queue[1].spell)
    for i, slot in ipairs(queue) do
      assert.is_not.equal("JUDGEMENT", slot.spell, "slot " .. i .. " should not be Judgement")
    end
  end)
end)
