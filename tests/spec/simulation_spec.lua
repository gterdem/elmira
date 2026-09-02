-- tests/spec/simulation_spec.lua — Core/Simulation.lua (docs/01-ARCHITECTURE.md §3, docs/02
-- "Simulation semantics"). Headless: no WoW globals, tests/fake_state.lua stands in for the adapter.
--
-- Load order matters: Simulation reads ns.Engine and ns.Interface, so Interface, Schema and Engine
-- must be loaded into the same `ns` before Simulation.
local helper = require("tests.helper")

describe("Simulation.queue", function()
  local Schema, Simulation, FakeState, spellsCtx

  local function compileBuild(raw, ctx)
    local build, errors = Schema.compile(raw, ctx or { spells = spellsCtx })
    assert.is_not_nil(build, table.concat(Schema.errorLines(errors or {}), "; "))
    return build
  end

  before_each(function()
    helper.reset()
    helper.load("Elmira/Adapters/Interface.lua")
    Schema = helper.load("Elmira/Core/Schema.lua")
    helper.load("Elmira/Core/Engine.lua") -- registers ns.Engine, which Simulation reads; not used directly here
    Simulation = helper.load("Elmira/Core/Simulation.lua")
    FakeState = dofile("tests/fake_state.lua")
    spellsCtx = dofile("tests/fixtures/spells.lua")
  end)

  -- Five distinct, always-eligible (no `when`) entries with distinct cooldowns and no shared
  -- interference, so every slot's pick is fully hand-computable: JUDGEMENT(8s), EXORCISM(15s,
  -- cdVolatile), CRUSADER_STRIKE(6s), DIVINE_STORM(10s), HAMMER_OF_WRATH(6s). With gcd=1.5 and every
  -- castTime defaulting to 0, each slot advances t by exactly 1.5s.
  local function fiveAbilityBuild()
    return compileBuild({
      schema = 1, key = "MINI_DEPTH", name = "Five abilities", class = "PALADIN", flavor = "SoD",
      entries = {
        { spell = "JUDGEMENT" }, { spell = "EXORCISM" }, { spell = "CRUSADER_STRIKE" },
        { spell = "DIVINE_STORM" }, { spell = "HAMMER_OF_WRATH" },
      },
    })
  end

  -- -------------------------------------------------------------- depth
  describe("depth", function()
    it("depth 1 returns only the live-state pick", function()
      local queue = Simulation.queue(fiveAbilityBuild(), FakeState.new{ gcd = 1.5 }, 1)
      assert.equal(1, #queue)
      assert.equal("JUDGEMENT", queue[1].spell)
      assert.equal(0, queue[1].t)
    end)

    it("depth 3 steps through three distinct picks at 1.5s spacing", function()
      local queue = Simulation.queue(fiveAbilityBuild(), FakeState.new{ gcd = 1.5 }, 3)
      assert.equal(3, #queue)
      assert.equal("JUDGEMENT", queue[1].spell);       assert.equal(0,   queue[1].t)
      assert.equal("EXORCISM", queue[2].spell);        assert.equal(1.5, queue[2].t)
      assert.equal("CRUSADER_STRIKE", queue[3].spell); assert.equal(3.0, queue[3].t)
    end)

    it("depth 5 exhausts all five abilities in priority order", function()
      local queue = Simulation.queue(fiveAbilityBuild(), FakeState.new{ gcd = 1.5 }, 5)
      assert.equal(5, #queue)
      local expected = { "JUDGEMENT", "EXORCISM", "CRUSADER_STRIKE", "DIVINE_STORM", "HAMMER_OF_WRATH" }
      for i, spell in ipairs(expected) do assert.equal(spell, queue[i].spell) end
      assert.equal(6.0, queue[5].t)
    end)

    it("shortens rather than repeating or erroring once every entry is back on cooldown", function()
      local queue = Simulation.queue(fiveAbilityBuild(), FakeState.new{ gcd = 1.5 }, 10)
      assert.equal(5, #queue) -- depth 10 requested; only 5 distinct abilities exist to fill it
    end)

    it("defaults depth to 3 when omitted", function()
      local queue = Simulation.queue(fiveAbilityBuild(), FakeState.new{ gcd = 1.5 })
      assert.equal(3, #queue)
    end)

    it("returns an empty queue for depth 0", function()
      local queue = Simulation.queue(fiveAbilityBuild(), FakeState.new{ gcd = 1.5 }, 0)
      assert.same({}, queue)
    end)

    it("returns an empty queue when nothing is castable even at slot 1", function()
      local build = compileBuild({
        schema = 1, key = "MINI_NONE", name = "Nothing castable", class = "PALADIN", flavor = "SoD",
        entries = { { spell = "JUDGEMENT" } },
      })
      local queue = Simulation.queue(build, FakeState.new{ cooldowns = { JUDGEMENT = 5 } }, 3)
      assert.same({}, queue)
    end)
  end)

  -- -------------------------------------------------------------- cdVolatile
  it("surfaces cdVolatile on the slot from Data, per spell", function()
    local queue = Simulation.queue(fiveAbilityBuild(), FakeState.new{ gcd = 1.5 }, 3)
    assert.is_false(queue[1].cdVolatile) -- JUDGEMENT: no cdVolatile flag in the fixture
    assert.is_true(queue[2].cdVolatile)  -- EXORCISM: cdVolatile = true in tests/fixtures/spells.lua
    assert.is_false(queue[3].cdVolatile) -- CRUSADER_STRIKE
  end)

  -- -------------------------------------------------------------- time-step: cast time vs GCD
  describe("time-step: t += max(gcd, castTime)", function()
    it("lets a long cast time beat a shorter GCD", function()
      local build = compileBuild({
        schema = 1, key = "MINI_CAST", name = "Cast beats GCD", class = "PALADIN", flavor = "SoD",
        entries = { { spell = "HOLY_WRATH" }, { spell = "CRUSADER_STRIKE" } },
      })
      -- HOLY_WRATH's cast time (2.0s, from state:castTime -- the live source of truth) exceeds gcd (1.5s).
      local state = FakeState.new{ gcd = 1.5, castTime = { HOLY_WRATH = 2.0 } }
      local queue = Simulation.queue(build, state, 2)
      assert.equal("HOLY_WRATH", queue[1].spell);      assert.equal(0,   queue[1].t)
      assert.equal("CRUSADER_STRIKE", queue[2].spell); assert.equal(2.0, queue[2].t)
    end)

    it("lets the GCD beat a shorter (instant) cast time", function()
      local build = compileBuild({
        schema = 1, key = "MINI_GCD", name = "GCD beats cast", class = "PALADIN", flavor = "SoD",
        entries = { { spell = "CRUSADER_STRIKE" }, { spell = "JUDGEMENT" } },
      })
      -- CRUSADER_STRIKE is instant (no castTime override): gcd (1.5s) is what advances the clock.
      local state = FakeState.new{ gcd = 1.5 }
      local queue = Simulation.queue(build, state, 2)
      assert.equal("CRUSADER_STRIKE", queue[1].spell); assert.equal(0,   queue[1].t)
      assert.equal("JUDGEMENT", queue[2].spell);        assert.equal(1.5, queue[2].t)
    end)
  end)

  -- -------------------------------------------------------------- procs
  describe("procs are false for t>0", function()
    it("honours a proc buff at t=0 but drops it for every later slot", function()
      local build = compileBuild({
        schema = 1, key = "MINI_PROC", name = "Proc window", class = "PALADIN", flavor = "SoD",
        entries = {
          { spell = "EXORCISM", when = { {"buff", "VENGEANCE_BUFF"} }, label = "Proc" },
          { spell = "CRUSADER_STRIKE" },
        },
      })
      local state = FakeState.new{ gcd = 1.5, buffs = { VENGEANCE_BUFF = { stacks = 1 } } }
      local queue = Simulation.queue(build, state, 2)
      assert.equal("EXORCISM", queue[1].spell); assert.equal("Proc", queue[1].label); assert.equal(0, queue[1].t)
      -- t>0 now: the proc is treated as absent even though the fixture buff never actually expires,
      -- so slot 2 falls through to the baseline rather than re-suggesting Exorcism.
      assert.equal("CRUSADER_STRIKE", queue[2].spell)
      assert.is_nil(queue[2].label)
    end)
  end)

  -- -------------------------------------------------------------- resource depletion
  it("lets a spell's cost deplete the virtual resource pool and gate out a later slot", function()
    local mergedSpells = {}
    for k, v in pairs(spellsCtx) do mergedSpells[k] = v end
    -- Synthetic spell: cheap cooldown so it is never the reason a later slot is denied, isolating the
    -- resource gate. Not added to tests/fixtures/spells.lua -- inline per tests/README.md guidance.
    mergedSpells.MANA_BURN_TEST = { id = 9001, cost = { mana = 150 }, cooldown = 1 }

    local build = compileBuild({
      schema = 1, key = "MINI_RESOURCE", name = "Resource depletion", class = "PALADIN", flavor = "SoD",
      entries = {
        { spell = "MANA_BURN_TEST", when = { {"resource", "MANA", minPct = 40} }, label = "Big spender" },
        { spell = "JUDGEMENT", label = "Fallback" },
      },
    }, { spells = mergedSpells })

    -- 450/1000 = 45%, above the 40% gate. Each cast spends 150 mana in the virtual pool.
    local state = FakeState.new{ gcd = 1.5, power = { MANA = { 450, 1000 } } }
    local queue = Simulation.queue(build, state, 2)
    assert.equal(2, #queue)
    assert.equal("MANA_BURN_TEST", queue[1].spell); assert.equal(0, queue[1].t)
    -- After one cast: (450-150)/1000 = 30% < 40% -- the gate fails purely on the depleted resource
    -- (the synthetic spell's 1s cooldown never blocks it: nominal < the 1.5s step it is compared
    -- against, so cdOverride always lands exactly on the next slot boundary).
    assert.equal("JUDGEMENT", queue[2].spell); assert.equal(1.5, queue[2].t)
  end)

  -- -------------------------------------------------------------- hold
  it("does not advance simulated time for a hold entry", function()
    local build = compileBuild({
      schema = 1, key = "MINI_HOLD", name = "Hold entry", class = "PALADIN", flavor = "SoD",
      entries = {
        { spell = "AVENGING_WRATH", hold = true, label = "Burst" },
        { spell = "CRUSADER_STRIKE" },
      },
    })
    local state = FakeState.new{ gcd = 1.5 }
    local queue = Simulation.queue(build, state, 3)
    assert.equal(2, #queue) -- Avenging Wrath (180s cd) and then Crusader Strike (6s cd) are both spent
    assert.equal("AVENGING_WRATH", queue[1].spell); assert.is_true(queue[1].hold); assert.equal(0, queue[1].t)
    -- Slot 2's t is still 0: the hold entry consumed no simulated time, so the clock has not moved.
    assert.equal("CRUSADER_STRIKE", queue[2].spell); assert.equal(0, queue[2].t)
  end)

  -- -------------------------------------------------------------- item suppression
  it("suppresses an item entry for the rest of the queue once suggested", function()
    local build = compileBuild({
      schema = 1, key = "MINI_ITEM_SIM", name = "Item suppression", class = "PALADIN", flavor = "SoD",
      entries = {
        { item = 13, hold = true, when = { {"item_ready", 13} }, label = "Trinket" },
        { spell = "CRUSADER_STRIKE" },
      },
    })
    local state = FakeState.new{ gcd = 1.5, items = { [13] = { cooldown = 0 } } }
    local queue = Simulation.queue(build, state, 3)
    assert.equal(2, #queue) -- the item never reappears at slot 3 even though depth allows it
    assert.equal(13, queue[1].item); assert.is_nil(queue[1].spell)
    assert.equal("CRUSADER_STRIKE", queue[2].spell)
  end)

  -- -------------------------------------------------------------- pluggable time-step
  describe("Simulation.setTimeStep / resetTimeStep", function()
    it("honours a custom time-step function", function()
      local build = fiveAbilityBuild()
      local state = FakeState.new{ gcd = 1.5 }

      Simulation.setTimeStep(function() return 3 end)
      local queue = Simulation.queue(build, state, 3)
      Simulation.resetTimeStep()

      assert.equal("JUDGEMENT", queue[1].spell);       assert.equal(0, queue[1].t)
      assert.equal("EXORCISM", queue[2].spell);        assert.equal(3, queue[2].t)
      assert.equal("CRUSADER_STRIKE", queue[3].spell); assert.equal(6, queue[3].t)
    end)

    it("resetTimeStep restores the default gcd/castTime stepping", function()
      local build = fiveAbilityBuild()
      local state = FakeState.new{ gcd = 1.5 }

      Simulation.setTimeStep(function() return 3 end)
      Simulation.queue(build, state, 2) -- exercise the custom step once
      Simulation.resetTimeStep()

      local queue = Simulation.queue(build, state, 3)
      assert.equal(0,   queue[1].t)
      assert.equal(1.5, queue[2].t)
      assert.equal(3.0, queue[3].t)
    end)

    -- Simulation.lua's own comment documents the contract as `fn(entry, state, t) -> seconds`
    -- (Core/Simulation.lua: "Contract: fn(entry, state, t) -> seconds to advance."), but the call
    -- site only ever passes two arguments. This pins down the ACTUAL behaviour so a regression in
    -- either direction is caught; see the bug note in the final report.
    it("invokes the time-step function with the documented (entry, state, t) arguments", function()
      local build = compileBuild({
        schema = 1, key = "MINI_ARGS", name = "Step fn arity", class = "PALADIN", flavor = "SoD",
        entries = { { spell = "JUDGEMENT" }, { spell = "CRUSADER_STRIKE" } },
      })
      local state = FakeState.new{ gcd = 1.5 }
      local seenArgCount, seenEntrySpell, seenState, offsets
      offsets = {}
      Simulation.setTimeStep(function(entry, st, t, ...)
        offsets[#offsets + 1] = t
        if seenArgCount == nil then -- only the first call: depth 3 triggers applyCast repeatedly
          seenArgCount = 3 + select("#", ...)
          seenEntrySpell = entry and entry.spell
          seenState = st
        end
        return 1
      end)
      -- depth 1 would return before ever calling applyCast (and so the time-step fn).
      Simulation.queue(build, state, 3)
      Simulation.resetTimeStep()
      assert.equal("JUDGEMENT", seenEntrySpell)
      assert.equal(3, seenArgCount)
      assert.is_function(seenState.cooldown) -- the virtual state, not the raw fixture table
      -- t is the offset into the simulated window, so it advances by the step this fn returns.
      assert.equal(0, offsets[1])
      assert.equal(1, offsets[2])
    end)
  end)

  -- -------------------------------------------------------------- live cooldown/cost precedence
  -- docs/01 §2: "Data/ may supply a fallback; the client wins." Simulation.applyCast reads
  -- state:baseCooldown()/state:powerCost() first and only falls back to the Data pack's
  -- `cooldown`/`cost` when the state has nothing to say (0 / no kind).
  describe("live state takes precedence over the Data pack for cooldown and cost", function()
    it("uses state:baseCooldown() instead of the Data pack's cooldown when the state provides one", function()
      local build = compileBuild({
        schema = 1, key = "MINI_BASECD", name = "Live cooldown wins", class = "PALADIN", flavor = "SoD",
        entries = { { spell = "JUDGEMENT" }, { spell = "CRUSADER_STRIKE" } },
      })
      -- JUDGEMENT's Data cooldown is 8s; the live baseCooldown says 3s (e.g. a rune shortened it).
      local state = FakeState.new{ gcd = 1.5, baseCooldown = { JUDGEMENT = 3 } }
      local queue = Simulation.queue(build, state, 3)
      assert.equal("JUDGEMENT", queue[1].spell);       assert.equal(0,   queue[1].t)
      assert.equal("CRUSADER_STRIKE", queue[2].spell); assert.equal(1.5, queue[2].t)
      -- At t=3.0, JUDGEMENT's live 3s cooldown (not the Data pack's 8s) has elapsed, so it is back.
      assert.equal("JUDGEMENT", queue[3].spell);       assert.equal(3.0, queue[3].t)
    end)

    it("uses state:powerCost() instead of the Data pack's cost when the state provides one", function()
      local build = compileBuild({
        schema = 1, key = "MINI_LIVECOST", name = "Live cost wins", class = "PALADIN", flavor = "SoD",
        entries = { { spell = "CONSECRATION", when = { {"resource", "MANA", minPct = 40} } } },
      })
      -- CONSECRATION's Data cost is 300 mana; the live powerCost says only 50 (e.g. a rune discount).
      -- A short live baseCooldown keeps the cooldown from ever being the reason a slot is denied, so
      -- only the resource gate can explain the result.
      local state = FakeState.new{
        gcd = 1.5, power = { MANA = { 450, 1000 } },
        baseCooldown = { CONSECRATION = 1 }, powerCost = { CONSECRATION = 50 },
      }
      local queue = Simulation.queue(build, state, 3)
      -- If the Data pack's 300-mana cost were used instead, slot 2's pool would already read
      -- (450-300)/1000 = 15% < 40% and the queue would stop at 1 slot instead of 2.
      assert.equal(2, #queue)
      assert.equal("CONSECRATION", queue[1].spell)
      assert.equal("CONSECRATION", queue[2].spell)
    end)
  end)
  -- Both found by the M2 acceptance run on a live character; both invisible to a spec that hands the
  -- state a nonzero `gcd`, which is what every earlier fixture did (docs/07 §9.15).
  describe("live-character defects found at M2 acceptance", function()
    it("advances the clock by the GCD DURATION, not the remaining GCD", function()
      -- Idle character: no global is running, so gcd() is 0 but a cast still costs 1.5s.
      local state = FakeState.new{ gcd = 0, gcdDuration = 1.5,
                                   usable = { EXORCISM = true, CONSECRATION = true } }
      local build = compileBuild({
        schema = 1, key = "T", name = "T", class = "PALADIN",
        entries = { { spell = "EXORCISM", when = {} }, { spell = "CONSECRATION", when = {} } },
      })
      local q = Simulation.queue(build, state, 2)
      assert.equal(2, #q)
      assert.is_true(q[2].t > 0, "slot 2 must be later than slot 1; t=0 means the clock never moved")
    end)

    it("does not suggest the same seal in every slot", function()
      local state = FakeState.new{ gcd = 0, gcdDuration = 1.5, seal = nil,
                                   usable = { SEAL_OF_MARTYRDOM = true, EXORCISM = true } }
      local build = compileBuild({
        schema = 1, key = "T", name = "T", class = "PALADIN",
        entries = { { spell = "SEAL_OF_MARTYRDOM", when = { { "no_seal" } } },
                    { spell = "EXORCISM", when = {} } },
      })
      local q = Simulation.queue(build, state, 3)
      assert.equal("SEAL_OF_MARTYRDOM", q[1].spell)
      assert.is_not.equal("SEAL_OF_MARTYRDOM", q[2].spell,
        "casting the seal must satisfy no_seal for the following slots")
    end)
  end)
end)

-- M1 audit findings 1-3: every one of these used to fail silently or confusingly. They are grouped
-- here because they share a shape — the queue produces nothing, or the wrong thing, without saying
-- so. That is what cost this project a full in-game verification round at M0.
describe("Simulation dependency and normalisation guards", function()
  local Schema, Simulation, FakeState, logged

  local function loadAll(opts)
    opts = opts or {}
    helper.reset()
    local ns = helper.ns()
    logged = {}
    ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
    if not opts.withoutInterface then helper.load("Elmira/Adapters/Interface.lua") end
    Schema = helper.load("Elmira/Core/Schema.lua")
    if not opts.withoutEngine then helper.load("Elmira/Core/Engine.lua") end
    Simulation = helper.load("Elmira/Core/Simulation.lua")
    Simulation.resetWarnings()
    FakeState = dofile("tests/fake_state.lua")
  end

  local function miniBuild()
    return Schema.compile({ schema = 1, key = "G", name = "G", class = "PALADIN",
      entries = { { spell = "JUDGEMENT" }, { spell = "CRUSADER_STRIKE" } } },
      { spells = { JUDGEMENT = { id = 1, cooldown = 8 }, CRUSADER_STRIKE = { id = 2, cooldown = 6 } } })
  end

  it("says so when Core/Engine.lua never loaded, instead of returning a silent empty queue", function()
    loadAll{ withoutEngine = true }
    local q = Simulation.queue(miniBuild(), FakeState.new{ gcd = 1.5 }, 3)
    assert.same({}, q)
    assert.equal(1, #logged)
    assert.matches("Core/Engine%.lua", logged[1])
  end)

  it("says so when Adapters/Interface.lua never loaded", function()
    loadAll{ withoutInterface = true }
    local q = Simulation.queue(miniBuild(), FakeState.new{ gcd = 1.5 }, 3)
    assert.same({}, q)
    assert.equal(1, #logged)
    assert.matches("Adapters/Interface%.lua", logged[1])
  end)

  it("warns once, not once per frame — the display loop runs this at up to 10 Hz", function()
    loadAll{ withoutEngine = true }
    local build, state = miniBuild(), FakeState.new{ gcd = 1.5 }
    for _ = 1, 25 do Simulation.queue(build, state, 3) end
    assert.equal(1, #logged)
  end)

  it("stays quiet when everything is loaded and the queue is legitimately empty", function()
    loadAll()
    local build = Schema.compile({ schema = 1, key = "E", name = "E", class = "PALADIN",
      entries = { { spell = "JUDGEMENT" } } }, { spells = { JUDGEMENT = { id = 1 } } })
    local state = FakeState.new{ gcd = 1.5, usable = { JUDGEMENT = false } }
    assert.same({}, Simulation.queue(build, state, 3))
    assert.equal(0, #logged) -- "nothing castable" is not a wiring problem
  end)

  it("upper-cases the adapter's power kind so the virtual pool actually drains", function()
    loadAll()
    -- Adapter answers "Mana"; the condition asks for "MANA". Un-normalised, spent["Mana"] accumulates
    -- against a pool nothing reads, and the gate never closes.
    local build = Schema.compile({ schema = 1, key = "P", name = "P", class = "PALADIN",
      entries = { { spell = "CONSECRATION", when = { { "resource", "MANA", min = 300 } } } } },
      { spells = { CONSECRATION = { id = 1 } } })
    local state = FakeState.new{ gcd = 1.5, power = { MANA = { 650, 2000 } },
                                 powerCost = { CONSECRATION = { 300, "Mana" } } }
    -- 650 -> 350 -> 50, so the third pick must fail the >= 300 gate.
    assert.equal(2, #Simulation.queue(build, state, 4))
  end)


  -- M3b. The virtual state models cooldowns and resources; before this it delegated swing timing
  -- straight through, so every projected slot asked "how long until the swing" and got the answer
  -- for RIGHT NOW. Same shape as the cooldown that did not tick down (docs/07 §9.15).
  describe("swing timing advances with the simulated clock", function()
    it("brings the swing closer as simulated time passes", function()
      local state = FakeState.new{ gcd = 1.5, gcdDuration = 1.5, swing = 3.0 }
      local v = Simulation.newVirtualState(state)
      assert.equal(3.0, v:swingRemaining())
      v.elapsed = 1.5
      assert.equal(1.5, v:swingRemaining())
    end)

    it("answers nil once the simulated clock passes the swing, rather than a negative or a guess", function()
      -- The contract carries no swing PERIOD, so the next swing's time is genuinely unknown.
      local state = FakeState.new{ swing = 1.0 }
      local v = Simulation.newVirtualState(state)
      v.elapsed = 2.0
      assert.is_nil(v:swingRemaining())
    end)

    it("stays nil when the real state has no swing data at all", function()
      local v = Simulation.newVirtualState(FakeState.new{})
      assert.is_nil(v:swingRemaining())
      v.elapsed = 1.0
      assert.is_nil(v:swingRemaining())
    end)
  end)
end)
