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
    -- The Builder's item palette ships showing trinkets only: most characters have nothing on-use
    -- in the other slots, and a palette of empty rows teaches you to stop reading it.
    assert.is_false(DB.defaults.profile.paletteAllSlots)
    -- The next-cast glow's brightness, pinned to a number so deleting it cannot silently fall back
    -- to the constant. It has no style of its own (PE7): it always draws in the main style, dimmed.
    assert.equal(0.35, DB.defaults.profile.glow.secondaryAlpha)
    assert.is_nil(DB.defaults.profile.glow.secondaryStyle)
    -- The only category that can reach party chat, so the bar for what counts is pinned: 120s
    -- takes Avenging Wrath and Aura Mastery and leaves Crusader Strike's 6s alone.
    assert.equal(120, DB.defaults.profile.announce.cooldownFloor)
    -- D38: the queue strip's own nudge ships ON; the owner can switch it off from Queue.
    assert.is_true(DB.defaults.profile.showPlaceholder)
    -- D37: the first-run popup is offered until the player explicitly says stop.
    assert.is_false(DB.defaults.char.firstRunDismissed)
    -- R2 (D53): the Spells registry starts empty and PER CHARACTER, not account-wide -- a name only
    -- one alt's client has resolved means nothing to another.
    assert.same({}, DB.defaults.char.spells)
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
  --
  -- D25: there is no `chatWindow` any more -- Elmira finds System-message chat windows itself.
  it("ships announcements with no stored routing and no per-category sound overrides", function()
    local a = DB.defaults.profile.announce
    assert.same({}, a.routes)
    assert.is_nil(a.chatWindow)
    assert.same({}, a.sounds)
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

  -- D27: no dropped-lines counter any more -- the panel's own row for it is gone.
  it("keeps the announcement log account-wide, so an alt sees what was said", function()
    assert.same({}, DB.defaults.global.announceLog)
    assert.is_nil(DB.defaults.global.announceDropped)
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

  -- D27 (2026-09-07 Notifications pass): the Log's cap dropped from 200 to 20, so an existing
  -- SavedVariables file sitting at up to 200 lines has to be trimmed on load, not merely on the
  -- next write.
  describe("the D27 announceLog migration", function()
    it("truncates an existing log down to the newest twenty lines", function()
      local log = {}
      for i = 1, 30 do log[i] = { text = "line " .. i } end
      local db = { global = { dbVersion = 0, announceLog = log }, profile = {}, char = {} }
      DB.migrate(db)
      assert.equal(20, #db.global.announceLog)
      assert.equal("line 11", db.global.announceLog[1].text)   -- oldest ten dropped
      assert.equal("line 30", db.global.announceLog[#db.global.announceLog].text)
    end)

    it("leaves a short log alone", function()
      local db = { global = { dbVersion = 0, announceLog = { { text = "only one" } } }, profile = {}, char = {} }
      DB.migrate(db)
      assert.equal(1, #db.global.announceLog)
    end)

    it("does nothing to a database with no log at all yet", function()
      local db = { global = { dbVersion = 0 }, profile = {}, char = {} }
      assert.has_no.errors(function() DB.migrate(db) end)
    end)
  end)

  -- D21/D22 (2026-09-07 Notifications pass): `template`/`mode` routing rows are dead weight now
  -- that neither category exists, and the single `party` flag has to become BOTH `party` and
  -- `raid` for anyone who had it on, or their message would stop reaching either group.
  describe("the D21/D22 announce.routes profile migration", function()
    local function oldProfile(routes)
      return { dbVersion = 0, announce = { routes = routes } }
    end

    it("drops stale routing for the two removed categories", function()
      local profile = oldProfile{
        template = { chat = true },
        mode = { screen = true },
        warning = { chat = true },
      }
      DB.migrateProfile(profile)
      assert.is_nil(profile.announce.routes.template)
      assert.is_nil(profile.announce.routes.mode)
      assert.is_not_nil(profile.announce.routes.warning)
    end)

    it("turns a stored party=true into both party AND raid, so the reach does not shrink", function()
      local profile = oldProfile{ cooldown = { chat = true, party = true } }
      DB.migrateProfile(profile)
      assert.is_true(profile.announce.routes.cooldown.party)
      assert.is_true(profile.announce.routes.cooldown.raid)
    end)

    it("leaves party=false alone -- nothing to widen", function()
      local profile = oldProfile{ cooldown = { chat = true, party = false } }
      DB.migrateProfile(profile)
      assert.is_false(profile.announce.routes.cooldown.party)
      assert.is_falsy(profile.announce.routes.cooldown.raid)
    end)

    it("does nothing to a profile with no stored routes at all", function()
      local profile = { dbVersion = 0, announce = { routes = {} } }
      assert.has_no.errors(function() DB.migrateProfile(profile) end)
      assert.same({}, profile.announce.routes)
    end)

    it("does nothing to a profile with no announce table at all yet", function()
      local profile = { dbVersion = 0 }
      assert.has_no.errors(function() DB.migrateProfile(profile) end)
    end)

    it("runs on a genuinely old profile shape end to end", function()
      -- A realistic pre-D21 SavedVariables profile, dbVersion 1 (the M0 baseline, before any
      -- migration ever ran).
      local profile = {
        dbVersion = 1,
        announce = {
          chatWindow = 2,
          sound = "Elmira chime",
          routes = {
            rotation = { chat = true, screen = true, party = false },
            template = { chat = true },
            mode = { screen = true },
            cooldown = { chat = false, party = true },
          },
        },
      }
      local from = DB.migrateProfile(profile)
      assert.equal(1, from)
      assert.equal(DB.CURRENT, profile.dbVersion)
      assert.is_nil(profile.announce.routes.template)
      assert.is_nil(profile.announce.routes.mode)
      assert.is_true(profile.announce.routes.cooldown.party)
      assert.is_true(profile.announce.routes.cooldown.raid)
      assert.is_false(profile.announce.routes.rotation.party)
    end)
  end)
end)
