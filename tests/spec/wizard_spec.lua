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
    -- Present BEFORE Wizard.lua loads: the first-run popup registers itself at file scope, the same
    -- way any addon's StaticPopupDialogs entry does.
    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show = function(which, arg1)
      _G.__lastStaticPopup = { which = which, arg1 = arg1 }
      return { which = which }
    end
    helper.load("Elmira/Adapters/Interface.lua")
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/Schema.lua")
    helper.load("Elmira/Core/Advisor.lua")
    helper.load("Elmira/Setup/Detect.lua")
    -- D2: the first-run popup now goes through ns.Popups.show (Display/Popups.lua), the addon's one
    -- StaticPopup_Show call site, rather than calling StaticPopup_Show itself.
    helper.load("Elmira/Display/Popups.lua")
    Wizard = helper.load("Elmira/Setup/Wizard.lua")
    Wizard.resetFirstRunOffer()
    ns.log = function() end
    ns.API = { GetState = function() return ns.Interface.newNullState() end }
    ns.Adapter = { playerClass = function() return "PALADIN" end, talents = function() return nil end }
    ns.db = { profile = { activeBuild = false }, char = { setupDone = 0, firstRunDismissed = false } }
  end)

  after_each(function()
    _G.StaticPopupDialogs, _G.StaticPopup_Show, _G.__lastStaticPopup, _G.InCombatLockdown =
      nil, nil, nil, nil
  end)

  -- D48. The tree shows a playstyle the pack cannot run, muted, on a page that says why; only the
  -- "pick one for me" callers want the filtered list. So the filter is a flag on the row here, and
  -- `choices` is the subset -- one catalog read, two audiences.
  describe("rows()", function()
    it("keeps an entry the pack cannot run, flagged unavailable rather than dropped", function()
      install(packWith{
        { build = "PALADIN_EXODIN", available = true, playstyle = "Exodin" },
        { build = "PALADIN_WRATHLIKE", available = false, playstyle = "Wrath-like" },
        { build = "PALADIN_GHOST", available = true, playstyle = "Ghost" },   -- no build file
      })
      local byKey = {}
      for _, row in ipairs(Wizard.rows()) do byKey[row.build] = row end
      assert.equal(3, #Wizard.rows())
      assert.is_true(byKey.PALADIN_EXODIN.available)
      assert.is_false(byKey.PALADIN_WRATHLIKE.available)   -- the catalog says not yet
      assert.is_false(byKey.PALADIN_GHOST.available)       -- available, but nothing shipped under it
      assert.equal("Wrath-like", byKey.PALADIN_WRATHLIKE.playstyle)
    end)

    it("checks an unavailable entry's requirements like any other, so its page can explain them", function()
      install(packWith{
        { build = "PALADIN_TWIST", available = false, playstyle = "Twist",
          requires = { weapon = "2H" } },
      })
      local row = Wizard.rows({ weapon = { type = "1H", speed = 2.0 } })[1]
      assert.is_false(row.available)
      assert.is_false(row.fits)
      assert.is_false(row.checks[1].ok)
    end)

    -- Every one of these is read straight off the row by the Rotations tree -- the card's meta line
    -- (difficulty, updated, source, experimental), its summary, the page's notes and the root
    -- page's phase header. A field that quietly stopped being copied would empty a line on screen
    -- and nothing else, which is why they are pinned one by one rather than by shape.
    it("carries the catalog entry's own words onto the row", function()
      install(packWith{
        { build = "PALADIN_EXODIN", available = true, playstyle = "Exodin", difficulty = "medium",
          summary = "Fast 2H.", notes = "Never holds Exorcism.", updated = "2026-08-01",
          phase = "SoD P8", source = "https://www.wowhead.com/classic/guide/paladin",
          experimental = true, recommended = true },
      })
      local row = Wizard.rows()[1]
      assert.equal("Exodin", row.playstyle)
      assert.equal("medium", row.difficulty)
      assert.equal("Fast 2H.", row.summary)
      assert.equal("Never holds Exorcism.", row.notes)
      assert.equal("2026-08-01", row.updated)
      assert.equal("SoD P8", row.phase)
      assert.equal("https://www.wowhead.com/classic/guide/paladin", row.source)
      assert.is_true(row.experimental)
      assert.is_true(row.recommended)
    end)

    it("names a catalog entry by its key when it carries no playstyle of its own", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      assert.equal("PALADIN_EXODIN", Wizard.rows()[1].playstyle)
    end)

    it("returns an empty list, not an error, with no pack at all", function()
      ns.Display = { currentPack = function() return nil end }
      assert.same({}, Wizard.rows())
    end)
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

    -- D33's template page reads these straight off the row: the catalog's own notes (the
    -- explanation beneath the summary) and phase (the root page's header, "Playstyles for X - Y").
    it("carries the catalog entry's notes and phase onto the row", function()
      install(packWith{
        { build = "PALADIN_EXODIN", available = true, notes = "Never holds Exorcism.",
          phase = "SoD P8" },
      })
      local choices = Wizard.choices()
      assert.equal("Never holds Exorcism.", choices[1].notes)
      assert.equal("SoD P8", choices[1].phase)
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


    end)

    -- R1: the old wizard rendered these lines itself (`choiceLines`, an AceGUI-only concern); the
    -- Rotations tree's template page (Options/Rotation.lua's `needsArgs`) renders the same
    -- `checks`/`runesToEngrave` data now, and is what carries this coverage forward.
    it("returns an empty list, not an error, with no pack at all", function()
      ns.Display = { currentPack = function() return nil end }
      assert.same({}, Wizard.choices())
    end)
  end)

  -- R1: pinning a build is now `Rotation.use` (Options/Rotation.lua), tested in rotation_spec.lua's
  -- own `use()` describe -- `Wizard.apply` no longer exists.
  describe("shouldOffer()", function()
    -- R1: the "never set up at all" branch moved entirely to the first-run popup below; this
    -- question is ONLY about a catalog that has moved on since a character last looked.
    it("does not offer a character that has simply never been set up", function()
      install(packWith({}, { catalogVersion = 0 }))
      assert.is_false(Wizard.shouldOffer())
    end)

    it("does not offer again once this version has been seen", function()
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

    -- F37: the login line is a status message, so a player can move it out of chat entirely
    -- without losing it -- it is still in the Log. D39: the wording no longer names /elm setup.
    it("announces as status when Announce is loaded", function()
      install(packWith({}, { catalogVersion = 2 }))
      ns.db.char.setupDone = 1
      local said = {}
      ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
      assert.is_true(Wizard.OfferOnLogin())
      assert.equal(1, #said)
      assert.equal("status", said[1][1])
      assert.equal("New playstyles have arrived since you chose yours.", said[1][2])
    end)

    it("prints once and then stops, rather than nagging every login", function()
      install(packWith({}, { catalogVersion = 2 }))
      ns.db.char.setupDone = 1
      local printed = 0
      ns.log = function() printed = printed + 1 end
      assert.is_true(Wizard.OfferOnLogin())
      assert.equal(1, printed)
      assert.is_false(Wizard.OfferOnLogin())
      assert.equal(1, printed)
    end)

    it("does nothing at all with no character database", function()
      ns.db = nil
      assert.is_false(Wizard.shouldOffer())
    end)
  end)

  -- D37. The other nudge: a StaticPopup (a real frame, never AceConfig) offering to open the
  -- Rotations tree, gated on `profile.activeBuild` and `char.firstRunDismissed` alone -- no catalog
  -- version, so a class with no catalog at all still gets it.
  describe("maybeShowFirstRun()", function()
    it("shows once, out of combat, with nothing chosen and nothing dismissed", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true, playstyle = "Exodin" } })
      assert.is_true(Wizard.maybeShowFirstRun())
      assert.equal("ELMIRA_FIRST_RUN", _G.__lastStaticPopup.which)
    end)

    it("shows only once per login even if asked again", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      assert.is_true(Wizard.maybeShowFirstRun())
      assert.is_false(Wizard.maybeShowFirstRun())
    end)

    it("does not show while a rotation is already active", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      ns.db.profile.activeBuild = "PALADIN_EXODIN"
      assert.is_false(Wizard.maybeShowFirstRun())
    end)

    it("does not show once the player has said not to ask again", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      ns.db.char.firstRunDismissed = true
      assert.is_false(Wizard.maybeShowFirstRun())
    end)

    -- "Not now" is button2 (Cancel): StaticPopup itself asks again next login just by having said
    -- nothing, so there is no flag here to assert other than the absence of one.
    it("'Not now' leaves firstRunDismissed alone, so it is offered again next login", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      assert.is_true(Wizard.maybeShowFirstRun())
      assert.is_not_nil(_G.StaticPopupDialogs.ELMIRA_FIRST_RUN.button2, "there is no 'Not now' button")
      assert.is_false(ns.db.char.firstRunDismissed)
    end)

    it("'Don't ask again' sets firstRunDismissed", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      Wizard.maybeShowFirstRun()
      _G.StaticPopupDialogs.ELMIRA_FIRST_RUN.OnAlt()
      assert.is_true(ns.db.char.firstRunDismissed)
    end)

    it("choosing a playstyle opens the Rotations tree", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      local opened
      ns.Options = { Open = function(...) opened = { ... } end }
      Wizard.maybeShowFirstRun()
      _G.StaticPopupDialogs.ELMIRA_FIRST_RUN.OnAccept()
      assert.same({ "rotation" }, opened)
    end)

    it("never shows in combat", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      _G.InCombatLockdown = function() return true end
      assert.is_false(Wizard.maybeShowFirstRun())
    end)

    -- D37's no-catalog wording: the first button reads "Build a rotation" instead.
    it("offers 'Build a rotation' for a class with no catalog at all", function()
      ns.Display = { currentPack = function() return { class = "PALADIN" } end }
      local renamed
      local shownWidget = { button1 = { SetText = function(_, t) renamed = t end } }
      _G.StaticPopup_Show = function() return shownWidget end
      Wizard.maybeShowFirstRun()
      assert.equal("Build a rotation", renamed)
    end)

    it("offers 'Choose a playstyle' when the class has a catalog", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      local renamed
      local shownWidget = { button1 = { SetText = function(_, t) renamed = t end } }
      _G.StaticPopup_Show = function() return shownWidget end
      Wizard.maybeShowFirstRun()
      assert.equal("Choose a playstyle", renamed)
    end)

    -- D2 (review of 65896ad): this was the fifth StaticPopup_Show call site in the
    -- addon, and the only one with no raiseAbovePanel, so it could open BEHIND the options window
    -- exactly like the naming popups did before D61-D67. Pinned the same way those are: a fake
    -- dialog with the real frame methods, asserting the ACTUAL strata/level values `ns.Popups.show`
    -- leaves it at, not merely that some function got called.
    it("raises the first-run popup above the options panel, same as every other popup", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      local frame = { level = 5 }
      function frame:SetFrameStrata(s) self.strata = s end
      function frame:GetFrameStrata() return self.strata end
      function frame:SetFrameLevel(l) self.level = l end
      function frame:GetFrameLevel() return self.level end
      function frame:HookScript() end
      _G.StaticPopup_Show = function() return frame end
      Wizard.maybeShowFirstRun()
      assert.equal("FULLSCREEN_DIALOG", frame:GetFrameStrata())
      assert.equal(106, frame:GetFrameLevel())
    end)

    it("also drops the D39 first-login Status line, so it is not missed if the popup is", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      local said = {}
      ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
      Wizard.maybeShowFirstRun()
      assert.equal(1, #said)
      assert.equal("status", said[1][1])
      assert.equal("Elmira is not set up yet. Open Rotations to pick a playstyle.", said[1][2])
    end)

    it("does nothing with no profile or character database at all", function()
      ns.db = nil
      assert.is_false(Wizard.maybeShowFirstRun())
    end)

    it("does nothing, without erroring, when StaticPopup is not available", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      _G.StaticPopupDialogs, _G.StaticPopup_Show = nil, nil
      assert.is_false(Wizard.maybeShowFirstRun())
    end)

    it("registers a real StaticPopup: no timeout, survives death, closeable with Escape", function()
      local dialog = _G.StaticPopupDialogs.ELMIRA_FIRST_RUN
      assert.equal("%s", dialog.text)
      assert.equal(0, dialog.timeout)
      assert.is_true(dialog.whileDead)
      assert.is_true(dialog.hideOnEscape)
    end)

    it("does not re-register the dialog on a second load", function()
      local first = _G.StaticPopupDialogs.ELMIRA_FIRST_RUN
      Wizard = helper.load("Elmira/Setup/Wizard.lua")
      assert.equal(first, _G.StaticPopupDialogs.ELMIRA_FIRST_RUN)
    end)

    it("loads without erroring when StaticPopupDialogs does not exist yet at all", function()
      _G.StaticPopupDialogs = nil
      assert.has_no.errors(function() Wizard = helper.load("Elmira/Setup/Wizard.lua") end)
    end)

    it("resetFirstRunOffer lets it be offered again without a fresh login", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      assert.is_true(Wizard.maybeShowFirstRun())
      assert.is_false(Wizard.maybeShowFirstRun())
      Wizard.resetFirstRunOffer()
      assert.is_true(Wizard.maybeShowFirstRun())
    end)

    -- A pack with a `catalog` table for the class but nothing IN it is the same as no catalog: the
    -- Rotations tree would show the empty "No playstyles" page either way.
    it("treats an empty catalog list the same as no catalog at all", function()
      ns.Display = { currentPack = function()
        return { class = "PALADIN", catalog = { PALADIN = {} } }
      end }
      local renamed
      _G.StaticPopup_Show = function() return { button1 = { SetText = function(_, t) renamed = t end } } end
      Wizard.maybeShowFirstRun()
      assert.equal("Build a rotation", renamed)
    end)

    -- D48's consequence: the tree lists a playstyle with no rotation behind it (muted), so "the
    -- catalog has entries" stopped meaning "there is something to choose". The popup asks the
    -- second question -- otherwise it sends a player to a tree where every Use says "not shipped".
    it("offers 'Build a rotation' when every catalog entry is one the pack cannot run", function()
      install(packWith({
        { build = "PALADIN_TWIST", available = false, playstyle = "Twist" },
        { build = "PALADIN_GHOST", available = true, playstyle = "Ghost" },   -- no build file
      }, { builds = {} }))
      local renamed
      _G.StaticPopup_Show = function() return { button1 = { SetText = function(_, t) renamed = t end } } end
      Wizard.maybeShowFirstRun()
      assert.equal("Build a rotation", renamed)
    end)

    it("names the detected class in the no-catalog sentence", function()
      ns.Display = { currentPack = function() return { class = "PALADIN" } end }
      ns.Adapter.playerClass = function() return "PALADIN" end
      local shown
      _G.StaticPopup_Show = function(_, text) shown = text; return {} end
      Wizard.maybeShowFirstRun()
      assert.is_truthy(shown:find("PALADIN", 1, true))
      assert.is_truthy(shown:find("build your own from your spellbook", 1, true))
    end)

    it("carries the detection line in the catalog case's popup text", function()
      install(packWith{ { build = "PALADIN_EXODIN", available = true } })
      ns.Adapter.playerClass = function() return "PALADIN" end
      ns.API.GetState = function()
        return { level = function() return 60 end, weapon = function() return { type = "2H" } end,
                 enchant = function() return nil end, rune = function() return nil end,
                 setCount = function() return 0 end }
      end
      local shown
      _G.StaticPopup_Show = function(_, text) shown = text; return {} end
      Wizard.maybeShowFirstRun()
      assert.is_truthy(shown:find("Level 60 PALADIN, holding a 2H", 1, true))
      assert.is_truthy(shown:find("not set up yet", 1, true))
    end)
  end)
end)
