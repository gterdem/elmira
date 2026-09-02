-- tests/spec/queue_snapshot_failed_spec.lua — ns.queueSnapshot(pack, depth) entries[i].failed
-- (Core/Slash.lua + Core/Schema.lua), Contract B.
--
-- Written from the contract text: a compiled entry's `failed` is a list of short labels naming the
-- conditions that REJECTED it, nil when the entry passed, and the two never disagree with `passes`.
-- Labels for a nested condition render their children, e.g. "any(target_type:Undead,rune:RUNE_..)".
-- This drives the REAL shipped Elmira_Paladin PALADIN_EXODIN build (not a fixture copy), because the
-- contract explicitly asks for the passes/failed invariant to be checked "against the real shipped
-- Exodin build across a few different fake states".
local helper = require("tests.helper")
local FakeState = dofile("tests/fake_state.lua")

-- Same loading pattern as tests/spec/gear_matrix_spec.lua's loadClassPack: each class pack gets its
-- own private ns, mirroring how the WoW client hands a LoadOnDemand addon its own namespace. Trimmed
-- to just what PALADIN_EXODIN's conditions reference (Spells/Sets/Souls) — no Advice/Catalog needed.
local function loadPaladinData()
  local dataNs = { Data = { SoD = {} } }
  for _, file in ipairs({ "Spells.lua", "Sets.lua", "Souls.lua" }) do
    local chunk = loadfile("Elmira_Paladin/Data/" .. file)
    if chunk then chunk("Elmira_Paladin", dataNs) end
  end
  local chunk = assert(loadfile("Elmira_Paladin/Data/Builds/Paladin_Exodin.lua"))
  chunk("Elmira_Paladin", dataNs)
  return dataNs.Data.SoD
end

