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

  -- Two switches, not one (ADR-0015 §3). `enabled` is the whole display; `showQueue` is the strip.
  -- Defaulting either to nil would read as "off" through the `~= false` tests in Options and Queue.
  it("ships the strip and its animations on", function()
    assert.is_true(DB.defaults.profile.showQueue)
    assert.is_true(DB.defaults.profile.animate)
  end)

  -- Every glow number ships as `false`, meaning "whatever LibCustomGlow would do on its own", so a
  -- default install renders exactly as it did before the controls existed. A number here would
  -- silently restyle every existing user's glow on upgrade.
  it("leaves every glow appearance setting to the library", function()
    local g = DB.defaults.profile.glow
    assert.is_false(g.color)
    assert.is_false(g.particles)
    assert.is_false(g.frequency)
    assert.is_false(g.thickness)
    assert.is_false(g.speed)
  end)

  it("ships the second-suggestion hint off", function()
    assert.is_false(DB.defaults.profile.glow.secondary)
  end)

  -- F37. `routes` starts EMPTY on purpose: Core/Announce falls back to its shipped defaults, so a
  -- category added by a later release arrives with its intended routing instead of silent, and a
  -- user who never opened the panel is not carrying a frozen copy of an old default set.
  it("ships announcements with no stored routing and the default chat window", function()
    local a = DB.defaults.profile.announce
    assert.same({}, a.routes)
    assert.equal(0, a.chatWindow)
    assert.equal("None", a.sound)
  end)

  it("gives the on-screen message a font, a size and a place to sit", function()
    local screen = DB.defaults.profile.announce.screen
    assert.equal("Friz Quadrata TT", screen.font)
    assert.equal(18, screen.size)
    assert.equal(4, screen.duration)
    assert.equal("TOP", screen.anchor.point)
    assert.equal(-140, screen.anchor.y)
  end)

  it("keeps the announcement log account-wide, so an alt sees what was said", function()
    assert.same({}, DB.defaults.global.announceLog)
    assert.equal(0, DB.defaults.global.announceDropped)
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
