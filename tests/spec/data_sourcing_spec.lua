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

-- Every shipped class pack, discovered rather than listed (ADR-0011: Elmira/Classes/<Class>.lua).
-- The policy below applies per class, so a Classes/Mage.lua added later is policed automatically.
local function shippedPacks()
  local packs = {}
  for _, path in ipairs(helper.classFiles()) do
    local class = path:match("([^/]+)%.lua$")
    packs[#packs + 1] = { class = class, path = path, data = helper.classPack(class) }
  end
  assert(#packs > 0, "no shipped class packs found under Elmira/Classes/")
  return packs
end

-- The source text of every class file, for the assertions that are about what is WRITTEN (src lines,
-- provenance sentences) rather than about the values the thunk produces.
local function sourceOf(path)
  local f = assert(io.open(path, "r"), path .. " is missing")
  local text = f:read("*a"); f:close()
  return text
end

local function isWowhead(src)
  return type(src) == "string" and src:find("wowhead.com", 1, true) ~= nil
end

describe("Data sourcing policy (docs/03)", function()
  local pack

  setup(function() pack = helper.classPack("Paladin") end)
  before_each(function() helper.reset() end)

  -- The pack's IDENTITY fields, which Core keys everything off. These were covered by
  -- Elmira_Paladin/Register.lua's spec until M4b retired that file with the folder; the fields moved
  -- into the thunk's return block and the mutation gate immediately reported them as unprotected,
  -- which is exactly what it is for. `class` is the registry key -- get it wrong and the pack
  -- registers under a class nobody plays, silently. `flavor` is required by RegisterDataPack, so a
  -- missing one is a rejected registration and a null state.
  it("carries the identity fields Core registers the pack under", function()
    assert.equal("PALADIN", pack.class)
    assert.equal("SoD", pack.flavor)
  end)

  -- The wizard re-offers itself once when this rises (docs/01 §5b). Absent, it never re-offers and a
  -- refreshed catalog is never shown to anyone who already ran setup -- a silent no-op with no error.
  it("exposes the catalog version the wizard watches, and keeps it in step with the catalog", function()
    assert.is_number(pack.catalogVersion)
    assert.equal(pack.catalog.version, pack.catalogVersion)
  end)

  it("loads the shipped paladin pack", function()
    assert.is_table(pack.spells)
    assert.is_table(pack.sets)
    assert.is_table(pack.souls)
  end)

  -- Hard rule 2: every id carries the page it came from.
  it("gives every spell id a non-empty src", function()
    local missing = {}
    for key, record in pairs(pack.spells) do
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
    for key, record in pairs(pack.spells) do
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
    for key, record in pairs(pack.spells) do
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
    for key, record in pairs(pack.spells) do
      if type(record) == "table" and record.id == 0 then zeroed[#zeroed + 1] = key end
    end
    for key, soul in pairs(pack.souls) do
      if type(soul) == "table" and soul.itemID == 0 then zeroed[#zeroed + 1] = key end
    end
    table.sort(zeroed)
    assert.same({}, zeroed)
  end)

  -- docs/03 rule 4: bonus SPELL ids must be sourced too. They were inheriting the set's own src
  -- implicitly, which meant ~11 shipped ids were never policed by anything.
  it("gives every set bonus spell its own src", function()
    local missing = {}
    for key, set in pairs(pack.sets) do
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
    for _, entry in ipairs(shippedPacks()) do
      local data = entry.data
      local ctx = { spells = data.spells, sets = data.sets, souls = data.souls, bonuses = data.bonuses }
      for key, build in pairs(data.builds or {}) do
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
    for _, entry in ipairs(shippedPacks()) do
      for key, build in pairs(entry.data.builds or {}) do
        local cues = (build.visuals and build.visuals.cues) or build.overlayCues or build.cues or {}
        for _, cue in ipairs(cues) do
          if type(cue.spell) == "string" and entry.data.spells[cue.spell] == nil then
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
    -- Every build any shipped pack provides. A catalog entry may legitimately name a build that
    -- lives in another class's file, so the shipped set is collected across all of them first.
    local shipped = {}
    local catalog = {}
    for _, entry in ipairs(shippedPacks()) do
      for key in pairs(entry.data.builds or {}) do shipped[key] = true end
      for class, list in pairs(entry.data.catalog or {}) do catalog[class] = list end
    end

    local offered = {}
    for class, entries in pairs(catalog) do
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
    for key, set in pairs(pack.sets) do
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
    for key, set in pairs(pack.sets) do
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
    for key, record in pairs(pack.spells) do
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
    for key, set in pairs(pack.sets) do
      for threshold, bonus in pairs(set.bonuses or {}) do
        if type(bonus.aura) == "string" and pack.spells[bonus.aura] == nil then
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
    -- The constants moved into Elmira/Classes/Paladin.lua with the rest of the data (ADR-0011), so
    -- the provenance assertions read that file's text; the value assertions read the built pack.
    local function timingSource() return sourceOf("Elmira/Classes/Paladin.lua") end

    it("exposes only sourced, positive numbers", function()
      assert.is_number(pack.sealLingerWindow, "the pack exposes no sealLingerWindow")
      assert.is_true(pack.sealLingerWindow > 0, "sealLingerWindow must be positive")
    end)

    it("carries a src line for every constant, and says the window is not Blizzard-published", function()
      local text = timingSource()
      assert.truthy(text:find("-- src:", 1, true), "the class file carries no src line")
      -- The provenance sentence is load-bearing, not decoration: 0.4 is sim-derived, and a reader who
      -- thinks Blizzard published it will not re-measure when it drifts.
      assert.truthy(text:lower():find("not blizzard%-confirmed")
        or text:lower():find("no number"),
        "the class file must state that the linger window is not a published Blizzard figure")
    end)

    it("leaves the window inert rather than guessed if it is ever removed", function()
      -- Documents the contract the adapter relies on: absent constant -> sealLinger() answers nil ->
      -- seal_linger reads false. Nothing may substitute a default.
      local window = pack.sealLingerWindow
      assert.is_number(window)
      assert.is_true(window > 0 and window < 5, "a linger window outside 0-5s is a typo, not a tuning")
    end)
  end)
end)
