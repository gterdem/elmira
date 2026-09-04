local helper = require("tests.helper")

-- Elmira/Display/Driver.lua — the tick decision: recompute, repaint, or do nothing.
--
-- Two behaviours here have no other home. VISIBILITY: the display used to run from login to logout
-- with no concept of being off, so it glowed a player's action bar while they stood in a city and
-- burned ticks doing it. HIDDEN is now a first-class tick outcome, and the transition into it must
-- paint once — a queue that merely stops updating leaves the strip on screen and a bar button lit.
-- ERROR REPORTING: a broken renderer errors on every queue change, which in combat is several times
-- a second.
describe("Display.Driver", function()
  local Display, ns, rendered, logged

  local function stubQueue(queue, key)
    Display.computeQueue = function() return queue, key end
  end

  local function stubState(inCombat, hasTarget)
    ns.API = { GetState = function()
      return { inCombat = function() return inCombat end,
               targetExists = function() return hasTarget end }
    end }
  end

  before_each(function()
    ns = helper.reset()
    rendered, logged = {}, {}
    ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
    helper.load("Elmira/Core/Ticker.lua")
    helper.load("Elmira/Core/Visibility.lua")
    Display = helper.load("Elmira/Display/Driver.lua")
    ns.db = { profile = { enabled = true, depth = 3, visibility = "always" } }
    stubState(false, false)
    stubQueue({ { spell = "EXORCISM" } }, "PALADIN_EXODIN")
    Display.register("test", function(queue, key, visible)
      rendered[#rendered + 1] = { queue = queue, key = key, visible = visible }
    end)
  end)

  -- Ticks are throttled to 10 Hz, so every step advances well past that.
  local t = 0
  local function tick()
    t = t + 1
    return Display.tick(t)
  end

  describe("visibility", function()
    it("renders when the mode says always, whatever the combat state is", function()
      assert.equal("rendered", tick())
      assert.equal(1, #rendered)
      assert.is_true(rendered[1].visible)
    end)

    it("does not compute a queue at all while hidden", function()
      ns.db.profile.visibility = "combat"
      local computed = false
      Display.computeQueue = function() computed = true; return {}, "k" end
      assert.equal("hidden", tick())
      assert.is_false(computed)
    end)

    it("paints the hidden state exactly once, then stops doing anything", function()
      ns.db.profile.visibility = "combat"
      assert.equal("hidden", tick())
      assert.equal(1, #rendered)
      assert.is_nil(rendered[1].queue)      -- renderers must be able to tell "hide" from "empty"
      assert.is_false(rendered[1].visible)
      assert.equal("hidden", tick())
      assert.equal("hidden", tick())
      assert.equal(1, #rendered)            -- still one: a hidden tick is free
    end)

    it("repaints when combat starts, and again when it ends", function()
      ns.db.profile.visibility = "combat"
      assert.equal("hidden", tick())
      stubState(true, false)
      assert.equal("rendered", tick())
      assert.is_true(rendered[#rendered].visible)
      stubState(false, false)
      assert.equal("hidden", tick())
      assert.is_false(rendered[#rendered].visible)
    end)

    it("a target alone shows it under the default mode but not under 'combat'", function()
      ns.db.profile.visibility = "combat_or_target"
      stubState(false, true)
      assert.equal("rendered", tick())
      ns.db.profile.visibility = "combat"
      Display.refresh()
      assert.equal("hidden", tick())
    end)

    it("the master switch hides it regardless of mode", function()
      ns.db.profile.enabled = false
      ns.db.profile.visibility = "always"
      assert.equal("hidden", tick())
      local _, reason = Display.shouldShow()
      assert.equal("display disabled", reason)
    end)

    it("a state that errors shows the display rather than hiding it silently", function()
      ns.API = { GetState = function() return { inCombat = function() error("boom") end } end }
      assert.equal("rendered", tick())
    end)

    it("stats carry the visibility decision and its reason", function()
      ns.db.profile.visibility = "combat"
      tick()
      local s = Display.stats()
      assert.is_false(s.visible)
      assert.equal("out of combat", s.visibleReason)
      assert.equal("combat", s.mode)
    end)
  end)

  -- Display.stats() is what `/elm debug perf` reads. lastBuildKey is only set by a RENDER, so before
  -- M4b it was nil whenever the display was hidden -- most of a session, and exactly when someone
  -- runs this to ask why the screen is empty.
  -- ADR-0010: a pinned fork resolves and compiles exactly like a shipped build. Real Schema,
  -- Profiles and UserBuilds; the pack is the shipped paladin data.
  describe("activeBuild() with a fork pinned", function()
    it("compiles the fork under its own key", function()
      helper.load("Elmira/Adapters/Interface.lua")
      helper.load("Elmira/Core/Schema.lua")
      helper.load("Elmira/Core/Profiles.lua")
      helper.load("Elmira/Core/UserBuilds.lua")
      ns.compileBuild = ns.compileBuild or function(b, ctx) return ns.Schema.compile(b, ctx) end
      local pack = helper.classPack("Paladin")
      ns.API = { GetProviders = function() return { PALADIN = pack } end }
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      local fork = {}
      for k, v in pairs(pack.builds.PALADIN_EXODIN) do fork[k] = v end
      fork.key = "USER_MINE"
      ns.db = { profile = { activeBuild = "USER_MINE" },
                global = { userBuilds = { USER_MINE = { class = "PALADIN", build = fork } } } }
      local compiled, key, reason = Display.activeBuild()
      assert.equal("USER_MINE", key)
      assert.equal("pinned", reason)
      assert.is_table(compiled)
      assert.equal("USER_MINE", compiled.key)
      assert.is_true(#compiled.entries > 10)
    end)
  end)

  describe("stats() build resolution", function()
    it("resolves a build via activeBuild() when nothing has rendered yet, carrying the reason", function()
      -- No tick() has run: lastBuildKey is unset. ns.API is unset by default (before_each only sets
      -- ns.db), so the real activeBuild() takes the "no data pack for this class" path.
      local s = Display.stats()
      assert.is_nil(s.build)
      assert.equal("no data pack for this class", s.buildReason)
    end)

    it("reports the RENDERED build key once a tick has painted, with no buildReason attached", function()
      assert.equal("rendered", tick())
      local s = Display.stats()
      assert.equal("PALADIN_EXODIN", s.build)
      assert.is_nil(s.buildReason)
    end)

    it("does not re-resolve via activeBuild() once a render has already set the key", function()
      assert.equal("rendered", tick())
      -- A decoy: if stats() called activeBuild() again despite already having a real build key, this
      -- would leak through instead of the rendered one.
      Display.activeBuild = function() return {}, "DECOY", "should never be read" end
      local s = Display.stats()
      assert.equal("PALADIN_EXODIN", s.build)
      assert.is_nil(s.buildReason)
    end)
  end)

  describe("renderer errors", function()
    it("reports the same error once, not on every queue change", function()
      Display.register("broken", function() error("kaboom") end)
      tick()
      stubQueue({ { spell = "JUDGEMENT" } }, "PALADIN_EXODIN")
      tick()
      stubQueue({ { spell = "CONSECRATION" } }, "PALADIN_EXODIN")
      tick()
      assert.equal(1, #logged)
      assert.truthy(logged[1]:find("kaboom", 1, true))
    end)

    it("reports again once the error changes, and after a renderer recovers", function()
      local message = "first"
      Display.register("broken", function() error(message) end)
      tick()
      message = "second"
      stubQueue({ { spell = "JUDGEMENT" } }, "PALADIN_EXODIN")
      tick()
      assert.equal(2, #logged)
    end)

    it("one broken renderer does not stop the others", function()
      Display.register("broken", function() error("kaboom") end)
      tick()
      assert.equal(1, #rendered)
    end)
  end)
end)
