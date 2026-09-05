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

    -- ADR-0013 §2: the runes a build is written for are a shopping list on the row, by readable
    -- name, only for the ones actually missing -- and never for ones we could not read.
    describe("rune shopping list", function()
      local function packNeedingRunes()
        local p = packWith{
          { build = "PALADIN_EXODIN", available = true,
            requires = { runes = { "RUNE_ART_OF_WAR", "RUNE_DIVINE_STORM" } } },
        }
        p.spells = {
          RUNE_ART_OF_WAR = { id = 1, rune = "feet", name = "Art of War" },
          RUNE_DIVINE_STORM = { id = 2, rune = "hands", name = "Divine Storm" },
        }
        return p
      end

      it("lists only the missing runes, by readable name, and still marks the row as not fitting", function()
        install(packNeedingRunes())
        local choices = Wizard.choices({ runes = { RUNE_ART_OF_WAR = false, RUNE_DIVINE_STORM = true } })
        assert.same({ "Art of War (feet)" }, choices[1].runesToEngrave)
        assert.is_false(choices[1].fits)
      end)

      it("lists nothing when the runes could not be read -- an unknown is not a purchase", function()
        install(packNeedingRunes())
        local choices = Wizard.choices({})
        assert.same({}, choices[1].runesToEngrave)
        assert.is_true(choices[1].fits)
      end)

      it("carries the same list on the summary shown before applying", function()
        install(packNeedingRunes())
        local summary = Wizard.summary("PALADIN_EXODIN",
          { runes = { RUNE_ART_OF_WAR = false, RUNE_DIVINE_STORM = false } })
        assert.same({ "Art of War (feet)", "Divine Storm (hands)" }, summary.runesToEngrave)
      end)

      it("renders the shopping line once, under the checks, naming the Rune Broker", function()
        install(packNeedingRunes())
        local choice = Wizard.choices({ runes = { RUNE_ART_OF_WAR = false, RUNE_DIVINE_STORM = true } })[1]
        local lines = Wizard.choiceLines(choice)
        -- two check lines (one per required rune) then the shopping line; no summary on this entry
        assert.equal(3, #lines)
        assert.truthy(lines[3]:find("Engrave first: Art of War (feet).", 1, true))
        assert.truthy(lines[3]:find("Rune Broker", 1, true))
        assert.truthy(lines[1]:find("Engrave Art of War (feet)", 1, true))
        assert.truthy(lines[2]:find("Divine Storm engraved", 1, true))
      end)

      it("joins several missing runes with a comma, in requires order", function()
        install(packNeedingRunes())
        local choice = Wizard.choices({ runes = { RUNE_ART_OF_WAR = false, RUNE_DIVINE_STORM = false } })[1]
        local lines = Wizard.choiceLines(choice)
        assert.truthy(lines[#lines]:find("Engrave first: Art of War (feet), Divine Storm (hands).", 1, true))
      end)

      it("renders no shopping line when nothing is missing, and the summary first when present", function()
        local p = packNeedingRunes(); p.catalog.PALADIN[1].summary = "Fast 2H."; install(p)
        local choice = Wizard.choices({ runes = { RUNE_ART_OF_WAR = true, RUNE_DIVINE_STORM = true } })[1]
        local lines = Wizard.choiceLines(choice)
        assert.equal(3, #lines)
        assert.equal("Fast 2H.", lines[1])
        for _, line in ipairs(lines) do assert.is_nil(line:find("Engrave first", 1, true)) end
      end)
    end)

    -- The row itself, through a recording fake of the two AceGUI calls it makes. This is the only
    -- test of addChoice: before it, the button wording and the click wiring were verified in game or
    -- not at all.
    describe("addChoice()", function()
      local function fakeGui()
        local created = {}
        local function widget(kind)
          local w = { kind = kind, children = {}, calls = {} }
          function w:SetFullWidth(v) self.fullWidth = v end
          function w:SetTitle(t) self.title = t end
          function w:SetText(t) self.text = t end
          function w:AddChild(c) self.children[#self.children + 1] = c end
          function w:SetCallback(name, fn) self.calls[name] = fn end
          return w
        end
        return { Create = function(_, kind) local w = widget(kind); created[#created + 1] = w; return w end,
                 created = created }, widget("Container")
      end

      local function rowFor(detection, entryExtra)
        local entry = { build = "PALADIN_EXODIN", available = true, playstyle = "Exodin",
                        requires = { runes = { "RUNE_ART_OF_WAR" } } }
        for k, v in pairs(entryExtra or {}) do entry[k] = v end
        local p = packWith{ entry }
        p.spells = { RUNE_ART_OF_WAR = { id = 1, rune = "feet", name = "Art of War" } }
        install(p)
        return Wizard.choices(detection)[1]
      end

      it("renders one label per line, then a button, inside a titled group added to the container", function()
        local gui, container = fakeGui()
        local choice = rowFor({ runes = { RUNE_ART_OF_WAR = false } }, { recommended = true })
        Wizard.addChoice(gui, container, choice, function() end)
        local group = container.children[1]
        assert.equal("InlineGroup", group.kind)
        assert.is_true(group.fullWidth)
        assert.truthy(group.title:find("Exodin", 1, true))
        assert.truthy(group.title:find("recommended", 1, true))
        local lines = Wizard.choiceLines(choice)
        assert.equal(#lines + 1, #group.children)
        for i, text in ipairs(lines) do
          assert.equal("Label", group.children[i].kind)
          assert.equal(text, group.children[i].text)
          assert.is_true(group.children[i].fullWidth)
        end
        assert.equal("Button", group.children[#group.children].kind)
      end)

      it("says 'Use this anyway' when the row does not fit, and 'Use this' when it does", function()
        local gui, container = fakeGui()
        Wizard.addChoice(gui, container, rowFor({ runes = { RUNE_ART_OF_WAR = false } }), function() end)
        local button = container.children[1].children[#container.children[1].children]
        assert.equal("Use this anyway", button.text)

        gui, container = fakeGui()
        Wizard.addChoice(gui, container, rowFor({ runes = { RUNE_ART_OF_WAR = true } }), function() end)
        button = container.children[1].children[#container.children[1].children]
        assert.equal("Use this", button.text)
      end)

      it("marks an experimental row, and clicking the button picks that row's build", function()
        local gui, container = fakeGui()
        local picked
        Wizard.addChoice(gui, container, rowFor({}, { experimental = true }), function(b) picked = b end)
        local group = container.children[1]
        assert.truthy(group.title:find("experimental", 1, true))
        group.children[#group.children].calls.OnClick()
        assert.equal("PALADIN_EXODIN", picked)
      end)
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

    -- F37: the login line is a status message, so a player can move it out of chat entirely
    -- without losing it -- it is still in the Log.
    it("announces as status when Announce is loaded", function()
      install(packWith({}, { catalogVersion = 2 }))
      local said = {}
      ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
      assert.is_true(Wizard.OfferOnLogin())
      assert.equal(1, #said)
      assert.equal("status", said[1][1])
      assert.is_truthy(said[1][2]:find("/elm setup"))
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
