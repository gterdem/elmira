-- tests/spec/gear_matrix_spec.lua — the M2 gear matrix (docs/04-TESTING.md, ADR-0006 rule 6).
--
-- For every shipped build, walks tests/fixtures/gear_scenarios.lua and asserts the actual top-3
-- Simulation.queue() output for a state built from the scenario's gear/rune/soul description. Uses
-- the REAL shipped Elmira_Paladin/Data/ files (not a fixture copy of them) so this breaks the moment
-- the data changes underneath a build, per the task brief.
--
-- Two structural guards, both because this project's history is "looks right, does nothing":
--   1. every build actually shipped under Elmira_*/Data/Builds/*.lua must have a fixture entry;
--   2. every fixture scenario must be well-formed (name + either `expect` or `adviseExpected`) or the
--      suite fails loudly instead of silently skipping it.
local helper = require("tests.helper")

-- ---------------------------------------------------------------- filesystem discovery
-- `ls` rather than LuaFileSystem: tests/spec/toc_spec.lua already relies on io.popen for exactly this
-- (enumerating Elmira_*/ module folders and Elmira/Core|Adapters/*.lua), so this follows the same,
-- already-sanctioned pattern rather than adding a new dependency for one spec.
local function listFiles(globPattern)
  local files = {}
  local pipe = io.popen("ls " .. globPattern .. " 2>/dev/null")
  if pipe then
    for line in pipe:lines() do files[#files + 1] = line end
    pipe:close()
  end
  table.sort(files)
  return files
end

-- Loads one class pack's data files (Spells/Sets/Souls, then every file under Data/Builds/) into a
-- fresh, private ns — mirroring tests/spec/data_sourcing_spec.lua's loadPack, extended to also pull
-- in Builds/, Advice/<Class>.lua and Catalog.lua. Each class pack gets its OWN ns table, exactly as
-- the WoW client hands each LoadOnDemand addon its own private `...` namespace; Elmira_Paladin's
-- Register.lua is the only thing that ever hands this data to Core; the spec bypasses it and speaks
-- to the raw Data/ files directly, same as data_sourcing_spec.lua does.
local function loadClassPack(dir, className)
  local ns = { Data = { SoD = {} } }
  for _, file in ipairs({ "Spells.lua", "Sets.lua", "Souls.lua" }) do
    local path = dir .. "/Data/" .. file
    local chunk = loadfile(path)
    if chunk then chunk(dir, ns) end
  end
  for _, path in ipairs(listFiles(dir .. "/Data/Builds/*.lua")) do
    local chunk = assert(loadfile(path), path .. " does not load")
    chunk(dir, ns)
  end
  local advicePath = dir .. "/Data/Advice/" .. className .. ".lua"
  local adviceChunk = loadfile(advicePath)
  if adviceChunk then adviceChunk(dir, ns) end
  return ns.Data.SoD
end

-- Every Elmira_*/ folder that actually ships a Data/Builds/ directory is a class pack under test.
-- Elmira/ (no trailing class suffix) is the core addon, never a class pack.
local function discoverClassPacks()
  local packs = {}
  for _, dirLine in ipairs(listFiles("-d Elmira_*/")) do
    local dir = dirLine:gsub("/$", "")
    local buildFiles = listFiles(dir .. "/Data/Builds/*.lua")
    if #buildFiles > 0 then
      local className = dir:match("^Elmira_(.+)$")
      packs[#packs + 1] = { dir = dir, class = className, buildFiles = buildFiles }
    end
  end
  return packs
end

-- ---------------------------------------------------------------- fixture integrity
local scenarios = dofile("tests/fixtures/gear_scenarios.lua")

describe("gear_scenarios.lua fixture integrity", function()
  -- Requirement 1: a build that ships with no fixture entry fails the suite (docs/04: "A build that
  -- lacks scenarios fails the suite"), rather than the matrix quietly only ever covering Exodin.
  it("gives every shipped build at least one gear scenario", function()
    local uncovered = {}
    for _, pack in ipairs(discoverClassPacks()) do
      local data = loadClassPack(pack.dir, pack.class)
      for key in pairs(data.Builds or {}) do
        local list = scenarios[key]
        if type(list) ~= "table" or #list == 0 then
          uncovered[#uncovered + 1] = key
        end
      end
    end
    table.sort(uncovered)
    assert.same({}, uncovered)
  end)

  -- Requirement 2: a malformed scenario must fail loudly, not be silently skipped by whatever loop
  -- later tries to run it (a skipped scenario is indistinguishable from a passing one).
  it("has a name and either `expect` or `adviseExpected` on every scenario", function()
    local problems = {}
    for buildKey, list in pairs(scenarios) do
      for i, s in ipairs(list) do
        local where = buildKey .. "[" .. i .. "]" .. (type(s) == "table" and s.name and (" (" .. s.name .. ")") or "")
        if type(s) ~= "table" then
          problems[#problems + 1] = where .. ": scenario is not a table"
        else
          if type(s.name) ~= "string" or s.name == "" then
            problems[#problems + 1] = where .. ": missing/empty `name`"
          end
          local hasExpect = type(s.expect) == "table" and #s.expect > 0
          local hasAdvise = type(s.adviseExpected) == "table" and type(s.adviseExpected.soul) == "string"
          if not hasExpect and not hasAdvise then
            problems[#problems + 1] = where .. ": needs a non-empty `expect` or a valid `adviseExpected.soul`"
          end
          if s.expect then
            for j, spell in ipairs(s.expect) do
              if type(spell) ~= "string" then
                problems[#problems + 1] = where .. ": expect[" .. j .. "] is not a string"
              end
            end
          end
          if s.bonusExpected ~= nil and type(s.bonusExpected) ~= "table" then
            problems[#problems + 1] = where .. ": bonusExpected must be a table"
          end
        end
      end
    end
    table.sort(problems)
    assert.same({}, problems)
  end)
end)

-- ---------------------------------------------------------------- the matrix itself
describe("Gear matrix: PALADIN_EXODIN", function()
  local Schema, Simulation, FakeState, pack, build

  local function compileBuild(raw, ctx)
    local compiled, errors = Schema.compile(raw, ctx)
    assert.is_not_nil(compiled, table.concat(Schema.errorLines(errors or {}), "; "))
    return compiled
  end

  -- Builds a FakeState from a scenario table: every scenario field maps 1:1 onto a tests/fake_state.lua
  -- constructor key (sets, souls, seal, buffs, usable, targetType, items, runes, ...), so this is a
  -- plain copy with the fixture's own bookkeeping fields stripped out, plus two defaults:
  --   * gcd = 1.5 unless the scenario says otherwise. Without a nonzero GCD, Simulation's virtual
  --     clock (t += max(gcd, castTime)) never advances, so every slot after the first would evaluate
  --     at the same t=0 as slot 1 — not what a "top-3 queue" is supposed to mean.
  --   * bonusDefs = the REAL Bonuses table (Souls.lua), so state:bonus() resolves the same way the
  --     adapter would: from set pieces OR a soul, per docs/02 "bonus".
  local NON_STATE_FIELDS = { name = true, expect = true, bonusExpected = true, adviseExpected = true, build = true }
  local function stateFromScenario(scenario)
    local opts = {}
    for k, v in pairs(scenario) do
      if not NON_STATE_FIELDS[k] then opts[k] = v end
    end
    opts.gcd = opts.gcd or 1.5
    opts.bonusDefs = pack.Bonuses
    return FakeState.new(opts)
  end

  local function queueToNames(queue)
    local names = {}
    for i, slot in ipairs(queue) do
      names[i] = slot.spell or ("item:" .. tostring(slot.item))
    end
    return names
  end

  -- Same key shape as queueToNames, applied to a compiled entry instead of a queue slot -- so an
  -- entry and a slot it might have produced always compare on identical keys.
  local function entryKey(entry)
    return entry.spell or ("item:" .. tostring(entry.item))
  end

  -- How many compiled entries in the REAL build can produce each spell/item key. Derived from
  -- `build.entries` every time, never a hand-maintained list of "the ambiguous spells" -- so a future
  -- entry added for an existing key (a second CONSECRATION line, say) makes this ambiguity guard fire
  -- the moment any scenario's `expect` references that key, with no separate bookkeeping to remember.
  local function countEntriesByKey(compiledBuild)
    local counts = {}
    for _, entry in ipairs(compiledBuild.entries) do
      local key = entryKey(entry)
      counts[key] = (counts[key] or 0) + 1
    end
    return counts
  end

  -- Stand-in for Core/Advisor.lua, which does not exist yet (see the report — this is flagged there
  -- as a gap, not patched here per the task brief's "do not edit Core/"). Data/Advice/<Class>.lua's
  -- own header says "First matching soul rule wins"; PALADIN_EXODIN's only rule carries no `when`, so
  -- this only needs to walk the list and return the first unconditional pick. It deliberately does
  -- NOT evaluate `when` (that needs Schema's private condition compiler, which is not exported) — a
  -- future build whose advice depends on gear would need Core/Advisor.lua itself, not this stand-in.
  local function recommendedSoul(adviceForBuild)
    for _, rule in ipairs(adviceForBuild.soul or {}) do
      if rule.when == nil then return rule.pick end
    end
    return nil
  end

  before_each(function()
    helper.reset()
    helper.load("Elmira/Adapters/Interface.lua")
    Schema = helper.load("Elmira/Core/Schema.lua")
    helper.load("Elmira/Core/Engine.lua")
    Simulation = helper.load("Elmira/Core/Simulation.lua")
    FakeState = dofile("tests/fake_state.lua")

    pack = loadClassPack("Elmira_Paladin", "Paladin")
    build = compileBuild(pack.Builds.PALADIN_EXODIN, { spells = pack.Spells, sets = pack.Sets, bonuses = pack.Bonuses })
  end)

  for _, scenario in ipairs(scenarios.PALADIN_EXODIN) do
    if scenario.expect then
      -- Ambiguity guard: `queueToNames`/`expect` only compare spell KEYS, and PALADIN_EXODIN has
      -- several keys more than one entry can produce (three JUDGEMENT entries, three CONSECRATION,
      -- two DIVINE_STORM as of 2026-09-02). A name-only match can't tell which entry actually fired,
      -- so a reordering that makes a gated upgrade unreachable can still pass — the exact class of bug
      -- that nearly shipped this week. This fails the suite the moment a scenario's `expect` touches an
      -- ambiguous key without an `expectLabels` to say which entry must have produced it; it is derived
      -- from the compiled build every run (see countEntriesByKey), never a hardcoded spell list, so a
      -- future entry added for an existing key trips it automatically.
      it(scenario.name .. ": expect spells are disambiguated where the build is ambiguous", function()
        local counts = countEntriesByKey(build)
        local seen, ambiguous = {}, {}
        for _, key in ipairs(scenario.expect) do
          if (counts[key] or 0) > 1 and not seen[key] then
            seen[key] = true
            ambiguous[#ambiguous + 1] = key
          end
        end
        if #ambiguous > 0 then
          assert.is_not_nil(scenario.expectLabels, "scenario '" .. scenario.name ..
            "' expect[] includes " .. table.concat(ambiguous, ", ") ..
            " -- PALADIN_EXODIN has more than one entry that can produce " ..
            (#ambiguous > 1 and "each of those keys" or "that key") ..
            "; add expectLabels naming which entry must fire in each slot")
        end
      end)

      it(scenario.name .. ": top-" .. #scenario.expect .. " queue", function()
        local state = stateFromScenario(scenario)
        local queue = Simulation.queue(build, state, 3)
        assert.same(scenario.expect, queueToNames(queue))

        if scenario.expectLabels then
          assert.equal(#scenario.expect, #scenario.expectLabels, "scenario '" .. scenario.name ..
            "': expectLabels must be the same length as expect")
          for i, slot in ipairs(queue) do
            -- `false` is the sentinel for "the unlabelled baseline entry": a compiled entry with no
            -- `label` field carries entry.label == nil, and a Lua array cannot hold a nil element
            -- without leaving a hole that ipairs/# would stop at — so expectLabels spells that case
            -- out as `false` instead, which can never collide with a real (string) label.
            local want = scenario.expectLabels[i]
            if want == false then want = nil end
            assert.equal(want, slot.label, "scenario '" .. scenario.name .. "' slot " .. i .. " label")
          end
        end

        if scenario.bonusExpected then
          for key, want in pairs(scenario.bonusExpected) do
            assert.equal(want, state:bonus(key), "state:bonus(" .. key .. ")")
          end
        end
      end)
    end

    if scenario.adviseExpected then
      it(scenario.name .. ": advisor recommendation", function()
        local advice = pack.Advice and pack.Advice.PALADIN and pack.Advice.PALADIN[scenario.build]
        assert.is_not_nil(advice, "no Data/Advice/Paladin.lua entry for " .. tostring(scenario.build))
        local pick = recommendedSoul(advice)
        assert.equal(scenario.adviseExpected.soul, pick)
        -- The scenario's own equipped soul must actually differ, or this isn't a "wrong soul" case.
        local wearing = scenario.souls and scenario.souls[1]
        assert.is_not_nil(wearing, "advisor_wrong_soul scenario needs `souls`")
        assert.is_not.equal(pick, wearing)
      end)
    end
  end
end)
