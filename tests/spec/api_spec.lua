local helper = require("tests.helper")

describe("Elmira.API v1 registry", function()
  local API

  before_each(function()
    helper.reset()
    API = helper.load("Elmira/Core/API.lua")
  end)

  it("has an integer version >= 1", function()
    assert.is_number(API.version)
    assert.equal(API.version, math.floor(API.version))
    assert.is_true(API.version >= 1)
  end)

  it("registers a valid data pack and makes it retrievable", function()
    local ok = API.RegisterDataPack{ class = "PALADIN", flavor = "SoD" }
    assert.is_true(ok)
    local packs = API.GetProviders("dataPacks")
    assert.equal("SoD", packs.PALADIN.flavor)
  end)

  it("rejects a malformed data pack without throwing", function()
    local ok, reason = API.RegisterDataPack{}
    assert.is_false(ok)
    assert.is_string(reason)
  end)

  it("rejects a non-table spec without throwing", function()
    local ok, reason = API.RegisterDataPack(nil)
    assert.is_false(ok)
    assert.is_string(reason)
  end)

  it("sorts bar providers by priority descending with a stable name tiebreak", function()
    API.RegisterBarProvider{ name = "Zeta", priority = 5 }
    API.RegisterBarProvider{ name = "ElvUI", priority = 10 }
    API.RegisterBarProvider{ name = "Alpha", priority = 5 }
    local providers = API.GetProviders("barProviders")
    assert.equal("ElvUI", providers[1].name)
    assert.equal("Alpha", providers[2].name) -- tie at priority 5, "Alpha" < "Zeta"
    assert.equal("Zeta", providers[3].name)
  end)

  it("defaults an unspecified priority to 0", function()
    API.RegisterBarProvider{ name = "Generic" }
    local providers = API.GetProviders("barProviders")
    assert.equal(0, providers[1].priority)
  end)

  it("supports colon-call registration defensively", function()
    local ok = API:RegisterExporter{ name = "WoWSims", export = function() end }
    assert.is_true(ok)
    local exporters = API.GetProviders("exporters")
    assert.equal("WoWSims", exporters[1].name)
  end)

  it("GetState() satisfies the State contract even with no adapter loaded", function()
    local Interface = helper.load("Elmira/Adapters/Interface.lua")
    local state = API.GetState()
    local ok, missing = Interface.validate(state)
    assert.is_true(ok, table.concat(missing or {}, ", "))
  end)

  it("GetActiveBuild() is nil at M0", function()
    assert.is_nil(API.GetActiveBuild())
  end)

  it("Advise() returns a fresh table shaped per docs/08 on every call", function()
    local a1 = API.Advise()
    local a2 = API.Advise()
    assert.is_nil(a1.soul)
    assert.is_nil(a1.weapon)
    assert.same({}, a1.runes)
    assert.same({}, a1.notes)
    assert.are_not.equal(a1, a2) -- distinct tables, not a shared default
  end)

  it("GetProviders() returns a copy that does not mutate the registry", function()
    API.RegisterExporter{ name = "WoWSims", export = function() end }
    local exporters = API.GetProviders("exporters")
    table.insert(exporters, { name = "Rogue" })
    assert.equal(1, #API.GetProviders("exporters"))
  end)

  it("GetProviders() returns an empty table for an unknown registry", function()
    assert.same({}, API.GetProviders("nonsense"))
  end)
end)
