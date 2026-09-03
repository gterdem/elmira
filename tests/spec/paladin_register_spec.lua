local helper = require("tests.helper")

-- Elmira_Paladin/Register.lua — hands the Paladin data pack to Elmira.API.RegisterDataPack. 19
-- lines, but exactly the shape this project's characteristic defect takes: a registration that is
-- never made (or made with a field silently dropped) looks like correct code and does nothing.
--
-- Loaded with a synthetic ns.Data.SoD (fixture-shaped, not the real Elmira_Paladin/Data/ files,
-- which are already independently covered by gear_matrix_spec.lua etc. — this spec's only job is
-- Register.lua's OWN wiring: does every field reach API.RegisterDataPack, unrenamed and undropped).
describe("Elmira_Paladin.Register", function()
  local API

  local function fakeData()
    return {
      Spells = { EXORCISM = { id = 1 } },
      Sets = { some_set = {} },
      Souls = { some_soul = {} },
      Bonuses = { some_bonus = {} },
      Builds = { PALADIN_EXODIN = {} },
      Catalog = { version = 3, entries = {} },
      Advice = { some_advice = {} },
      Timing = { sealLingerWindow = 0.4 },
    }
  end

  before_each(function()
    local ns = helper.reset()
    API = helper.load("Elmira/Core/API.lua")
    _G.Elmira = { API = API }
    ns.Data = { SoD = fakeData() }
  end)

  after_each(function() _G.Elmira = nil end)

  local function loadRegister()
    return helper.load("Elmira_Paladin/Register.lua")
  end

  describe("load guard", function()
    it("registers nothing when Elmira core has not loaded yet", function()
      _G.Elmira = nil
      loadRegister()
      assert.same({}, API.GetProviders("dataPacks"))
    end)

    it("registers nothing when Elmira.API.version is below what this file needs", function()
      _G.Elmira = { API = { version = 0 } }
      loadRegister()
      assert.same({}, API.GetProviders("dataPacks"))
    end)

    it("registers nothing, and reports why, when the Data files did not load (ns.Data.SoD absent)", function()
      helper.ns().Data = nil
      local printed = {}
      _G.Elmira.Print = function(self, msg) printed[#printed + 1] = msg end
      loadRegister()
      assert.same({}, API.GetProviders("dataPacks"))
      assert.equal(1, #printed)
      assert.truthy(printed[1]:find("did not load", 1, true))
    end)

    it("does not error when the Data files are absent AND Elmira has no Print (still just declines)", function()
      helper.ns().Data = nil
      _G.Elmira.Print = nil
      local ok = pcall(loadRegister)
      assert.is_true(ok)
      assert.same({}, API.GetProviders("dataPacks"))
    end)
  end)

  describe("registration", function()
    it("registers PALADIN/SoD with every field carried through, unrenamed", function()
      local D = helper.ns().Data.SoD
      loadRegister()
      local pack = API.GetProviders("dataPacks").PALADIN
      assert.is_table(pack)
      assert.equal("SoD", pack.flavor)
      assert.equal(D.Spells, pack.spells)
      assert.equal(D.Sets, pack.sets)
      assert.equal(D.Souls, pack.souls)
      assert.equal(D.Bonuses, pack.bonuses)
      assert.equal(D.Builds, pack.builds)
      assert.equal(D.Catalog, pack.catalog)
      assert.equal(D.Advice, pack.advice)
      assert.equal(D.Timing.sealLingerWindow, pack.sealLingerWindow)
      assert.equal(D.Catalog.version, pack.catalogVersion)
    end)

    it("leaves sealLingerWindow absent (not defaulted to anything) when Timing is missing", function()
      helper.ns().Data.SoD.Timing = nil
      loadRegister()
      local pack = API.GetProviders("dataPacks").PALADIN
      assert.is_nil(pack.sealLingerWindow)
    end)

    it("leaves catalogVersion absent when Catalog is missing", function()
      helper.ns().Data.SoD.Catalog = nil
      loadRegister()
      local pack = API.GetProviders("dataPacks").PALADIN
      assert.is_nil(pack.catalogVersion)
      assert.is_nil(pack.catalog)
    end)
  end)
end)
