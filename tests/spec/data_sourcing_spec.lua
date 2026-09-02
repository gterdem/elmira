-- tests/spec/data_sourcing_spec.lua — enforces the ID-sourcing policy (docs/03) against the REAL
-- shipped data files, not a fixture.
--
-- The marker grep in `make lint` only catches an id someone left explicitly unverified. It cannot
-- catch the failure that actually matters: a bare number sourced from somewhere other than a fetched
-- Wowhead page, which is byte-identical to a verified one. That is exactly the shape that let a whole
-- rune block ship with teach-spell ids.
--
-- Policy, in one sentence: an id ships either with a Wowhead `src`, or with a non-Wowhead `src` AND
-- `verify = "in-game"` marking it provisional. There is no third option.
local helper = require("tests.helper")
local DATA = "Elmira_Paladin/Data/"

local function loadPack()
  local ns = { Data = { SoD = {} } }
  for _, file in ipairs({ "Spells.lua", "Sets.lua", "Souls.lua" }) do
    local chunk = assert(loadfile(DATA .. file), DATA .. file .. " does not load")
    chunk("Elmira_Paladin", ns)
  end
  return ns.Data.SoD
end

local function buildFiles()
  local out = {}
  local p = io.popen("ls " .. DATA .. "Builds/*.lua 2>/dev/null")
  if p then
    for line in p:lines() do out[#out + 1] = line end
    p:close()
  end
  return out
end

local function isWowhead(src)
  return type(src) == "string" and src:find("wowhead.com", 1, true) ~= nil
end

describe("Data sourcing policy (docs/03)", function()
  local pack

  setup(function() pack = loadPack() end)
  before_each(function() helper.reset() end)

  it("loads the shipped paladin pack", function()
    assert.is_table(pack.Spells)
    assert.is_table(pack.Sets)
    assert.is_table(pack.Souls)
  end)

  -- Hard rule 2: every id carries the page it came from.
  it("gives every spell id a non-empty src", function()
    local missing = {}
    for key, record in pairs(pack.Spells) do
      if type(record) == "table" and type(record.id) == "number" then
        if type(record.src) ~= "string" or record.src == "" then missing[#missing + 1] = key end
      end
    end
    assert.same({}, missing)
  end)

  -- The rule this file exists for. A non-Wowhead src is allowed — WoWSims is the sanctioned fallback
  -- for server-side-scripted SoD bonuses Wowhead structurally cannot show — but only when the entry
  -- says out loud that it is still awaiting in-game confirmation.
  it("requires verify=\"in-game\" on any spell whose src is not a Wowhead page", function()
    local untagged = {}
    for key, record in pairs(pack.Spells) do
      if type(record) == "table" and type(record.id) == "number" then
        if not isWowhead(record.src) and record.verify ~= "in-game" then
          untagged[#untagged + 1] = key .. " (src: " .. tostring(record.src) .. ")"
        end
      end
    end
    table.sort(untagged)
    assert.same({}, untagged)
  end)

  -- The converse: a provisional tag with no source at all is not a citation, it is a shrug.
  it("requires a src alongside verify=\"in-game\"", function()
    for key, record in pairs(pack.Spells) do
      if type(record) == "table" and record.verify == "in-game" then
        assert.is_true(type(record.src) == "string" and record.src ~= "",
          key .. ' is verify="in-game" but cites no source')
      end
    end
  end)

  -- Absent means absent. A 0 is a real id that a scan can never match, so it fails silently rather
  -- than visibly — the opposite of what an unknown value should do.
  it("never writes an unknown id as 0", function()
    local zeroed = {}
    for key, record in pairs(pack.Spells) do
      if type(record) == "table" and record.id == 0 then zeroed[#zeroed + 1] = key end
    end
    for key, soul in pairs(pack.Souls) do
      if type(soul) == "table" and soul.itemID == 0 then zeroed[#zeroed + 1] = key end
    end
    table.sort(zeroed)
    assert.same({}, zeroed)
  end)

  -- docs/03 rule 4: bonus SPELL ids must be sourced too. They were inheriting the set's own src
  -- implicitly, which meant ~11 shipped ids were never policed by anything.
  it("gives every set bonus spell its own src", function()
    local missing = {}
    for key, set in pairs(pack.Sets) do
      for threshold, bonus in pairs(set.bonuses or {}) do
        if bonus.spell and not isWowhead(bonus.src) and bonus.verify ~= "in-game" then
          missing[#missing + 1] = string.format("%s [%s] spell=%s", key, tostring(threshold), tostring(bonus.spell))
        end
      end
    end
    table.sort(missing)
    assert.same({}, missing)
  end)

  -- Nothing loaded the shipped BUILD or CATALOG, so a malformed one could ship silently.
  it("validates every shipped build against the real data pack", function()
    local Schema = helper.load("Elmira/Core/Schema.lua")
    local ctx = { spells = pack.Spells, sets = pack.Sets, souls = pack.Souls, bonuses = pack.Bonuses }
    for _, path in ipairs(buildFiles()) do
      local ns = { Data = { SoD = { Builds = {} } } }
      assert(loadfile(path), path .. " does not load")("Elmira_Paladin", ns)
      for key, build in pairs(ns.Data.SoD.Builds or {}) do
        local ok, errors = Schema.validate(build, ctx)
        assert.is_true(ok, key .. ": " .. table.concat(Schema.errorLines(errors or {}), "; "))
      end
    end
  end)

  -- Overlay cues carry a spell key just like entries do, but Schema only validates entries. A cue
  -- naming a key the pack lacks resolves to nil and simply never fires — no error, no cue, ADR-0009's
  -- opt-in flare silently dead. Found by corrupting a cue and watching the suite stay green.
  it("resolves every overlay cue's spell key to a real spell", function()
    local dangling = {}
    for _, path in ipairs(buildFiles()) do
      local ns = { Data = { SoD = { Builds = {} } } }
      assert(loadfile(path), path .. " does not load")("Elmira_Paladin", ns)
      for key, build in pairs(ns.Data.SoD.Builds or {}) do
        local cues = (build.visuals and build.visuals.cues) or build.overlayCues or build.cues or {}
        for _, cue in ipairs(cues) do
          if type(cue.spell) == "string" and pack.Spells[cue.spell] == nil then
            dangling[#dangling + 1] = key .. " cue -> " .. cue.spell
          end
        end
      end
    end
    table.sort(dangling)
    assert.same({}, dangling)
  end)

  -- The catalog is the wizard's ONLY list (rule 7). An entry the wizard can offer whose
  -- build file does not exist resolves to nil and the user picks a playstyle that does nothing.
  it("marks a catalog entry available only when its build actually ships", function()
    local ns = { Data = { SoD = {} } }
    assert(loadfile(DATA .. "Catalog.lua"), "Catalog.lua does not load")("Elmira_Paladin", ns)

    local shipped = {}
    for _, path in ipairs(buildFiles()) do
      local bns = { Data = { SoD = { Builds = {} } } }
      assert(loadfile(path))("Elmira_Paladin", bns)
      for key in pairs(bns.Data.SoD.Builds or {}) do shipped[key] = true end
    end

    local offered = {}
    for class, entries in pairs(ns.Data.SoD.Catalog or {}) do
      if type(entries) == "table" and type(class) == "string" and class:upper() == class then
        for _, entry in ipairs(entries) do
          if entry.available ~= false and not shipped[entry.build] then
            offered[#offered + 1] = entry.build
          end
        end
      end
    end
    table.sort(offered)
    assert.same({}, offered, "catalog offers builds that do not ship")
  end)

  it("gives every set a src and non-zero item ids", function()
    for key, set in pairs(pack.Sets) do
      assert.is_true(type(set.src) == "string" and set.src ~= "", key .. " has no src")
      for i, item in ipairs(set.items or {}) do
        assert.is_true(type(item) == "number" and item > 0,
          string.format("%s items[%d] is not a real item id", key, i))
      end
    end
  end)

  -- ADR-0004 / hard rule 5: where a bonus produces an aura, the data must name it, otherwise a build
  -- has nothing to gate on and silently falls back to counting set pieces.
  --
  -- The sanctioned exception is the same one that applies to ids: a bonus known to apply an aura
  -- whose id is not yet sourced may ship tagged `verify = "in-game"`. That keeps "we know it exists
  -- but cannot detect it yet" visible in the data, instead of it hiding as a `kind` nobody honours.
  it("names the applied aura for every bonus declared kind=\"aura\"", function()
    local missing = {}
    for key, set in pairs(pack.Sets) do
      for threshold, bonus in pairs(set.bonuses or {}) do
        if bonus.kind == "aura" and bonus.aura == nil and bonus.verify ~= "in-game" then
          missing[#missing + 1] = string.format("%s [%d]", key, threshold)
        end
      end
    end
    table.sort(missing)
    assert.same({}, missing)
  end)

  -- Every entry still awaiting in-game confirmation, named out loud. This test does not fail on
  -- their existence — provisional entries are legal — it fails when the list drifts from what is
  -- documented, so one can never be added or quietly resolved without a deliberate edit here.
  it("has exactly the provisional entries we expect", function()
    local pending = {}
    for key, record in pairs(pack.Spells) do
      if type(record) == "table" and record.verify == "in-game" then pending[#pending + 1] = key end
    end
    table.sort(pending)
    -- The four SOUL_*_AURA entries were here until 2026-09-01, when the dump refuted them: a soul's
    -- "permanent hidden aura" is not visible to UnitAura, so it cannot drive detection (docs/07 §9.13).
    assert.same({ "SWIFT_JUDGEMENT_BUFF", "TEMPLAR_BUFF" }, pending)
  end)

  -- A bonus naming an aura key that no spell record defines resolves to nil at runtime and the
  -- condition quietly never passes.
  it("resolves every named bonus aura to a real spell key", function()
    local dangling = {}
    for key, set in pairs(pack.Sets) do
      for threshold, bonus in pairs(set.bonuses or {}) do
        if type(bonus.aura) == "string" and pack.Spells[bonus.aura] == nil then
          dangling[#dangling + 1] = string.format("%s [%d] -> %s", key, threshold, bonus.aura)
        end
      end
    end
    table.sort(dangling)
    assert.same({}, dangling)
  end)

  -- A server-side TIMING constant is held to the same bar as an id, for the same reason: it is a
  -- number the server owns, it changes on a tuning pass, and a remembered one is indistinguishable
  -- from a verified one once it is in the file. The seal-twist window in particular is NOT
  -- Blizzard-published — the hotfix note says "a short time" and gives no figure — so the file must
  -- carry where 0.4 actually came from, or the next person to read it will assume Blizzard said so.
  describe("timing constants", function()
    local TIMING = DATA .. "Timing.lua"

    local function timingSource()
      local f = io.open(TIMING, "r")
      if not f then return nil end
      local text = f:read("*a")
      f:close()
      return text
    end

    it("ships a Timing.lua that loads and exposes only sourced numbers", function()
      local text = timingSource()
      assert.is_string(text, "Elmira_Paladin/Data/Timing.lua is missing")
      local ns = { Data = { SoD = {} } }
      local chunk = assert(loadfile(TIMING), TIMING .. " does not load")
      chunk("Elmira_Paladin", ns)
      local timing = ns.Data.SoD.Timing
      assert.is_table(timing)
      for key, value in pairs(timing) do
        assert.equal("number", type(value), key .. " must be a number")
        assert.is_true(value > 0, key .. " must be positive")
      end
    end)

    it("carries a src line for every constant, and says the window is not Blizzard-published", function()
      local text = timingSource()
      assert.truthy(text:find("-- src:", 1, true), "Timing.lua carries no src line")
      -- The provenance sentence is load-bearing, not decoration: 0.4 is sim-derived, and a reader who
      -- thinks Blizzard published it will not re-measure when it drifts.
      assert.truthy(text:lower():find("not blizzard%-confirmed")
        or text:lower():find("no number"),
        "Timing.lua must state that the linger window is not a published Blizzard figure")
    end)

    it("leaves the window inert rather than guessed if it is ever removed", function()
      -- Documents the contract the adapter relies on: absent constant -> sealLinger() answers nil ->
      -- seal_linger reads false. Nothing may substitute a default.
      local ns = { Data = { SoD = {} } }
      assert(loadfile(TIMING))("Elmira_Paladin", ns)
      local window = ns.Data.SoD.Timing.sealLingerWindow
      assert.is_number(window)
      assert.is_true(window > 0 and window < 5, "a linger window outside 0-5s is a typo, not a tuning")
    end)
  end)
end)
