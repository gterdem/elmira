local helper = require("tests.helper")

-- Recursively asserts no `nil` appears anywhere in a defaults tree. This is what keeps the
-- `false`-sentinel discipline honest (see Core/DB.lua's comment): a stray `nil` default would be
-- indistinguishable from "AceDB omitted this because it equals the default".
local function assertNoNils(t, path)
  path = path or "defaults"
  for k, v in pairs(t) do
    local here = path .. "." .. tostring(k)
    assert.is_not_nil(v, here .. " must not be nil")
    if type(v) == "table" then
      assertNoNils(v, here)
    end
  end
end

describe("Core.DB", function()
  local DB

  before_each(function()
    helper.reset()
    DB = helper.load("Elmira/Core/DB.lua")
  end)

  it("defaults.profile.depth is 3", function()
    assert.equal(3, DB.defaults.profile.depth)
  end)

  it("has no nil values anywhere in the defaults tree", function()
    assertNoNils(DB.defaults)
  end)

  it("global.dbVersion defaults to 0, not DB.CURRENT", function()
    assert.equal(0, DB.defaults.global.dbVersion)
    assert.is_true(DB.CURRENT > 0)
  end)

  it("migrate() stamps global.dbVersion to DB.CURRENT and returns the prior version", function()
    local db = { global = {}, profile = {}, char = {} }
    local from = DB.migrate(db)
    assert.equal(0, from)
    assert.equal(DB.CURRENT, db.global.dbVersion)
  end)

  it("migrateProfile() stamps profile.dbVersion to DB.CURRENT", function()
    local profile = {}
    DB.migrateProfile(profile)
    assert.equal(DB.CURRENT, profile.dbVersion)
  end)

  it("a registered migration runs exactly once and is idempotent on a second call", function()
    local runs = 0
    table.insert(DB.migrations, { version = 1, apply = function() runs = runs + 1 end })
    local db = { global = { dbVersion = 0 }, profile = {}, char = {} }
    DB.migrate(db)
    DB.migrate(db) -- second call: dbVersion is now DB.CURRENT, so version=1 must not re-apply
    assert.equal(1, runs)
  end)
end)