describe("ns.queueSnapshot entries[i].failed (Contract B)", function()
  local ns, pack

  before_each(function()
    helper.reset()
    -- Schema and Simulation are both real; Slash.lua's queueSnapshot needs both present to run at
    -- all (`pack and pack.builds and ns.Schema and ns.Simulation and ns.API`). Engine/Interface are
    -- deliberately NOT loaded: the entries/failed verdict loop calls each compiled condition's own
    -- closure directly and never touches Simulation.queue's Engine dependency, so this is a true
    -- test of Schema.compile's per-condition `conditions` list, not of the simulated queue rows.
    helper.load("Elmira/Core/Schema.lua")
    helper.load("Elmira/Core/Simulation.lua")
    helper.load("Elmira/Core/Slash.lua") -- ns.queueSnapshot itself lives here
    ns = helper.ns()
    ns.API = { GetState = function() return ns._state end }

    -- The pack table handed to Core is the lowercase shape Elmira_Paladin/Register.lua builds, per
    -- the harness note, NOT the capitalised Data.SoD keys the raw Data/ files export.
    local data = loadPaladinData()
    pack = {
      spells = data.Spells, sets = data.Sets, souls = data.Souls, bonuses = data.Bonuses,
      builds = { PALADIN_EXODIN = data.Builds.PALADIN_EXODIN },
    }
  end)

  local function snapshotWith(state)
    ns._state = state
    return ns.queueSnapshot(pack, 5).PALADIN_EXODIN
  end

  -- Entry indices below are PALADIN_EXODIN's entries in the order Paladin_Exodin.lua lists them:
  --   1  SEAL_OF_MARTYRDOM   when={no_seal}
  --   2  AVENGING_WRATH      when={buff:VENGEANCE_BUFF, any(buff:HOLY_POWER_BUFF, not(set:PALADIN_T35_INQUISITION))}
  --   9  HOLY_WRATH          when={bonus:HOLY_WRATH_INSTANT, any(target_type:Undead/Demon, rune:RUNE_PURIFYING_POWER)}
  --  13  item 13 (Trinket)   when={item_ready:13}

  it("gives a passing entry `failed = nil`, not an empty table", function()
    -- No seal active, so entry 1's `no_seal` condition passes.
    local snap = snapshotWith(FakeState.new{ bonusDefs = pack.bonuses })
    local entry1 = snap.entries[1]
    assert.is_true(entry1.passes)
    assert.is_nil(entry1.failed, "a passing entry must record `failed = nil`, never an empty table")
  end)

  it("labels a bare boolean condition by its kind alone, e.g. `no_seal`", function()
    -- Seal IS active, so `no_seal` rejects entry 1.
    local snap = snapshotWith(FakeState.new{ seal = "SEAL_OF_MARTYRDOM", bonusDefs = pack.bonuses })
    local entry1 = snap.entries[1]
    assert.is_false(entry1.passes)
    assert.same({ "no_seal" }, entry1.failed)
  end)

  it("labels an item condition with its slot number, e.g. `item_ready:13`", function()
    -- No item in slot 13, so item_ready fails.
    -- Located by its item slot, NOT by its index in the list. This asserted `entries[13]` and broke
    -- the moment two filler entries were inserted above it -- a positional lookup makes every build
    -- reorder look like a regression in a test that is not about ordering at all.
    local snap = snapshotWith(FakeState.new{ bonusDefs = pack.bonuses })
    local trinket
    for _, e in ipairs(snap.entries) do
      if e.item == 13 then trinket = e break end
    end
    assert.is_not_nil(trinket, "no entry for trinket slot 13")
    assert.is_false(trinket.passes)
    assert.same({ "item_ready:13" }, trinket.failed)
  end)

  it("lists two separately-failing top-level conditions, in the order they appear in `when`", function()
    -- Entry 2 (AVENGING_WRATH): no VENGEANCE_BUFF (condition 1 fails), and the nested `any` also
    -- fails because HOLY_POWER_BUFF is absent AND the T3.5 2-set IS present (so `not(set...)` fails).
    local state = FakeState.new{
      sets = { PALADIN_T35_INQUISITION = 2 },
      bonusDefs = pack.bonuses,
    }
    local snap = snapshotWith(state)
    local aw = snap.entries[2]
    assert.equal("AVENGING_WRATH", aw.spell)
    assert.is_false(aw.passes)
    assert.same({
      "buff:VENGEANCE_BUFF",
      "any(buff:HOLY_POWER_BUFF,not(set:PALADIN_T35_INQUISITION))",
    }, aw.failed)
  end)

  it("renders a nested any() with a variadic target_type condition and a rune condition", function()
    -- Entry 9 (HOLY_WRATH): no T3 Redemption 4-set/soul bonus, no Undead/Demon target, no
    -- Purifying Power rune engraved -- both top-level conditions fail.
    local state = FakeState.new{ bonusDefs = pack.bonuses }
    local snap = snapshotWith(state)
    local hw = snap.entries[9]
    assert.equal("HOLY_WRATH", hw.spell)
    assert.is_false(hw.passes)
    -- Undead/Demon, not just Undead: the build's condition is {"target_type","Undead","Demon"} and
    -- a label naming only the first argument describes a narrower test than the one that ran. This
    -- expectation asserted the truncated form until a review caught it -- the spec had inherited the
    -- bug from the contract it was written against, which is the failure mode this suite exists to
    -- avoid. "/" joins one condition's arguments, "," separates siblings inside any(...).
    assert.same({
      "bonus:HOLY_WRATH_INSTANT",
      "any(target_type:Undead/Demon,rune:RUNE_PURIFYING_POWER)",
    }, hw.failed)
  end)

  -- The invariant, checked against several different fake states rather than one: `failed` must
  -- never disagree with `passes`.
  describe("the passes/failed invariant", function()
    local function assertInvariant(entries, label)
      for i, v in ipairs(entries) do
        if v.passes then
          assert.is_nil(v.failed,
            label .. " entry " .. i .. ": passes=true must mean failed=nil")
        else
          assert.is_true(type(v.failed) == "table" and #v.failed > 0,
            label .. " entry " .. i .. ": passes=false must mean a non-empty failed list")
        end
      end
    end

    it("holds for a fresh level-60 in dungeon blues with no runes engraved", function()
      assertInvariant(snapshotWith(FakeState.new{ bonusDefs = pack.bonuses }).entries, "blues-no-runes")
    end)

    it("holds mid-fight with buffs, a seal and holy power up", function()
      local state = FakeState.new{
        seal = "SEAL_OF_MARTYRDOM",
        buffs = {
          VENGEANCE_BUFF = { stacks = 1, remaining = 20 },
          HOLY_POWER_BUFF = { stacks = 3, remaining = 30 },
          SEAL_OF_MARTYRDOM = { stacks = 1, remaining = 2 },
        },
        bonusDefs = pack.bonuses,
      }
      assertInvariant(snapshotWith(state).entries, "mid-fight")
    end)

    it("holds with full BiS set bonuses and runes engraved", function()
      local state = FakeState.new{
        sets = { PALADIN_T2_JUDGEMENT = 2, PALADIN_T35_INQUISITION = 4, PALADIN_T3_REDEMPTION = 4 },
        runes = { RUNE_ART_OF_WAR = true, RUNE_CRUSADER_STRIKE = true, RUNE_DIVINE_STORM = true,
                  RUNE_PURIFYING_POWER = true },
        targetType = "Undead",
        items = { [13] = { cooldown = 0 }, [14] = { cooldown = 0 } },
        power = { MANA = { 900, 1000 } },
        bonusDefs = pack.bonuses,
      }
      assertInvariant(snapshotWith(state).entries, "full-bis")
    end)

    it("holds with an item on cooldown and low mana", function()
      local state = FakeState.new{
        items = { [13] = { cooldown = 30 } },
        power = { MANA = { 50, 1000 } },
        bonusDefs = pack.bonuses,
      }
      assertInvariant(snapshotWith(state).entries, "low-mana")
    end)
  end)
end)
