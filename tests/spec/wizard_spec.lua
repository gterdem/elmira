local helper = require("tests.helper")

-- Elmira/Setup/Wizard.lua — the setup flow's LOGIC, which is everything except the window itself.
--
-- The window cannot be tested headlessly and nobody will see it until it is in front of the owner,
-- so the design splits the decisions out: `choices()`, `summary()`, `apply()` and `shouldOffer()`
-- are pure over the data pack and the DB, and `Open()` is a thin renderer over them. What is
-- covered here is therefore the part that can be wrong in a way nobody notices — an entry offered
-- that resolves to no build, a wizard that re-offers itself every login, a "one click configures"
-- that silently configures the wrong thing.
describe("Setup.Wizard", function()
  local Wizard, ns

  local function packWith(entries, opts)
    opts = opts or {}
    return {
      class = "PALADIN",
      catalogVersion = opts.catalogVersion,
      builds = opts.builds or { PALADIN_EXODIN = {}, PALADIN_SHOCKADIN = {} },
      spells = {}, sets = {}, souls = {}, bonuses = {},
      advice = opts.advice,
      catalog = { PALADIN = entries },
    }
  end

  local function install(pack)
    ns.Display = { currentPack = function() return pack end, refresh = function() end }
  end

  before_each(function()
    ns = helper.reset()
    helper.load("Elmira/Adapters/Interface.lua")
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/Schema.lua")
    helper.load("Elmira/Core/Advisor.lua")
    helper.load("Elmira/Setup/Detect.lua")
    Wizard = helper.load("Elmira/Setup/Wizard.lua")
    ns.log = function() end
    ns.API = { GetState = function() return ns.Interface.newNullState() end }
    ns.Adapter = { playerClass = function() return "PALADIN" end, talents = function() return nil end }
    ns.db = { profile = { activeBuild = false }, char = { setupDone = 0 } }
  end)

  describe("choices()", function()
    it("offers only entries that are available AND have a build that exists", function()
      install(packWith{
        { build = "PALADIN_EXODIN", available = true, playstyle = "Exodin" },
        { build = "PALADIN_WRATHLIKE", available = false, playstyle = "Wrath-like" },
        { build = "PALADIN_GHOST", available = true, playstyle = "Ghost" },   -- no build file
      })
      local choices = Wizard.choices()
      assert.equal(1, #choices)
      assert.equal("PALADIN_EXODIN", choices[1].build)
    end)

    it("puts the recommended entry first, then the most recently updated", function()
      install(packWith{
        { build = "PALADIN_SHOCKADIN", available = true, updated = "2026-01-01" },
        { build = "PALADIN_EXODIN", available = true, updated = "2025-01-01", recommended = true },
      })
      local choices = Wizard.choices()
      assert.equal("PALADIN_EXODIN", choices[1].build)
    end)

    -- `requires` is advisory (hard rule 8): a mismatch is a warning on the row, never a locked door.
    it("still offers an entry the character does not meet, marked as not fitting", function()
      install(packWith{
        { build = "PALADIN_EXODIN", available = true, requires = { weapon = "2H" } },
      })
      local detection = { weapon = { type = "1H", speed = 2.0 } }
      local choices = Wizard.choices(detection)
      assert.equal(1, #choices)
      assert.is_false(choices[1].fits)
      assert.is_false(choices[1].checks[1].ok)
    end)

    it("treats 'could not tell' as fitting, so an unreadable tooltip costs nobody a build", function()
      install(packWith{
        { build = "PALADIN_EXODIN", available = true, requires = { weapon = "2H" } },
      })
      local choices = Wizard.choices({})     -- nothing detected at all
      assert.is_true(choices[1].fits)
      assert.is_nil(choices[1].checks[1].ok)
    end)

    it("returns an empty list, not an error, with no pack at all", function()
      ns.Display = { currentPack = function() return nil end }
      assert.same({}, Wizard.choices())
    end)
  end)

  describe("apply()", function()
    it("pins the build and records the catalog version seen", function()
      install(packWith({ { build = "PALADIN_EXODIN", available = true } }, { catalogVersion = 3 }))
      assert.is_true(Wizard.apply("PALADIN_EXODIN"))
      assert.equal("PALADIN_EXODIN", ns.db.profile.activeBuild)
      assert.equal(3, ns.db.char.setupDone)
    end)

    it("refuses a build that is not in the pack rather than writing a dead key", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      local ok, why = Wizard.apply("PALADIN_NONSENSE")
      assert.is_false(ok)
      assert.truthy(why:find("unknown build", 1, true))
      assert.is_false(ns.db.profile.activeBuild)
    end)
  end)

  describe("shouldOffer()", function()
    it("offers on a character that has never been set up", function()
      install(packWith({}, { catalogVersion = 1 }))
      assert.is_true(Wizard.shouldOffer())
    end)

    it("does not offer again afterwards", function()
      install(packWith({}, { catalogVersion = 1 }))
      ns.db.char.setupDone = 1
      assert.is_false(Wizard.shouldOffer())
    end)

    it("offers once more when the catalog moves on", function()
      install(packWith({}, { catalogVersion = 2 }))
      ns.db.char.setupDone = 1
      local offer, why = Wizard.shouldOffer()
      assert.is_true(offer)
      assert.truthy(why:find("catalog", 1, true))
    end)

    it("an unversioned pack does not silently disable the wizard forever", function()
      -- Version 0 vs a setupDone of 0 means "never set up", which still offers.
      install(packWith({}, {}))
      assert.is_true(Wizard.shouldOffer())
    end)

    it("prints once and then stops, rather than nagging every login", function()
      install(packWith({}, { catalogVersion = 2 }))
      local printed = 0
      ns.log = function() printed = printed + 1 end
      assert.is_true(Wizard.OfferOnLogin())
      assert.equal(1, printed)
      assert.is_false(Wizard.OfferOnLogin())
      assert.equal(1, printed)
    end)
  end)

  describe("summary()", function()
    it("carries the gear advice for the chosen build", function()
      install(packWith({ { build = "PALADIN_EXODIN", available = true, playstyle = "Exodin" } },
        { advice = { PALADIN = { PALADIN_EXODIN = {
            soul = { { pick = "SOUL_OF_THE_EXILE", reason = "always" } },
            weapon = { type = "2H" },
          } } } }))
      local s = Wizard.summary("PALADIN_EXODIN", {})
      assert.equal("Exodin", s.playstyle)
      assert.equal("SOUL_OF_THE_EXILE", s.advice.soul.pick)
    end)

    it("survives a build with no advice written for it", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      local s = Wizard.summary("PALADIN_EXODIN", {})
      assert.is_nil(s.advice)
    end)
  end)
end)
