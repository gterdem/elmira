local helper = require("tests.helper")
local mock = require("tests.wow_mock")

-- tests/spec/init_class_pack_spec.lua — NA:OnEnable()'s TWO class-pack sources (ADR-0011 §3):
-- the built-in thunk from Elmira/Classes/<Class>.lua (via ns.Packs.BuiltinPack) and an external
-- LoadOnDemand addon claiming the class via `## X-Elmira-Class` (via ns.Adapter.loadClassPack).
--
-- This is a sibling of init_spec.lua, not an extension of it: it needs the REAL ns.Packs/ns.API
-- registry (to prove the built-in registration and the external one actually compete for the same
-- registry slot, not two independent fakes that could never disagree) on top of init_spec.lua's real
-- Ace3 harness, so it earns its own file rather than growing an already-long describe block.
--
-- What this pins that nothing else does:
--   1. a built-in pack, with no external addon present, gets attached;
--   2. the ORDER Init.lua calls the two sources in — builtin first, external second — because that
--      order is what lets the external registration OVERWRITE the built-in one in the registry
--      (API.RegisterDataPack just does `registry.dataPacks[class] = spec`; last write wins, so the
--      order is the entire contract, not merely documentation);
--   3. the three-way branch on whether to log a `loadClassPack` failure: never for the "no-pack"
--      sentinel, never when a built-in pack already covers the class, and always (naming the addon
--      and the reason) when an external pack claims a class with no built-in and fails to load.
describe("Core.Init — built-in vs external class pack (ADR-0011 §3)", function()
  local ACE_LIBS = {
    "Elmira/Libs/LibStub/LibStub.lua",
    "Elmira/Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
    "Elmira/Libs/AceEvent-3.0/AceEvent-3.0.lua",
    "Elmira/Libs/AceConsole-3.0/AceConsole-3.0.lua",
    "Elmira/Libs/AceTimer-3.0/AceTimer-3.0.lua",
    "Elmira/Libs/AceDB-3.0/AceDB-3.0.lua",
    "Elmira/Libs/AceAddon-3.0/AceAddon-3.0.lua",
  }

  local function loadRealAce3()
    _G.LibStub = nil
    for _, path in ipairs(ACE_LIBS) do
      local chunk, err = loadfile(path)
      assert(chunk, "Core/Init.lua runs on the real Ace3, which lives in the gitignored Elmira/Libs/."
                 .. " Run `make libs` once to populate it. (" .. tostring(err) .. ")")
      chunk()
    end
  end

  local ns, NA, logged, order, attachedPack

  -- A fake adapter whose `loadClassPack` is supplied per test: this is the one seam that has to
  -- differ from init_spec.lua's fixed fake, since the whole point of this file is exercising several
  -- different loadClassPack outcomes (no-pack / external success / external failure) against one
  -- real registry. `attachPack` captures the actual pack table it was handed (not just that it was
  -- called), which is what lets a test prove WHICH pack won, not merely that attach happened.
  local function fakeAdapter(class, loadClassPackImpl)
    return {
      playerClass = function() return class end,
      loadClassPack = function(c)
        order[#order + 1] = "loadClassPack:" .. tostring(c)
        return loadClassPackImpl(c)
      end,
      attachPack = function(pack)
        order[#order + 1] = "attachPack"
        attachedPack = pack
      end,
    }
  end

  -- Deliberately does NOT touch anything else Init.lua wires up: ns.Display/ns.Queue stay absent, so
  -- StartDisplay() (called at the end of every OnEnable) returns on its very first line and never
  -- reaches Options/Wizard/the minimap button — proven safe by init_spec.lua's own "does nothing at
  -- all... when the Display module is absent" case, so re-faking all of that here would only dilute
  -- what this file is actually about.
  local function loadInit()
    mock.reset()
    ns = helper.reset()
    order, logged, attachedPack = {}, {}, nil
    _G.ElmiraDB = nil

    loadRealAce3()
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/API.lua")
    helper.load("Elmira/Core/DB.lua")
    helper.load("Elmira/Core/Packs.lua") -- real registry: builtin vs external must genuinely compete

    -- Spies on the REAL RegisterDataPack rather than replacing it, so both the built-in call (inside
    -- Init.lua) and the external call (simulated inside a test's loadClassPack fake) still actually
    -- write the registry — this is what lets "external wins" be a fact about the registry, not an
    -- assertion about which fake ran.
    local realRegisterDataPack = ns.API.RegisterDataPack
    ns.API.RegisterDataPack = function(a, b)
      local spec = b or a
      local marker = spec and spec.spells and spec.spells.marker or (spec and spec.class)
      order[#order + 1] = "RegisterDataPack:" .. tostring(marker)
      return realRegisterDataPack(a, b)
    end

    helper.load("Elmira/Core/Init.lua")
    NA = ns.addon
    ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
  end

  before_each(loadInit)
  after_each(function() _G.LibStub = nil end)

  local function builtinThunk(class)
    return function() return { class = class, flavor = "SoD", spells = { marker = "builtin" } } end
  end

  it("attaches the built-in pack when no external pack claims the class", function()
    ns.RegisterBuiltinPack("PALADIN", builtinThunk("PALADIN"))
    ns.Adapter = fakeAdapter("PALADIN", function() return false, "no-pack" end)

    NA:OnInitialize()
    NA:OnEnable()

    assert.is_table(attachedPack)
    assert.equal("builtin", attachedPack.spells.marker)
  end)

  it("calls the built-in registration BEFORE loadClassPack, so an external pack registered inside "
     .. "loadClassPack overwrites it and wins (ADR-0011 §3's whole contract)", function()
    ns.RegisterBuiltinPack("PALADIN", builtinThunk("PALADIN"))
    ns.Adapter = fakeAdapter("PALADIN", function(c)
      ns.API.RegisterDataPack{ class = c, flavor = "SoD", spells = { marker = "external" } }
      return true, nil, "Elmira_ExternalPaladin"
    end)

    NA:OnInitialize()
    NA:OnEnable()

    assert.same({
      "RegisterDataPack:builtin",
      "loadClassPack:PALADIN",
      "RegisterDataPack:external",
      "attachPack",
    }, order)
    assert.equal("external", attachedPack.spells.marker,
      "the external registration must be what actually got attached, not just called")
  end)

  it("logs nothing about loadClassPack when nothing claims the class (the 'no-pack' sentinel)", function()
    -- No built-in either: MAGE has none registered. The null-state message this also produces is a
    -- SEPARATE log line from Init.lua's own later branch; this test only asserts the loadClassPack
    -- failure line specifically never appears.
    ns.Adapter = fakeAdapter("MAGE", function() return false, "no-pack" end)

    NA:OnInitialize()
    NA:OnEnable()

    for _, line in ipairs(logged) do
      assert.is_nil(line:find("did not load", 1, true),
        "no-pack must never produce a 'did not load' line: " .. line)
    end
  end)

  it("logs nothing about loadClassPack when an external pack fails but a built-in one covers the "
     .. "class", function()
    ns.RegisterBuiltinPack("PALADIN", builtinThunk("PALADIN"))
    ns.Adapter = fakeAdapter("PALADIN", function()
      return false, "DISABLED", "Elmira_BrokenPaladin" -- claims the class, fails to load
    end)

    NA:OnInitialize()
    NA:OnEnable()

    for _, line in ipairs(logged) do
      assert.is_nil(line:find("did not load", 1, true),
        "the built-in fallback means this failure is not worth reporting: " .. line)
    end
    -- And the addon keeps working on the built-in pack, not a null state.
    assert.equal("builtin", attachedPack.spells.marker)
  end)

  it("logs the addon name and the exact reason when an external pack claims a class with no "
     .. "built-in and fails to load", function()
    -- No RegisterBuiltinPack("MAGE", ...) at all.
    ns.Adapter = fakeAdapter("MAGE", function()
      return false, "DISABLED", "Elmira_BrokenMage"
    end)

    NA:OnInitialize()
    NA:OnEnable()

    -- Exact string, not merely "contains something": a mutation that swaps the name/class/reason
    -- arguments, or drops one, must fail this line rather than surviving behind a loose substring
    -- check on "did not load" alone.
    local found = false
    for _, line in ipairs(logged) do
      if line == "Elmira: Elmira_BrokenMage claims MAGE but did not load (DISABLED)." then found = true end
    end
    assert.is_true(found, "expected the exact failure line among: " .. table.concat(logged, " | "))
  end)
end)
